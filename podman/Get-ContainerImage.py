#!/usr/bin/env python3
"""Download one or more container images into a transferable OCI bundle."""

from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
import sys
import tarfile
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from oci_registry import (
    INDEX_MEDIA_TYPES,
    MANIFEST_ACCEPT,
    Credentials,
    ImageReference,
    RegistryClient,
    RegistryError,
    blob_path,
    digest_bytes,
    digest_file,
    load_credentials_file,
    parse_image_reference,
    split_digest,
    validate_file_digest,
    write_json,
)


@dataclass(frozen=True)
class ImageRequest:
    image: str
    target_repository: str = ""
    target_tag: str = ""


def status(message: str) -> None:
    print(f"[oci-download] {message}", file=sys.stderr)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def descriptor_from_response(body: bytes, headers: Any, document: dict[str, Any]) -> dict[str, Any]:
    digest = headers.get("Docker-Content-Digest") or digest_bytes(body)
    media_type = document.get("mediaType") or str(headers.get("Content-Type", "")).split(";", 1)[0]
    if not media_type:
        raise RegistryError("Registry manifest response did not include a media type")
    return {"mediaType": media_type, "digest": digest, "size": len(body)}


def save_bytes(layout: Path, digest: str, content: bytes) -> Path:
    path = blob_path(layout, digest)
    if path.exists():
        try:
            validate_file_digest(path, digest)
            return path
        except RegistryError:
            status(f"replacing corrupt cached blob {digest}")
    path.parent.mkdir(parents=True, exist_ok=True)
    algorithm, _ = split_digest(digest)
    if digest_bytes(content, algorithm) != digest.lower():
        raise RegistryError(f"Downloaded content did not match {digest}")
    temporary = path.with_name(path.name + ".partial")
    temporary.write_bytes(content)
    temporary.replace(path)
    return path


def download_blob(
    client: RegistryClient,
    layout: Path,
    reference: ImageReference,
    descriptor: dict[str, Any],
) -> Path:
    digest = str(descriptor.get("digest", ""))
    if not digest:
        raise RegistryError(f"Manifest for {reference.original} contains a descriptor without a digest")
    path = blob_path(layout, digest)
    if path.exists():
        try:
            validate_file_digest(path, digest)
            status(f"reusing {digest}")
            return path
        except RegistryError:
            status(f"replacing corrupt cached blob {digest}")

    path.parent.mkdir(parents=True, exist_ok=True)
    algorithm, _ = split_digest(digest)
    temporary = path.with_name(path.name + ".partial")
    url = client.api_url(reference.repository, f"blobs/{digest}")
    last_error: Exception | None = None
    for attempt in range(client.retries + 1):
        temporary.unlink(missing_ok=True)
        status(f"downloading {reference.registry}/{reference.repository} blob {digest}")
        response = None
        try:
            response = client.open("GET", url, repository=reference.repository, actions=("pull",))
            hasher = hashlib.new(algorithm)
            with temporary.open("wb") as handle:
                for chunk in iter(lambda: response.read(1024 * 1024), b""):
                    handle.write(chunk)
                    hasher.update(chunk)
            actual = f"{algorithm}:{hasher.hexdigest()}"
            if actual != digest.lower():
                raise RegistryError(f"Downloaded blob digest mismatch: expected {digest}, got {actual}")
            if descriptor.get("size") is not None and temporary.stat().st_size != int(descriptor["size"]):
                raise RegistryError(
                    f"Downloaded blob size mismatch for {digest}: expected {descriptor['size']}, "
                    f"got {temporary.stat().st_size}"
                )
            temporary.replace(path)
            return path
        except (OSError, RegistryError, http.client.HTTPException) as exc:
            last_error = exc
            temporary.unlink(missing_ok=True)
            if attempt >= client.retries:
                raise
            time.sleep(client.retry_delay * (attempt + 1))
        finally:
            if response is not None:
                response.close()
    raise RegistryError(f"Could not download {digest}: {last_error}")


def get_manifest(
    client: RegistryClient,
    reference: ImageReference,
    manifest_reference: str,
) -> tuple[dict[str, Any], dict[str, Any], bytes]:
    url = client.api_url(reference.repository, f"manifests/{manifest_reference}")
    response = client.request_bytes(
        "GET",
        url,
        repository=reference.repository,
        actions=("pull",),
        headers={"Accept": MANIFEST_ACCEPT},
    )
    try:
        document = json.loads(response.body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RegistryError(f"Registry returned an invalid manifest for {reference.original}") from exc
    if not isinstance(document, dict):
        raise RegistryError(f"Registry manifest for {reference.original} was not a JSON object")
    return document, descriptor_from_response(response.body, response.headers, document), response.body


def parse_platform(value: str) -> tuple[str, str, str]:
    parts = value.split("/")
    if len(parts) not in {2, 3} or not parts[0] or not parts[1]:
        raise RegistryError("Platform must be OS/ARCH or OS/ARCH/VARIANT, such as linux/amd64")
    return parts[0], parts[1], parts[2] if len(parts) == 3 else ""


def select_manifest(index: dict[str, Any], platform: str) -> dict[str, Any]:
    requested_os, requested_arch, requested_variant = parse_platform(platform)
    available: list[str] = []
    for descriptor in index.get("manifests", []):
        candidate = descriptor.get("platform") or {}
        candidate_os = str(candidate.get("os", ""))
        candidate_arch = str(candidate.get("architecture", ""))
        candidate_variant = str(candidate.get("variant", ""))
        display = f"{candidate_os}/{candidate_arch}" + (f"/{candidate_variant}" if candidate_variant else "")
        if candidate_os and candidate_arch:
            available.append(display)
        if (
            candidate_os == requested_os
            and candidate_arch == requested_arch
            and (not requested_variant or candidate_variant == requested_variant)
        ):
            return descriptor
    choices = ", ".join(sorted(set(available))) or "none"
    raise RegistryError(f"Platform {platform} was not found in image index; available platforms: {choices}")


def pull_image(
    request: ImageRequest,
    *,
    platform: str,
    layout: Path,
    client: RegistryClient,
    skip_layers: bool,
) -> tuple[dict[str, Any], dict[str, Any]]:
    reference = parse_image_reference(request.image)
    status(f"resolving {reference.canonical_name} for {platform}")
    document, descriptor, content = get_manifest(client, reference, reference.reference)
    source_index_digest = ""

    if descriptor["mediaType"] in INDEX_MEDIA_TYPES or "manifests" in document:
        source_index_digest = descriptor["digest"]
        save_bytes(layout, source_index_digest, content)
        selected = select_manifest(document, platform)
        selected_digest = str(selected.get("digest", ""))
        if not selected_digest:
            raise RegistryError(f"Selected platform descriptor for {request.image} has no digest")
        document, descriptor, content = get_manifest(client, reference, selected_digest)

    save_bytes(layout, descriptor["digest"], content)
    config = document.get("config")
    if not isinstance(config, dict) or not config.get("digest"):
        raise RegistryError(f"Selected manifest for {request.image} has no image config descriptor")
    download_blob(client, layout, reference, config)

    layers = document.get("layers")
    if not isinstance(layers, list):
        raise RegistryError(f"Selected manifest for {request.image} has no layers array")
    if not skip_layers:
        for layer in layers:
            if not isinstance(layer, dict):
                raise RegistryError(f"Selected manifest for {request.image} contains an invalid layer")
            download_blob(client, layout, reference, layer)

    annotations = {
        "org.opencontainers.image.ref.name": reference.original,
        "io.containerd.image.name": reference.canonical_name,
    }
    index_descriptor = {**descriptor, "annotations": annotations}
    record = {
        "source": reference.original,
        "canonicalSource": reference.canonical_name,
        "registry": reference.registry,
        "repository": reference.repository,
        "sourceReference": reference.reference,
        "sourceTag": reference.tag,
        "sourceDigest": reference.digest,
        "sourceIndexDigest": source_index_digest,
        "platform": platform,
        "manifest": descriptor,
        "config": config,
        "layers": layers,
        "complete": not skip_layers,
        "targetRepository": request.target_repository,
        "targetTag": request.target_tag,
    }
    return record, index_descriptor


def image_request_from_value(value: Any, source: str) -> ImageRequest:
    if isinstance(value, str):
        image = value.strip()
        if not image:
            raise RegistryError(f"Empty image entry in {source}")
        return ImageRequest(image=image)
    if isinstance(value, dict) and value.get("image"):
        return ImageRequest(
            image=str(value["image"]).strip(),
            target_repository=str(value.get("targetRepository", "")).strip(),
            target_tag=str(value.get("targetTag", "")).strip(),
        )
    raise RegistryError(f"Image entries in {source} must be strings or objects with an 'image' field")


def read_images_file(path: Path) -> list[ImageRequest]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise RegistryError(f"Could not read image list {path}: {exc}") from exc
    if path.suffix.lower() == ".json" or text.lstrip().startswith(("[", "{")):
        try:
            document = json.loads(text)
        except json.JSONDecodeError as exc:
            raise RegistryError(f"Invalid JSON image list {path}: {exc}") from exc
        values = document.get("images") if isinstance(document, dict) else document
        if not isinstance(values, list):
            raise RegistryError(f"JSON image list {path} must be an array or an object with an images array")
        return [image_request_from_value(value, str(path)) for value in values]

    requests: list[ImageRequest] = []
    for number, line in enumerate(text.splitlines(), 1):
        value = line.split("#", 1)[0].strip()
        if value:
            requests.append(image_request_from_value(value, f"{path}:{number}"))
    return requests


def unique_requests(values: Iterable[ImageRequest]) -> list[ImageRequest]:
    result: list[ImageRequest] = []
    seen: set[tuple[str, str, str]] = set()
    for item in values:
        key = (item.image, item.target_repository, item.target_tag)
        if key not in seen:
            seen.add(key)
            result.append(item)
    return result


def credential_map(args: argparse.Namespace, requests: list[ImageRequest]) -> dict[str, Credentials]:
    credentials: dict[str, Credentials] = {}
    if args.credentials_file:
        credentials.update(load_credentials_file(Path(args.credentials_file)))

    inline = Credentials(
        username=args.username,
        password=args.password,
        bearer_token=args.bearer_token,
    )
    if any((inline.username, inline.password, inline.bearer_token)):
        if bool(inline.username) != bool(inline.password):
            raise RegistryError("Both --username and --password are required for Basic authentication")
        hosts = sorted({parse_image_reference(item.image).registry for item in requests})
        host = args.credential_registry.lower()
        if not host:
            if len(hosts) != 1:
                raise RegistryError(
                    "Set --credential-registry when credentials are used with images from multiple registries"
                )
            host = hosts[0]
        credentials[host] = inline
    return credentials


def write_checksums(bundle: Path) -> Path:
    checksum_file = bundle / "SHA256SUMS"
    temporary = bundle / "SHA256SUMS.partial"
    temporary.unlink(missing_ok=True)
    lines = []
    excluded = {checksum_file, temporary}
    for path in sorted(item for item in bundle.rglob("*") if item.is_file() and item not in excluded):
        relative = path.relative_to(bundle).as_posix()
        lines.append(f"{digest_file(path).split(':', 1)[1]}  {relative}")
    temporary.write_text("\n".join(lines) + "\n", encoding="utf-8")
    temporary.replace(checksum_file)
    return checksum_file


def validate_bundle_content(layout: Path, records: list[dict[str, Any]], skip_layers: bool) -> None:
    """Verify that every descriptor promised by the bundle is present and intact."""
    expected: set[str] = set()
    for record in records:
        source_index_digest = str(record.get("sourceIndexDigest", ""))
        if source_index_digest:
            expected.add(source_index_digest)
        for name in ("manifest", "config"):
            descriptor = record.get(name)
            if not isinstance(descriptor, dict) or not descriptor.get("digest"):
                raise RegistryError(f"Bundle record for {record.get('source', 'image')} has no {name} digest")
            expected.add(str(descriptor["digest"]))
        if not skip_layers:
            for descriptor in record.get("layers", []):
                if not isinstance(descriptor, dict) or not descriptor.get("digest"):
                    raise RegistryError(
                        f"Bundle record for {record.get('source', 'image')} contains a layer without a digest"
                    )
                expected.add(str(descriptor["digest"]))

    for digest in sorted(expected):
        path = blob_path(layout, digest)
        if not path.is_file():
            raise RegistryError(f"Bundle is missing downloaded blob {digest}: {path}")
        validate_file_digest(path, digest)


def verify_checksums(bundle: Path) -> None:
    checksum_file = bundle / "SHA256SUMS"
    if not checksum_file.is_file():
        raise RegistryError("Bundle checksum manifest was not created")
    for number, line in enumerate(checksum_file.read_text(encoding="utf-8").splitlines(), 1):
        if not line:
            continue
        try:
            expected, relative = line.split("  ", 1)
        except ValueError as exc:
            raise RegistryError(f"Invalid SHA256SUMS entry on line {number}") from exc
        path = bundle / relative
        if not path.is_file():
            raise RegistryError(f"SHA256SUMS references a missing bundle file: {relative}")
        actual = digest_file(path).split(":", 1)[1]
        if actual != expected.lower():
            raise RegistryError(f"SHA256SUMS verification failed for {relative}")


def prune_unreferenced_blobs(layout: Path, records: list[dict[str, Any]], skip_layers: bool) -> int:
    referenced: set[str] = set()
    for record in records:
        for key in ("sourceIndexDigest",):
            if record.get(key):
                referenced.add(str(record[key]).lower())
        for key in ("manifest", "config"):
            descriptor = record.get(key)
            if isinstance(descriptor, dict) and descriptor.get("digest"):
                referenced.add(str(descriptor["digest"]).lower())
        if not skip_layers:
            for descriptor in record.get("layers", []):
                if isinstance(descriptor, dict) and descriptor.get("digest"):
                    referenced.add(str(descriptor["digest"]).lower())

    removed = 0
    blobs = layout / "blobs"
    if blobs.is_dir():
        for path in blobs.glob("*/*"):
            if not path.is_file():
                continue
            candidate = f"{path.parent.name}:{path.name}".lower()
            if candidate not in referenced:
                path.unlink()
                removed += 1
        for directory in sorted((item for item in blobs.iterdir() if item.is_dir()), reverse=True):
            try:
                directory.rmdir()
            except OSError:
                pass
    return removed


def create_archive(bundle: Path, archive: Path) -> None:
    archive.parent.mkdir(parents=True, exist_ok=True)
    if bundle.resolve() in archive.resolve().parents:
        raise RegistryError("--archive-output must be outside --output-directory")
    temporary = archive.with_name(archive.name + ".partial")
    temporary.unlink(missing_ok=True)
    mode = "w:gz" if archive.name.endswith((".tar.gz", ".tgz")) else "w"
    with tarfile.open(temporary, mode) as handle:
        handle.add(bundle, arcname=bundle.name)
    temporary.replace(archive)


def bundle_readme(platform: str) -> str:
    return f"""OCI image transfer bundle

This is an OCI image layout containing the selected {platform} manifest for each
requested image. bundle-manifest.json records source names, resolved manifest
digests, optional destination overrides, and all config/layer descriptors.

Transfer the archive together with upload-container-images-to-artifactory.sh,
then publish it to an Artifactory Docker repository with:

  ./upload-container-images-to-artifactory.sh --bundle-tar <archive> \\
    --registry-url https://artifactory.example.com --repository docker-local

SHA256SUMS covers every file in the bundle. The uploader verifies those checksums
and all OCI content digests before it sends data to the target registry. The
receiving host needs Bash, curl, jq, tar, and sha256sum (or shasum), but does not
need Python or a container CLI.
"""


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Download container images into a transferable, Artifactory-ready OCI bundle."
    )
    parser.add_argument("images", nargs="*", help="Image reference; may also be supplied with --image")
    parser.add_argument("--image", action="append", default=[], help="Image reference; repeat as needed")
    parser.add_argument("--images-file", action="append", default=[], help="Text or JSON image list; repeat as needed")
    parser.add_argument("--platform", default="linux/amd64", help="Target OS/architecture[/variant]")
    parser.add_argument("--output-directory", default="oci-image-bundle", help="OCI bundle directory")
    parser.add_argument("--archive-output", default="", help="Optional .tar or .tar.gz transfer archive")
    parser.add_argument("--credentials-file", default="", help="Registry-keyed JSON or Docker config.json auth file")
    parser.add_argument("--credential-registry", default=os.environ.get("REGISTRY_HOST", ""))
    parser.add_argument("--username", default=os.environ.get("REGISTRY_USERNAME", ""))
    parser.add_argument("--password", default=os.environ.get("REGISTRY_PASSWORD", ""))
    parser.add_argument("--bearer-token", default=os.environ.get("REGISTRY_BEARER_TOKEN", ""))
    parser.add_argument("--skip-layers", action="store_true", help="Connectivity testing only; creates an incomplete bundle")
    parser.add_argument("--insecure", action="store_true", help="Use HTTP instead of HTTPS for source registries")
    parser.add_argument("--no-verify-tls", action="store_true", help="Disable source registry TLS certificate checks")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    requests = [ImageRequest(image=value) for value in [*args.images, *args.image]]
    for file_name in args.images_file:
        requests.extend(read_images_file(Path(file_name)))
    requests = unique_requests(requests)
    if not requests:
        raise RegistryError("Provide at least one image or --images-file")
    parse_platform(args.platform)

    layout = Path(args.output_directory).resolve()
    layout.mkdir(parents=True, exist_ok=True)
    # An interrupted rerun must not leave an old checksum manifest that makes a
    # partially updated directory look like a completed bundle.
    (layout / "SHA256SUMS").unlink(missing_ok=True)
    (layout / "SHA256SUMS.partial").unlink(missing_ok=True)
    (layout / "blobs" / "sha256").mkdir(parents=True, exist_ok=True)
    credentials = credential_map(args, requests)
    clients: dict[str, RegistryClient] = {}

    records: list[dict[str, Any]] = []
    index_descriptors: list[dict[str, Any]] = []
    for request in requests:
        reference = parse_image_reference(request.image)
        if reference.registry not in clients:
            scheme = "http" if args.insecure else "https"
            clients[reference.registry] = RegistryClient(
                f"{scheme}://{reference.registry}",
                credentials.get(reference.registry),
                verify_tls=not args.no_verify_tls,
            )
        record, descriptor = pull_image(
            request,
            platform=args.platform,
            layout=layout,
            client=clients[reference.registry],
            skip_layers=args.skip_layers,
        )
        records.append(record)
        index_descriptors.append(descriptor)

    removed_blobs = prune_unreferenced_blobs(layout, records, args.skip_layers)
    if removed_blobs:
        status(f"pruned {removed_blobs} unreferenced cached blob(s)")
    validate_bundle_content(layout, records, args.skip_layers)

    write_json(layout / "oci-layout", {"imageLayoutVersion": "1.0.0"})
    write_json(layout / "index.json", {"schemaVersion": 2, "manifests": index_descriptors})
    bundle_manifest = {
        "schemaVersion": 1,
        "mediaType": "application/vnd.fetch-kit.oci-transfer.v1+json",
        "createdAt": utc_now(),
        "platform": args.platform,
        "complete": not args.skip_layers,
        "imageCount": len(records),
        "images": records,
    }
    write_json(layout / "bundle-manifest.json", bundle_manifest)
    (layout / "artifactory-upload-manifest.tsv").unlink(missing_ok=True)
    (layout / "README.txt").write_text(bundle_readme(args.platform), encoding="utf-8")
    write_checksums(layout)
    verify_checksums(layout)

    archive_path = Path(args.archive_output).resolve() if args.archive_output else None
    if archive_path:
        status(f"creating transfer archive {archive_path}")
        create_archive(layout, archive_path)

    unique_blob_paths = [item for item in (layout / "blobs").rglob("*") if item.is_file()]
    result = {
        "mode": "OciImageBundle",
        "platform": args.platform,
        "bundleDirectory": str(layout),
        "bundleManifest": str(layout / "bundle-manifest.json"),
        "archiveOutput": str(archive_path) if archive_path else "",
        "archiveBytes": archive_path.stat().st_size if archive_path else 0,
        "archiveSha256": digest_file(archive_path) if archive_path else "",
        "imageCount": len(records),
        "blobCount": len(unique_blob_paths),
        "complete": not args.skip_layers,
        "images": records,
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RegistryError, OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
