#!/usr/bin/env python3
"""Real npm integration against a local-only source and destination registry."""
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit


NPM_DIR = Path(__file__).resolve().parents[1]


def tarball(name, version, dependencies=None, extra=None):
    manifest = {
        "name": name, "version": version, "main": "index.js",
        "scripts": {"prepublishOnly": "exit 98", "postinstall": "exit 99"},
        "publishConfig": {"registry": "https://unreachable.invalid/"},
        "dependencies": dependencies or {},
    }
    manifest.update(extra or {})
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode="w:gz") as archive:
        files = {
            "package/package.json": json.dumps(manifest).encode(),
            "package/index.js": ("module.exports = " + json.dumps(version) + ";\n").encode(),
        }
        for name, content in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(content)
            info.mode = 0o644
            archive.addfile(info, io.BytesIO(content))
    return manifest, data.getvalue()


class Registry(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body):
        if isinstance(body, dict):
            body = json.dumps(body).encode()
            content_type = "application/json"
        else:
            content_type = "application/octet-stream"
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        route = unquote(urlsplit(self.path).path)
        self.server.requests.append(("GET", route))
        if route.startswith("/source/") and self.server.source_disabled:
            self.reply(503, {"error": "Source disconnected"})
            return
        if route in self.server.blobs:
            self.reply(200, self.server.blobs[route])
            return
        parts = route.strip("/").split("/", 1)
        if len(parts) == 2:
            manifest = self.server.packuments.get((parts[0], parts[1]))
            if manifest is not None:
                self.reply(200, manifest)
                return
        self.reply(404, {"error": "not_found"})

    def do_PUT(self):
        route = unquote(urlsplit(self.path).path)
        self.server.requests.append(("PUT", route))
        if not route.startswith("/target/"):
            self.reply(403, {"error": "Wrong publish destination"})
            return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if route.startswith("/target/-/package/") and route.endswith("/dist-tags/latest"):
            name = route[len("/target/-/package/"):-len("/dist-tags/latest")]
            self.server.packuments[("target", name)]["dist-tags"]["latest"] = body
            self.reply(200, {"ok": True})
            return
        name = body["name"]
        document = self.server.packuments.setdefault(("target", name), {
            "name": name, "versions": {}, "dist-tags": {},
        })
        for version, manifest in body["versions"].items():
            if version in document["versions"]:
                self.reply(409, {"error": "conflict"})
                return
            document["versions"][version] = manifest
            attachment = next(iter(body["_attachments"].values()))
            blob = base64.b64decode(attachment["data"])
            assert len(blob) == attachment["length"]
            self.server.blobs[unquote(urlsplit(manifest["dist"]["tarball"]).path)] = blob
        document["dist-tags"].update(body["dist-tags"])
        self.reply(201, {"ok": True})


@unittest.skipUnless(shutil.which("node") and shutil.which("npm"), "Requires Node and npm")
class WorkflowTest(unittest.TestCase):
    def test_real_npm_lock_download_publish_install(self):
        with tempfile.TemporaryDirectory(prefix="npm-lock-workflow-") as temp:
            root = Path(temp)
            source = root / "source"
            source.mkdir()
            server = ThreadingHTTPServer(("127.0.0.1", 0), Registry)
            server.packuments = {}
            server.blobs = {}
            server.requests = []
            server.source_disabled = False
            origin = "http://127.0.0.1:" + str(server.server_port)
            for name, version, deps, extra in [
                ("fixture-leaf", "1.0.0", {}, {}),
                ("fixture-leaf", "2.0.0", {}, {}),
                ("@fixture/parent", "1.0.0", {"fixture-leaf": "1.0.0"},
                 {"optionalDependencies": {"fixture-other-platform": "1.0.0"}}),
                ("fixture-other-platform", "1.0.0", {}, {"os": ["win32"]}),
            ]:
                manifest, blob = tarball(name, version, deps, extra)
                route = "/source/" + name + "/-/" + name.split("/")[-1] + "-" + version + ".tgz"
                manifest["dist"] = {
                    "tarball": origin + route,
                    "integrity": "sha512-" + base64.b64encode(hashlib.sha512(blob).digest()).decode(),
                    "shasum": hashlib.sha1(blob).hexdigest(),
                }
                document = server.packuments.setdefault(("source", name), {
                    "name": name, "versions": {}, "dist-tags": {},
                })
                document["versions"][version] = manifest
                document["dist-tags"]["latest"] = version
                server.blobs[route] = blob
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            env = os.environ.copy()
            for key in list(env):
                if key.lower().startswith("npm_config_") or key in ("NPM_TOKEN", "NPM_USERNAME", "NPM_PASSWORD"):
                    env.pop(key)
            userconfig = root / "empty.npmrc"
            userconfig.write_text("")
            env["npm_config_userconfig"] = str(userconfig)
            env["npm_config_cache"] = str(root / "cache")

            def run(*args, cwd=source):
                completed = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True, timeout=120)
                self.assertEqual(completed.returncode, 0, completed.stdout + "\n" + completed.stderr)
                return completed.stdout

            try:
                project = {"name": "airgap-fixture", "version": "1.0.0", "private": True,
                           "dependencies": {"fixture-leaf": "2.0.0", "aliased-parent": "npm:@fixture/parent@1.0.0"}}
                (source / "package.json").write_text(json.dumps(project))
                run("npm", "install", "--package-lock-only", "--ignore-scripts", "--no-audit", "--no-fund",
                    "--registry", origin + "/source/")
                original_lock = (source / "package-lock.json").read_bytes()
                transfer = root / "transfer.tar"
                run("node", str(NPM_DIR / "soon-to-be-deprecated" / "download-npm-artifactory-bundle.js"),
                    "--node-version", "22.0.0", "--package-lock", str(source / "package-lock.json"),
                    "--destination-registry", origin + "/target/", "--tar-file", str(transfer),
                    "--state-dir", str(root / "state"), "--output-dir", str(root / "out"))
                server.source_disabled = True
                before_publish = len(server.requests)
                work = root / "publish"
                run(os.sys.executable, str(NPM_DIR / "upload-npm-artifactory-bundle.py"),
                    "--bundle-tar", str(transfer), "--registry-url", origin + "/target/",
                    "--allow-http", "--work-dir", str(work))
                locks = list(work.rglob("package-lock.json"))
                self.assertTrue(locks, "Publisher must emit an installable lockfile")
                # Find the prepared lock with target URLs (exclude extracted input).
                lock = next(p for p in locks if all(
                    "/target/" in item.get("resolved", "")
                    for key, item in json.loads(p.read_text())["packages"].items() if key))
                consumer = root / "consumer"
                consumer.mkdir()
                (consumer / "package.json").write_text(json.dumps(project))
                shutil.copyfile(lock, consumer / "package-lock.json")
                run("npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund",
                    "--registry", origin + "/target/", "--cache", str(root / "fresh-cache"), cwd=consumer)
                values = run("node", "-e", "console.log(require('fixture-leaf')); console.log(require('aliased-parent')); console.log(require('aliased-parent/node_modules/fixture-leaf'));", cwd=consumer)
                self.assertEqual(values.splitlines(), ["2.0.0", "1.0.0", "1.0.0"])
                self.assertFalse(any(route.startswith("/source/") for _, route in server.requests[before_publish:]))
                self.assertEqual((source / "package-lock.json").read_bytes(), original_lock)
                self.assertEqual(sum(method == "PUT" and "/-/package/" not in route
                                     for method, route in server.requests), 4)
                self.assertIn(("target", "fixture-other-platform"), server.packuments)
                self.assertEqual(server.packuments[("target", "fixture-leaf")]["dist-tags"]["latest"], "2.0.0")
                for manifest in server.packuments[("target", "@fixture/parent")]["versions"].values():
                    self.assertNotIn("scripts", manifest)
            finally:
                server.shutdown()
                server.server_close()
                thread.join()


if __name__ == "__main__":
    unittest.main()
