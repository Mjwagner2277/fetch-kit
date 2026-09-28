#!/usr/bin/env python3
"""Validate and publish fetch-kit npm bundles using only Python's standard library.

No npm, Node.js, shell, package lifecycle scripts, or external tar program runs.
The npm PUT payload follows npm/cli workspaces/libnpmpublish/lib/publish.js.
"""

import argparse
import base64
import copy
import datetime
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import ssl
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


NUMERIC = r"(?:0|[1-9][0-9]*)"
PRERELEASE = r"(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)"
SEMVER = re.compile(r"(" + NUMERIC + r")\.(" + NUMERIC + r")\.(" + NUMERIC +
                    r")(?:-(" + PRERELEASE + r"(?:\." + PRERELEASE +
                    r")*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?")


def semver_key(version):
    """SemVer precedence: numeric components, prereleases below stable, no build metadata."""
    match = SEMVER.fullmatch(version) if isinstance(version, str) else None
    if not match:
        raise BundleError("Invalid semantic version in registry metadata")
    major, minor, patch, prerelease = match.groups()
    identifiers = tuple((0, int(part)) if part.isdigit() else (1, part)
                        for part in prerelease.split(".")) if prerelease else ()
    return int(major), int(minor), int(patch), 0 if prerelease else 1, identifiers


class BundleError(Exception):
    """A validation or registry failure safe to print without credentials."""


class RegistryError(BundleError):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    temporary.replace(path)


def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError) as exc:
        raise BundleError("Invalid JSON file: " + str(path)) from exc


def member_path(name):
    if not isinstance(name, str) or "\\" in name or "\x00" in name:
        raise BundleError("Unsafe archive path")
    while name.startswith("./"):
        name = name[2:]
    path = PurePosixPath(name)
    if not name or not path.parts or path.is_absolute() or ".." in path.parts or ":" in path.parts[0]:
        raise BundleError("Unsafe archive path: " + name)
    return path


def local_file(root, relative):
    path = member_path(relative)
    candidate = root.joinpath(*path.parts)
    current = root
    for part in path.parts:
        current = current / part
        if current.is_symlink():
            raise BundleError("Symlinks are not allowed in bundle paths: " + relative)
    if not candidate.is_file():
        raise BundleError("Missing bundle file: " + relative)
    return candidate


def checked_members(archive, max_bytes, package=False):
    seen = set()
    total = 0
    members = []
    for member in archive:
        # A leading './' directory is common in tar output and contains no data.
        if member.isdir() and member.name.rstrip("/") in (".", ""):
            continue
        path = member_path(member.name)
        canonical = str(path)
        if package and path.parts[0] != "package":
            raise BundleError("Package tarball member is outside package/: " + canonical)
        if not (member.isdir() or member.isfile()):
            raise BundleError("Archive links and special files are not supported: " + canonical)
        if canonical in seen:
            raise BundleError("Duplicate archive path: " + canonical)
        seen.add(canonical)
        if member.size < 0:
            raise BundleError("Negative archive member size")
        total += member.size
        if total > max_bytes:
            raise BundleError("Archive exceeds --max-unpacked-bytes")
        members.append((member, path))
    # A file must never be the parent of another archive entry.
    files = {str(path) for member, path in members if member.isfile()}
    for _, path in members:
        if any(str(parent) in files for parent in path.parents):
            raise BundleError("Archive file is also a directory: " + str(path))
    return members


def unpack_bundle(source, destination, max_bytes):
    destination.mkdir(parents=True, exist_ok=False)
    try:
        with tarfile.open(source, "r:*") as archive:
            members = checked_members(archive, max_bytes)
            for member, relative in members:
                target = destination.joinpath(*relative.parts)
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with archive.extractfile(member) as content, target.open("xb") as output:
                        shutil.copyfileobj(content, output)
    except (tarfile.TarError, OSError, EOFError) as exc:
        raise BundleError("Cannot read transfer bundle archive") from exc
    candidates = {p.parent for name in ("packages.json", "packages.jsonl") for p in destination.rglob(name)}
    if len(candidates) != 1:
        raise BundleError("Transfer archive must contain exactly one bundle manifest directory")
    return candidates.pop()


def digest_file(path):
    algorithms = {name: hashlib.new(name) for name in ("sha1", "sha256", "sha384", "sha512")}
    size = 0
    with path.open("rb") as source:
        for data in iter(lambda: source.read(1024 * 1024), b""):
            size += len(data)
            for digest in algorithms.values():
                digest.update(data)
    result = {name: digest.hexdigest() for name, digest in algorithms.items()}
    result["bytes"] = size
    result["integrity"] = "sha512-" + base64.b64encode(algorithms["sha512"].digest()).decode("ascii")
    return result


def integrity_matches(value, hashes):
    """SRI selects the strongest recognized algorithm, including alternatives."""
    if not isinstance(value, str):
        return False
    tokens = {}
    for token in value.split():
        match = re.fullmatch(r"(sha1|sha256|sha384|sha512)-([A-Za-z0-9+/=]+)(?:\?\S*)?", token)
        if match:
            tokens.setdefault(match[1], []).append(match[2])
    for algorithm in ("sha512", "sha384", "sha256", "sha1"):
        if algorithm in tokens:
            expected = base64.b64encode(bytes.fromhex(hashes[algorithm])).decode("ascii")
            return expected in tokens[algorithm]
    return False


def validate_identity(name, version):
    if not isinstance(name, str) or not re.fullmatch(r"(?:@[A-Za-z0-9._~-]+/)?[A-Za-z0-9._~-]+", name) or any(part.lstrip("@") in (".", "..") for part in name.split("/")):
        raise BundleError("Invalid npm package name in manifest")
    if not isinstance(version, str) or not SEMVER.fullmatch(version):
        raise BundleError("Invalid npm package version for " + name)


def load_manifest(bundle):
    if (bundle / "packages.json").is_file():
        entries = read_json(local_file(bundle, "packages.json"))
    elif (bundle / "packages.jsonl").is_file():
        try:
            entries = [json.loads(line) for line in local_file(bundle, "packages.jsonl").read_text(encoding="utf-8").splitlines() if line.strip()]
        except (OSError, UnicodeError, ValueError) as exc:
            raise BundleError("Invalid packages.jsonl") from exc
    else:
        raise BundleError("Bundle needs packages.json or packages.jsonl with tarball hashes")
    if not isinstance(entries, list) or not entries:
        raise BundleError("Manifest must be a nonempty array of package records")
    seen = set()
    paths = set()
    for entry in entries:
        if not isinstance(entry, dict):
            raise BundleError("Manifest record must be an object")
        validate_identity(entry.get("name"), entry.get("version"))
        key = (entry["name"], entry["version"])
        if key in seen:
            raise BundleError("Duplicate package identity: " + "@".join(key))
        seen.add(key)
        tarball = str(member_path(entry.get("tarball")))
        if PurePosixPath(tarball).parts[0] in {"packages.json", "packages.jsonl", "package.json", "package-lock.json", "package-lock.original.json", "root-packages.json", "artifactory-upload-manifest.tsv"}:
            raise BundleError("Tarball path conflicts with bundle metadata: " + tarball)
        if tarball in paths:
            raise BundleError("Duplicate tarball path in manifest")
        paths.add(tarball)
        entry["tarball"] = tarball
    return entries


def validate_hashes(entry, hashes):
    checked = False
    for algorithm in ("sha1", "sha256", "sha384", "sha512"):
        if algorithm in entry:
            value = entry[algorithm]
            if not isinstance(value, str) or value.lower() != hashes[algorithm]:
                raise BundleError("Manifest " + algorithm + " mismatch for " + entry["name"] + "@" + entry["version"])
            checked = True
    if "integrity" in entry:
        if not integrity_matches(entry["integrity"], hashes):
            raise BundleError("Manifest integrity mismatch for " + entry["name"] + "@" + entry["version"])
        checked = True
    if not checked:
        raise BundleError("Manifest record has no supported tarball hash: " + entry["name"])
    if "bytes" in entry and (isinstance(entry["bytes"], bool) or entry["bytes"] != hashes["bytes"]):
        raise BundleError("Manifest byte count mismatch for " + entry["name"])


def inspect_package(source, entry, sanitize, max_bytes, output):
    replacements = {}
    removed = []
    package_json = None
    label = entry["tarball"] if entry is not None else str(source)
    try:
        with tarfile.open(source, "r:gz") as archive:
            members = checked_members(archive, max_bytes, package=True)
            for member, path in members:
                # Examples and tests may contain intentionally invalid JSON;
                # only installed package manifests participate in lifecycles.
                is_manifest = re.fullmatch(r"package/(?:node_modules/(?:@[^/]+/)?[^/]+/)*package\.json", str(path))
                if member.isfile() and is_manifest:
                    if member.size > 16 * 1024 * 1024:
                        raise BundleError("package.json exceeds 16 MiB")
                    try:
                        with archive.extractfile(member) as content:
                            metadata = json.loads(content.read().decode("utf-8"))
                    except (ValueError, UnicodeError) as exc:
                        raise BundleError("Invalid JSON in " + str(path)) from exc
                    if not isinstance(metadata, dict):
                        raise BundleError("package.json must be a JSON object")
                    fields = [field for field in ("scripts", "private", "publishConfig") if field in metadata]
                    if sanitize and fields:
                        for field in fields:
                            del metadata[field]
                        replacements[member.name] = (json.dumps(metadata, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
                        removed.append({"path": str(path), "fields": fields})
                    if str(path) == "package/package.json":
                        package_json = metadata
            if package_json is None:
                raise BundleError("Tarball lacks package/package.json: " + label)
            validate_identity(package_json.get("name"), package_json.get("version"))
            if entry is not None and (package_json.get("name"), package_json.get("version")) != (entry["name"], entry["version"]):
                raise BundleError("Tarball package identity mismatch for " + entry["name"] + "@" + entry["version"])
            if output is None:
                return package_json, removed
            output.parent.mkdir(parents=True, exist_ok=True)
            if replacements:
                with output.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as zipped:
                    with tarfile.open(fileobj=zipped, mode="w", format=tarfile.PAX_FORMAT) as target:
                        for member, _ in members:
                            member = copy.copy(member)
                            member.pax_headers = dict(member.pax_headers)
                            if member.name in replacements:
                                data = replacements[member.name]
                                member.size = len(data)
                                member.pax_headers.pop("size", None)
                                target.addfile(member, io.BytesIO(data))
                            elif member.isfile():
                                with archive.extractfile(member) as content:
                                    target.addfile(member, content)
                            else:
                                target.addfile(member)
            else:
                shutil.copyfile(source, output)
    except (tarfile.TarError, OSError, EOFError) as exc:
        raise BundleError("Cannot inspect package tarball: " + label) from exc
    return package_json, removed


def discover_packages(directory, max_bytes, work):
    """Inventory loose npm archives without a manifest or any package execution."""
    entries = {}
    work_path = work.resolve()

    def walk_error(error):
        raise BundleError("Cannot read packages directory: " + str(error.filename))

    for folder, directories, filenames in os.walk(directory, followlinks=False, onerror=walk_error):
        folder = Path(folder)
        retained = []
        for name in sorted(directories):
            child = folder / name
            if child.resolve() == work_path:
                continue
            if child.is_symlink():
                raise BundleError("Symlink directories are not supported in --packages-dir: " + str(child))
            retained.append(name)
        directories[:] = retained
        for filename in sorted(filenames):
            if not filename.lower().endswith((".tgz", ".tar.gz")):
                continue
            relative = (folder / filename).relative_to(directory).as_posix()
            source = local_file(directory, relative)
            hashes = digest_file(source)
            metadata, _ = inspect_package(source, None, False, max_bytes, None)
            name, version = metadata["name"], metadata["version"]
            key = (name, version)
            if key in entries:
                entry = entries[key]
                if entry["sha512"] != hashes["sha512"]:
                    raise BundleError("Conflicting tarballs for " + name + "@" + version + ": " + entry["sourceTarball"] + " and " + relative)
                entry["sourceFiles"].append(relative)
                continue
            safe_name = re.sub(r"[^A-Za-z0-9._-]", "-", name)
            identity_hash = hashlib.sha256((name + "@" + version).encode("utf-8")).hexdigest()[:12]
            entries[key] = {
                "name": name, "version": version, "package": name + "@" + version,
                "tarball": "tarballs/" + safe_name + "-" + version + "-" + identity_hash + ".tgz",
                "sourceTarball": relative, "sourceFiles": [relative],
                "sourceIntegrity": "computed-from-local-file", **hashes,
            }
    if not entries:
        raise BundleError("No npm .tgz or .tar.gz packages found in --packages-dir")
    return sorted(entries.values(), key=lambda entry: (entry["name"], semver_key(entry["version"]), entry["version"]))


def registry_tarball_url(registry, name, version):
    # Artifactory uses the usual scoped route: @scope/name/-/name-version.tgz.
    filename = name.rsplit("/", 1)[-1] + "-" + version + ".tgz"
    return registry + urllib.parse.quote(name, safe="@/") + "/-/" + urllib.parse.quote(filename, safe="")


def name_from_lock_path(lock_path):
    tail = lock_path.rsplit("node_modules/", 1)[-1]
    parts = tail.split("/")
    return "/".join(parts[:2]) if tail.startswith("@") else parts[0]


def rewrite_lock(lock, entries, registry, sanitize_bundled=False):
    by_key = {(entry["name"], entry["version"]): entry for entry in entries}
    rewrites = 0

    def update(meta, default_name):
        nonlocal rewrites
        if not isinstance(meta, dict) or meta.get("link"):
            return
        if meta.get("inBundle") or meta.get("bundled"):
            if sanitize_bundled:
                for field in ("integrity", "resolved", "hasInstallScript"):
                    meta.pop(field, None)
            return
        name = meta.get("name") or default_name
        version = meta.get("version", "")
        if isinstance(version, str) and version.startswith("npm:"):
            alias = version[4:]
            name, _, version = alias.rpartition("@")
        entry = by_key.get((name, version))
        if entry:
            meta["integrity"] = entry["integrity"]
            meta["resolved"] = registry_tarball_url(registry, entry["name"], entry["version"])
            if entry.get("publishSanitized"):
                meta.pop("hasInstallScript", None)
            rewrites += 1

    packages = lock.get("packages", {})
    if isinstance(packages, dict):
        for lock_path, metadata in packages.items():
            if lock_path:
                update(metadata, name_from_lock_path(lock_path))

    def dependencies(values):
        if not isinstance(values, dict):
            return
        for name, metadata in values.items():
            if isinstance(metadata, dict):
                update(metadata, name)
                dependencies(metadata.get("dependencies"))

    dependencies(lock.get("dependencies"))
    return rewrites


def prepare_bundle(bundle, destination, args, source_entries=None):
    directory_input = source_entries is not None
    if source_entries is None:
        source_entries = load_manifest(bundle)
    entries = []
    prepared = []
    destination.mkdir(parents=True, exist_ok=False)
    for original in source_entries:
        source = local_file(bundle, original["sourceTarball"] if directory_input else original["tarball"])
        before = digest_file(source)
        validate_hashes(original, before)
        entry = copy.deepcopy(original)
        output = destination / entry["tarball"]
        metadata, removed = inspect_package(source, entry, args.sanitize_scripts, args.max_unpacked_bytes, output)
        if digest_file(source)["sha512"] != before["sha512"]:
            raise BundleError("Source tarball changed while being prepared: " + entry["tarball"])
        after = digest_file(output)
        if not removed and after["sha512"] != before["sha512"]:
            raise BundleError("Prepared tarball differs from the verified source: " + entry["tarball"])
        entry.update(after)
        if args.sanitize_scripts:
            entry["publishSanitized"] = True
            entry["publishSanitizedFields"] = sorted({field for change in removed for field in change["fields"]} | set(entry.get("publishSanitizedFields", [])))
            entry["sanitizedPackageJsonFiles"] = removed
        entry["packageJsonValidated"] = True
        entries.append(entry)
        prepared.append({"entry": entry, "metadata": metadata, "path": output, "changed": before["sha512"] != after["sha512"], "removed": removed})
    for filename in ("package.json", "package-lock.original.json", "root-packages.json"):
        if not directory_input and (bundle / filename).exists():
            shutil.copyfile(local_file(bundle, filename), destination / filename)
    lock_count = 0
    if not directory_input and (bundle / "package-lock.json").exists():
        lock_file = local_file(bundle, "package-lock.json")
        lock = read_json(lock_file)
        if not isinstance(lock, dict):
            raise BundleError("package-lock.json must be an object")
        if not (destination / "package-lock.original.json").exists():
            shutil.copyfile(lock_file, destination / "package-lock.original.json")
        lock_count = rewrite_lock(lock, entries, args.registry_url, args.sanitize_scripts)
        write_json(destination / "package-lock.json", lock)
    write_json(destination / "packages.json", entries)
    (destination / "packages.jsonl").write_text("".join(json.dumps(entry, ensure_ascii=False) + "\n" for entry in entries), encoding="utf-8")
    (destination / "artifactory-upload-manifest.tsv").write_text("".join("\t".join((entry["name"], entry["version"], entry["tarball"])) + "\n" for entry in entries), encoding="utf-8")
    return prepared, lock_count


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        # Never forward registry Authorization to a redirect target.
        return None


class Registry:
    def __init__(self, args):
        context = ssl.create_default_context(cafile=args.ca_file)
        self.opener = urllib.request.build_opener(NoRedirect(), urllib.request.HTTPSHandler(context=context))
        self.registry = args.registry_url
        self.timeout = args.timeout
        self.auth = None
        if args.token:
            self.auth = "Bearer " + args.token
        elif args.username is not None:
            self.auth = "Basic " + base64.b64encode((args.username + ":" + args.password).encode("utf-8")).decode("ascii")

    def request(self, method, name, body=None, tag=None):
        route = urllib.parse.quote(name, safe="@")
        if tag is not None:
            route = "-/package/" + route + "/dist-tags/" + urllib.parse.quote(tag, safe="")
        url = self.registry + route
        headers = {"Accept": "application/json", "User-Agent": "fetch-kit-python-stdlib/1", "Cache-Control": "no-cache"}
        if self.auth:
            headers["Authorization"] = self.auth
        data = None
        if body is not None:
            headers["Content-Type"] = "application/json"
            data = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                if method in ("PUT", "DELETE"):
                    return None
                raw = response.read(64 * 1024 * 1024 + 1)
                if len(raw) > 64 * 1024 * 1024:
                    raise BundleError("Registry package metadata exceeds 64 MiB")
                value = json.loads(raw.decode("utf-8"))
                if not isinstance(value, dict):
                    raise BundleError("Registry returned invalid package metadata")
                return value
        except urllib.error.HTTPError as exc:
            if (method == "GET" or (method == "DELETE" and tag is not None)) and exc.code == 404:
                return {}
            raise RegistryError(exc.code, method + " failed with HTTP " + str(exc.code) + " for " + name + (" (redirects are disabled)" if 300 <= exc.code < 400 else "")) from None
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise RegistryError(None, method + " connection failed for " + name + "; check registry connectivity and certificate trust") from None
        except (ValueError, UnicodeError) as exc:
            raise BundleError("Registry returned invalid JSON for " + name) from exc


def remote_version(packument, version):
    versions = packument.get("versions", {})
    if not isinstance(versions, dict):
        raise BundleError("Registry returned invalid versions metadata")
    return versions.get(version)


def check_existing(packument, entry):
    remote = remote_version(packument, entry["version"])
    if remote is None:
        return False
    if not isinstance(remote, dict) or not isinstance(remote.get("dist"), dict):
        raise BundleError("Existing version has no verifiable content hash: " + entry["name"] + "@" + entry["version"])
    dist = remote["dist"]
    checks = []
    if "integrity" in dist:
        checks.append(integrity_matches(dist["integrity"], entry))
    if "shasum" in dist:
        checks.append(isinstance(dist["shasum"], str) and dist["shasum"].lower() == entry["sha1"])
    if not checks or not all(checks):
        raise BundleError("Existing version content differs or cannot be verified: " + entry["name"] + "@" + entry["version"])
    return True


def publish_payload(package, registry, tag):
    entry = package["entry"]
    metadata = copy.deepcopy(package["metadata"])
    # dist signatures/attestations refer to upstream bytes and cannot be copied.
    metadata["_id"] = entry["name"] + "@" + entry["version"]
    metadata["dist"] = {"shasum": entry["sha1"], "integrity": entry["integrity"], "tarball": registry_tarball_url(registry, entry["name"], entry["version"])}
    filename = entry["name"] + "-" + entry["version"] + ".tgz"
    return {"_id": entry["name"], "name": entry["name"], "description": metadata.get("description", ""), "dist-tags": {tag: entry["version"]}, "versions": {entry["version"]: metadata}, "_attachments": {filename: {"content_type": "application/octet-stream", "data": base64.b64encode(package["path"].read_bytes()).decode("ascii"), "length": entry["bytes"]}}}


def latest_value(packument):
    tags = packument.get("dist-tags", {})
    if not isinstance(tags, dict):
        raise BundleError("Registry returned invalid dist-tags metadata")
    value = tags.get("latest")
    if value is not None:
        semver_key(value)
        if remote_version(packument, value) is None:
            raise BundleError("Registry latest tag points to a missing version")
    return value


def reconcile_latest(registry, name, before, policy):
    """Reconcile once after publication, without relying on upload timestamps.

    The npm tag API offers no compare-and-swap. Use one writer per package;
    verification detects a conflicting result but is not a distributed lock.
    """
    document = registry.request("GET", name)
    current = latest_value(document)
    if before is not None and remote_version(document, before) is None:
        raise BundleError("Cannot reconcile latest: original version is no longer in the registry")
    desired = before
    reason = "preserve"
    if policy == "computed":
        versions = document.get("versions", {})
        if not isinstance(versions, dict):
            raise BundleError("Registry returned invalid versions metadata")
        stable = [version for version in versions if semver_key(version)[3] == 1]
        if before is not None and semver_key(before)[3] == 0:
            # A prerelease explicitly tagged before the run is an existing
            # release-channel decision; don't replace it with our stable policy.
            reason = "preserve-existing-prerelease"
        elif stable:
            highest = max(semver_key(version) for version in stable)
            candidates = [version for version in stable if semver_key(version) == highest]
            if before in candidates:
                desired = before
            elif current in candidates:
                desired = current
            else:
                desired = sorted(candidates, key=lambda value: ("+" in value, value))[0]
            reason = "highest-stable"
        else:
            desired = None
            reason = "no-stable-version"
    if desired is not None and remote_version(document, desired) is None:
        raise BundleError("Cannot restore latest: original version is no longer in the registry")
    changed = current != desired
    if changed:
        if desired is None:
            registry.request("DELETE", name, tag="latest")
        else:
            registry.request("PUT", name, desired, tag="latest")
        verified = registry.request("GET", name)
        if latest_value(verified) != desired:
            raise BundleError("Latest tag verification failed; registry settings or another writer changed the requested tag")
    return {"name": name, "before": before, "observedAfterUpload": current, "latest": desired,
            "status": "updated" if changed else "unchanged", "reason": reason}


def publish_one(registry, package, args, tag, initial_latest):
    entry = package["entry"]
    for attempt in range(args.publish_retries + 1):
        try:
            existing = registry.request("GET", entry["name"])
            if entry["name"] not in initial_latest:
                initial_latest[entry["name"]] = latest_value(existing)
            if check_existing(existing, entry):
                if not args.skip_existing:
                    raise BundleError("Version already exists and --no-skip-existing was requested")
                return "skipped-existing", attempt
            registry.request("PUT", entry["name"], publish_payload(package, args.registry_url, tag))
            verified = registry.request("GET", entry["name"])
            if not check_existing(verified, entry):
                raise BundleError("Publish returned success but version is absent during verification")
            return "published", attempt + 1
        except RegistryError as exc:
            # A failed/uncertain PUT may have succeeded. Recheck on the next loop.
            if exc.status not in (None, 403, 409, 429, 500, 502, 503, 504) or attempt >= args.publish_retries:
                raise
            time.sleep(min(args.retry_delay * (2 ** attempt), 10))
    raise BundleError("Publish retries exhausted")


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--bundle-dir", "--bundle", type=Path, help="Unpacked fetch-kit bundle directory")
    source.add_argument("--bundle-tar", type=Path, help="Transfer tar/tar.gz archive")
    source.add_argument("--packages-dir", "--tarball-dir", type=Path, help="Directory of npm .tgz/.tar.gz packages, scanned recursively; no manifest or lockfile needed")
    parser.add_argument("--registry-url", "--registry", required=True, help="Artifactory npm local repository URL, e.g. https://host/artifactory/api/npm/npm-local/")
    parser.add_argument("--token", default=os.environ.get("ARTIFACTORY_TOKEN"), help="Bearer token (prefer ARTIFACTORY_TOKEN to avoid shell history)")
    parser.add_argument("--username", default=os.environ.get("ARTIFACTORY_USERNAME"))
    parser.add_argument("--password", default=os.environ.get("ARTIFACTORY_PASSWORD"), help="Basic-auth password (prefer ARTIFACTORY_PASSWORD)")
    parser.add_argument("--ca-file", help="PEM certificate authority file")
    parser.add_argument("--work-dir", type=Path, help="Durable output directory (must be empty); defaults to a new directory in the current directory")
    parser.add_argument("--sanitize-scripts", action="store_true", help="Remove scripts/private/publishConfig from root and bundled dependency manifests; emit updated tarballs, manifest, and lock")
    parser.add_argument("--dry-run", action="store_true", help="Validate and prepare locally; make no network requests")
    parser.add_argument("--latest-policy", choices=("computed", "preserve"), default="computed", help="After sequential uploads, set latest to the highest destination stable version (default), or preserve its pre-run value; existing prerelease latest is preserved in either mode")
    parser.add_argument("--allow-http", action="store_true", help="Explicitly allow an unencrypted HTTP registry")
    parser.add_argument("--no-skip-existing", dest="skip_existing", action="store_false", help="Fail even when an existing version has identical content")
    parser.add_argument("--skip-existing", dest="skip_existing", action="store_true", default=True, help="Skip existing versions only when hashes match (default)")
    parser.add_argument("--timeout", type=float, default=60, help="HTTP timeout in seconds (default: 60)")
    parser.add_argument("--publish-retries", type=int, default=2)
    parser.add_argument("--retry-delay", type=float, default=1, help="Initial retry delay in seconds")
    parser.add_argument("--max-unpacked-bytes", type=int, default=4 * 1024 ** 3, help="Maximum total uncompressed bytes in each archive (default: 4 GiB)")
    args = parser.parse_args(argv)
    parsed = urllib.parse.urlsplit(args.registry_url)
    if parsed.scheme not in ("https", "http") or not parsed.netloc or parsed.username or parsed.password or parsed.query or parsed.fragment:
        parser.error("--registry-url must be an HTTP(S) repository URL without embedded credentials, query, or fragment")
    if parsed.scheme == "http" and not args.allow_http:
        parser.error("HTTP exposes package data and credentials; use HTTPS or explicitly pass --allow-http")
    if re.search(r"[\x00-\x20\x7f]", args.registry_url):
        parser.error("--registry-url contains invalid whitespace or control characters")
    args.registry_url = args.registry_url.rstrip("/") + "/"
    if args.token and ("\r" in args.token or "\n" in args.token):
        parser.error("Token must not contain newline characters")
    if not args.token and ((args.username is None) != (args.password is None)):
        parser.error("Basic authentication requires both --username and --password (or their environment variables)")
    if args.timeout <= 0 or args.publish_retries < 0 or args.retry_delay < 0 or args.max_unpacked_bytes <= 0:
        parser.error("Timeout and size limit must be positive; retries and delay must be nonnegative")
    return args


def main(argv=None):
    args = arguments(argv)
    work = None
    summary = {"startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(), "registry": args.registry_url, "inputMode": "packages-directory" if args.packages_dir else "bundle", "dryRun": args.dry_run, "sanitizeScripts": args.sanitize_scripts, "latestPolicy": args.latest_policy, "publishOrder": "sequential-semver-ascending", "published": 0, "skippedExisting": 0, "failed": 0, "latestFailed": 0, "latestResults": [], "results": []}
    try:
        if args.work_dir:
            requested_work = args.work_dir.expanduser().absolute()
            if requested_work.is_symlink() or (requested_work.exists() and (not requested_work.is_dir() or any(requested_work.iterdir()))):
                raise BundleError("--work-dir must be an empty directory")
            requested_work.mkdir(parents=True, exist_ok=True)
            work = requested_work
        else:
            work = Path(tempfile.mkdtemp(prefix="npm-artifactory-upload-", dir=str(Path.cwd())))
        print("Work directory: " + str(work), flush=True)
        bundle = unpack_bundle(args.bundle_tar, work / "extracted", args.max_unpacked_bytes) if args.bundle_tar else (args.packages_dir or args.bundle_dir).expanduser().resolve()
        if not bundle.is_dir():
            raise BundleError("Bundle directory does not exist")
        destination = work / "prepared-bundle"
        source_entries = None
        if args.packages_dir:
            source_entries = discover_packages(bundle, args.max_unpacked_bytes, work)
            write_json(work / "discovered-packages.json", source_entries)
            discovered_count = sum(len(entry["sourceFiles"]) for entry in source_entries)
            summary.update({"sourceDirectory": str(bundle), "discoveredTarballCount": discovered_count,
                            "duplicateTarballCount": discovered_count - len(source_entries),
                            "sourceIntegrity": "computed-from-local-files"})
        prepared, rewritten = prepare_bundle(bundle, destination, args, source_entries)
        prepared.sort(key=lambda package: (package["entry"]["name"], semver_key(package["entry"]["version"]), package["entry"]["version"]))
        summary.update({"bundleDir": str(bundle), "preparedBundleDir": str(destination), "manifestFile": str(destination / "packages.json"), "packageCount": len(prepared), "lockEntriesRewritten": rewritten, "changedTarballs": sum(package["changed"] for package in prepared)})
        if (destination / "package-lock.json").is_file():
            summary["packageLockFile"] = str(destination / "package-lock.json")
            print("Prepared lockfile: " + summary["packageLockFile"], flush=True)
        # All packages, hashes, archive paths, and identities are checked first.
        registry = None if args.dry_run else Registry(args)
        initial_latest = {}
        failed_packages = set()
        for package in prepared:
            entry = package["entry"]
            tag = "airgap-" + entry["version"].replace("+", "-build-")
            result = {"name": entry["name"], "version": entry["version"], "tarball": str(package["path"]), "sha1": entry["sha1"], "sha512": entry["sha512"], "integrity": entry["integrity"], "distTag": tag, "sanitized": package["changed"], "removedFields": package["removed"]}
            try:
                if args.dry_run:
                    result.update({"status": "dry-run", "publishAttempts": 0})
                else:
                    status, attempts = publish_one(registry, package, args, tag, initial_latest)
                    result.update({"status": status, "publishAttempts": attempts})
                    summary["published" if status == "published" else "skippedExisting"] += 1
            except BundleError as exc:
                result.update({"status": "failed", "error": str(exc)})
                summary["failed"] += 1
                failed_packages.add(entry["name"])
            summary["results"].append(result)
            print(result["status"] + " " + entry["name"] + "@" + entry["version"] + (": " + result["error"] if "error" in result else ""), flush=True)
            write_json(work / "upload-results.json", summary["results"])
            write_json(work / "upload-summary.json", summary)
        # All publish requests finish before any final latest tag updates. A
        # partial package failure restores the initial channel instead of
        # promoting the subset that happened to upload successfully.
        for name in sorted({package["entry"]["name"] for package in prepared}):
            if args.dry_run:
                result = {"name": name, "status": "dry-run", "policy": args.latest_policy, "reason": "requires-live-registry-state"}
            elif name not in initial_latest:
                result = {"name": name, "status": "skipped", "reason": "initial-registry-state-unavailable"}
            else:
                policy = "preserve" if name in failed_packages else args.latest_policy
                try:
                    result = reconcile_latest(registry, name, initial_latest[name], policy)
                    result["policy"] = policy
                    if name in failed_packages:
                        result["reason"] = "restore-after-package-failure"
                except BundleError as exc:
                    result = {"name": name, "status": "failed", "error": str(exc)}
                    summary["latestFailed"] += 1
                    summary["failed"] += 1
            summary["latestResults"].append(result)
            print("latest " + result["status"] + " " + name + (": " + result["error"] if "error" in result else ""), flush=True)
            write_json(work / "upload-summary.json", summary)
        if args.dry_run:
            print("Dry run complete: no network requests were made.", flush=True)
    except (BundleError, OSError, ssl.SSLError) as exc:
        # Never include registry response bodies, headers, or authentication.
        summary["error"] = str(exc) if isinstance(exc, BundleError) else "Local I/O or certificate configuration failed"
        summary["failed"] += 1
        print("ERROR: " + summary["error"], file=sys.stderr)
    finally:
        summary["completedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        if work and work.is_dir():
            try:
                write_json(work / "upload-results.json", summary["results"])
                write_json(work / "upload-summary.json", summary)
                print("Report: " + str(work / "upload-summary.json"), flush=True)
            except OSError:
                print("ERROR: Unable to write report", file=sys.stderr)
                summary["failed"] += 1
    return 1 if summary["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())
