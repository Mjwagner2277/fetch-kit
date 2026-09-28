#!/usr/bin/env python3
"""HTTP-only bundle integration tests; Python stdlib + Node, no npm or system tar.

Run: python3 -m unittest discover -s npm/tests -p 'test_npm_http_bundle.py' -v
All registries are local fixtures. The downloader runs with an empty PATH and a
preload that rejects child_process imports, including indirect CLI dependencies.
"""

import base64
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit

from test_upload_npm_artifactory_bundle import FixtureRegistry, archive_metadata


NPM_DIR = Path(__file__).resolve().parents[1]
DOWNLOADER = NPM_DIR / "download-npm-http-bundle.js"
UPLOADER = NPM_DIR / "upload-npm-artifactory-bundle.py"
NODE = shutil.which("node")


def integrity(data):
    return "sha512-" + base64.b64encode(hashlib.sha512(data).digest()).decode()


def package_archive(metadata, extra_files=None, extra_members=()):
    files = {
        "package/package.json": json.dumps(metadata).encode(),
        "package/index.js": b"module.exports = 42;\n",
    }
    files.update(extra_files or {})
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w:gz") as archive:
        for name, content in files.items():
            record = tarfile.TarInfo(name)
            record.size = len(content)
            record.mode = 0o644
            archive.addfile(record, io.BytesIO(content))
        for record, content in extra_members:
            archive.addfile(record, io.BytesIO(content) if content is not None else None)
    return stream.getvalue()


class SourceRegistry:
    def __init__(self):
        self.documents = {}
        self.blobs = {}
        self.requests = []
        self.redirects = {}
        self.errors = {}
        self.before_response = None
        self.disabled = False
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                route = unquote(urlsplit(self.path).path)
                fixture.requests.append({"path": route,
                                         "authorization": self.headers.get("Authorization")})
                if fixture.before_response is not None:
                    fixture.before_response(route)
                if route in fixture.redirects:
                    self.send_response(302)
                    self.send_header("Location", fixture.redirects[route])
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if fixture.disabled:
                    status, body = 503, {"error": "source_is_offline"}
                elif route in fixture.errors:
                    status, body = fixture.errors[route], {"error": "fixture_error"}
                elif route in fixture.blobs:
                    status, body = 200, fixture.blobs[route]
                elif route.startswith("/source/") and route[len("/source/"):] in fixture.documents:
                    status, body = 200, fixture.documents[route[len("/source/"):]]
                else:
                    status, body = 404, {"error": "not_found"}
                if not isinstance(body, bytes):
                    body = json.dumps(body).encode()
                    content_type = "application/json"
                else:
                    content_type = "application/octet-stream"
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.origin = "http://127.0.0.1:" + str(self.server.server_port)
        self.url = self.origin + "/source/"
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       kwargs={"poll_interval": 0.01}, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def add(self, name, version="1.0.0", metadata=None, extra_files=None, archive_metadata_override=None,
            extra_members=()):
        manifest = {"name": name, "version": version, "main": "index.js"}
        manifest.update(metadata or {})
        blob = package_archive(archive_metadata_override or manifest, extra_files, extra_members)
        route = "/source/" + name + "/-/" + name.split("/")[-1] + "-" + version + ".tgz"
        self.blobs[route] = blob
        manifest["dist"] = {"tarball": self.origin + route, "integrity": integrity(blob),
                            "shasum": hashlib.sha1(blob).hexdigest()}
        document = self.documents.setdefault(name, {"name": name, "versions": {}, "dist-tags": {}})
        document["versions"][version] = manifest
        document["dist-tags"]["latest"] = version
        return manifest


@unittest.skipUnless(NODE, "Requires Node, but not npm")
class HTTPBundleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.local_node = subprocess.check_output([NODE, "--version"], text=True).strip()
        cls.future_major = int(cls.local_node.lstrip("v").split(".")[0]) + 2
        cls.target_node = str(cls.future_major) + ".0.0"

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="npm http bundle ")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.output = self.root / "bundle"
        self.transfer = self.root / "transfer.tar"
        self.downloader = DOWNLOADER
        self.process_guard = self.root / "deny child processes.cjs"
        self.process_guard.write_text("""'use strict';
const Module = require('module');
const originalLoad = Module._load;
Module._load = function (name, ...args) {
  if (name === 'child_process' || name === 'node:child_process') {
    throw new Error('HTTP-only workflow must not load ' + name);
  }
  return originalLoad.call(this, name, ...args);
};
""")
        self.source = SourceRegistry()
        self.addCleanup(self.source.close)
        self.env = os.environ.copy()
        for key in list(self.env):
            if key.lower().startswith("npm_config_") or key.lower() in (
                    "npm_token", "npm_username", "npm_password", "npm_bin",
                    "node_options", "node_path", "http_proxy", "https_proxy", "all_proxy",
                    "artifactory_token", "path"):
                self.env.pop(key)
        # Windows commonly stores this as Path. Remove every casing before
        # adding the empty value so neither npm.cmd nor tar can be found.
        self.env["PATH"] = ""
        self.marker = self.root / "hook-ran"

    def download(self, packages, *extra, success=True, token=None, windows_list=False,
                 packages_file=None, failure_tarball=None):
        requested = packages_file or self.root / "packages.txt"
        if packages_file:
            pass
        elif windows_list:
            requested.write_bytes(("\ufeff" + "\r\n".join(packages) + "\r\n").encode("utf-8"))
        else:
            requested.write_text("\n".join(packages) + "\n")
        env = self.env.copy()
        if token:
            env["NPM_TOKEN"] = token
        result = subprocess.run([
            NODE, "--require", str(self.process_guard), str(self.downloader), "--node-version", self.target_node,
            "--packages-file", str(requested), "--registry", self.source.url,
            "--output-dir", str(self.output), "--tar-file", str(self.transfer), *extra,
        ], cwd=self.root, env=env, capture_output=True, text=True, timeout=60)
        diagnostic = result.stdout + "\n" + result.stderr
        if success:
            self.assertEqual(result.returncode, 0, diagnostic)
            self.assertTrue(self.transfer.is_file(), diagnostic)
        else:
            self.assertNotEqual(result.returncode, 0, diagnostic)
            if failure_tarball is None:
                self.assertFalse(self.transfer.exists(), "Failure must not leave a successful transfer archive")
            else:
                self.assertEqual(self.transfer.read_bytes(), failure_tarball,
                                 "A concurrent transfer archive must never be overwritten")
        self.assertFalse(self.marker.exists(), "No package lifecycle hook may execute")
        return result

    def entries(self):
        return json.loads((self.output / "packages.json").read_text())

    def identities(self):
        return {(item["name"], item["version"]) for item in self.entries()}

    def graph(self):
        return json.loads((self.output / "dependency-graph.json").read_text())

    def download_state(self):
        return json.loads((self.output / "download-state.json").read_text())

    def source_request_count(self, route):
        return sum(item["path"] == route for item in self.source.requests)

    def assert_incomplete(self, status="failed"):
        self.assertTrue(self.output.is_dir(), "Downloaded progress must survive a resolution failure")
        self.assertTrue((self.output / "npm-bundle.INCOMPLETE").is_file())
        summary = json.loads((self.output / "summary.json").read_text())
        self.assertEqual(summary["status"], status)
        self.assertFalse(summary["closureComplete"])
        self.assertTrue(summary["error"])
        self.assertFalse((self.output / "packages.json").exists())
        self.assertFalse((self.output / "packages.jsonl").exists())
        partial_graph = json.loads((self.output / "partial-dependency-graph.json").read_text())
        self.assertFalse(partial_graph["closureComplete"])
        return json.loads((self.output / "partial-packages.json").read_text())

    def assert_archive_valid(self):
        for entry in self.entries():
            data = (self.output / entry["tarball"]).read_bytes()
            self.assertEqual(entry["sha512"], hashlib.sha512(data).hexdigest())
            self.assertEqual(entry["sha1"], hashlib.sha1(data).hexdigest())
            self.assertEqual(entry["bytes"], len(data))
            package = archive_metadata(data)
            self.assertEqual((package["name"], package["version"]), (entry["name"], entry["version"]))
            self.assertNotIn("scripts", package)
            self.assertNotIn("publishConfig", package)
            self.assertNotIn("private", package)
        with tarfile.open(self.transfer) as transfer:
            names = transfer.getnames()
            self.assertTrue(any(name.endswith("/packages.json") or name == "packages.json" for name in names))
            for entry in self.entries():
                member = next(name for name in names if name.endswith("/" + entry["tarball"]) or name == entry["tarball"])
                self.assertEqual(transfer.extractfile(member).read(), (self.output / entry["tarball"]).read_bytes())

    def test_future_target_deep_graph_cycles_aliases_and_multiple_versions(self):
        future = str(self.future_major)
        self.source.add("app", metadata={
            "engines": {"node": ">=" + future},
            "dependencies": {"level-one": "^1.0.0", "alias-name": "npm:@fixture/leaf@^1.0.0"},
            "scripts": {"prepublish": "exit 99", "prepublishOnly": "exit 99", "publish": "exit 99",
                        "install": 'node -e "require(\'fs\').writeFileSync(' + json.dumps(str(self.marker)) + ',\'yes\')"'},
            "private": True, "publishConfig": {"registry": "https://unreachable.invalid"},
        })
        self.source.add("app", "2.0.0", {"engines": {"node": ">=" + str(self.future_major + 1)}})
        self.source.add("level-one", metadata={"dependencies": {"level-two": "1.0.0"}})
        self.source.add("level-two", metadata={"dependencies": {"level-three": "1.0.0"}})
        self.source.add("level-three", metadata={"dependencies": {"level-one": "1.0.0"}})
        self.source.add("@fixture/leaf")
        self.source.add("versions", "1.0.0")
        self.source.add("versions", "2.0.0")
        self.download(["# roots, including two versions of one package", "app", "versions@2.0.0", "versions@1.0.0"])
        self.assertEqual(self.identities(), {("app", "1.0.0"), ("level-one", "1.0.0"),
            ("level-two", "1.0.0"), ("level-three", "1.0.0"), ("@fixture/leaf", "1.0.0"),
            ("versions", "1.0.0"), ("versions", "2.0.0")})
        graph = self.graph()
        self.assertTrue(graph["closureComplete"])
        self.assertEqual(len(graph["roots"]), 3)
        self.assertTrue(any(edge.get("installName") == "alias-name" for edge in graph["edges"]))
        self.assertEqual(sum(request["path"] == "/source/level-one" for request in self.source.requests), 1)
        self.assert_archive_valid()

    def test_every_transitive_version_is_filtered_by_target_node(self):
        self.source.add("app", metadata={"dependencies": {"engine-leaf": ">=1 <3"}})
        self.source.add("engine-leaf", "1.0.0", {"engines": {"node": ">=" + str(self.future_major)}})
        self.source.add("engine-leaf", "2.0.0", {"engines": {"node": ">=" + str(self.future_major + 1)}})
        self.download(["app@1.0.0"])
        self.assertEqual(self.identities(), {("app", "1.0.0"), ("engine-leaf", "1.0.0")})

    def test_package_list_preserves_spaces_in_inline_and_separate_ranges(self):
        for name in ("app", "@fixture/space"):
            for version in ("1.0.0", "2.0.0", "3.0.0"):
                self.source.add(name, version)
        self.download(["app@>=1 <3", "@fixture/space >=1 <3"])
        self.assertEqual(self.identities(), {("app", "2.0.0"), ("@fixture/space", "2.0.0")})

    def test_windows_bom_encodings_accept_text_and_uppercase_json_lists(self):
        self.source.add("app")
        for encoding, bom in (("utf-8", b"\xef\xbb\xbf"),
                              ("utf-16-le", b"\xff\xfe"), ("utf-16-be", b"\xfe\xff")):
            for extension, contents in (("txt", "# Windows package list\r\napp@1.0.0\r\n"),
                                       ("JSON", '{\r\n  "dependencies": {"app": "1.0.0"}\r\n}\r\n')):
                with self.subTest(encoding=encoding, extension=extension):
                    slug = encoding + "-" + extension
                    self.output = self.root / ("bundle-" + slug)
                    self.transfer = self.root / ("transfer-" + slug + ".tar")
                    requested = self.root / ("packages-" + slug + "." + extension)
                    requested.write_bytes(bom + contents.encode(encoding))
                    self.download([], packages_file=requested)
                    self.assertEqual(self.identities(), {("app", "1.0.0")})

    def test_windows_transfer_path_cannot_alias_the_bundle_directory(self):
        cases = [
            [r"C:\Transfer\Bundle", r"c:\transfer\BUNDLE\transfer.tar", True],
            [r"C:\Transfer\Bundle", r"c:\transfer\BUNDLE", True],
            [r"C:\Transfer\Bundle", r"C:\Transfer\Bundle-other\transfer.tar", False],
            [r"C:\Transfer\Bundle", r"C:\Transfer\transfer.tar", False],
            [r"C:\Transfer\Bundle", r"D:\Transfer\Bundle\transfer.tar", False],
        ]
        script = """
const assert = require('assert');
const {win32} = require('path');
const {isWithinDirectory} = require(process.argv[1]);
for (const [directory, candidate, expected] of JSON.parse(process.argv[2])) {
  assert.strictEqual(isWithinDirectory(directory, candidate, win32), expected, candidate);
}
"""
        result = subprocess.run([NODE, "--require", str(self.process_guard), "-e", script,
                                 str(self.downloader), json.dumps(cases)], cwd=self.root,
                                env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + "\n" + result.stderr)

    def test_transfer_on_filesystem_without_hardlinks_preserves_concurrent_archive(self):
        self.source.add("app")
        guard = self.process_guard.read_text()
        existing = b"another completed transfer"
        for concurrent in (False, True):
            with self.subTest(concurrent=concurrent):
                self.output = self.root / ("bundle-hardlinks-" + str(concurrent))
                self.transfer = self.root / ("transfer-hardlinks-" + str(concurrent) + ".tar")
                self.process_guard.write_text(guard + "\nconst fs = require('fs');\n"
                    "fs.linkSync = function (source, destination) {\n" +
                    ("  fs.writeFileSync(destination, 'another completed transfer', {flag: 'wx'});\n"
                     if concurrent else "") +
                    "  throw Object.assign(new Error('fixture: hardlinks unavailable'), {code: 'ENOTSUP'});\n"
                    "};\n")
                self.download(["app"], success=not concurrent,
                              failure_tarball=existing if concurrent else None)
                if concurrent:
                    summary = json.loads((self.output / "summary.json").read_text())
                    self.assertEqual(summary["status"], "archive-failed")
                    self.assertTrue(summary["closureComplete"])
                    self.assertFalse((self.output / "npm-bundle.INCOMPLETE").exists())
                    self.assertEqual(self.identities(), {("app", "1.0.0")})
                else:
                    self.assert_archive_valid()

    def test_peers_optional_peers_and_optional_override_are_included(self):
        self.source.add("app", metadata={
            "dependencies": {"overridden": "1.0.0"},
            "optionalDependencies": {"overridden": "2.0.0", "optional-leaf": "1.0.0"},
            "peerDependencies": {"peer-leaf": "^1.0.0", "optional-peer": "^1.0.0"},
            "peerDependenciesMeta": {"optional-peer": {"optional": True}},
            "devDependencies": {"never-request-dev": "1.0.0"},
        })
        for name in ("optional-leaf", "peer-leaf", "optional-peer"):
            self.source.add(name)
        self.source.add("overridden", "1.0.0")
        self.source.add("overridden", "2.0.0")
        self.download(["app"])
        self.assertEqual(self.identities(), {("app", "1.0.0"), ("overridden", "2.0.0"),
            ("optional-leaf", "1.0.0"), ("peer-leaf", "1.0.0"), ("optional-peer", "1.0.0")})
        self.assertFalse(any("never-request-dev" in request["path"] for request in self.source.requests))

    def test_target_platform_omits_only_incompatible_optional_packages(self):
        self.source.add("app", metadata={"optionalDependencies": {"windows-only": "1.0.0",
                            "glibc-only": "1.0.0", "linux-arm": "1.0.0"}})
        self.source.add("windows-only", metadata={"os": ["win32"]})
        self.source.add("glibc-only", metadata={"os": ["linux"], "libc": ["glibc"]})
        self.source.add("linux-arm", metadata={"os": ["linux"], "cpu": ["arm64"], "libc": ["musl"]})
        self.download(["app"], "--target-os", "linux", "--target-arch", "arm64", "--target-libc", "musl")
        self.assertEqual(self.identities(), {("app", "1.0.0"), ("linux-arm", "1.0.0")})
        self.assertEqual(len(self.graph()["omissions"]), 2)
        self.assertFalse(any("windows-only/-/" in request["path"] for request in self.source.requests))

    def test_bundled_manifests_are_sanitized_and_external_dependencies_resolved(self):
        embedded = {"name": "embedded", "version": "1.0.0",
                    "scripts": {"prepublish": "exit 97", "postinstall": "exit 98"},
                    "dependencies": {"external-leaf": "^1.0.0"}, "private": True,
                    "publishConfig": {"registry": "https://unreachable.invalid"}}
        nested = {"name": "nested", "version": "1.0.0", "scripts": {"prepare": "exit 99"},
                  "dependencies": {"deep-external": "1.0.0"}}
        embedded["dependencies"]["nested"] = "1.0.0"
        self.source.add("app", metadata={"dependencies": {"embedded": "1.0.0"},
                            "bundledDependencies": ["embedded"]}, extra_files={
            "package/node_modules/embedded/package.json": json.dumps(embedded).encode(),
            "package/node_modules/embedded/node_modules/nested/package.json": json.dumps(nested).encode(),
        })
        self.source.add("external-leaf")
        self.source.add("deep-external")
        self.download(["app"])
        self.assertEqual(self.identities(), {("app", "1.0.0"), ("external-leaf", "1.0.0"), ("deep-external", "1.0.0")})
        app = next(entry for entry in self.entries() if entry["name"] == "app")
        with tarfile.open(self.output / app["tarball"]) as archive:
            for name in archive.getnames():
                if name.endswith("package.json"):
                    self.assertNotIn("scripts", json.load(archive.extractfile(name)))
        self.assertFalse(any(request["path"] in ("/source/embedded", "/source/nested")
                             for request in self.source.requests))

    def test_incompatible_bundled_version_cannot_leave_partial_optional_package(self):
        self.source.add("app", metadata={"optionalDependencies": {"optional-container": "1.0.0"}})
        embedded = {"name": "embedded", "version": "1.0.0",
                    "engines": {"node": ">=" + str(self.future_major + 1)}}
        self.source.add("optional-container", metadata={"dependencies": {"embedded": "1.0.0"},
                    "bundledDependencies": ["embedded"]}, extra_files={
            "package/node_modules/embedded/package.json": json.dumps(embedded).encode(),
        })
        result = self.download(["app"], success=False)
        self.assertIn("embedded", result.stdout + result.stderr)
        self.assert_incomplete()

    def test_long_valid_package_names_survive_transfer_archive(self):
        name = "@fixture/" + "long-package-name-" * 10
        self.assertLess(len(name), 214)
        self.source.add(name)
        self.download([name])
        self.assertEqual(self.identities(), {(name, "1.0.0")})
        self.assert_archive_valid()

    def test_dependency_tags_are_pinned_for_offline_use_including_aliases_and_bundles(self):
        embedded = {"name": "embedded", "version": "1.0.0",
                    "dependencies": {"embedded-channel": "preview"}}
        self.source.add("app", metadata={
            "dependencies": {"release-channel": "preview", "latest-leaf": "latest", "intended-latest": "latest",
                             "release-alias": "npm:@fixture/aliased@canary", "embedded": "1.0.0"},
            "peerDependencies": {"peer-channel": "next"},
            "optionalDependencies": {"optional-channel": "next"},
            "bundledDependencies": ["embedded"],
        }, extra_files={"package/node_modules/embedded/package.json": json.dumps(embedded).encode()})
        for name, tag in (("release-channel", "preview"), ("embedded-channel", "preview"),
                          ("peer-channel", "next"), ("optional-channel", "next")):
            self.source.add(name, "1.0.0")
            self.source.add(name, "2.0.0")
            self.source.documents[name]["dist-tags"][tag] = "1.0.0"
        self.source.add("latest-leaf", "1.0.0")
        self.source.add("latest-leaf", "2.0.0", {"engines": {"node": ">=" + str(self.future_major + 1)}})
        self.source.add("intended-latest", "1.0.0")
        self.source.add("intended-latest", "2.0.0")
        self.source.documents["intended-latest"]["dist-tags"]["latest"] = "1.0.0"
        self.source.add("@fixture/aliased", "1.0.0-beta.1")
        self.source.documents["@fixture/aliased"]["dist-tags"]["canary"] = "1.0.0-beta.1"
        self.download(["app"])
        self.assertIn(("latest-leaf", "1.0.0"), self.identities())
        self.assertNotIn(("latest-leaf", "2.0.0"), self.identities())
        app = next(item for item in self.entries() if item["name"] == "app")
        with tarfile.open(self.output / app["tarball"]) as archive:
            metadata = json.load(archive.extractfile("package/package.json"))
            bundled = json.load(archive.extractfile("package/node_modules/embedded/package.json"))
        self.assertEqual(metadata["dependencies"]["release-channel"], "1.0.0")
        self.assertEqual(metadata["dependencies"]["latest-leaf"], "1.0.0")
        self.assertEqual(metadata["dependencies"]["intended-latest"], "1.0.0")
        self.assertEqual(metadata["dependencies"]["release-alias"], "npm:@fixture/aliased@1.0.0-beta.1")
        self.assertEqual(metadata["peerDependencies"]["peer-channel"], "1.0.0")
        self.assertEqual(metadata["optionalDependencies"]["optional-channel"], "1.0.0")
        self.assertEqual(bundled["dependencies"]["embedded-channel"], "1.0.0")
        self.assert_archive_valid()

    def test_published_shrinkwraps_fail_explicitly_in_root_and_bundled_packages(self):
        for index, prefix in enumerate(("package/", "package/node_modules/embedded/")):
            with self.subTest(prefix=prefix):
                self.output = self.root / ("bundle-shrinkwrap-" + str(index))
                self.transfer = self.root / ("transfer-shrinkwrap-" + str(index) + ".tar")
                files = {prefix + "npm-shrinkwrap.json": json.dumps({"lockfileVersion": 2,
                    "name": "app" if index == 0 else "embedded", "version": "1.0.0", "packages": {}}).encode()}
                metadata = {}
                if index:
                    files[prefix + "package.json"] = json.dumps({"name": "embedded", "version": "1.0.0"}).encode()
                    metadata = {"dependencies": {"embedded": "1.0.0"}, "bundledDependencies": ["embedded"]}
                self.source.add("app", metadata=metadata, extra_files=files)
                result = self.download(["app"], success=False)
                self.assertIn("shrinkwrap", (result.stdout + result.stderr).lower())
                self.assert_incomplete()

    def test_noncanonical_manifests_and_archive_links_are_rejected(self):
        cases = ("package/node_modules/embedded/./package.json",
                 "package//node_modules/embedded/package.json", "symlink", "hardlink")
        for index, case in enumerate(cases):
            with self.subTest(case=case):
                self.output = self.root / ("bundle-path-" + str(index))
                self.transfer = self.root / ("transfer-path-" + str(index) + ".tar")
                if case in ("symlink", "hardlink"):
                    record = tarfile.TarInfo("package/link")
                    record.type = tarfile.SYMTYPE if case == "symlink" else tarfile.LNKTYPE
                    record.linkname = "package/index.js"
                    self.source.add("app", extra_members=[(record, None)])
                else:
                    embedded = {"name": "embedded", "version": "1.0.0", "scripts": {"postinstall": "exit 99"}}
                    self.source.add("app", extra_files={case: json.dumps(embedded).encode()})
                result = self.download(["app"], success=False)
                self.assertRegex((result.stdout + result.stderr).lower(), "canonical|link")
                self.assert_incomplete()

    def test_integrity_failure_does_not_make_transfer_archive(self):
        metadata = self.source.add("app")
        metadata["dist"]["integrity"] = integrity(b"different bytes")
        result = self.download(["app"], success=False)
        self.assertIn("integrity", (result.stdout + result.stderr).lower())

    def test_preflight_error_does_not_create_a_download_directory(self):
        self.source.add("app")
        self.download(["app"], "--node-version", "not-a-node-version", success=False)
        self.assertFalse(self.output.exists())
        self.assertFalse(self.source.requests, "Invalid configuration must fail before registry access")

    def test_required_unresolved_dependency_fails(self):
        self.source.add("app", metadata={"dependencies": {"missing": "1.0.0"}})
        result = self.download(["app"], success=False)
        self.assertIn("missing", result.stdout + result.stderr)

    def test_live_directory_preserves_progress_and_resumes_without_redownloading(self):
        metadata = self.source.add("app", metadata={"dependencies": {"missing": "1.0.0"},
            "scripts": {"prepublish": "exit 99", "postinstall": "exit 99"},
            "private": True, "publishConfig": {"registry": "https://unreachable.invalid"}})
        app_blob_route = unquote(urlsplit(metadata["dist"]["tarball"]).path)
        observations = []

        def observe_live_directory(route):
            if route != "/source/missing":
                return
            # The later request has not received its response yet: this proves
            # the files are visible during resolution, not only in its catch.
            try:
                entries = json.loads((self.output / "partial-packages.json").read_text())
                observations.append({
                    "entries": entries,
                    "metadata": [archive_metadata((self.output / item["tarball"]).read_bytes())
                                 for item in entries],
                    "summary": json.loads((self.output / "summary.json").read_text()),
                    "state": self.download_state(),
                    "graph": json.loads((self.output / "partial-dependency-graph.json").read_text()),
                    "incomplete": (self.output / "npm-bundle.INCOMPLETE").is_file(),
                    "final_manifest": (self.output / "packages.json").exists(),
                    "transfer": self.transfer.exists(),
                })
            except Exception as exc:
                observations.append({"error": repr(exc)})

        self.source.before_response = observe_live_directory
        self.download(["app"], success=False)
        self.assertTrue(observations)
        for observed in observations:
            self.assertNotIn("error", observed, observed)
            self.assertEqual([(item["name"], item["version"]) for item in observed["entries"]],
                             [("app", "1.0.0")])
            self.assertEqual(observed["summary"]["status"], "resolving")
            self.assertEqual(observed["state"]["schemaVersion"], 1)
            self.assertEqual(observed["state"]["inputMode"], "http-package-list")
            saved_app = next(item for item in observed["state"]["packages"] if item["name"] == "app")
            self.assertEqual(saved_app["version"], "1.0.0")
            for field in ("integrity", "cacheKey", "tarball"):
                self.assertTrue(saved_app[field], "Incremental state must retain " + field)
            self.assertFalse(observed["summary"]["closureComplete"])
            self.assertFalse(observed["graph"]["closureComplete"])
            self.assertTrue(observed["incomplete"])
            self.assertFalse(observed["final_manifest"])
            self.assertFalse(observed["transfer"])
            for package in observed["metadata"]:
                for field in ("scripts", "private", "publishConfig"):
                    self.assertNotIn(field, package)
        partial = self.assert_incomplete()
        self.assertEqual([(item["name"], item["version"]) for item in partial], [("app", "1.0.0")])

        # A normal rerun must neither discard progress nor silently resume it.
        summary_before = (self.output / "summary.json").read_bytes()
        requests_before = len(self.source.requests)
        self.download(["app"], success=False)
        self.assertEqual((self.output / "summary.json").read_bytes(), summary_before)
        self.assertEqual(len(self.source.requests), requests_before)
        self.download(["app"], "--resume", "--target-os", "linux", success=False)
        self.assertEqual((self.output / "summary.json").read_bytes(), summary_before,
                         "A different resolution profile must not overwrite saved progress")
        self.assertEqual(len(self.source.requests), requests_before)

        destination = FixtureRegistry()
        self.addCleanup(destination.close)
        result = subprocess.run([
            sys.executable, str(UPLOADER), "--bundle-dir", str(self.output),
            "--registry-url", destination.url, "--allow-http", "--work-dir", str(self.root / "incomplete-upload"),
        ], cwd=self.root, env=self.env, capture_output=True, text=True, timeout=60)
        self.assertNotEqual(result.returncode, 0, result.stdout + "\n" + result.stderr)
        self.assertIn("incomplete", (result.stdout + result.stderr).lower())
        self.assertFalse(destination.requests, "Incomplete progress must be rejected before destination access")

        self.source.before_response = None
        self.source.add("missing")
        metadata_count = sum(item["path"] == "/source/app" for item in self.source.requests)
        self.download(["app"], "--resume")
        self.assertEqual(sum(item["path"] == app_blob_route for item in self.source.requests), 1,
                         "A verified cached tarball must not be downloaded again")
        self.assertGreater(sum(item["path"] == "/source/app" for item in self.source.requests), metadata_count,
                           "Resume must resolve using fresh registry metadata")
        self.assertEqual(self.identities(), {("app", "1.0.0"), ("missing", "1.0.0")})
        summary = json.loads((self.output / "summary.json").read_text())
        self.assertEqual(summary["status"], "complete")
        self.assertTrue(summary["closureComplete"])
        for filename in ("npm-bundle.INCOMPLETE", "partial-packages.json", "partial-dependency-graph.json"):
            self.assertFalse((self.output / filename).exists())
        self.assert_archive_valid()

    def test_resume_revalidates_and_refetches_corrupted_cached_tarballs(self):
        metadata = self.source.add("app", metadata={"dependencies": {"missing": "1.0.0"}})
        app_blob_route = unquote(urlsplit(metadata["dist"]["tarball"]).path)
        self.download(["app"], success=False)
        self.assert_incomplete()
        cache = Path(str(self.output) + ".cache")
        raw_files = [file for file in cache.rglob("*.tgz")
                     if file.read_bytes() == self.source.blobs[app_blob_route]]
        self.assertEqual(len(raw_files), 1, "Keep one original verified tarball for resuming this package")
        raw_files[0].write_bytes(b"tampered cache contents")
        self.source.add("missing")
        self.download(["app"], "--resume")
        self.assertEqual(sum(item["path"] == app_blob_route for item in self.source.requests), 2,
                         "A corrupt cached tarball must be replaced with a verified source download")
        self.assert_archive_valid()

    def test_repeated_failed_resume_drops_previously_selected_versions_from_ready_bundle(self):
        original = self.source.add("app", "1.0.0", {"dependencies": {"missing": "1.0.0"}})
        original_route = unquote(urlsplit(original["dist"]["tarball"]).path)
        original_bytes = self.source.blobs[original_route]
        self.download(["app"], success=False)
        partial = self.assert_incomplete()
        self.assertEqual([(item["name"], item["version"]) for item in partial], [("app", "1.0.0")])
        earlier_tarball = self.output / partial[0]["tarball"]
        self.assertTrue(earlier_tarball.is_file())

        # This retry cannot even resolve its first root. A subsequent retry
        # must account for tarballs from earlier runs despite its empty graph.
        self.source.disabled = True
        self.download(["app"], "--resume", success=False)
        self.assert_incomplete()
        self.source.disabled = False
        self.source.add("app", "2.0.0")
        self.download(["app"], "--resume")

        self.assertEqual(self.identities(), {("app", "2.0.0")})
        selected = {entry["tarball"] for entry in self.entries()}
        actual = {file.relative_to(self.output).as_posix()
                  for file in (self.output / "tarballs").rglob("*.tgz")}
        self.assertEqual(actual, selected, "Ready directory must contain only currently selected tarballs")
        self.assertFalse(earlier_tarball.exists())
        with tarfile.open(self.transfer) as transfer:
            packed = {name.split("/", 1)[1] for name in transfer.getnames() if name.endswith(".tgz")}
        self.assertEqual(packed, selected, "Transfer archive must not retain a stale package version")
        cache = Path(str(self.output) + ".cache")
        self.assertTrue(any(file.read_bytes() == original_bytes for file in cache.rglob("*.tgz")),
                        "Removing an obsolete prepared package must retain its reusable source cache")
        self.assert_archive_valid()

    def test_update_complete_bundle_merges_roots_reuses_cache_and_adds_explicit_versions(self):
        custom_cache = self.root / "custom source cache"
        app = self.source.add("app", metadata={"dependencies": {"shared": "1.0.0"}})
        shared = self.source.add("shared")
        app_route = unquote(urlsplit(app["dist"]["tarball"]).path)
        shared_route = unquote(urlsplit(shared["dist"]["tarball"]).path)
        self.download(["app"], "--cache-dir", str(custom_cache))
        first_tar = self.transfer
        first_tar_bytes = first_tar.read_bytes()
        self.source.add("extra", metadata={"dependencies": {"shared": "1.0.0"}})
        self.transfer = self.root / "transfer-extended.tar"
        self.download(["extra"], "--update")
        self.assertEqual(self.identities(), {("app", "1.0.0"), ("shared", "1.0.0"), ("extra", "1.0.0")})
        state = self.download_state()
        self.assertEqual(set(state["resumeProfile"]["packageSpecs"]), {"app", "extra"})
        self.assertEqual(Path(state["cacheDir"]), custom_cache)
        self.assertEqual(self.source_request_count(app_route), 1)
        self.assertEqual(self.source_request_count(shared_route), 1)
        self.assertEqual(self.source_request_count("/source/app"), 2,
                         "An incremental update must still consult fresh metadata")
        self.assertEqual(first_tar.read_bytes(), first_tar_bytes)
        self.assert_archive_valid()

        # An expanded list must deduplicate roots and preserve prior selections
        # even when the registry's latest channel has advanced.
        self.source.add("app", "2.0.0", {"dependencies": {"shared": "1.0.0"}})
        second_tar = self.transfer
        second_tar_bytes = second_tar.read_bytes()
        self.transfer = self.root / "transfer-refreshed.tar"
        self.download(["app", "extra", "app"], "--update")
        specs = self.download_state()["resumeProfile"]["packageSpecs"]
        self.assertEqual(len(specs), 2)
        self.assertEqual(set(specs), {"app", "extra"})
        self.assertEqual(len(self.graph()["roots"]), 2)
        self.assertEqual(self.identities(), {("app", "1.0.0"), ("shared", "1.0.0"), ("extra", "1.0.0")})
        self.assertEqual(self.source_request_count(app_route), 1)
        self.assertEqual(self.source_request_count(shared_route), 1)
        self.assertEqual(first_tar.read_bytes(), first_tar_bytes)
        self.assertEqual(second_tar.read_bytes(), second_tar_bytes)
        self.assert_archive_valid()

        # Requesting the newer version explicitly adds it alongside the old
        # root, without redownloading their shared dependency.
        self.transfer = self.root / "transfer-add-version.tar"
        self.download(["app@2.0.0"], "--update")
        self.assertEqual(self.identities(), {("app", "1.0.0"), ("app", "2.0.0"),
                                            ("shared", "1.0.0"), ("extra", "1.0.0")})
        self.assertEqual(set(self.download_state()["resumeProfile"]["packageSpecs"]),
                         {"app", "extra", "app@2.0.0"})
        self.assertEqual(self.source_request_count(app_route), 1)
        self.assertEqual(self.source_request_count(shared_route), 1)
        self.assertEqual(first_tar.read_bytes(), first_tar_bytes)
        self.assert_archive_valid()

    def test_failed_update_and_resume_preserve_previously_normalized_dependency_tags(self):
        self.source.add("child", "1.0.0")
        self.source.add("app", metadata={"dependencies": {"child": "latest"}})
        self.download(["app"])
        app_entry = next(item for item in self.entries() if item["name"] == "app")
        original_app_bytes = (self.output / app_entry["tarball"]).read_bytes()
        original_app_hash = app_entry["sha512"]
        self.source.add("child", "2.0.0")
        self.source.add("extra", metadata={"dependencies": {"child": "latest", "missing": "1.0.0"}})
        self.transfer = self.root / "transfer-pinned-update.tar"
        self.download(["extra"], "--update", success=False)
        partial = self.assert_incomplete()
        self.assertIn(("child", "2.0.0"), {(item["name"], item["version"]) for item in partial})
        self.assertTrue(self.download_state()["resolutions"])

        # A retry of a failed extension must preserve both the original edge
        # and the newly selected edge, even if latest changes a second time.
        self.source.add("child", "3.0.0")
        self.source.add("missing")
        self.download([], "--resume")
        self.assertEqual(self.identities(), {("app", "1.0.0"), ("extra", "1.0.0"),
                                            ("child", "1.0.0"), ("child", "2.0.0"), ("missing", "1.0.0")})
        current_app = next(item for item in self.entries() if item["name"] == "app")
        self.assertEqual(current_app["sha512"], original_app_hash)
        self.assertEqual((self.output / current_app["tarball"]).read_bytes(), original_app_bytes,
                         "Extending a bundle must not rewrite an already published package version")
        for name, expected_child in (("app", "1.0.0"), ("extra", "2.0.0")):
            entry = next(item for item in self.entries() if item["name"] == name)
            manifest = archive_metadata((self.output / entry["tarball"]).read_bytes())
            self.assertEqual(manifest["dependencies"]["child"], expected_child)
        self.assert_archive_valid()

    def test_update_partial_bundle_remembers_expanded_roots_and_cache_for_empty_resume(self):
        custom_cache = self.root / "saved source cache"
        app = self.source.add("app", metadata={"dependencies": {"missing": "1.0.0"}})
        app_route = unquote(urlsplit(app["dist"]["tarball"]).path)
        self.download(["app"], "--cache-dir", str(custom_cache), success=False)
        self.assert_incomplete()
        self.source.add("extra")
        self.download(["extra"], "--update", success=False)
        self.assert_incomplete()
        state = self.download_state()
        self.assertEqual(set(state["resumeProfile"]["packageSpecs"]), {"app", "extra"})
        self.assertEqual(Path(state["cacheDir"]), custom_cache)
        state_bytes = (self.output / "download-state.json").read_bytes()
        requests_before = len(self.source.requests)
        self.download(["new-root"], "--resume", success=False)
        self.assertEqual((self.output / "download-state.json").read_bytes(), state_bytes)
        self.assertEqual(len(self.source.requests), requests_before)

        self.source.add("missing")
        self.download([], "--resume")
        self.assertEqual(self.identities(), {("app", "1.0.0"), ("extra", "1.0.0"), ("missing", "1.0.0")})
        self.assertEqual(self.source_request_count(app_route), 1)
        self.assertEqual(Path(self.download_state()["cacheDir"]), custom_cache)
        self.assert_archive_valid()

    def test_update_profile_and_existing_tar_refusals_preserve_previous_bundle(self):
        self.source.add("app")
        self.download(["app"])
        first_tar = self.transfer
        first_tar_bytes = first_tar.read_bytes()

        def saved_files():
            return {file.relative_to(self.output).as_posix(): file.read_bytes()
                    for file in self.output.rglob("*") if file.is_file()}

        original = saved_files()
        requests_before = len(self.source.requests)
        incompatible = (("--node-version", str(self.future_major + 1) + ".0.0"),
                        ("--target-os", "linux"),
                        ("--registry", self.source.origin + "/different-source/"),
                        ("--include-dev-dependencies",))
        for index, options in enumerate(incompatible):
            with self.subTest(options=options):
                self.transfer = self.root / ("refused-update-" + str(index) + ".tar")
                self.download(["extra"], "--update", *options, success=False)
                self.assertEqual(saved_files(), original)
                self.assertEqual(len(self.source.requests), requests_before)
                self.assertEqual(first_tar.read_bytes(), first_tar_bytes)

        self.transfer = first_tar
        self.download(["extra"], "--update", success=False, failure_tarball=first_tar_bytes)
        self.assertEqual(saved_files(), original)
        self.assertEqual(len(self.source.requests), requests_before)

    def test_update_migrates_bundle_with_summary_but_no_download_state(self):
        app = self.source.add("app")
        app_route = unquote(urlsplit(app["dist"]["tarball"]).path)
        self.download(["app"])
        (self.output / "download-state.json").unlink()
        self.source.add("extra")
        self.transfer = self.root / "migrated-transfer.tar"
        self.download(["extra"], "--update")
        state = self.download_state()
        self.assertEqual(state["schemaVersion"], 1)
        self.assertEqual(state["inputMode"], "http-package-list")
        self.assertEqual(set(state["resumeProfile"]["packageSpecs"]), {"app", "extra"})
        self.assertEqual(self.identities(), {("app", "1.0.0"), ("extra", "1.0.0")})
        self.assertEqual(self.source_request_count(app_route), 1)
        self.assert_archive_valid()

    def test_shared_cache_keeps_resolution_state_specific_to_target_node(self):
        cache = self.root / "shared cache for different node targets"
        app = self.source.add("app", metadata={"dependencies": {"engine-leaf": "^1.0.0"}})
        app_route = unquote(urlsplit(app["dist"]["tarball"]).path)
        self.source.add("engine-leaf", "1.0.0", {"engines": {"node": ">=" + str(self.future_major)}})
        self.source.add("engine-leaf", "1.1.0", {"engines": {"node": ">=" + str(self.future_major + 1)}})
        self.download(["app"], "--cache-dir", str(cache))
        self.assertEqual(self.identities(), {("app", "1.0.0"), ("engine-leaf", "1.0.0")})
        self.assertEqual(self.download_state()["resumeProfile"]["nodeVersion"], self.target_node)
        first_output = self.output
        first_state = (first_output / "download-state.json").read_bytes()
        first_tar = self.transfer
        first_tar_bytes = first_tar.read_bytes()

        self.target_node = str(self.future_major + 1) + ".0.0"
        self.output = self.root / "bundle for newer target"
        self.transfer = self.root / "transfer-newer-target.tar"
        self.download(["app"], "--cache-dir", str(cache))
        self.assertEqual(self.identities(), {("app", "1.0.0"), ("engine-leaf", "1.1.0")})
        self.assertEqual(self.download_state()["resumeProfile"]["nodeVersion"], self.target_node)
        self.assertEqual(self.source_request_count(app_route), 1,
                         "Compatible original package bytes may be reused across target-specific graphs")
        self.assertEqual((first_output / "download-state.json").read_bytes(), first_state)
        self.assertEqual(first_tar.read_bytes(), first_tar_bytes)
        self.assert_archive_valid()

    def test_update_refetches_corrupted_cache_instead_of_trusting_saved_state(self):
        app = self.source.add("app")
        app_route = unquote(urlsplit(app["dist"]["tarball"]).path)
        self.download(["app"])
        cache = Path(self.download_state()["cacheDir"])
        cached_app = [file for file in cache.rglob("*.tgz") if file.read_bytes() == self.source.blobs[app_route]]
        self.assertEqual(len(cached_app), 1)
        cached_app[0].write_bytes(b"corrupted original package")
        self.source.add("extra")
        self.transfer = self.root / "repaired-update.tar"
        self.download(["extra"], "--update")
        self.assertEqual(self.source_request_count(app_route), 2)
        self.assertEqual(self.identities(), {("app", "1.0.0"), ("extra", "1.0.0")})
        self.assert_archive_valid()

    def test_update_preserves_exact_build_metadata_identity_when_registry_order_changes(self):
        self.source.add("app", "1.0.0+a")
        self.download(["app"])
        original_entry = self.entries()[0]
        original_bytes = (self.output / original_entry["tarball"]).read_bytes()
        self.source.add("app", "1.0.0+b")
        versions = self.source.documents["app"]["versions"]
        self.source.documents["app"]["versions"] = {
            "1.0.0+b": versions["1.0.0+b"], "1.0.0+a": versions["1.0.0+a"],
        }
        self.source.add("extra")
        self.transfer = self.root / "transfer-build-metadata.tar"
        self.download(["extra"], "--update")
        self.assertEqual(self.identities(), {("app", "1.0.0+a"), ("extra", "1.0.0")})
        current = next(item for item in self.entries() if item["name"] == "app")
        self.assertEqual(current["sha512"], original_entry["sha512"])
        self.assertEqual((self.output / current["tarball"]).read_bytes(), original_bytes)
        self.assert_archive_valid()

    def test_update_preserves_optional_omission_while_new_parent_resolves_compatible_version(self):
        self.source.add("child", "1.0.0", {"engines": {"node": ">=" + str(self.future_major + 1)}})
        self.source.add("app", metadata={"optionalDependencies": {"child": "latest"}})
        self.download(["app"])
        self.assertEqual(self.identities(), {("app", "1.0.0")})
        original_entry = self.entries()[0]
        original_bytes = (self.output / original_entry["tarball"]).read_bytes()
        self.source.add("child", "2.0.0", {"engines": {"node": ">=" + str(self.future_major)}})
        self.source.add("extra", metadata={"dependencies": {"child": "latest"}})
        self.transfer = self.root / "transfer-preserved-omission.tar"
        self.download(["extra"], "--update")
        self.assertEqual(self.identities(), {("app", "1.0.0"), ("extra", "1.0.0"), ("child", "2.0.0")})
        current = next(item for item in self.entries() if item["name"] == "app")
        self.assertEqual(current["sha512"], original_entry["sha512"])
        self.assertEqual((self.output / current["tarball"]).read_bytes(), original_bytes,
                         "A formerly omitted dependency must not rewrite an existing package version")
        omitted = [edge for edge in self.graph()["edges"]
                   if edge["from"] == "app@1.0.0" and edge["name"] == "child"]
        self.assertEqual(len(omitted), 1)
        self.assertTrue(omitted[0]["omitted"])
        extra = next(item for item in self.entries() if item["name"] == "extra")
        metadata = archive_metadata((self.output / extra["tarball"]).read_bytes())
        self.assertEqual(metadata["dependencies"]["child"], "2.0.0")
        self.assert_archive_valid()

    def test_update_rejects_changed_source_integrity_of_pinned_version(self):
        self.source.add("app")
        self.download(["app"])
        original_entry = self.entries()[0]
        original_package = (self.output / original_entry["tarball"]).read_bytes()
        original_transfer = self.transfer
        original_transfer_bytes = original_transfer.read_bytes()
        self.source.add("app", extra_files={"package/index.js": b"module.exports = 'changed version';\n"})
        self.source.add("extra")
        self.transfer = self.root / "refused-republished-version.tar"
        result = self.download(["extra"], "--update", success=False)
        self.assertIn("integrity", (result.stdout + result.stderr).lower())
        self.assert_incomplete()
        self.assertEqual(original_transfer.read_bytes(), original_transfer_bytes,
                         "A failed update must retain the previously completed transfer")
        self.assertEqual((self.output / original_entry["tarball"]).read_bytes(), original_package)

    def test_missing_optional_dependency_is_not_silently_ignored(self):
        self.source.add("app", metadata={"optionalDependencies": {"missing": "1.0.0"}})
        self.download(["app"], success=False)

    def test_unsupported_dependency_protocols_fail_closed(self):
        for index, spec in enumerate(("git+https://example.invalid/repo.git", "file:../local", "workspace:*")):
            with self.subTest(spec=spec):
                self.output = self.root / ("bundle-" + str(index))
                self.transfer = self.root / ("transfer-" + str(index) + ".tar")
                self.source.add("app", metadata={"dependencies": {"unsupported": spec}})
                result = self.download(["app"], success=False)
                self.assertIn("unsupported", (result.stdout + result.stderr).lower())

    def test_diamond_graph_preserves_different_transitive_versions(self):
        self.source.add("app", metadata={"dependencies": {"left": "1.0.0", "right": "1.0.0"}})
        self.source.add("left", metadata={"dependencies": {"shared": "^1.0.0"}})
        self.source.add("right", metadata={"dependencies": {"shared": "~2.0.0"}})
        self.source.add("shared", "1.8.0")
        self.source.add("shared", "2.0.9")
        self.source.add("shared", "2.1.0")
        self.download(["app"])
        self.assertEqual(self.identities(), {("app", "1.0.0"), ("left", "1.0.0"), ("right", "1.0.0"),
                                            ("shared", "1.8.0"), ("shared", "2.0.9")})

    def test_dev_dependencies_opt_in_is_root_only(self):
        self.source.add("app", metadata={"dependencies": {"runtime-leaf": "1.0.0"},
                                         "devDependencies": {"root-dev": "1.0.0"}})
        self.source.add("runtime-leaf", metadata={"devDependencies": {"transitive-dev": "1.0.0"}})
        self.source.add("root-dev")
        self.download(["app"], "--include-dev-dependencies")
        self.assertEqual(self.identities(), {("app", "1.0.0"), ("runtime-leaf", "1.0.0"), ("root-dev", "1.0.0")})
        self.assertFalse(any("transitive-dev" in request["path"] for request in self.source.requests))

    def test_required_engine_incompatibility_fails(self):
        self.source.add("app", metadata={"dependencies": {"too-new": "1.0.0"}})
        self.source.add("too-new", metadata={"engines": {"node": ">=" + str(self.future_major + 1)}})
        self.download(["app"], success=False)

    def test_explicit_tag_does_not_fall_back_to_another_version(self):
        self.source.add("app", "1.0.0")
        self.source.add("app", "2.0.0", {"engines": {"node": ">=" + str(self.future_major + 1)}})
        self.source.documents["app"]["dist-tags"]["preview"] = "2.0.0"
        self.download(["app@preview"], success=False)

    def test_tarball_identity_must_match_resolved_package(self):
        self.source.add("app", archive_metadata_override={"name": "wrong-name", "version": "1.0.0"})
        self.download(["app"], success=False)

    def test_optional_authentication_failure_is_fatal(self):
        self.source.add("app", metadata={"optionalDependencies": {"private-package": "1.0.0"}})
        self.source.errors["/source/private-package"] = 401
        self.download(["app"], success=False)

    def test_cross_origin_tarball_redirect_does_not_leak_registry_token(self):
        external = SourceRegistry()
        self.addCleanup(external.close)
        metadata = self.source.add("app")
        route = unquote(urlsplit(metadata["dist"]["tarball"]).path)
        external.blobs["/cdn/app.tgz"] = self.source.blobs[route]
        self.source.redirects[route] = external.origin + "/cdn/app.tgz"
        self.download(["app"], token="fixture-source-token")
        self.assertTrue(self.source.requests)
        self.assertEqual(self.source.requests[0]["authorization"], "Bearer fixture-source-token")
        self.assertTrue(external.requests)
        self.assertTrue(all(request["authorization"] is None for request in external.requests))

    def test_http_bundle_publishes_offline_without_lock_or_npm_and_sets_latest(self):
        # The supported current workflow must be independently portable. A
        # legacy CLI downloader or checkout-level dependency cannot hide here.
        standalone = self.root / "standalone downloader with spaces"
        standalone.mkdir()
        for filename in (DOWNLOADER.name, UPLOADER.name):
            shutil.copy2(NPM_DIR / filename, standalone / filename)
        for directory in ("lib", "vendor"):
            shutil.copytree(NPM_DIR / directory, standalone / directory)
        self.downloader = standalone / DOWNLOADER.name
        self.source.add("@fixture/versions", "2.0.0", {"scripts": {"prepublishOnly": "exit 99"}})
        self.source.add("@fixture/versions", "1.0.0", {"scripts": {"prepublish": "exit 99", "postinstall": "exit 99"}})
        self.download(["@fixture/versions@2.0.0", "@fixture/versions@1.0.0"], windows_list=True)
        self.assertFalse((self.output / "package-lock.json").exists())
        self.source.disabled = True
        source_count = len(self.source.requests)
        destination = FixtureRegistry()
        self.addCleanup(destination.close)
        destination.force_latest_on_publish = True
        offline_uploader = self.root / "offline-upload.py"
        with tarfile.open(self.transfer) as transfer:
            uploader_member = next(member for member in transfer.getmembers()
                                   if member.name.endswith("/" + UPLOADER.name) or member.name == UPLOADER.name)
            offline_uploader.write_bytes(transfer.extractfile(uploader_member).read())
        result = subprocess.run([
            sys.executable, str(offline_uploader), "--bundle-tar", str(self.transfer),
            "--registry-url", destination.url, "--allow-http", "--work-dir", str(self.root / "upload"),
        ], cwd=self.root, env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + "\n" + result.stderr)
        self.assertEqual(len(self.source.requests), source_count, "Offline publishing must not contact source registry")
        self.assertEqual(destination.documents["@fixture/versions"]["dist-tags"]["latest"], "2.0.0")
        self.assertEqual([next(iter(request["payload"]["versions"])) for request in destination.puts], ["1.0.0", "2.0.0"])
        for request in destination.puts:
            attachment = next(iter(request["payload"]["_attachments"].values()))
            metadata = archive_metadata(base64.b64decode(attachment["data"]))
            self.assertNotIn("scripts", metadata)
            self.assertNotIn("publishConfig", metadata)


if __name__ == "__main__":
    unittest.main()
