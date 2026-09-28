#!/usr/bin/env python3
"""Exercise the stdlib uploader against a local npm protocol fixture.

Run with: python3 -m unittest discover -s npm/tests -p 'test_upload_npm*.py' -v
No npm, third-party Python modules, or external registry is needed.
"""

import base64
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit


UPLOADER = Path(__file__).resolve().parents[1] / "upload-npm-artifactory-bundle.py"
REGISTRY_PREFIX = "/artifactory/api/npm/npm-local/"


def integrity(data):
    return "sha512-" + base64.b64encode(hashlib.sha512(data).digest()).decode("ascii")


def package_tar(metadata, extra_members=()):
    """Build a real npm archive; optional members model unsafe inputs."""
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w:gz") as archive:
        contents = {
            "package/package.json": json.dumps(metadata).encode(),
            "package/index.js": b"module.exports = 42;\n",
            "package/index.d.ts": b"declare const value: number; export = value;\n",
        }
        for name, data in contents.items():
            member = tarfile.TarInfo(name)
            member.size = len(data)
            member.mode = 0o644
            archive.addfile(member, io.BytesIO(data))
        for member, data in extra_members:
            archive.addfile(member, io.BytesIO(data) if data is not None else None)
    return stream.getvalue()


def archive_metadata(data):
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        return json.load(archive.extractfile("package/package.json"))


class FixtureRegistry:
    """Small npm publish endpoint with observable HTTP requests."""

    def __init__(self):
        self.documents = {}
        self.requests = []
        self.put_status = 201
        self.package_put_statuses = {}
        self.version_put_statuses = {}
        self.tag_put_status = 201
        self.ignore_tag_updates = False
        self.force_latest_on_publish = False
        self.get_status = None
        self.redirect_url = None
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def reply(self, status, body):
                encoded = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

            def package_name(self):
                path = urlsplit(self.path).path
                return unquote(path[len(REGISTRY_PREFIX):])

            def do_GET(self):
                fixture.requests.append({
                    "method": "GET", "path": self.path,
                    "authorization": self.headers.get("Authorization"),
                })
                if fixture.redirect_url is not None:
                    self.send_response(302)
                    self.send_header("Location", fixture.redirect_url)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if fixture.get_status is not None:
                    self.reply(fixture.get_status, {"error": "fixture lookup error"})
                    return
                document = fixture.documents.get(self.package_name())
                self.reply(200 if document is not None else 404,
                           document if document is not None else {"error": "not_found"})

            def do_PUT(self):
                data = self.rfile.read(int(self.headers["Content-Length"]))
                try:
                    payload = json.loads(data)
                except (ValueError, UnicodeDecodeError):
                    self.reply(400, {"error": "invalid_json"})
                    return
                fixture.requests.append({
                    "method": "PUT", "path": self.path, "payload": payload,
                    "authorization": self.headers.get("Authorization"),
                })
                relative = urlsplit(self.path).path[len(REGISTRY_PREFIX):]
                if relative.startswith("-/package/"):
                    endpoint = relative[len("-/package/"):]
                    encoded_name, separator, tag = endpoint.rpartition("/dist-tags/")
                    if not separator or tag != "latest" or not isinstance(payload, str):
                        self.reply(400, {"error": "invalid_dist_tag_request"})
                        return
                    if fixture.tag_put_status not in (200, 201, 204):
                        self.reply(fixture.tag_put_status, {"error": "fixture tag error"})
                        return
                    name = unquote(encoded_name)
                    document = fixture.documents.get(name)
                    if document is None or payload not in document["versions"]:
                        self.reply(404, {"error": "version_not_found"})
                        return
                    if not fixture.ignore_tag_updates:
                        document["dist-tags"][tag] = payload
                    self.reply(fixture.tag_put_status, {"ok": True})
                    return
                name = self.package_name()
                version = next(iter(payload.get("versions", {})), None)
                status = fixture.version_put_statuses.get((name, version),
                    fixture.package_put_statuses.get(name, fixture.put_status))
                if status != 201:
                    self.reply(status, {"error": "fixture publish error"})
                    return
                document = fixture.documents.setdefault(
                    name, {"name": name, "versions": {}, "dist-tags": {}})
                document["versions"].update(payload.get("versions", {}))
                document["dist-tags"].update(payload.get("dist-tags", {}))
                if fixture.force_latest_on_publish:
                    document["dist-tags"]["latest"] = next(iter(payload["versions"]))
                self.reply(201, {"ok": True, "id": name, "rev": "fixture"})

            def do_DELETE(self):
                fixture.requests.append({
                    "method": "DELETE", "path": self.path,
                    "authorization": self.headers.get("Authorization"),
                })
                relative = urlsplit(self.path).path[len(REGISTRY_PREFIX):]
                endpoint = relative.removeprefix("-/package/")
                encoded_name, separator, tag = endpoint.rpartition("/dist-tags/")
                if not relative.startswith("-/package/") or not separator or tag != "latest":
                    self.reply(400, {"error": "invalid_dist_tag_request"})
                    return
                if fixture.tag_put_status not in (200, 201, 204):
                    self.reply(fixture.tag_put_status, {"error": "fixture tag error"})
                    return
                document = fixture.documents.get(unquote(encoded_name))
                if document is None:
                    self.reply(404, {"error": "not_found"})
                    return
                if not fixture.ignore_tag_updates:
                    document["dist-tags"].pop(tag, None)
                self.reply(200, {"ok": True})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(
            target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        self.thread.start()
        self.url = "http://127.0.0.1:%d%s" % (self.server.server_port, REGISTRY_PREFIX)

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    @property
    def puts(self):
        return [request for request in self.requests
                if request["method"] == "PUT" and "_attachments" in request["payload"]]

    @property
    def tag_puts(self):
        return [request for request in self.requests
                if request["method"] == "PUT" and isinstance(request["payload"], str)]

    @property
    def tag_deletes(self):
        return [request for request in self.requests if request["method"] == "DELETE"]


class UploaderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="npm-python-upload-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / "bundle"
        self.bundle.mkdir()
        (self.bundle / "tarballs").mkdir()
        self.work = self.root / "work"
        self.marker = self.root / "lifecycle-ran"
        self.registry = FixtureRegistry()
        self.addCleanup(self.registry.close)
        self.entries = []
        self.source_data = {}

    def add_package(self, name="fixture-lib", version="1.0.0", metadata=None,
                    extra_members=()):
        package = {
            "name": name, "version": version, "main": "index.js",
            "types": "index.d.ts", "exports": {".": "./index.js"},
            "dependencies": {"runtime-lib": "^1.0.0"},
            "optionalDependencies": {"optional-lib": "^1.0.0"},
            "peerDependencies": {"peer-lib": "^1.0.0"},
        }
        if metadata:
            package.update(metadata)
        filename = name.replace("@", "").replace("/", "-") + "-" + version + ".tgz"
        data = package_tar(package, extra_members)
        relative = "tarballs/" + filename
        (self.bundle / relative).write_bytes(data)
        entry = {
            "name": name, "version": version, "tarball": relative,
            "bytes": len(data), "sha1": hashlib.sha1(data).hexdigest(),
            "sha512": hashlib.sha512(data).hexdigest(),
        }
        self.entries.append(entry)
        self.source_data[(name, version)] = data
        self.write_manifest()
        return entry

    def write_manifest(self, jsonl=False):
        target = self.bundle / ("packages.jsonl" if jsonl else "packages.json")
        target.write_text(
            "".join(json.dumps(entry) + "\n" for entry in self.entries)
            if jsonl else json.dumps(self.entries), encoding="utf-8")
        other = self.bundle / ("packages.json" if jsonl else "packages.jsonl")
        if other.exists():
            other.unlink()

    def add_directory_package(self, relative, name="fixture-lib", version="1.0.0",
                              metadata=None, extra_members=()):
        packages = self.root / "loose-packages"
        target = packages / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        package = {"name": name, "version": version, "main": "index.js"}
        if metadata:
            package.update(metadata)
        target.write_bytes(package_tar(package, extra_members))
        return target

    def run_upload(self, *flags, bundle_tar=None, packages_dir=None,
                   directory_flag="--packages-dir", work_dir=None,
                   expected=0, token=True):
        args = [sys.executable, str(UPLOADER)]
        if packages_dir is not None:
            args += [directory_flag, str(packages_dir)]
        elif bundle_tar:
            args += ["--bundle-tar", str(bundle_tar)]
        else:
            args += ["--bundle-dir", str(self.bundle)]
        args += ["--registry-url", self.registry.url, "--allow-http",
                 "--work-dir", str(work_dir if work_dir is not None else self.work)]
        if token:
            args += ["--token", "fixture-secret-token"]
        args += list(flags)
        env = os.environ.copy()
        # Keep the test independent of real npm/registry credentials and prove
        # the uploader does not depend on npm, curl, jq, tar, or a shell.
        for key in list(env):
            if key.startswith(("NPM_", "ARTIFACTORY_", "npm_config_")):
                del env[key]
        env["PATH"] = str(self.root / "no-executables")
        env["NO_PROXY"] = "127.0.0.1,localhost"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        result = subprocess.run(args, capture_output=True, text=True, env=env,
                                cwd=self.root, timeout=15)
        if expected == 0:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("fixture-secret-token", result.stdout + result.stderr)
        return result

    def attachment(self, request):
        attachments = request["payload"]["_attachments"]
        self.assertEqual(len(attachments), 1)
        value = next(iter(attachments.values()))
        data = base64.b64decode(value["data"], validate=True)
        self.assertEqual(value["length"], len(data))
        self.assertEqual(value["content_type"], "application/octet-stream")
        return data

    def test_directory_discovers_nested_archives_using_real_package_identities(self):
        first = self.add_directory_package("wrong-name-99.0.0.tgz", "@fixture/scoped", "2.3.4")
        second = self.add_directory_package("nested/misleading.tar.gz", "other-lib", "1.2.0")
        packages = first.parent
        (packages / "README.txt").write_text("These archive names are arbitrary.")
        # Directory mode must derive identities from the archives even when
        # unrelated manifest/lock files happen to accompany them.
        (packages / "packages.json").write_text("unrelated malformed manifest")
        (packages / "package-lock.json").write_text("unrelated malformed lockfile")
        self.run_upload(packages_dir=packages)
        actual = {request["payload"]["name"]: self.attachment(request)
                  for request in self.registry.puts}
        self.assertEqual(actual, {"@fixture/scoped": first.read_bytes(),
                                  "other-lib": second.read_bytes()})
        prepared = self.work / "prepared-bundle"
        entries = json.loads((prepared / "packages.json").read_text())
        self.assertEqual({(entry["name"], entry["version"]) for entry in entries},
                         {("@fixture/scoped", "2.3.4"), ("other-lib", "1.2.0")})
        for entry in entries:
            data = (prepared / entry["tarball"]).read_bytes()
            self.assertEqual(entry["sha512"], hashlib.sha512(data).hexdigest())
            self.assertEqual(entry["integrity"], integrity(data))

    def test_directory_versions_are_sequential_and_latest_resists_server_retagging(self):
        for filename, version in (("a.tgz", "10.0.0-rc.1"),
                                  ("b.tgz", "1.10.0"), ("c.tgz", "1.2.0")):
            self.add_directory_package(filename, version=version)
        self.registry.force_latest_on_publish = True
        self.registry.documents["fixture-lib"] = {
            "name": "fixture-lib", "versions": {"3.0.0": {"version": "3.0.0"}},
            "dist-tags": {"latest": "3.0.0", "lts": "3.0.0"},
        }
        self.run_upload(packages_dir=self.root / "loose-packages")
        published = [next(iter(request["payload"]["versions"]))
                     for request in self.registry.puts]
        self.assertEqual(published, ["1.2.0", "1.10.0", "10.0.0-rc.1"])
        tags = self.registry.documents["fixture-lib"]["dist-tags"]
        self.assertEqual(tags["latest"], "3.0.0")
        self.assertEqual(tags["lts"], "3.0.0")
        publication_indexes = [self.registry.requests.index(request)
                               for request in self.registry.puts]
        for earlier, later in zip(publication_indexes, publication_indexes[1:]):
            self.assertTrue(any(request["method"] == "GET"
                                for request in self.registry.requests[earlier + 1:later]))
        self.assertLess(max(publication_indexes),
                        min(self.registry.requests.index(request)
                            for request in self.registry.tag_puts))

    def test_directory_upload_keeps_scripts_without_executing_them(self):
        command = '%s -c "from pathlib import Path; Path(%r).write_text(\'ran\')"' % (
            sys.executable, str(self.marker))
        scripts = {event: command for event in (
            "prepublish", "prepublishOnly", "publish", "postpublish", "prepare",
            "prepack", "install", "postinstall")}
        source = self.add_directory_package("hooks.tgz", metadata={"scripts": scripts})
        original = source.read_bytes()
        self.run_upload(packages_dir=source.parent)
        uploaded = self.attachment(self.registry.puts[0])
        self.assertEqual(uploaded, original)
        self.assertEqual(archive_metadata(uploaded)["scripts"], scripts)
        self.assertEqual(source.read_bytes(), original)
        self.assertFalse(self.marker.exists())

    def test_directory_sanitize_repacks_hooks_and_preserves_originals(self):
        nested = json.dumps({"name": "bundled-lib", "version": "1.0.0",
                             "scripts": {"install": "fail"}, "main": "index.js"}).encode()
        member = tarfile.TarInfo("package/node_modules/bundled-lib/package.json")
        member.size = len(nested)
        source = self.add_directory_package("hooks.tgz", metadata={
            "scripts": {"prepublish": "fail", "publish": "fail", "postinstall": "fail"},
            "private": True, "publishConfig": {"registry": "https://other.invalid"},
        }, extra_members=[(member, nested)])
        original = source.read_bytes()
        self.run_upload("--sanitize-scripts", packages_dir=source.parent)
        uploaded = self.attachment(self.registry.puts[0])
        self.assertNotEqual(uploaded, original)
        metadata = archive_metadata(uploaded)
        for field in ("scripts", "private", "publishConfig"):
            self.assertNotIn(field, metadata)
        self.assertEqual(metadata["main"], "index.js")
        with tarfile.open(fileobj=io.BytesIO(uploaded), mode="r:gz") as archive:
            self.assertNotIn("scripts", json.load(archive.extractfile(member.name)))
            self.assertEqual(archive.extractfile("package/index.js").read(),
                             b"module.exports = 42;\n")
        self.assertEqual(source.read_bytes(), original)

    def test_directory_identical_duplicate_versions_publish_once(self):
        source = self.add_directory_package("first.tgz")
        duplicate = source.parent / "nested" / "same-bytes.tar.gz"
        duplicate.parent.mkdir()
        duplicate.write_bytes(source.read_bytes())
        self.run_upload(packages_dir=source.parent)
        self.assertEqual(len(self.registry.puts), 1)
        report = json.loads((self.work / "upload-summary.json").read_text())
        self.assertEqual(report["discoveredTarballCount"], 2)
        self.assertEqual(report["duplicateTarballCount"], 1)
        entries = json.loads((self.work / "discovered-packages.json").read_text())
        self.assertEqual(entries[0]["sourceFiles"], ["first.tgz", "nested/same-bytes.tar.gz"])

    def test_directory_conflicting_duplicate_versions_fail_before_registry_access(self):
        self.add_directory_package("a-valid-first.tgz", name="another-lib")
        source = self.add_directory_package("b-original.tgz")
        self.add_directory_package("z-conflict.tgz", metadata={"description": "different"})
        result = self.run_upload(packages_dir=source.parent, expected=1)
        self.assertRegex((result.stdout + result.stderr).lower(), "conflict|duplicat|differ")
        self.assertEqual(self.registry.requests, [])

    def test_directory_with_no_package_archives_is_rejected(self):
        packages = self.root / "loose-packages"
        packages.mkdir()
        (packages / "README.txt").write_text("No archives here.")
        result = self.run_upload(packages_dir=packages, expected=1)
        self.assertRegex((result.stdout + result.stderr).lower(), "no |empty|archive|tarball")
        self.assertNotIn("Traceback", result.stdout + result.stderr)
        self.assertEqual(self.registry.requests, [])

    def test_directory_late_malformed_archive_blocks_all_registry_requests(self):
        source = self.add_directory_package("a-valid-first.tgz")
        (source.parent / "z-corrupt.tgz").write_bytes(b"not a gzip or tar archive")
        result = self.run_upload(packages_dir=source.parent, expected=1)
        self.assertNotIn("Traceback", result.stdout + result.stderr)
        self.assertEqual(self.registry.requests, [])

    def test_directory_invalid_package_version_blocks_all_registry_requests(self):
        source = self.add_directory_package("a-valid-first.tgz")
        self.add_directory_package("z-invalid.tgz", name="invalid-lib", version="not-semver")
        result = self.run_upload(packages_dir=source.parent, expected=1)
        self.assertRegex((result.stdout + result.stderr).lower(), "version|identity|semver")
        self.assertNotIn("Traceback", result.stdout + result.stderr)
        self.assertEqual(self.registry.requests, [])

    def test_directory_symlink_archive_is_rejected(self):
        source = self.add_directory_package("a-valid.tgz")
        (source.parent / "z-symlink.tgz").symlink_to(source)
        result = self.run_upload(packages_dir=source.parent, expected=1)
        self.assertRegex((result.stdout + result.stderr).lower(), "symlink|symbolic|link")
        self.assertEqual(self.registry.requests, [])

    def test_directory_rejects_symlink_directories_without_following_them(self):
        source = self.add_directory_package("valid.tgz")
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "should-not-publish.tgz").write_bytes(
            package_tar({"name": "outside-lib", "version": "1.0.0"}))
        (source.parent / "linked-directory").symlink_to(outside, target_is_directory=True)
        result = self.run_upload(packages_dir=source.parent, expected=1)
        self.assertRegex((result.stdout + result.stderr).lower(), "symlink|symbolic|link")
        self.assertEqual(self.registry.requests, [])

    def test_directory_relative_nested_workdir_is_not_rediscovered(self):
        source = self.add_directory_package("input.tgz")
        relative_work = Path("loose-packages") / "upload-work"
        self.run_upload(packages_dir=Path("loose-packages"), work_dir=relative_work)
        self.assertEqual(len(self.registry.puts), 1)
        self.assertTrue((self.root / relative_work / "prepared-bundle" / "packages.json").is_file())
        self.assertEqual(self.attachment(self.registry.puts[0]), source.read_bytes())

    def test_directory_alias_dry_run_prepares_without_registry_requests(self):
        source = self.add_directory_package("arbitrary.tgz")
        result = self.run_upload("--dry-run", packages_dir=source.parent,
                                 directory_flag="--tarball-dir", token=False)
        self.assertEqual(self.registry.requests, [])
        self.assertRegex((result.stdout + result.stderr).lower(), "dry.run|would publish")
        entries = json.loads((self.work / "prepared-bundle" / "packages.json").read_text())
        self.assertEqual([(entry["name"], entry["version"]) for entry in entries],
                         [("fixture-lib", "1.0.0")])

    def test_scoped_and_unscoped_publish_protocol_and_hashes(self):
        self.add_package()
        self.add_package("@fixture/scoped", "2.3.4")
        self.run_upload()
        self.assertEqual(len(self.registry.puts), 2)
        for request in self.registry.puts:
            payload = request["payload"]
            name = payload["name"]
            self.assertEqual(payload["_id"], name)
            self.assertEqual(request["authorization"], "Bearer fixture-secret-token")
            self.assertEqual(unquote(request["path"]), REGISTRY_PREFIX + name)
            if name.startswith("@"):
                self.assertIn("%2f", request["path"].lower())
            self.assertEqual(len(payload["versions"]), 1)
            version, metadata = next(iter(payload["versions"].items()))
            data = self.attachment(request)
            self.assertEqual(data, self.source_data[(name, version)])
            self.assertEqual(metadata["name"], name)
            self.assertEqual(metadata["version"], version)
            self.assertEqual(metadata["dist"]["shasum"], hashlib.sha1(data).hexdigest())
            self.assertEqual(metadata["dist"]["integrity"], integrity(data))
            self.assertTrue(metadata["dist"]["tarball"].startswith(self.registry.url))
            self.assertEqual(metadata["dependencies"], {"runtime-lib": "^1.0.0"})

    def test_multiple_versions_preserved_and_newer_latest_untouched(self):
        self.add_package(version="1.0.0")
        self.add_package(version="2.0.0")
        self.registry.documents["fixture-lib"] = {
            "name": "fixture-lib", "versions": {"3.0.0": {"version": "3.0.0"}},
            "dist-tags": {"latest": "3.0.0"},
        }
        self.run_upload()
        document = self.registry.documents["fixture-lib"]
        self.assertEqual(set(document["versions"]), {"1.0.0", "2.0.0", "3.0.0"})
        self.assertEqual(document["dist-tags"]["latest"], "3.0.0")
        self.assertEqual(len(self.registry.puts), 2)
        self.assertEqual(self.registry.tag_puts, [])

    def test_publishes_versions_in_semver_order_then_sets_highest_stable_latest(self):
        for version in ("10.0.0-rc.10", "1.10.0", "1.2.0", "10.0.0-rc.2",
                        "2.0.0", "1.0.0", "10.0.0-rc.1"):
            self.add_package(version=version)
        self.run_upload()
        published = [next(iter(request["payload"]["versions"]))
                     for request in self.registry.puts]
        self.assertEqual(published, ["1.0.0", "1.2.0", "1.10.0", "2.0.0",
                                     "10.0.0-rc.1", "10.0.0-rc.2", "10.0.0-rc.10"])
        self.assertEqual(self.registry.documents["fixture-lib"]["dist-tags"]["latest"],
                         "2.0.0")
        for request in self.registry.puts:
            version = next(iter(request["payload"]["versions"]))
            self.assertEqual(request["payload"]["dist-tags"], {"airgap-" + version: version})
        self.assertEqual(len(self.registry.tag_puts), 1)
        tag_request = self.registry.tag_puts[0]
        self.assertEqual(tag_request["payload"], "2.0.0")
        self.assertEqual(tag_request["path"],
                         REGISTRY_PREFIX + "-/package/fixture-lib/dist-tags/latest")
        final_publish = max(self.registry.requests.index(request) for request in self.registry.puts)
        self.assertGreater(self.registry.requests.index(tag_request), final_publish)
        self.assertEqual(self.registry.requests[-1]["method"], "GET")

    def test_all_package_uploads_finish_before_any_latest_update(self):
        self.add_package("zeta-lib", "2.0.0")
        self.add_package("alpha-lib", "1.0.0")
        self.add_package("zeta-lib", "1.0.0")
        self.run_upload()
        self.assertEqual([request["payload"]["name"] for request in self.registry.puts],
                         ["alpha-lib", "zeta-lib", "zeta-lib"])
        publication_indexes = [self.registry.requests.index(request) for request in self.registry.puts]
        tag_indexes = [self.registry.requests.index(request) for request in self.registry.tag_puts]
        self.assertTrue(tag_indexes)
        self.assertLess(max(publication_indexes), min(tag_indexes))
        # A later version must not start publishing before the previous version
        # has been verified by a registry read.
        for earlier, later in zip(publication_indexes, publication_indexes[1:]):
            between = self.registry.requests[earlier + 1:later]
            self.assertTrue(any(request["method"] == "GET" for request in between))

    def test_latest_update_uses_scoped_npm_endpoint_and_json_string(self):
        self.add_package("@fixture/scoped", "1.2.3")
        self.registry.tag_put_status = 200
        self.run_upload()
        self.assertEqual(len(self.registry.tag_puts), 1)
        request = self.registry.tag_puts[0]
        self.assertEqual(unquote(request["path"]),
                         REGISTRY_PREFIX + "-/package/@fixture/scoped/dist-tags/latest")
        self.assertIn("%2f", request["path"].lower())
        self.assertEqual(request["payload"], "1.2.3")
        self.assertEqual(request["authorization"], "Bearer fixture-secret-token")

    def test_prerelease_only_package_does_not_get_latest(self):
        self.add_package(version="2.0.0-beta.1")
        self.add_package(version="2.0.0-beta.10")
        self.run_upload()
        self.assertNotIn("latest", self.registry.documents["fixture-lib"]["dist-tags"])
        self.assertEqual(self.registry.tag_puts, [])

    def test_prerelease_only_auto_latest_is_removed(self):
        self.add_package(version="2.0.0-beta.1")
        self.registry.force_latest_on_publish = True
        self.run_upload()
        self.assertNotIn("latest", self.registry.documents["fixture-lib"]["dist-tags"])
        self.assertEqual(self.registry.tag_puts, [])
        self.assertEqual(len(self.registry.tag_deletes), 1)
        self.assertEqual(self.registry.tag_deletes[0]["path"],
                         REGISTRY_PREFIX + "-/package/fixture-lib/dist-tags/latest")
        self.assertEqual(self.registry.requests[-1]["method"], "GET")

    def test_registry_auto_latest_is_corrected_without_downgrading_remote_version(self):
        self.add_package(version="1.0.0")
        self.add_package(version="2.0.0")
        self.registry.force_latest_on_publish = True
        self.registry.documents["fixture-lib"] = {
            "name": "fixture-lib", "versions": {"9.0.0": {"version": "9.0.0"}},
            "dist-tags": {"latest": "9.0.0", "lts": "9.0.0"},
        }
        self.run_upload()
        tags = self.registry.documents["fixture-lib"]["dist-tags"]
        self.assertEqual(tags["latest"], "9.0.0")
        self.assertEqual(tags["lts"], "9.0.0")
        self.assertEqual([request["payload"] for request in self.registry.tag_puts], ["9.0.0"])

    def test_new_prerelease_cannot_replace_stable_latest(self):
        self.add_package(version="1.0.0")
        self.add_package(version="2.0.0-rc.1")
        self.registry.force_latest_on_publish = True
        self.run_upload()
        self.assertEqual(self.registry.documents["fixture-lib"]["dist-tags"]["latest"], "1.0.0")
        self.assertEqual([request["payload"] for request in self.registry.tag_puts], ["1.0.0"])

    def test_preexisting_higher_prerelease_latest_is_restored_after_server_retags(self):
        self.add_package(version="1.0.0")
        self.registry.force_latest_on_publish = True
        self.registry.documents["fixture-lib"] = {
            "name": "fixture-lib", "versions": {"2.0.0-rc.1": {"version": "2.0.0-rc.1"}},
            "dist-tags": {"latest": "2.0.0-rc.1"},
        }
        self.run_upload()
        self.assertEqual(self.registry.documents["fixture-lib"]["dist-tags"]["latest"],
                         "2.0.0-rc.1")
        self.assertEqual([request["payload"] for request in self.registry.tag_puts], ["2.0.0-rc.1"])

    def test_missing_latest_is_repaired_when_every_version_already_exists(self):
        self.add_package(version="1.0.0")
        data = self.source_data[("fixture-lib", "1.0.0")]
        self.registry.documents["fixture-lib"] = {
            "name": "fixture-lib", "dist-tags": {}, "versions": {
                "1.0.0": {"version": "1.0.0", "dist": {"integrity": integrity(data)}},
                "3.0.0": {"version": "3.0.0"},
            },
        }
        self.run_upload()
        self.assertEqual(self.registry.puts, [])
        self.assertEqual([request["payload"] for request in self.registry.tag_puts], ["3.0.0"])

    def test_build_metadata_does_not_change_semver_precedence_of_existing_latest(self):
        self.add_package(version="1.2.3+build.8")
        self.registry.documents["fixture-lib"] = {
            "name": "fixture-lib", "versions": {
                "1.2.3+build.7": {"version": "1.2.3+build.7"},
            }, "dist-tags": {"latest": "1.2.3+build.7"},
        }
        self.run_upload()
        self.assertEqual(self.registry.documents["fixture-lib"]["dist-tags"]["latest"],
                         "1.2.3+build.7")
        self.assertEqual(self.registry.tag_puts, [])

    def test_preserve_latest_policy_keeps_curated_tag(self):
        self.add_package(version="3.0.0")
        self.registry.documents["fixture-lib"] = {
            "name": "fixture-lib", "versions": {"1.0.0": {"version": "1.0.0"}},
            "dist-tags": {"latest": "1.0.0"},
        }
        self.run_upload("--latest-policy", "preserve")
        self.assertEqual(self.registry.documents["fixture-lib"]["dist-tags"]["latest"], "1.0.0")
        self.assertEqual(self.registry.tag_puts, [])

    def test_preserve_policy_restores_latest_after_server_changes_it(self):
        self.add_package(version="3.0.0")
        self.registry.force_latest_on_publish = True
        self.registry.documents["fixture-lib"] = {
            "name": "fixture-lib", "versions": {"1.0.0": {"version": "1.0.0"}},
            "dist-tags": {"latest": "1.0.0"},
        }
        self.run_upload("--latest-policy", "preserve")
        self.assertEqual(self.registry.documents["fixture-lib"]["dist-tags"]["latest"], "1.0.0")
        self.assertEqual([request["payload"] for request in self.registry.tag_puts], ["1.0.0"])

    def test_preserve_policy_restores_absent_latest_after_server_creates_it(self):
        self.add_package(version="3.0.0")
        self.registry.force_latest_on_publish = True
        self.run_upload("--latest-policy", "preserve")
        self.assertNotIn("latest", self.registry.documents["fixture-lib"]["dist-tags"])
        self.assertEqual(self.registry.tag_puts, [])
        self.assertEqual(len(self.registry.tag_deletes), 1)

    def test_failed_package_does_not_get_latest_but_other_packages_finish(self):
        self.add_package("broken-lib", "1.0.0")
        self.add_package("working-lib", "2.0.0")
        self.registry.package_put_statuses["broken-lib"] = 403
        self.run_upload("--publish-retries", "0", expected=1)
        self.assertNotIn("broken-lib", self.registry.documents)
        self.assertEqual(self.registry.documents["working-lib"]["dist-tags"]["latest"], "2.0.0")
        self.assertEqual(len(self.registry.tag_puts), 1)
        self.assertIn("working-lib", self.registry.tag_puts[0]["path"])

    def test_partial_package_failure_restores_original_latest_without_promoting(self):
        self.add_package(version="2.0.0")
        self.add_package(version="3.0.0")
        self.registry.force_latest_on_publish = True
        self.registry.version_put_statuses[("fixture-lib", "3.0.0")] = 403
        self.registry.documents["fixture-lib"] = {
            "name": "fixture-lib", "versions": {"1.0.0": {"version": "1.0.0"}},
            "dist-tags": {"latest": "1.0.0"},
        }
        self.run_upload("--publish-retries", "0", expected=1)
        document = self.registry.documents["fixture-lib"]
        self.assertIn("2.0.0", document["versions"])
        self.assertNotIn("3.0.0", document["versions"])
        self.assertEqual(document["dist-tags"]["latest"], "1.0.0")
        self.assertEqual([request["payload"] for request in self.registry.tag_puts], ["1.0.0"])

    def test_latest_update_failure_is_reported_after_successful_package_publish(self):
        self.add_package()
        self.registry.tag_put_status = 403
        result = self.run_upload("--publish-retries", "0", expected=1)
        self.assertIn("403", result.stdout + result.stderr)
        self.assertIn("1.0.0", self.registry.documents["fixture-lib"]["versions"])
        self.assertNotIn("latest", self.registry.documents["fixture-lib"]["dist-tags"])
        report = json.loads((self.work / "upload-summary.json").read_text())
        self.assertEqual(report["published"], 1)
        self.assertEqual(report["latestFailed"], 1)

    def test_successful_tag_response_requires_read_back_verification(self):
        self.add_package()
        self.registry.ignore_tag_updates = True
        result = self.run_upload("--publish-retries", "0", expected=1)
        self.assertRegex((result.stdout + result.stderr).lower(), "latest|tag|verif")
        self.assertTrue(self.registry.tag_puts)
        self.assertNotIn("latest", self.registry.documents["fixture-lib"]["dist-tags"])
        report = json.loads((self.work / "upload-summary.json").read_text())
        self.assertEqual(report["latestFailed"], 1)

    def test_no_sanitize_preserves_bytes_and_never_runs_scripts(self):
        command = '%s -c "from pathlib import Path; Path(%r).write_text(\'ran\')"' % (
            sys.executable, str(self.marker))
        scripts = {event: command for event in (
            "prepublish", "prepublishOnly", "publish", "postpublish", "prepare",
            "prepack", "install", "postinstall")}
        entry = self.add_package(metadata={"scripts": scripts})
        original = (self.bundle / entry["tarball"]).read_bytes()
        self.run_upload()
        uploaded = self.attachment(self.registry.puts[0])
        self.assertEqual(uploaded, original)
        self.assertEqual(archive_metadata(uploaded)["scripts"], scripts)
        self.assertEqual((self.bundle / entry["tarball"]).read_bytes(), original)
        self.assertFalse(self.marker.exists())

    def test_sanitize_repacks_and_preserves_runtime_content_and_source(self):
        executable = tarfile.TarInfo("package/cli.js")
        executable.mode = 0o755
        executable_data = b"#!/usr/bin/env node\nconsole.log(42);\n"
        executable.size = len(executable_data)
        entry = self.add_package(metadata={
            "scripts": {"prepublish": "fail", "postinstall": "fail", "build": "fail"},
            "private": True, "publishConfig": {"registry": "https://other.invalid"},
        }, extra_members=[(executable, executable_data)])
        original = (self.bundle / entry["tarball"]).read_bytes()
        self.run_upload("--sanitize-scripts")
        data = self.attachment(self.registry.puts[0])
        self.assertNotEqual(data, original)
        metadata = archive_metadata(data)
        for field in ("scripts", "private", "publishConfig"):
            self.assertNotIn(field, metadata)
        for field in ("main", "types", "exports", "dependencies", "optionalDependencies",
                      "peerDependencies"):
            self.assertEqual(metadata[field], archive_metadata(original)[field])
        self.assertEqual((self.bundle / entry["tarball"]).read_bytes(), original)
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
            self.assertEqual(archive.extractfile("package/index.js").read(),
                             b"module.exports = 42;\n")
            self.assertEqual(archive.extractfile(executable.name).read(), executable_data)
            self.assertEqual(archive.getmember(executable.name).mode & 0o777, 0o755)
        prepared = self.work / "prepared-bundle"
        entries = json.loads((prepared / "packages.json").read_text())
        self.assertEqual(len(entries), 1)
        self.assertEqual((prepared / entries[0]["tarball"]).read_bytes(), data)
        self.assertEqual(entries[0]["sha512"], hashlib.sha512(data).hexdigest())

    def check_lock_rewrite(self, sanitize):
        name, version = "@fixture/scoped", "1.2.3"
        self.add_package(name, version, metadata={"scripts": {"prepublishOnly": "fail"}})
        source = self.source_data[(name, version)]
        key = "node_modules/" + name
        source_lock = {
            "name": "fixture-project", "version": "1.0.0", "lockfileVersion": 3,
            "packages": {"": {"dependencies": {name: version}}, key: {
                "version": version, "resolved": "https://source.invalid/old.tgz",
                "integrity": integrity(source), "hasInstallScript": True,
            }},
        }
        (self.bundle / "package-lock.json").write_text(json.dumps(source_lock))
        self.run_upload(*(["--sanitize-scripts"] if sanitize else []))
        request = self.registry.puts[0]
        uploaded = self.attachment(request)
        lock = json.loads((self.work / "prepared-bundle" / "package-lock.json").read_text())
        self.assertEqual(lock["packages"][key]["integrity"], integrity(uploaded))
        self.assertEqual(lock["packages"][key]["resolved"],
                         request["payload"]["versions"][version]["dist"]["tarball"])
        self.assertTrue(lock["packages"][key]["resolved"].startswith(self.registry.url))
        self.assertEqual(json.loads((self.bundle / "package-lock.json").read_text()), source_lock)

    def test_rewrites_lock_to_target_registry_and_unchanged_archive_integrity(self):
        self.check_lock_rewrite(sanitize=False)

    def test_rewrites_lock_to_target_registry_and_sanitized_archive_integrity(self):
        self.check_lock_rewrite(sanitize=True)

    def test_jsonl_manifest_and_transfer_archive_input(self):
        self.add_package("@fixture/scoped", "1.2.0")
        self.write_manifest(jsonl=True)
        transfer = self.root / "bundle.tar"
        with tarfile.open(transfer, "w") as archive:
            archive.add(self.bundle, arcname="npm-transfer-bundle")
        self.run_upload(bundle_tar=transfer)
        self.assertEqual(len(self.registry.puts), 1)

    def test_sanitize_removes_lifecycle_hooks_from_bundled_dependencies(self):
        nested = json.dumps({"name": "bundled-lib", "version": "1.0.0",
                             "scripts": {"install": "fail"}, "main": "index.js"}).encode()
        member = tarfile.TarInfo("package/node_modules/bundled-lib/package.json")
        member.size = len(nested)
        self.add_package(extra_members=[(member, nested)])
        self.run_upload("--sanitize-scripts")
        data = self.attachment(self.registry.puts[0])
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
            nested_metadata = json.load(archive.extractfile(member.name))
        self.assertNotIn("scripts", nested_metadata)
        self.assertEqual(nested_metadata["main"], "index.js")

    def test_sanitize_preserves_invalid_test_fixture_manifests(self):
        fixture = tarfile.TarInfo("package/test/fixtures/broken/package.json")
        fixture_data = b"{ deliberately invalid JSON used by package tests"
        fixture.size = len(fixture_data)
        self.add_package(metadata={"scripts": {"prepublish": "fail"}},
                         extra_members=[(fixture, fixture_data)])
        self.run_upload("--sanitize-scripts")
        data = self.attachment(self.registry.puts[0])
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
            self.assertEqual(archive.extractfile(fixture.name).read(), fixture_data)

    def test_legacy_uppercase_registry_package_name_is_accepted(self):
        self.add_package("JSONStream", "1.3.5")
        self.run_upload()
        self.assertEqual(self.registry.puts[0]["payload"]["name"], "JSONStream")

    def test_integrity_failure_prevents_every_network_request(self):
        self.add_package("valid-first", "1.0.0")
        bad = self.add_package("corrupt-second", "1.0.0")
        bad["sha512"] = "0" * 128
        self.write_manifest()
        result = self.run_upload(expected=1)
        self.assertRegex((result.stdout + result.stderr).lower(), "hash|integrity|sha512")
        self.assertEqual(self.registry.requests, [])

    def test_missing_digest_is_rejected(self):
        entry = self.add_package()
        del entry["sha1"]
        del entry["sha512"]
        self.write_manifest()
        result = self.run_upload(expected=1)
        self.assertRegex((result.stdout + result.stderr).lower(), "hash|digest|integrity|sha")
        self.assertEqual(self.registry.requests, [])

    def test_manifest_path_traversal_is_rejected(self):
        entry = self.add_package()
        (self.root / "outside.tgz").write_bytes(self.source_data[("fixture-lib", "1.0.0")])
        entry["tarball"] = "../outside.tgz"
        self.write_manifest()
        result = self.run_upload(expected=1)
        self.assertRegex((result.stdout + result.stderr).lower(), "path|outside|unsafe|travers")
        self.assertEqual(self.registry.requests, [])

    def test_dot_manifest_path_produces_clean_validation_error(self):
        entry = self.add_package()
        entry["tarball"] = "."
        self.write_manifest()
        result = self.run_upload(expected=1)
        self.assertNotIn("Traceback", result.stdout + result.stderr)
        self.assertEqual(self.registry.requests, [])

    def test_tarball_cannot_replace_prepared_bundle_metadata(self):
        entry = self.add_package()
        reserved = self.bundle / "package.json"
        reserved.write_bytes((self.bundle / entry["tarball"]).read_bytes())
        entry["tarball"] = "package.json"
        self.write_manifest()
        result = self.run_upload(expected=1)
        self.assertRegex((result.stdout + result.stderr).lower(), "metadata|reserved|conflict|tarball")
        self.assertEqual(self.registry.requests, [])
        self.assertEqual(reserved.read_bytes(), self.source_data[("fixture-lib", "1.0.0")])

    def test_nonempty_work_directory_is_rejected_without_overwriting_files(self):
        self.add_package()
        self.work.mkdir()
        sentinel = self.work / "upload-summary.json"
        sentinel.write_bytes(b"previous user report\n")
        result = self.run_upload(expected=1)
        self.assertRegex((result.stdout + result.stderr).lower(), "empty|exists|existing")
        self.assertEqual(sentinel.read_bytes(), b"previous user report\n")
        self.assertEqual(self.registry.requests, [])

    def test_package_archive_traversal_is_rejected_without_extracting(self):
        member = tarfile.TarInfo("../../lifecycle-ran")
        member.size = 3
        self.add_package(extra_members=[(member, b"bad")])
        self.run_upload("--sanitize-scripts", expected=1)
        self.assertEqual(self.registry.requests, [])
        self.assertFalse(self.marker.exists())
        self.assertEqual(list(self.root.rglob("lifecycle-ran")), [])

    def test_transfer_archive_absolute_member_is_rejected_before_writes(self):
        transfer = self.root / "hostile.tar"
        with tarfile.open(transfer, "w") as archive:
            member = tarfile.TarInfo(str(self.marker))
            member.size = 3
            archive.addfile(member, io.BytesIO(b"bad"))
        self.run_upload(bundle_tar=transfer, expected=1)
        self.assertEqual(self.registry.requests, [])
        self.assertFalse(self.marker.exists())

    def test_transfer_archive_symlink_is_rejected_without_following_it(self):
        transfer = self.root / "hostile-symlink.tar"
        with tarfile.open(transfer, "w") as archive:
            symlink = tarfile.TarInfo("bundle/link")
            symlink.type = tarfile.SYMTYPE
            symlink.linkname = str(self.root)
            archive.addfile(symlink)
            payload = tarfile.TarInfo("bundle/link/lifecycle-ran")
            payload.size = 3
            archive.addfile(payload, io.BytesIO(b"bad"))
        self.run_upload(bundle_tar=transfer, expected=1)
        self.assertEqual(self.registry.requests, [])
        self.assertFalse(self.marker.exists())

    def test_package_identity_mismatch_is_rejected(self):
        self.add_package(metadata={"name": "different-name"})
        result = self.run_upload(expected=1)
        self.assertRegex((result.stdout + result.stderr).lower(), "name|identity|mismatch")
        self.assertEqual(self.registry.requests, [])

    def test_existing_identical_version_is_skipped(self):
        self.add_package()
        data = self.source_data[("fixture-lib", "1.0.0")]
        self.registry.documents["fixture-lib"] = {
            "name": "fixture-lib", "dist-tags": {"latest": "1.0.0"},
            "versions": {"1.0.0": {"name": "fixture-lib", "version": "1.0.0",
                                   "dist": {"integrity": integrity(data)}}},
        }
        self.run_upload()
        self.assertTrue(self.registry.requests)
        self.assertTrue(all(request["method"] == "GET" for request in self.registry.requests))
        self.assertEqual(self.registry.puts, [])

    def test_existing_different_version_bytes_fail(self):
        self.add_package()
        self.registry.documents["fixture-lib"] = {
            "name": "fixture-lib", "dist-tags": {}, "versions": {
                "1.0.0": {"version": "1.0.0", "dist": {"integrity": integrity(b"other")}},
            },
        }
        result = self.run_upload(expected=1)
        self.assertRegex((result.stdout + result.stderr).lower(), "conflict|differ|mismatch")
        self.assertEqual(self.registry.puts, [])

    def test_existing_shasum_match_is_skipped(self):
        self.add_package()
        data = self.source_data[("fixture-lib", "1.0.0")]
        self.registry.documents["fixture-lib"] = {
            "name": "fixture-lib", "versions": {
                "1.0.0": {"dist": {"shasum": hashlib.sha1(data).hexdigest()}},
            }, "dist-tags": {},
        }
        self.run_upload()
        self.assertEqual(self.registry.puts, [])

    def test_existing_conflicting_digest_is_not_skipped(self):
        self.add_package()
        data = self.source_data[("fixture-lib", "1.0.0")]
        self.registry.documents["fixture-lib"] = {
            "name": "fixture-lib", "versions": {
                "1.0.0": {"dist": {"integrity": integrity(data), "shasum": "0" * 40}},
            }, "dist-tags": {},
        }
        self.run_upload(expected=1)
        self.assertEqual(self.registry.puts, [])

    def test_dry_run_validates_locally_without_network(self):
        self.add_package()
        result = self.run_upload("--dry-run", token=False)
        self.assertEqual(self.registry.requests, [])
        self.assertRegex((result.stdout + result.stderr).lower(), "dry.run|would publish")

    def test_username_password_authentication(self):
        self.add_package()
        result = self.run_upload("--username", "fixture-user", "--password",
                                 "fixture-password", token=False)
        expected = "Basic " + base64.b64encode(b"fixture-user:fixture-password").decode()
        self.assertTrue(self.registry.requests)
        for request in self.registry.requests:
            self.assertEqual(request["authorization"], expected)
        self.assertNotIn("fixture-password", result.stdout + result.stderr)

    def test_http_permission_errors_are_actionable_and_do_not_leak_token(self):
        self.add_package()
        self.registry.get_status = 401
        result = self.run_upload(expected=1)
        self.assertIn("401", result.stdout + result.stderr)
        self.assertEqual(self.registry.puts, [])

    def test_publish_failure_is_not_mistaken_for_success(self):
        self.add_package()
        self.registry.put_status = 403
        result = self.run_upload(expected=1)
        self.assertIn("403", result.stdout + result.stderr)
        self.assertGreaterEqual(len(self.registry.puts), 1)

    def test_registry_redirect_is_not_followed_with_authentication(self):
        self.add_package()
        receiver = FixtureRegistry()
        self.addCleanup(receiver.close)
        self.registry.redirect_url = receiver.url + "fixture-lib"
        result = self.run_upload(expected=1)
        self.assertRegex((result.stdout + result.stderr).lower(), "302|redirect")
        self.assertEqual(receiver.requests, [])
        self.assertEqual(self.registry.puts, [])


if __name__ == "__main__":
    unittest.main()
