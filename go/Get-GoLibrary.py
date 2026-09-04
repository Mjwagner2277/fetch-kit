#!/usr/bin/env python3
"""Retrieve Go modules and export optional static Go proxy cache layout."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import tarfile
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from collections import deque
from dataclasses import dataclass
from pathlib import Path
from typing import Any


def status(message: str) -> None:
    print(f"[go-fetch] {message}", file=sys.stderr)


def safe_file_name(value: str) -> str:
    return re.sub(r'[\\/:*?"<>|@]', "_", value)


def escape_go_proxy_segment(value: str) -> str:
    out: list[str] = []
    for char in value:
        if "A" <= char <= "Z":
            out.append("!")
            out.append(char.lower())
        else:
            out.append(char)
    return "".join(out)


def go_proxy_relative_path(module_path: str) -> Path:
    return Path(*escape_go_proxy_segment(module_path).split("/"))


def go_proxy_version_dir(root: Path, module_path: str) -> Path:
    return root / go_proxy_relative_path(module_path) / "@v"


def join_url(base: str, path: str) -> str:
    return base.rstrip("/") + "/" + path.lstrip("/")


def http_request(
    uri: str,
    *,
    headers: dict[str, str] | None = None,
    out_file: Path | None = None,
) -> bytes:
    request = urllib.request.Request(uri, headers=headers or {})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            if out_file:
                out_file.parent.mkdir(parents=True, exist_ok=True)
                with out_file.open("wb") as handle:
                    shutil.copyfileobj(response, handle)
                return b""
            return response.read()
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"HTTP {exc.code} from {uri}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"{exc.reason} from {uri}") from exc


def http_text(uri: str, *, headers: dict[str, str] | None = None) -> str:
    return http_request(uri, headers=headers).decode("utf-8")


def http_json(uri: str, *, headers: dict[str, str] | None = None) -> Any:
    content = http_text(uri, headers=headers)
    return json.loads(content) if content else None


def default_go_proxies(proxy: list[str]) -> list[str]:
    if proxy:
        return proxy
    if os.environ.get("GOPROXY"):
        return [item for item in os.environ["GOPROXY"].split(",") if item]
    return ["https://proxy.golang.org", "direct"]


def github_headers(token: str = "") -> dict[str, str]:
    headers = {"User-Agent": "fetch-kit-go-library"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def gitlab_headers(token: str = "") -> dict[str, str]:
    return {"PRIVATE-TOKEN": token} if token else {}


def semver_sort_key(version: str) -> tuple[int, int, int, int, str]:
    match = re.match(r"^v(\d+)\.(\d+)\.(\d+)(-.+)?(?:\+.*)?$", version)
    if not match:
        return (-1, -1, -1, 0, version)
    major, minor, patch = (int(match.group(i)) for i in range(1, 4))
    prerelease = match.group(4) or ""
    stable = 1 if not prerelease else 0
    return (major, minor, patch, stable, prerelease)


def sort_go_versions_desc(versions: list[str]) -> list[str]:
    return sorted(versions, key=semver_sort_key, reverse=True)


def compare_go_module_version(left: str, right: str) -> int:
    left_key = semver_sort_key(left)
    right_key = semver_sort_key(right)
    if left_key > right_key:
        return 1
    if left_key < right_key:
        return -1
    return 0


def go_version_tuple(value: str) -> tuple[int, int, int]:
    match = re.search(r"(\d+)(?:\.(\d+))?(?:\.(\d+))?", value.strip())
    if not match:
        raise RuntimeError(
            f"Could not parse Go version '{value}'. Use a value like 1.26.5-1, 1.26.5, or 1.26."
        )
    return (
        int(match.group(1)),
        int(match.group(2) or 0),
        int(match.group(3) or 0),
    )


def go_version_string(value: tuple[int, int, int]) -> str:
    return f"{value[0]}.{value[1]}.{value[2]}"


def is_go_directive_compatible(directive: str, target: tuple[int, int, int]) -> bool:
    if not directive:
        return True
    return go_version_tuple(directive) <= target


def go_directive_from_mod(content: str) -> str:
    for raw_line in content.splitlines():
        clean = re.sub(r"//.*$", "", raw_line).strip()
        match = re.match(r"^go\s+([0-9]+(?:\.[0-9]+){1,2})$", clean)
        if match:
            return match.group(1)
    return ""


PACKAGE_ALIASES = {
    "air": "github.com/air-verse/air",
    "dlv": "github.com/go-delve/delve/cmd/dlv",
    "gocover-cobertura": "github.com/boumenot/gocover-cobertura",
    "godoc": "golang.org/x/tools/cmd/godoc",
    "gofumpt": "mvdan.cc/gofumpt",
    "goimports": "golang.org/x/tools/cmd/goimports",
    "golangci-lint": "github.com/golangci/golangci-lint/v2/cmd/golangci-lint",
    "gopls": "golang.org/x/tools/gopls",
    "gosec": "github.com/securego/gosec/v2/cmd/gosec",
    "gotestsum": "gotest.tools/gotestsum",
    "govulncheck": "golang.org/x/vuln/cmd/govulncheck",
    "mockgen": "go.uber.org/mock/mockgen",
    "protoc-gen-go": "google.golang.org/protobuf/cmd/protoc-gen-go",
    "protoc-gen-go-grpc": "google.golang.org/grpc/cmd/protoc-gen-go-grpc",
    "staticcheck": "honnef.co/go/tools/cmd/staticcheck",
    "stringer": "golang.org/x/tools/cmd/stringer",
}

PACKAGE_MODULE_OVERRIDES = {
    "golang.org/x/tools/cmd/godoc": "golang.org/x/tools",
    "golang.org/x/tools/cmd/goimports": "golang.org/x/tools",
    "golang.org/x/tools/cmd/stringer": "golang.org/x/tools",
    "github.com/golangci/golangci-lint/v2/cmd/golangci-lint": "github.com/golangci/golangci-lint/v2",
    "github.com/go-delve/delve/cmd/dlv": "github.com/go-delve/delve",
    "github.com/securego/gosec/v2/cmd/gosec": "github.com/securego/gosec/v2",
    "go.uber.org/mock/mockgen": "go.uber.org/mock",
    "golang.org/x/vuln/cmd/govulncheck": "golang.org/x/vuln",
    "google.golang.org/protobuf/cmd/protoc-gen-go": "google.golang.org/protobuf",
    "honnef.co/go/tools/cmd/staticcheck": "honnef.co/go/tools",
}


@dataclass
class PackagePath:
    package: str
    module: str


@dataclass
class PackageEntry:
    line_number: int
    package: str
    module: str
    version: str
    resolved_by_compatibility: bool = False
    compatible_go_directive: str = ""

    def to_json(self) -> dict[str, Any]:
        return {
            "LineNumber": self.line_number,
            "Package": self.package,
            "Module": self.module,
            "Version": self.version,
            "ResolvedByCompatibility": self.resolved_by_compatibility,
            "CompatibleGoDirective": self.compatible_go_directive,
        }


class GoFetcher:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.output_directory = Path(args.output_directory) if args.output_directory else None
        self.go_proxy_directory = Path(args.go_proxy_directory) if args.go_proxy_directory else None
        self.using_default_go_proxy_directory = False
        self.using_temporary_output_directory = False
        self.version_list_cache: dict[tuple[str, str], list[str]] = {}
        self.latest_cache: dict[tuple[str, str], str] = {}
        self.mod_directive_cache: dict[tuple[str, str, str], str] = {}
        self.compatibility_cache: dict[tuple[tuple[int, int, int], str, str], dict[str, Any]] = {}

        if args.package_list_path and not self.go_proxy_directory:
            self.go_proxy_directory = Path.cwd() / "go-proxy-cache"
            self.using_default_go_proxy_directory = True

        if not self.output_directory:
            if self.go_proxy_directory and not args.expand:
                self.output_directory = Path(tempfile.mkdtemp(prefix="go-library-cache-"))
                self.using_temporary_output_directory = True
            else:
                self.output_directory = Path.cwd() / "go-library-cache"

        self.output_directory.mkdir(parents=True, exist_ok=True)
        status(f"working output directory: {self.output_directory}")
        if self.go_proxy_directory:
            status(f"static proxy output directory: {self.go_proxy_directory}")

    def cleanup(self) -> None:
        if self.using_temporary_output_directory and self.output_directory and self.output_directory.exists():
            shutil.rmtree(self.output_directory)

    def finalize(self, result: dict[str, Any]) -> dict[str, Any]:
        archive_file = self.create_archive()
        result["WorkingOutputDirectory"] = str(self.output_directory)
        result["TemporaryOutputDirectory"] = self.using_temporary_output_directory
        result["GoProxyDirectory"] = str(self.go_proxy_directory) if self.go_proxy_directory else ""
        result["DefaultGoProxyDirectory"] = self.using_default_go_proxy_directory
        if archive_file:
            result["ArchiveFile"] = str(archive_file)
        return result

    def create_archive(self) -> Path | None:
        if not self.args.archive_output:
            return None
        if not self.go_proxy_directory:
            raise RuntimeError("--archive-output requires a static proxy cache. Use --go-proxy-directory or --package-list-path.")
        if not self.go_proxy_directory.exists():
            raise RuntimeError(f"Cannot archive missing Go proxy directory: {self.go_proxy_directory}")

        archive_path = Path(self.args.archive_output)
        archive_path.parent.mkdir(parents=True, exist_ok=True)
        status(f"creating transfer archive {archive_path} from {self.go_proxy_directory}")
        with tarfile.open(archive_path, "w:gz") as archive:
            for child in sorted(self.go_proxy_directory.iterdir(), key=lambda item: item.name):
                archive.add(child, arcname=child.name)
        status(f"created transfer archive {archive_path}")
        return archive_path

    def proxies(self) -> list[str]:
        return default_go_proxies(self.args.proxy)

    def proxy_versions(self, module_path: str, proxy_base: str) -> list[str]:
        key = (proxy_base, module_path)
        if key in self.version_list_cache:
            return self.version_list_cache[key]
        escaped_module = escape_go_proxy_segment(module_path)
        module_base = join_url(proxy_base, escaped_module)
        list_url = join_url(join_url(module_base, "@v"), "list")
        versions = [line.strip() for line in http_text(list_url).splitlines() if line.strip()]
        self.version_list_cache[key] = versions
        return versions

    def proxy_latest_version(self, module_path: str, proxy_base: str) -> str:
        key = (proxy_base, module_path)
        if key in self.latest_cache:
            return self.latest_cache[key]
        escaped_module = escape_go_proxy_segment(module_path)
        latest = http_json(join_url(join_url(proxy_base, escaped_module), "@latest"))
        version = latest["Version"]
        self.latest_cache[key] = version
        return version

    def proxy_mod_directive(self, module_path: str, version: str, proxy_base: str) -> str:
        key = (proxy_base, module_path, version)
        if key in self.mod_directive_cache:
            return self.mod_directive_cache[key]
        escaped_module = escape_go_proxy_segment(module_path)
        escaped_version = escape_go_proxy_segment(version)
        version_base = join_url(join_url(proxy_base, escaped_module), "@v")
        directive = go_directive_from_mod(http_text(join_url(version_base, f"{escaped_version}.mod")))
        self.mod_directive_cache[key] = directive
        return directive

    def static_proxy_version_complete(self, module_path: str, version: str) -> bool:
        if not self.go_proxy_directory:
            return False
        version_dir = go_proxy_version_dir(self.go_proxy_directory, module_path)
        escaped_version = escape_go_proxy_segment(version)
        list_file = version_dir / "list"
        required = [
            version_dir / f"{escaped_version}.info",
            version_dir / f"{escaped_version}.mod",
            version_dir / f"{escaped_version}.zip",
            list_file,
        ]
        if not all(path.exists() for path in required):
            return False
        return version in [line.strip() for line in list_file.read_text(encoding="utf-8").splitlines() if line.strip()]

    def static_proxy_versions(self, module_path: str) -> list[str]:
        if not self.go_proxy_directory:
            return []
        list_file = go_proxy_version_dir(self.go_proxy_directory, module_path) / "list"
        if not list_file.exists():
            return []
        return [
            line.strip()
            for line in list_file.read_text(encoding="utf-8").splitlines()
            if line.strip() and self.static_proxy_version_complete(module_path, line.strip())
        ]

    def resolve_from_static_proxy(self, package_path: str, module_path: str, target: tuple[int, int, int]) -> dict[str, Any] | None:
        versions = self.static_proxy_versions(module_path)
        if not versions:
            return None
        version_dir = go_proxy_version_dir(self.go_proxy_directory, module_path)  # type: ignore[arg-type]
        for candidate in sort_go_versions_desc(versions):
            mod_file = version_dir / f"{escape_go_proxy_segment(candidate)}.mod"
            directive = go_directive_from_mod(mod_file.read_text(encoding="utf-8"))
            if is_go_directive_compatible(directive, target):
                return {
                    "PackagePath": package_path,
                    "ModulePath": module_path,
                    "Version": candidate,
                    "GoDirective": directive,
                    "Proxy": "GoProxyDirectory",
                }
        return None

    def resolve_latest_compatible(self, package_path: str, module_path: str, target: tuple[int, int, int]) -> dict[str, Any]:
        key = (target, package_path, module_path)
        if key in self.compatibility_cache:
            cached = self.compatibility_cache[key]
            status(f"resolved {package_path} from in-run compatibility cache as {cached['ModulePath']}@{cached['Version']}")
            return cached

        status(f"resolving latest {package_path} compatible with Go {go_version_string(target)}")
        cached = self.resolve_from_static_proxy(package_path, module_path, target)
        if cached:
            self.compatibility_cache[key] = cached
            status(
                f"resolved {package_path} from static proxy cache as {cached['ModulePath']}@{cached['Version']} "
                f"(go {cached['GoDirective']})"
            )
            return cached

        errors: list[str] = []
        for proxy_base in self.proxies():
            if proxy_base == "off":
                break
            if proxy_base == "direct":
                continue
            candidate_checks: list[str] = []
            latest_version = ""
            try:
                try:
                    latest_version = self.proxy_latest_version(module_path, proxy_base)
                    status(f"checking {module_path}@{latest_version} from {proxy_base} for Go {go_version_string(target)} compatibility")
                    directive = self.proxy_mod_directive(module_path, latest_version, proxy_base)
                    compatible = is_go_directive_compatible(directive, target)
                    candidate_checks.append(f"{latest_version}: go {directive} compatible={compatible}")
                    if compatible:
                        resolved = {
                            "PackagePath": package_path,
                            "ModulePath": module_path,
                            "Version": latest_version,
                            "GoDirective": directive,
                            "Proxy": proxy_base,
                        }
                        self.compatibility_cache[key] = resolved
                        status(f"resolved {package_path} as {module_path}@{latest_version} from {proxy_base} (go {directive})")
                        return resolved
                except Exception as exc:
                    candidate_checks.append(f"@latest: {exc}")

                versions = sort_go_versions_desc(self.proxy_versions(module_path, proxy_base))
                status(f"scanning {len(versions)} versions for {module_path} from {proxy_base}")
                for candidate in versions:
                    if latest_version and candidate == latest_version:
                        continue
                    try:
                        directive = self.proxy_mod_directive(module_path, candidate, proxy_base)
                        compatible = is_go_directive_compatible(directive, target)
                        candidate_checks.append(f"{candidate}: go {directive} compatible={compatible}")
                        if compatible:
                            resolved = {
                                "PackagePath": package_path,
                                "ModulePath": module_path,
                                "Version": candidate,
                                "GoDirective": directive,
                                "Proxy": proxy_base,
                            }
                            self.compatibility_cache[key] = resolved
                            status(f"resolved {package_path} as {module_path}@{candidate} from {proxy_base} (go {directive})")
                            return resolved
                    except Exception as exc:
                        candidate_checks.append(f"{candidate}: {exc}")
                raise RuntimeError(f"No compatible versions found for {module_path} on {proxy_base}. Checked: {'; '.join(candidate_checks)}")
            except Exception as exc:
                errors.append(f"{proxy_base}: {exc}")

        raise RuntimeError(
            f"Could not resolve latest compatible version for {package_path} using Go {go_version_string(target)}. "
            f"Attempts: {' | '.join(errors)}"
        )

    def retrieve_from_proxy(self, module_path: str, requested_version: str, proxy_base: str, destination: Path) -> dict[str, Any]:
        escaped_module = escape_go_proxy_segment(module_path)
        module_base = join_url(proxy_base, escaped_module)
        resolved_version = requested_version
        if requested_version == "latest":
            status(f"resolving latest version from {join_url(module_base, '@latest')}")
            resolved_version = http_json(join_url(module_base, "@latest"))["Version"]
        escaped_version = escape_go_proxy_segment(resolved_version)
        version_base = join_url(module_base, "@v")
        destination.mkdir(parents=True, exist_ok=True)

        info_file = destination / f"{escaped_version}.info"
        mod_file = destination / f"{escaped_version}.mod"
        zip_file = destination / f"{escaped_version}.zip"
        used_working_cache = info_file.exists() and mod_file.exists() and zip_file.exists()
        if not used_working_cache:
            http_request(join_url(version_base, f"{escaped_version}.info"), out_file=info_file)
            http_request(join_url(version_base, f"{escaped_version}.mod"), out_file=mod_file)
            http_request(join_url(version_base, f"{escaped_version}.zip"), out_file=zip_file)

        expanded_to = None
        if self.args.expand:
            expanded_to = destination / escaped_version
            expanded_to.mkdir(parents=True, exist_ok=True)
            with zipfile.ZipFile(zip_file) as archive:
                archive.extractall(expanded_to)

        return {
            "Mode": "ModuleProxy",
            "Module": module_path,
            "Version": resolved_version,
            "Proxy": proxy_base,
            "InfoFile": str(info_file),
            "ModFile": str(mod_file),
            "ZipFile": str(zip_file),
            "UsedWorkingCache": used_working_cache,
            "ExpandedTo": str(expanded_to) if expanded_to else None,
        }

    def github_repo_from_path(self, module_path: str) -> tuple[str, str]:
        parsed = urllib.parse.urlparse(module_path)
        if parsed.scheme:
            parts = parsed.path.strip("/").split("/")
        else:
            parts = module_path.split("/")
            if len(parts) < 3 or parts[0] != "github.com":
                raise RuntimeError("GitHub module paths must look like github.com/owner/repository.")
            parts = parts[1:]
        if len(parts) < 2:
            raise RuntimeError("GitHub module paths must include an owner and repository.")
        return parts[0], re.sub(r"\.git$", "", parts[1])

    def latest_github_ref(self, owner: str, repo: str) -> str:
        headers = github_headers(self.args.github_token)
        tags = http_json(f"https://api.github.com/repos/{owner}/{repo}/tags?per_page=100", headers=headers) or []
        versioned = [(item.get("name", str(item)), semver_sort_key(item.get("name", str(item)))) for item in tags]
        versioned = [item for item in versioned if item[1][0] >= 0]
        if versioned:
            return sorted(versioned, key=lambda item: item[1], reverse=True)[0][0]
        repo_info = http_json(f"https://api.github.com/repos/{owner}/{repo}", headers=headers)
        if repo_info and repo_info.get("default_branch"):
            return repo_info["default_branch"]
        raise RuntimeError(f"Could not resolve latest ref for github.com/{owner}/{repo}.")

    def retrieve_from_github(self, module_path: str, requested_version: str, destination: Path) -> dict[str, Any]:
        owner, repo = self.github_repo_from_path(module_path)
        ref = self.latest_github_ref(owner, repo) if requested_version == "latest" else requested_version
        destination.mkdir(parents=True, exist_ok=True)
        safe_ref = safe_file_name(ref)
        zip_file = destination / f"{safe_ref}.github-archive.zip"
        escaped_ref = urllib.parse.quote(ref, safe="")
        http_request(f"https://api.github.com/repos/{owner}/{repo}/zipball/{escaped_ref}", headers=github_headers(self.args.github_token), out_file=zip_file)
        expanded_to = None
        if self.args.expand:
            expanded_to = destination / safe_ref
            expanded_to.mkdir(parents=True, exist_ok=True)
            with zipfile.ZipFile(zip_file) as archive:
                archive.extractall(expanded_to)
        return {
            "Mode": "GitHubArchive",
            "Module": module_path,
            "Ref": ref,
            "Owner": owner,
            "Repository": repo,
            "ZipFile": str(zip_file),
            "ExpandedTo": str(expanded_to) if expanded_to else None,
        }

    def find_gitlab_project(self, host_name: str, module_path: str) -> str:
        if self.args.gitlab_project_path:
            return self.args.gitlab_project_path
        path_without_host = module_path[len(host_name) + 1 :] if module_path.startswith(host_name + "/") else module_path
        parts = path_without_host.split("/")
        for length in range(len(parts), 1, -1):
            candidate = "/".join(parts[:length])
            encoded = urllib.parse.quote(candidate, safe="")
            try:
                http_json(f"https://{host_name}/api/v4/projects/{encoded}", headers=gitlab_headers(self.args.gitlab_token))
                return candidate
            except Exception:
                continue
        raise RuntimeError(f"Could not discover GitLab project for {module_path}. Pass --gitlab-project-path explicitly.")

    def latest_gitlab_ref(self, host_name: str, encoded_project: str) -> str:
        headers = gitlab_headers(self.args.gitlab_token)
        try:
            tags = http_json(f"https://{host_name}/api/v4/projects/{encoded_project}/repository/tags?per_page=100", headers=headers) or []
            versioned = [(item.get("name", str(item)), semver_sort_key(item.get("name", str(item)))) for item in tags]
            versioned = [item for item in versioned if item[1][0] >= 0]
            if versioned:
                return sorted(versioned, key=lambda item: item[1], reverse=True)[0][0]
        except Exception:
            pass
        try:
            project = http_json(f"https://{host_name}/api/v4/projects/{encoded_project}", headers=headers)
            if project and project.get("default_branch"):
                return project["default_branch"]
        except Exception:
            pass
        return "HEAD"

    def retrieve_from_gitlab(self, module_path: str, requested_version: str, destination: Path) -> dict[str, Any]:
        host_name = self.args.gitlab_host or module_path.split("/")[0]
        project_path = self.find_gitlab_project(host_name, module_path)
        encoded_project = urllib.parse.quote(project_path, safe="")
        ref = self.latest_gitlab_ref(host_name, encoded_project) if requested_version == "latest" else requested_version
        destination.mkdir(parents=True, exist_ok=True)
        safe_ref = safe_file_name(ref)
        zip_file = destination / f"{safe_ref}.gitlab-archive.zip"
        uri = f"https://{host_name}/api/v4/projects/{encoded_project}/repository/archive.zip?sha={urllib.parse.quote(ref, safe='')}"
        http_request(uri, headers=gitlab_headers(self.args.gitlab_token), out_file=zip_file)
        expanded_to = None
        if self.args.expand:
            expanded_to = destination / safe_ref
            expanded_to.mkdir(parents=True, exist_ok=True)
            with zipfile.ZipFile(zip_file) as archive:
                archive.extractall(expanded_to)
        return {
            "Mode": "GitLabArchive",
            "Module": module_path,
            "Ref": ref,
            "GitLabHost": host_name,
            "GitLabProject": project_path,
            "ZipFile": str(zip_file),
            "ExpandedTo": str(expanded_to) if expanded_to else None,
        }

    def go_import_meta(self, module_path: str) -> dict[str, str] | None:
        parts = module_path.split("/")
        for length in range(len(parts), 1, -1):
            prefix = "/".join(parts[:length])
            try:
                content = http_text(f"https://{prefix}?go-get=1")
            except Exception:
                continue
            matches = re.finditer(r"<meta\s+[^>]*name=[\"']go-import[\"'][^>]*content=[\"']([^\"']+)[\"'][^>]*>", content, re.I)
            for match in matches:
                fields = match.group(1).strip().split()
                if len(fields) >= 3 and module_path.startswith(fields[0]):
                    return {"Prefix": fields[0], "Vcs": fields[1], "RepoRoot": fields[2]}
        return None

    def retrieve_direct(self, module_path: str, requested_version: str, destination: Path) -> dict[str, Any]:
        host_name = module_path.split("/")[0]
        if host_name == "github.com":
            return self.retrieve_from_github(module_path, requested_version, destination)
        if self.args.gitlab_host or re.search(r"(^|\.)gitlab\.", host_name):
            return self.retrieve_from_gitlab(module_path, requested_version, destination)
        meta = self.go_import_meta(module_path)
        if meta and meta["Vcs"] == "git":
            repo = urllib.parse.urlparse(meta["RepoRoot"])
            if repo.hostname == "github.com":
                return self.retrieve_from_github(meta["RepoRoot"], requested_version, destination)
            if repo.hostname and re.search(r"(^|\.)gitlab\.", repo.hostname):
                return self.retrieve_from_gitlab(repo.hostname + repo.path.rstrip("/"), requested_version, destination)
            raise RuntimeError(
                f"go-import metadata resolved to {meta['RepoRoot']}, but direct archive retrieval is only implemented for GitHub and GitLab."
            )
        raise RuntimeError(f"Direct retrieval for {module_path} is not supported. Use a Go module proxy or a GitHub/GitLab-backed module path.")

    def export_go_proxy_artifact(self, retrieval: dict[str, Any]) -> dict[str, Any] | None:
        if not self.go_proxy_directory:
            return None
        if retrieval.get("Mode") != "ModuleProxy":
            return {
                "Exported": False,
                "Reason": "Only ModuleProxy retrievals can be exported to static Go proxy layout.",
                "Mode": retrieval.get("Mode"),
            }
        for key in ("InfoFile", "ModFile", "ZipFile"):
            if not retrieval.get(key) or not Path(retrieval[key]).exists():
                raise RuntimeError(f"Cannot export {retrieval['Module']}@{retrieval['Version']}: missing proxy file {retrieval.get(key)}")

        module_dir = go_proxy_version_dir(self.go_proxy_directory, retrieval["Module"])
        module_dir.mkdir(parents=True, exist_ok=True)
        escaped_version = escape_go_proxy_segment(retrieval["Version"])
        info_file = module_dir / f"{escaped_version}.info"
        mod_file = module_dir / f"{escaped_version}.mod"
        zip_file = module_dir / f"{escaped_version}.zip"
        list_file = module_dir / "list"
        shutil.copyfile(retrieval["InfoFile"], info_file)
        shutil.copyfile(retrieval["ModFile"], mod_file)
        shutil.copyfile(retrieval["ZipFile"], zip_file)
        versions = set()
        if list_file.exists():
            versions.update(line.strip() for line in list_file.read_text(encoding="utf-8").splitlines() if line.strip())
        versions.add(retrieval["Version"])
        list_file.write_text("\n".join(sorted(versions)) + "\n", encoding="ascii")
        status(f"exported {retrieval['Module']}@{retrieval['Version']} to static proxy {module_dir}")
        return {
            "Exported": True,
            "Module": retrieval["Module"],
            "Version": retrieval["Version"],
            "ModuleDirectory": str(module_dir),
            "ListFile": str(list_file),
            "InfoFile": str(info_file),
            "ModFile": str(mod_file),
            "ZipFile": str(zip_file),
        }

    def retrieve_from_static_proxy(self, module_path: str, requested_version: str) -> dict[str, Any] | None:
        if not self.go_proxy_directory or requested_version == "latest":
            return None
        if not self.static_proxy_version_complete(module_path, requested_version):
            return None
        version_dir = go_proxy_version_dir(self.go_proxy_directory, module_path)
        escaped_version = escape_go_proxy_segment(requested_version)
        status(f"found cached {module_path}@{requested_version} in static proxy {version_dir}")
        return {
            "Mode": "ModuleProxy",
            "Module": module_path,
            "Version": requested_version,
            "Proxy": "GoProxyDirectory",
            "InfoFile": str(version_dir / f"{escaped_version}.info"),
            "ModFile": str(version_dir / f"{escaped_version}.mod"),
            "ZipFile": str(version_dir / f"{escaped_version}.zip"),
            "UsedProxyCache": True,
            "ExpandedTo": None,
            "GoProxyExport": {
                "Exported": True,
                "Reused": True,
                "Module": module_path,
                "Version": requested_version,
                "ModuleDirectory": str(version_dir),
                "ListFile": str(version_dir / "list"),
                "InfoFile": str(version_dir / f"{escaped_version}.info"),
                "ModFile": str(version_dir / f"{escaped_version}.mod"),
                "ZipFile": str(version_dir / f"{escaped_version}.zip"),
            },
        }

    def retrieve_module(self, module_path: str, requested_version: str) -> dict[str, Any]:
        cached = self.retrieve_from_static_proxy(module_path, requested_version)
        if cached:
            return cached

        status(f"retrieving {module_path}@{requested_version}")
        destination = self.output_directory / "modules" / safe_file_name(module_path)  # type: ignore[operator]
        errors: list[str] = []
        for proxy_base in self.proxies():
            if proxy_base == "off":
                break
            try:
                if proxy_base == "direct":
                    status(f"downloading {module_path}@{requested_version} directly")
                    result = self.retrieve_direct(module_path, requested_version, destination)
                else:
                    status(f"downloading {module_path}@{requested_version} from {proxy_base}")
                    result = self.retrieve_from_proxy(module_path, requested_version, proxy_base, destination)
                export = self.export_go_proxy_artifact(result)
                if export:
                    result["GoProxyExport"] = export
                return result
            except Exception as exc:
                errors.append(f"{proxy_base}: {exc}")
                status(f"failed {module_path}@{requested_version} via {proxy_base}: {exc}")
        if not errors:
            raise RuntimeError(f"Could not retrieve module {module_path} because the proxy list disabled retrieval.")
        raise RuntimeError(f"Could not retrieve module {module_path}. Attempts: {' | '.join(errors)}")

    def selected_module_versions(self, retrieved: list[dict[str, Any]]) -> dict[str, list[dict[str, str]]]:
        selected_by_module: dict[str, dict[str, Any]] = {}
        for item in retrieved:
            module = item.get("Module")
            version = item.get("Version")
            if not module or not version:
                continue
            if module not in selected_by_module or compare_go_module_version(version, selected_by_module[module]["Version"]) > 0:
                selected_by_module[module] = item

        selected: list[dict[str, str]] = []
        selected_keys: set[tuple[str, str]] = set()
        superseded: list[dict[str, str]] = []
        for item in retrieved:
            module = item.get("Module")
            version = item.get("Version")
            if not module or not version:
                continue
            chosen = selected_by_module[module]
            if chosen["Version"] == version:
                key = (module, version)
                if key not in selected_keys:
                    selected_keys.add(key)
                    selected.append({"Module": module, "Version": version})
            else:
                superseded.append({"Module": module, "Version": version, "SelectedVersion": chosen["Version"]})
        return {
            "Selected": sorted(selected, key=lambda item: (item["Module"], item["Version"])),
            "Superseded": sorted(superseded, key=lambda item: (item["Module"], item["Version"])),
        }

    def resolve_dependency_graph(self, root_module: str, root_version: str) -> dict[str, Any]:
        queue: deque[dict[str, str]] = deque([{"Module": root_module, "Version": root_version, "Parent": ""}])
        seen: set[str] = set()
        retrieved: list[dict[str, Any]] = []
        failures: list[dict[str, str]] = []
        replacements: list[dict[str, Any]] = []
        exclusions: list[dict[str, str]] = []
        skipped: list[dict[str, str]] = []
        is_root = True
        status(f"resolving dependency graph for {root_module}@{root_version}")

        while queue:
            current = queue.popleft()
            key = f"{current['Module']}@{current['Version']}"
            if key in seen:
                continue
            seen.add(key)
            try:
                result = self.retrieve_module(current["Module"], current["Version"])
                retrieved.append(result)
                mod_file = result.get("ModFile")
                if mod_file and Path(mod_file).exists():
                    directives = parse_go_mod(Path(mod_file))
                    if is_root:
                        replacements = directives["Replacements"]
                        exclusions = directives["Exclusions"]
                        is_root = False
                    for requirement in directives["Requirements"]:
                        child_module = requirement["Module"]
                        child_version = requirement["Version"]
                        if is_excluded(exclusions, child_module, child_version):
                            skipped.append({"Module": child_module, "Version": child_version, "Parent": key, "Reason": "ExcludedByRootGoMod"})
                            continue
                        replacement = find_replacement(replacements, child_module, child_version)
                        if replacement:
                            if replacement["IsLocal"]:
                                skipped.append(
                                    {
                                        "Module": child_module,
                                        "Version": child_version,
                                        "Parent": key,
                                        "Reason": "LocalReplaceCannotBeDownloaded",
                                        "Replacement": replacement["NewModule"],
                                    }
                                )
                                continue
                            child_module = replacement["NewModule"]
                            if replacement["NewVersion"]:
                                child_version = replacement["NewVersion"]
                        child_key = f"{child_module}@{child_version}"
                        if child_key not in seen:
                            queue.append({"Module": child_module, "Version": child_version, "Parent": key})
            except Exception as exc:
                status(f"dependency failed {current['Module']}@{current['Version']} from parent {current['Parent']}: {exc}")
                failures.append({"Module": current["Module"], "Version": current["Version"], "Parent": current["Parent"], "Error": str(exc)})

        version_selection = self.selected_module_versions(retrieved)
        status(
            f"completed dependency graph for {root_module}@{root_version}: retrieved={len(retrieved)}, "
            f"selected={len(version_selection['Selected'])}, failures={len(failures)}, skipped={len(skipped)}"
        )
        return {
            "Mode": "ModuleDependencyGraph",
            "RootModule": root_module,
            "RootVersion": root_version,
            "RetrievedCount": len(retrieved),
            "SelectedCount": len(version_selection["Selected"]),
            "SupersededCount": len(version_selection["Superseded"]),
            "FailureCount": len(failures),
            "SkippedCount": len(skipped),
            "Replacements": replacements,
            "Exclusions": exclusions,
            "Skipped": skipped,
            "Selected": version_selection["Selected"],
            "Superseded": version_selection["Superseded"],
            "Retrieved": retrieved,
            "Failures": failures,
        }

    def retrieve_package_list(self, path: Path) -> dict[str, Any]:
        entries = read_package_list(path, self)
        results: list[dict[str, Any]] = []
        failures: list[dict[str, Any]] = []
        for entry in entries:
            status(f"processing package list entry {entry.line_number}: {entry.package} -> {entry.module}@{entry.version}")
            try:
                retrieval = (
                    self.resolve_dependency_graph(entry.module, entry.version)
                    if self.args.resolve_dependencies
                    else self.retrieve_module(entry.module, entry.version)
                )
                status(f"completed package list entry {entry.line_number}: {entry.package}")
                results.append(
                    {
                        **entry.to_json(),
                        "Success": True,
                        "Result": retrieval,
                    }
                )
            except Exception as exc:
                status(f"failed package list entry {entry.line_number}: {entry.package} - {exc}")
                failure = {
                    "LineNumber": entry.line_number,
                    "Package": entry.package,
                    "Module": entry.module,
                    "Version": entry.version,
                    "Error": str(exc),
                }
                failures.append(failure)
                results.append({**entry.to_json(), "Success": False, "Error": str(exc)})
        return {
            "Mode": "ModulePackageList",
            "PackageList": str(path.resolve()),
            "TargetGoVersion": go_version_string(go_version_tuple(self.args.go_version)) if self.args.go_version else "",
            "Requested": [entry.to_json() for entry in entries],
            "SuccessCount": len([item for item in results if item["Success"]]),
            "FailureCount": len(failures),
            "Results": results,
            "Failures": failures,
        }


def split_go_mod_directive(line: str) -> list[str]:
    return [match.group(0).strip('"') for match in re.finditer(r'"[^"]+"|\S+', line)]


def is_local_module_path(module_path: str) -> bool:
    return module_path.startswith(".") or module_path.startswith("/") or module_path.startswith("\\") or bool(re.match(r"^[A-Za-z]:[\\/]", module_path))


def parse_go_mod(mod_file: Path) -> dict[str, list[dict[str, Any]]]:
    requirements: list[dict[str, str]] = []
    replacements: list[dict[str, Any]] = []
    exclusions: list[dict[str, str]] = []
    block_directive = ""

    for raw_line in mod_file.read_text(encoding="utf-8").splitlines():
        line = re.sub(r"//.*$", "", raw_line).strip()
        if not line:
            continue
        block_match = re.match(r"^(require|replace|exclude)\s+\($", line)
        if block_match:
            block_directive = block_match.group(1)
            continue
        if block_directive and line == ")":
            block_directive = ""
            continue
        directive = block_directive
        if not directive:
            parts_for_directive = split_go_mod_directive(line)
            if not parts_for_directive or parts_for_directive[0] not in {"require", "replace", "exclude"}:
                continue
            directive = parts_for_directive[0]
            line = line[len(directive) :].strip()
        parts = split_go_mod_directive(line)
        if not parts:
            continue
        if directive == "require" and len(parts) >= 2:
            requirements.append({"Module": parts[0], "Version": parts[1]})
        elif directive == "exclude" and len(parts) >= 2:
            exclusions.append({"Module": parts[0], "Version": parts[1]})
        elif directive == "replace":
            try:
                arrow = parts.index("=>")
            except ValueError:
                continue
            if arrow < 1 or arrow == len(parts) - 1:
                continue
            old = parts[:arrow]
            new = parts[arrow + 1 :]
            replacements.append(
                {
                    "OldModule": old[0],
                    "OldVersion": old[1] if len(old) > 1 else "",
                    "NewModule": new[0],
                    "NewVersion": new[1] if len(new) > 1 else "",
                    "IsLocal": is_local_module_path(new[0]),
                }
            )
    return {"Requirements": requirements, "Replacements": replacements, "Exclusions": exclusions}


def find_replacement(replacements: list[dict[str, Any]], module_path: str, version: str) -> dict[str, Any] | None:
    for replacement in replacements:
        if replacement["OldModule"] == module_path and replacement["OldVersion"] == version:
            return replacement
    for replacement in replacements:
        if replacement["OldModule"] == module_path and not replacement["OldVersion"]:
            return replacement
    return None


def is_excluded(exclusions: list[dict[str, str]], module_path: str, version: str) -> bool:
    return any(item["Module"] == module_path and item["Version"] == version for item in exclusions)


def resolve_package_module_path(package_path: str) -> PackagePath:
    package_path = PACKAGE_ALIASES.get(package_path, package_path)
    return PackagePath(package=package_path, module=PACKAGE_MODULE_OVERRIDES.get(package_path, package_path))


def read_package_list(path: Path, fetcher: GoFetcher) -> list[PackageEntry]:
    if not path.exists():
        raise RuntimeError(f"Package list file does not exist: {path}")
    entries: list[PackageEntry] = []
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        line = re.sub(r"\s+#.*$", "", line).strip()
        if not line:
            continue
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=\($", line):
            continue
        if re.match(r"^go\s+install\s+", line):
            parts = [part for part in re.split(r"\s+", line) if part]
            line = parts[-1]
        line = line.strip().rstrip(",").strip("\"'")
        if not line or line in {"(", ")"}:
            continue

        requested_version = ""
        go_directive = ""
        resolved_by_compatibility = False
        if re.match(r"^\S+@\S+$", line):
            package_raw, requested_version = line.rsplit("@", 1)
            resolved = resolve_package_module_path(package_raw)
        else:
            parts = [part for part in re.split(r"[,\s]+", line) if part]
            if len(parts) == 2:
                resolved = resolve_package_module_path(parts[0].strip("\"'"))
                requested_version = parts[1].strip("\"'")
            elif len(parts) == 1:
                if not fetcher.args.go_version:
                    raise RuntimeError(
                        f"Package list entry at {path}:{line_number} does not include a version. "
                        "Pass --go-version to resolve the latest compatible version."
                    )
                resolved = resolve_package_module_path(parts[0].strip("\"'"))
                compatibility = fetcher.resolve_latest_compatible(
                    resolved.package,
                    resolved.module,
                    go_version_tuple(fetcher.args.go_version),
                )
                resolved = PackagePath(package=compatibility["PackagePath"], module=compatibility["ModulePath"])
                requested_version = compatibility["Version"]
                go_directive = compatibility["GoDirective"]
                resolved_by_compatibility = True
            else:
                raise RuntimeError(f"Invalid package list entry at {path}:{line_number}. Use 'package', 'package@version', or 'package version'.")

        if not resolved.module or not requested_version:
            raise RuntimeError(f"Invalid package list entry at {path}:{line_number}. Use 'package', 'package@version', or 'package version'.")
        entries.append(
            PackageEntry(
                line_number=line_number,
                package=resolved.package,
                module=resolved.module,
                version=requested_version,
                resolved_by_compatibility=resolved_by_compatibility,
                compatible_go_directive=go_directive,
            )
        )
    if not entries:
        raise RuntimeError(f"Package list file did not contain any package/version entries: {path}")
    return entries


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Retrieve Go modules and optional static Go proxy artifacts.")
    parser.add_argument("-Module", "--module", default="")
    parser.add_argument("-Version", "--version", default="latest")
    parser.add_argument("-PackageListPath", "--package-list-path", default="")
    parser.add_argument("-GoVersion", "--go-version", default="")
    parser.add_argument("-Proxy", "--proxy", action="append", default=[])
    parser.add_argument("-GitLabHost", "--gitlab-host", default="")
    parser.add_argument("-GitLabProjectPath", "--gitlab-project-path", default="")
    parser.add_argument("-OutputDirectory", "--output-directory", default="")
    parser.add_argument("-GoProxyDirectory", "--go-proxy-directory", default="")
    parser.add_argument("-ArchiveOutput", "--archive-output", default="")
    parser.add_argument("-GitLabToken", "--gitlab-token", default=os.environ.get("GITLAB_TOKEN", ""))
    parser.add_argument("-GitHubToken", "--github-token", default=os.environ.get("GITHUB_TOKEN", ""))
    parser.add_argument("-ResolveDependencies", "--resolve-dependencies", action="store_true")
    parser.add_argument("-Expand", "--expand", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if bool(args.module) == bool(args.package_list_path):
        print("Specify exactly one of --module or --package-list-path.", file=sys.stderr)
        return 2
    fetcher = GoFetcher(args)
    exit_code = 0
    try:
        if args.package_list_path:
            result = fetcher.retrieve_package_list(Path(args.package_list_path))
            if result["FailureCount"] > 0:
                exit_code = 1
        elif args.resolve_dependencies:
            result = fetcher.resolve_dependency_graph(args.module, args.version)
        else:
            result = fetcher.retrieve_module(args.module, args.version)
        print(json.dumps(fetcher.finalize(result), indent=2))
        return exit_code
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 1
    finally:
        fetcher.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
