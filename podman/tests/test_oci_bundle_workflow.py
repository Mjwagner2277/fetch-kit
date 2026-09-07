#!/usr/bin/env python3
"""End-to-end local test for OCI download, archive, and registry upload."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from oci_registry import parse_image_reference  # noqa: E402


OCI_INDEX = "application/vnd.oci.image.index.v1+json"
OCI_MANIFEST = "application/vnd.oci.image.manifest.v1+json"
OCI_CONFIG = "application/vnd.oci.image.config.v1+json"
OCI_LAYER = "application/vnd.oci.image.layer.v1.tar+gzip"


def encoded(value: object) -> bytes:
    return json.dumps(value, separators=(",", ":"), sort_keys=True).encode("utf-8")


def digest(content: bytes) -> str:
    return "sha256:" + hashlib.sha256(content).hexdigest()


class RegistryState:
    def __init__(self) -> None:
        self.config = encoded({"architecture": "amd64", "os": "linux"})
        self.layer = b"tiny fake compressed layer\n"
        self.config_digest = digest(self.config)
        self.layer_digest = digest(self.layer)
        self.manifest = encoded(
            {
                "schemaVersion": 2,
                "mediaType": OCI_MANIFEST,
                "config": {"mediaType": OCI_CONFIG, "digest": self.config_digest, "size": len(self.config)},
                "layers": [{"mediaType": OCI_LAYER, "digest": self.layer_digest, "size": len(self.layer)}],
            }
        )
        self.manifest_digest = digest(self.manifest)
        self.index = encoded(
            {
                "schemaVersion": 2,
                "mediaType": OCI_INDEX,
                "manifests": [
                    {
                        "mediaType": OCI_MANIFEST,
                        "digest": self.manifest_digest,
                        "size": len(self.manifest),
                        "platform": {"os": "linux", "architecture": "amd64"},
                    }
                ],
            }
        )
        self.index_digest = digest(self.index)
        self.uploaded_blobs: dict[tuple[str, str], bytes] = {}
        self.uploaded_manifests: dict[tuple[str, str], bytes] = {}
        self.upload_counter = 0
        self.upload_repositories: dict[str, str] = {}


class RegistryHandler(BaseHTTPRequestHandler):
    state: RegistryState
    server_url: str

    def log_message(self, format: str, *args: object) -> None:
        pass

    def _send(self, status: int, body: bytes = b"", headers: dict[str, str] | None = None) -> None:
        self.send_response(status)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD" and body:
            self.wfile.write(body)

    def _authorized(self) -> bool:
        if self.path.startswith("/token"):
            return True
        if self.headers.get("Authorization") == "Bearer local-test-token":
            return True
        self._send(
            401,
            headers={
                "WWW-Authenticate": (
                    f'Bearer realm="{self.server_url}/token",service="local-test",scope="repository:test:pull,push"'
                )
            },
        )
        return False

    def do_GET(self) -> None:
        path = urllib.parse.urlsplit(self.path).path
        if path == "/token":
            self._send(200, encoded({"token": "local-test-token"}), {"Content-Type": "application/json"})
            return
        if not self._authorized():
            return
        prefix = "/v2/acme/widget/"
        if path in {prefix + "manifests/v1", prefix + "manifests/v2"}:
            self._send(
                200,
                self.state.index,
                {"Content-Type": OCI_INDEX, "Docker-Content-Digest": self.state.index_digest},
            )
        elif path == prefix + "manifests/" + self.state.manifest_digest:
            self._send(
                200,
                self.state.manifest,
                {"Content-Type": OCI_MANIFEST, "Docker-Content-Digest": self.state.manifest_digest},
            )
        elif path == prefix + "blobs/" + self.state.config_digest:
            self._send(200, self.state.config, {"Content-Type": OCI_CONFIG})
        elif path == prefix + "blobs/" + self.state.layer_digest:
            self._send(200, self.state.layer, {"Content-Type": OCI_LAYER})
        else:
            self._send(404)

    def do_HEAD(self) -> None:
        if not self._authorized():
            return
        path = urllib.parse.urlsplit(self.path).path
        if "/blobs/" in path:
            repository, digest_value = path.removeprefix("/v2/").split("/blobs/", 1)
            self._send(200 if (repository, digest_value) in self.state.uploaded_blobs else 404)
        elif "/manifests/" in path:
            repository, tag = path.removeprefix("/v2/").split("/manifests/", 1)
            self._send(200 if (repository, tag) in self.state.uploaded_manifests else 404)
        else:
            self._send(404)

    def do_POST(self) -> None:
        if not self._authorized():
            return
        path = urllib.parse.urlsplit(self.path).path
        if not path.startswith("/v2/") or not path.endswith("/blobs/uploads/"):
            self._send(404)
            return
        repository = path.removeprefix("/v2/").removesuffix("/blobs/uploads/")
        self.state.upload_counter += 1
        upload_id = str(self.state.upload_counter)
        self.state.upload_repositories[upload_id] = repository
        self._send(202, headers={"Location": f"/uploads/{upload_id}"})

    def do_PUT(self) -> None:
        if not self._authorized():
            return
        parsed = urllib.parse.urlsplit(self.path)
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        if parsed.path.startswith("/uploads/"):
            upload_id = parsed.path.rsplit("/", 1)[-1]
            repository = self.state.upload_repositories[upload_id]
            digest_value = urllib.parse.parse_qs(parsed.query)["digest"][0]
            if digest(body) != digest_value:
                self._send(400)
                return
            self.state.uploaded_blobs[(repository, digest_value)] = body
            self._send(201, headers={"Docker-Content-Digest": digest_value})
            return
        if parsed.path.startswith("/v2/") and "/manifests/" in parsed.path:
            repository, tag = parsed.path.removeprefix("/v2/").split("/manifests/", 1)
            self.state.uploaded_manifests[(repository, tag)] = body
            self._send(201, headers={"Docker-Content-Digest": digest(body)})
            return
        self._send(404)


def run(command: list[str], cwd: Path) -> dict[str, object]:
    completed = subprocess.run(command, cwd=cwd, text=True, capture_output=True, check=False)
    if completed.returncode != 0:
        raise AssertionError(
            f"Command failed ({completed.returncode}): {' '.join(command)}\n"
            f"STDOUT:\n{completed.stdout}\nSTDERR:\n{completed.stderr}"
        )
    return json.loads(completed.stdout)


def run_failure(command: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(command, cwd=cwd, text=True, capture_output=True, check=False)
    if completed.returncode == 0:
        raise AssertionError(f"Command unexpectedly succeeded: {' '.join(command)}")
    return completed


def main() -> int:
    shorthand = parse_image_reference("alpine:3.22")
    assert shorthand.registry == "registry-1.docker.io"
    assert shorthand.repository == "library/alpine"
    assert shorthand.tag == "3.22"
    digest_only = parse_image_reference("example.com/team/image@sha256:" + "a" * 64)
    assert digest_only.tag == ""

    podman_dir = Path(__file__).resolve().parents[1]
    state = RegistryState()
    RegistryHandler.state = state
    server = ThreadingHTTPServer(("127.0.0.1", 0), RegistryHandler)
    host = f"127.0.0.1:{server.server_port}"
    RegistryHandler.server_url = f"http://{host}"
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    try:
        with tempfile.TemporaryDirectory(prefix="fetch-kit-oci-test-") as temporary:
            root = Path(temporary)
            image_list = root / "images.txt"
            image_list.write_text(
                f"# two tags sharing the same blobs\n{host}/acme/widget:v1\n{host}/acme/widget:v2\n",
                encoding="utf-8",
            )
            bundle = root / "bundle"
            archive = root / "bundle.tar.gz"

            stale_bundle = root / "stale-bundle"
            stale_bundle.mkdir()
            stale_checksum = stale_bundle / "SHA256SUMS"
            stale_checksum.write_text(
                f"{'0' * 64}  blobs/sha256/{'0' * 64}\n",
                encoding="utf-8",
            )
            run_failure(
                [
                    sys.executable,
                    "-B",
                    str(podman_dir / "Get-ContainerImage.py"),
                    f"{host}/acme/widget:missing",
                    "--output-directory",
                    str(stale_bundle),
                    "--insecure",
                ],
                podman_dir,
            )
            assert not stale_checksum.exists()

            download = run(
                [
                    sys.executable,
                    "-B",
                    str(podman_dir / "Get-ContainerImage.py"),
                    "--images-file",
                    str(image_list),
                    "--output-directory",
                    str(bundle),
                    "--archive-output",
                    str(archive),
                    "--insecure",
                ],
                podman_dir,
            )
            assert download["imageCount"] == 2
            assert download["blobCount"] == 4
            assert download["complete"] is True
            assert archive.is_file()
            assert (bundle / "bundle-manifest.json").is_file()
            assert not (bundle / "artifactory-upload-manifest.tsv").exists()
            assert (bundle / "blobs" / "sha256" / state.layer_digest.split(":", 1)[1]).read_bytes() == state.layer
            for checksum_line in (bundle / "SHA256SUMS").read_text(encoding="utf-8").splitlines():
                _, relative = checksum_line.split("  ", 1)
                assert (bundle / relative).is_file(), relative

            upload = run(
                [
                    "bash",
                    str(podman_dir / "upload-container-images-to-artifactory.sh"),
                    "--bundle-tar",
                    str(archive),
                    "--registry-url",
                    RegistryHandler.server_url,
                    "--repository",
                    "docker-local",
                    "--target-prefix",
                    "mirror",
                    "--token",
                    "local-test-token",
                ],
                podman_dir,
            )
            assert upload["published"] == 2
            target_repository = f"docker-local/mirror/127.0.0.1-{server.server_port}/acme/widget"
            assert state.uploaded_blobs[(target_repository, state.config_digest)] == state.config
            assert state.uploaded_blobs[(target_repository, state.layer_digest)] == state.layer
            assert state.uploaded_manifests[(target_repository, "v1")] == state.manifest
            assert state.uploaded_manifests[(target_repository, "v2")] == state.manifest

            skipped = run(
                [
                    "bash",
                    str(podman_dir / "upload-container-images-to-artifactory.sh"),
                    "--bundle-tar",
                    str(archive),
                    "--registry-url",
                    RegistryHandler.server_url,
                    "--repository",
                    "docker-local",
                    "--target-prefix",
                    "mirror",
                    "--token",
                    "local-test-token",
                    "--skip-existing",
                ],
                podman_dir,
            )
            assert skipped["skippedExisting"] == 2

            dry_run = run(
                [
                    "bash",
                    str(podman_dir / "upload-container-images-to-artifactory.sh"),
                    "--bundle-dir",
                    str(bundle),
                    "--registry-url",
                    "https://does-not-resolve.invalid",
                    "--repository",
                    "docker-local",
                    "--dry-run",
                ],
                podman_dir,
            )
            assert dry_run["planned"] == 2
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)

    print("OCI bundle download/upload test passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
