#!/usr/bin/env python3
"""Small standard-library helpers for OCI Distribution API clients."""

from __future__ import annotations

import base64
import hashlib
import json
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Iterable, Mapping


MANIFEST_ACCEPT = ", ".join(
    (
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    )
)

INDEX_MEDIA_TYPES = {
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
}


class RegistryError(RuntimeError):
    """An OCI registry request or validation failed."""


@dataclass(frozen=True)
class Credentials:
    username: str = ""
    password: str = ""
    bearer_token: str = ""
    api_key: str = ""

    def initial_headers(self) -> dict[str, str]:
        if self.bearer_token:
            return {"Authorization": f"Bearer {self.bearer_token}"}
        if self.username and self.password:
            raw = f"{self.username}:{self.password}".encode("utf-8")
            return {"Authorization": "Basic " + base64.b64encode(raw).decode("ascii")}
        if self.api_key:
            return {"X-JFrog-Art-Api": self.api_key}
        return {}

    def basic_header(self) -> str:
        if not self.username or not self.password:
            return ""
        raw = f"{self.username}:{self.password}".encode("utf-8")
        return "Basic " + base64.b64encode(raw).decode("ascii")


@dataclass(frozen=True)
class ImageReference:
    original: str
    registry: str
    repository: str
    tag: str
    digest: str
    reference: str

    @property
    def canonical_name(self) -> str:
        suffix = f"@{self.digest}" if self.digest else f":{self.tag}"
        return f"{self.registry}/{self.repository}{suffix}"


@dataclass(frozen=True)
class ResponseData:
    body: bytes
    headers: Mapping[str, str]
    url: str
    status: int


class SafeRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Avoid forwarding registry credentials to a cross-host blob CDN."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[no-untyped-def]
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is None:
            return None
        old_host = urllib.parse.urlsplit(req.full_url).netloc.lower()
        new_host = urllib.parse.urlsplit(newurl).netloc.lower()
        if old_host != new_host:
            redirected.remove_header("Authorization")
            redirected.remove_header("X-JFrog-Art-Api")
        return redirected


def parse_image_reference(value: str) -> ImageReference:
    original = value.strip()
    if not original:
        raise RegistryError("Image reference cannot be empty")

    parsed_url = urllib.parse.urlsplit(original)
    if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", original):
        if parsed_url.scheme not in {"http", "https"}:
            raise RegistryError(f"Unsupported image reference scheme: {parsed_url.scheme}")
        if parsed_url.query or parsed_url.fragment:
            raise RegistryError(f"Image references must not contain a query string or fragment: {original}")
        value = parsed_url.netloc + parsed_url.path
    else:
        value = original

    digest = ""
    if "@" in value:
        value, digest = value.rsplit("@", 1)
        if not re.fullmatch(r"[A-Za-z0-9_+.-]+:[A-Fa-f0-9]+", digest):
            raise RegistryError(f"Invalid image digest in reference: {original}")

    first, separator, remainder = value.partition("/")
    if separator and ("." in first or ":" in first or first == "localhost"):
        registry = first.lower()
        repository_and_tag = remainder
    else:
        registry = "registry-1.docker.io"
        repository_and_tag = value

    if registry in {"docker.io", "index.docker.io"}:
        registry = "registry-1.docker.io"

    last_component = repository_and_tag.rsplit("/", 1)[-1]
    tag = ""
    if ":" in last_component:
        repository_and_tag, tag = repository_and_tag.rsplit(":", 1)
    elif not digest:
        tag = "latest"
    if registry == "registry-1.docker.io" and "/" not in repository_and_tag:
        repository_and_tag = "library/" + repository_and_tag

    if not repository_and_tag or any(part in {"", ".", ".."} for part in repository_and_tag.split("/")):
        raise RegistryError(f"Invalid repository in image reference: {original}")
    if not digest and not tag:
        raise RegistryError(f"Invalid tag in image reference: {original}")

    return ImageReference(
        original=original,
        registry=registry,
        repository=repository_and_tag,
        tag=tag,
        digest=digest,
        reference=digest or tag,
    )


def parse_www_authenticate(header: str) -> tuple[str, dict[str, str]]:
    match = re.match(r"^\s*([A-Za-z]+)\s*(.*)$", header or "")
    if not match:
        return "", {}
    scheme = match.group(1).lower()
    values: dict[str, str] = {}
    for item in re.finditer(r'(\w+)=(?:"((?:[^"\\]|\\.)*)"|([^,\s]+))', match.group(2)):
        value = item.group(2) if item.group(2) is not None else item.group(3)
        values[item.group(1).lower()] = value.replace('\\"', '"')
    return scheme, values


def digest_bytes(content: bytes, algorithm: str = "sha256") -> str:
    try:
        hasher = hashlib.new(algorithm)
    except ValueError as exc:
        raise RegistryError(f"Unsupported digest algorithm: {algorithm}") from exc
    hasher.update(content)
    return f"{algorithm}:{hasher.hexdigest()}"


def split_digest(digest: str) -> tuple[str, str]:
    if ":" not in digest:
        raise RegistryError(f"Unsupported digest format: {digest}")
    algorithm, encoded = digest.split(":", 1)
    if not algorithm or not re.fullmatch(r"[A-Fa-f0-9]+", encoded):
        raise RegistryError(f"Unsupported digest format: {digest}")
    try:
        hashlib.new(algorithm)
    except ValueError as exc:
        raise RegistryError(f"Unsupported digest algorithm: {algorithm}") from exc
    return algorithm, encoded.lower()


def digest_file(path: Path, algorithm: str = "sha256") -> str:
    try:
        hasher = hashlib.new(algorithm)
    except ValueError as exc:
        raise RegistryError(f"Unsupported digest algorithm: {algorithm}") from exc
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return f"{algorithm}:{hasher.hexdigest()}"


def blob_path(layout: Path, digest: str) -> Path:
    algorithm, encoded = split_digest(digest)
    return layout / "blobs" / algorithm / encoded


def validate_file_digest(path: Path, expected: str) -> None:
    algorithm, _ = split_digest(expected)
    actual = digest_file(path, algorithm)
    if actual != expected.lower():
        raise RegistryError(f"Digest mismatch for {path}: expected {expected}, got {actual}")


def quote_repository(repository: str) -> str:
    return "/".join(urllib.parse.quote(part, safe="._-") for part in repository.split("/"))


class RegistryClient:
    """OCI Distribution API client with Basic and bearer-challenge auth."""

    def __init__(
        self,
        base_url: str,
        credentials: Credentials | None = None,
        *,
        verify_tls: bool = True,
        retries: int = 3,
        retry_delay: float = 1.0,
        user_agent: str = "fetch-kit-oci/2.0",
    ) -> None:
        parts = urllib.parse.urlsplit(base_url.rstrip("/"))
        if parts.scheme not in {"http", "https"} or not parts.netloc:
            raise RegistryError(f"Registry URL must include http(s) scheme and host: {base_url}")
        if parts.query or parts.fragment:
            raise RegistryError(f"Registry URL must not include a query or fragment: {base_url}")
        self.base_url = base_url.rstrip("/")
        self.credentials = credentials or Credentials()
        self.retries = retries
        self.retry_delay = retry_delay
        self.user_agent = user_agent
        self._tokens: dict[tuple[str, str], str] = {}
        self._repository_tokens: dict[str, str] = {}
        context = None if verify_tls else ssl._create_unverified_context()
        handlers: list[urllib.request.BaseHandler] = [SafeRedirectHandler()]
        if context is not None:
            handlers.append(urllib.request.HTTPSHandler(context=context))
        self.opener = urllib.request.build_opener(*handlers)

    def api_url(self, repository: str, suffix: str) -> str:
        quoted_repo = quote_repository(repository)
        return f"{self.base_url}/v2/{quoted_repo}/{suffix.lstrip('/')}"

    def _token_for_challenge(
        self,
        challenge: Mapping[str, str],
        repository: str,
        actions: Iterable[str],
        *,
        force_refresh: bool = False,
    ) -> str:
        realm = challenge.get("realm", "")
        if not realm:
            raise RegistryError("Registry bearer challenge did not include a realm")
        scope = challenge.get("scope") or f"repository:{repository}:{','.join(actions)}"
        service = challenge.get("service", "")
        cache_key = (realm, scope)
        if force_refresh:
            self._tokens.pop(cache_key, None)
        if cache_key in self._tokens:
            return self._tokens[cache_key]

        query = [("scope", scope)]
        if service:
            query.insert(0, ("service", service))
        separator = "&" if urllib.parse.urlsplit(realm).query else "?"
        token_url = realm + separator + urllib.parse.urlencode(query)
        headers = {"Accept": "application/json"}
        basic = self.credentials.basic_header()
        if basic:
            headers["Authorization"] = basic
        elif self.credentials.bearer_token:
            headers["Authorization"] = f"Bearer {self.credentials.bearer_token}"
        if self.credentials.api_key:
            headers["X-JFrog-Art-Api"] = self.credentials.api_key

        response = self._open_raw("GET", token_url, headers=headers, data=None)
        try:
            payload = json.loads(response.read().decode("utf-8"))
        finally:
            response.close()
        token = payload.get("token") or payload.get("access_token")
        if not token:
            raise RegistryError("Registry token endpoint did not return a token")
        self._tokens[cache_key] = str(token)
        return str(token)

    def _open_raw(
        self,
        method: str,
        url: str,
        *,
        headers: Mapping[str, str],
        data: bytes | BinaryIO | None,
    ):
        request = urllib.request.Request(url, data=data, headers=dict(headers), method=method)
        last_error: Exception | None = None
        for attempt in range(self.retries + 1):
            if hasattr(data, "seek"):
                data.seek(0)
            try:
                return self.opener.open(request, timeout=120)
            except urllib.error.HTTPError as exc:
                if exc.code not in {429, 500, 502, 503, 504} or attempt >= self.retries:
                    raise
                last_error = exc
                exc.close()
            except urllib.error.URLError as exc:
                if attempt >= self.retries:
                    raise
                last_error = exc
            time.sleep(self.retry_delay * (attempt + 1))
        raise RegistryError(f"Request failed: {last_error}")

    def open(
        self,
        method: str,
        url: str,
        *,
        repository: str,
        actions: Iterable[str],
        headers: Mapping[str, str] | None = None,
        data: bytes | BinaryIO | None = None,
        allow_status: Iterable[int] = (),
    ):
        request_headers = {"User-Agent": self.user_agent, **self.credentials.initial_headers()}
        if repository in self._repository_tokens and "Authorization" not in request_headers:
            request_headers["Authorization"] = f"Bearer {self._repository_tokens[repository]}"
        if headers:
            request_headers.update(headers)
        try:
            return self._open_raw(method, url, headers=request_headers, data=data)
        except urllib.error.HTTPError as exc:
            if exc.code in set(allow_status):
                return exc
            if exc.code != 401:
                detail = exc.read(4096).decode("utf-8", errors="replace").strip()
                exc.close()
                raise RegistryError(f"HTTP {exc.code} from {url}{': ' + detail if detail else ''}") from exc
            challenge_header = exc.headers.get("WWW-Authenticate", "")
            exc.close()

        scheme, challenge = parse_www_authenticate(challenge_header)
        if scheme == "bearer":
            token = self._token_for_challenge(
                challenge,
                repository,
                tuple(actions),
                force_refresh=True,
            )
            self._repository_tokens[repository] = token
            request_headers["Authorization"] = f"Bearer {token}"
        elif scheme == "basic":
            basic = self.credentials.basic_header()
            if not basic:
                raise RegistryError(f"Registry requires Basic authentication for {url}")
            request_headers["Authorization"] = basic
        else:
            raise RegistryError(
                f"Registry returned HTTP 401 without a supported authentication challenge for {url}"
            )

        try:
            return self._open_raw(method, url, headers=request_headers, data=data)
        except urllib.error.HTTPError as exc:
            if exc.code in set(allow_status):
                return exc
            detail = exc.read(4096).decode("utf-8", errors="replace").strip()
            exc.close()
            raise RegistryError(f"HTTP {exc.code} from {url}{': ' + detail if detail else ''}") from exc
        except urllib.error.URLError as exc:
            raise RegistryError(f"Could not reach {url}: {exc.reason}") from exc

    def request_bytes(
        self,
        method: str,
        url: str,
        *,
        repository: str,
        actions: Iterable[str],
        headers: Mapping[str, str] | None = None,
        data: bytes | None = None,
        allow_status: Iterable[int] = (),
    ) -> ResponseData:
        response = self.open(
            method,
            url,
            repository=repository,
            actions=actions,
            headers=headers,
            data=data,
            allow_status=allow_status,
        )
        try:
            body = response.read()
            return ResponseData(
                body=body,
                headers=response.headers,
                url=response.geturl(),
                status=response.status,
            )
        finally:
            response.close()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def load_credentials_file(path: Path) -> dict[str, Credentials]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RegistryError(f"Could not read credentials file {path}: {exc}") from exc

    auths = data.get("auths", data) if isinstance(data, dict) else None
    if not isinstance(auths, dict):
        raise RegistryError("Credentials file must be a JSON object or contain an 'auths' object")

    result: dict[str, Credentials] = {}
    for raw_registry, raw_entry in auths.items():
        if not isinstance(raw_entry, dict):
            raise RegistryError(f"Credentials entry for {raw_registry} must be an object")
        registry = urllib.parse.urlsplit(
            raw_registry if "://" in raw_registry else "https://" + raw_registry
        ).netloc.lower()
        if registry in {"docker.io", "index.docker.io"}:
            registry = "registry-1.docker.io"
        username = str(raw_entry.get("username", ""))
        password = str(raw_entry.get("password", ""))
        bearer = str(raw_entry.get("bearerToken") or raw_entry.get("identitytoken") or raw_entry.get("token") or "")
        encoded = str(raw_entry.get("auth", ""))
        if encoded and not (username and password):
            try:
                decoded = base64.b64decode(encoded).decode("utf-8")
                username, password = decoded.split(":", 1)
            except (ValueError, UnicodeDecodeError) as exc:
                raise RegistryError(f"Invalid base64 auth value for {raw_registry}") from exc
        result[registry] = Credentials(username=username, password=password, bearer_token=bearer)
    return result
