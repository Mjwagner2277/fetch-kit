#!/usr/bin/env python3
"""Scan a static Go proxy cache against an offline Go vulnerability database."""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
import urllib.error
import urllib.request
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


def status(message: str) -> None:
    print(f"[go-vuln-scan] {message}", file=sys.stderr)


def unescape_go_proxy_segment(value: str) -> str:
    out: list[str] = []
    index = 0
    while index < len(value):
        if value[index] == "!" and index + 1 < len(value):
            out.append(value[index + 1].upper())
            index += 2
        else:
            out.append(value[index])
            index += 1
    return "".join(out)


def module_from_version_dir(version_dir: Path, proxy_root: Path) -> str:
    relative = version_dir.parent.relative_to(proxy_root).as_posix()
    return "/".join(unescape_go_proxy_segment(part) for part in relative.split("/"))


def escape_go_proxy_segment(value: str) -> str:
    out: list[str] = []
    for char in value:
        if "A" <= char <= "Z":
            out.append("!")
            out.append(char.lower())
        else:
            out.append(char)
    return "".join(out)


def join_url(base: str, path: str) -> str:
    return base.rstrip("/") + "/" + path.lstrip("/")


def http_text(uri: str) -> str:
    request = urllib.request.Request(uri, headers={"User-Agent": "fetch-kit-go-vuln-scan"})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"HTTP {exc.code} from {uri}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"{exc.reason} from {uri}") from exc


def go_proxy_version_dir(root: Path, module_path: str) -> Path:
    return root / Path(*escape_go_proxy_segment(module_path).split("/")) / "@v"


def semver_sort_key(version: str) -> tuple[int, int, int, int, str]:
    clean = version.strip()
    if clean == "0":
        return (0, 0, 0, 1, "")
    match = re.match(r"^v?(\d+)\.(\d+)\.(\d+)(-.+)?(?:\+.*)?$", clean)
    if not match:
        return (-1, -1, -1, 0, clean)
    major, minor, patch = (int(match.group(i)) for i in range(1, 4))
    prerelease = match.group(4) or ""
    stable = 1 if not prerelease else 0
    return (major, minor, patch, stable, prerelease)


def normalize_go_module_version(version: str) -> str:
    if re.match(r"^\d+\.\d+\.\d+", version):
        return "v" + version
    return version


def compare_versions(left: str, right: str) -> int:
    left_key = semver_sort_key(left)
    right_key = semver_sort_key(right)
    if left_key > right_key:
        return 1
    if left_key < right_key:
        return -1
    return 0


def go_directive_from_mod(content: str) -> str:
    for raw_line in content.splitlines():
        clean = re.sub(r"//.*$", "", raw_line).strip()
        match = re.match(r"^go\s+([0-9]+(?:\.[0-9]+){1,2})$", clean)
        if match:
            return match.group(1)
    return ""


def csv_join(values: Iterable[str]) -> str:
    return ";".join(value for value in values if value)


@dataclass
class DownloadedModule:
    package: str
    module: str
    version: str
    go_version: str
    mod_file: Path


@dataclass
class VulnerabilityMatch:
    vuln_id: str
    cve: str
    aliases: list[str]
    severity: str
    severity_score: float
    fixed_version: str
    fixed_go_version: str
    summary: str
    details_url: str


def load_package_map(download_result: Path | None) -> dict[tuple[str, str], list[str]]:
    if not download_result:
        return {}
    result = json.loads(download_result.read_text(encoding="utf-8"))
    requested_items = result.get("Requested", [])
    if isinstance(requested_items, dict):
        requested_items = [requested_items]
    package_map: dict[tuple[str, str], list[str]] = {}
    for item in requested_items:
        module = item.get("Module", "")
        version = item.get("Version", "")
        package = item.get("Package", "")
        if module and version and package:
            package_map.setdefault((module, version), [])
            if package not in package_map[(module, version)]:
                package_map[(module, version)].append(package)
    return package_map


def discover_downloaded_modules(proxy_root: Path, package_map: dict[tuple[str, str], list[str]]) -> list[DownloadedModule]:
    modules: list[DownloadedModule] = []
    for version_dir in sorted(proxy_root.glob("**/@v")):
        list_file = version_dir / "list"
        if not list_file.exists():
            continue
        module = module_from_version_dir(version_dir, proxy_root)
        for raw_version in list_file.read_text(encoding="utf-8").splitlines():
            version = raw_version.strip()
            if not version:
                continue
            escaped_version = escape_go_proxy_segment(version)
            mod_file = version_dir / f"{escaped_version}.mod"
            info_file = version_dir / f"{escaped_version}.info"
            zip_file = version_dir / f"{escaped_version}.zip"
            if not mod_file.exists() or not info_file.exists() or not zip_file.exists():
                status(f"skipping incomplete proxy entry {module}@{version}")
                continue
            go_version = go_directive_from_mod(mod_file.read_text(encoding="utf-8"))
            packages = package_map.get((module, version), [module])
            for package in packages:
                modules.append(DownloadedModule(package=package, module=module, version=version, go_version=go_version, mod_file=mod_file))
    return modules


def iter_vuln_records(vuln_db: Path) -> Iterable[dict[str, Any]]:
    if vuln_db.is_dir():
        for path in sorted((vuln_db / "ID").glob("*.json")):
            yield json.loads(path.read_text(encoding="utf-8"))
        return

    with zipfile.ZipFile(vuln_db) as archive:
        for name in sorted(archive.namelist()):
            normalized = name.lstrip("/")
            if normalized.startswith("ID/") and normalized.endswith(".json"):
                with archive.open(name) as handle:
                    yield json.loads(handle.read().decode("utf-8"))


def affected_module_names(record: dict[str, Any]) -> set[str]:
    names: set[str] = set()
    for affected in record.get("affected", []) or []:
        package = affected.get("package", {}) or {}
        if package.get("ecosystem") == "Go" and package.get("name"):
            names.add(package["name"])
    return names


def version_in_osv_range(version: str, affected: dict[str, Any]) -> bool:
    explicit_versions = affected.get("versions", []) or []
    if version in explicit_versions:
        return True

    ranges = affected.get("ranges", []) or []
    for version_range in ranges:
        if version_range.get("type") not in {"SEMVER", "ECOSYSTEM"}:
            continue
        introduced = "0"
        vulnerable = False
        for event in version_range.get("events", []) or []:
            if "introduced" in event:
                introduced = event["introduced"]
                vulnerable = compare_versions(version, introduced) >= 0
            elif "fixed" in event and vulnerable and compare_versions(version, event["fixed"]) < 0:
                return True
            elif "fixed" in event:
                vulnerable = False
            elif "last_affected" in event and vulnerable and compare_versions(version, event["last_affected"]) <= 0:
                return True
            elif "limit" in event and vulnerable and compare_versions(version, event["limit"]) < 0:
                return True
        if vulnerable:
            return True
    return False


def fixed_versions_for_module(affected: dict[str, Any]) -> list[str]:
    versions: list[str] = []
    for version_range in affected.get("ranges", []) or []:
        if version_range.get("type") not in {"SEMVER", "ECOSYSTEM"}:
            continue
        for event in version_range.get("events", []) or []:
            fixed = event.get("fixed")
            if fixed:
                versions.append(normalize_go_module_version(fixed))
    return sorted(set(versions), key=semver_sort_key)


def highest_fixed_version(fixed_versions: list[str], current_version: str) -> str:
    candidates = [version for version in fixed_versions if compare_versions(version, current_version) > 0]
    if candidates:
        return candidates[0]
    return fixed_versions[0] if fixed_versions else ""


def fixed_go_version(proxy_root: Path, module: str, fixed_version: str, proxies: list[str]) -> str:
    if not fixed_version:
        return ""
    mod_file = go_proxy_version_dir(proxy_root, module) / f"{escape_go_proxy_segment(fixed_version)}.mod"
    if not mod_file.exists():
        escaped_module = escape_go_proxy_segment(module)
        escaped_version = escape_go_proxy_segment(fixed_version)
        for proxy in proxies:
            if proxy in {"off", "direct"}:
                continue
            try:
                status(f"looking up fixed go directive for {module}@{fixed_version} from {proxy}")
                return go_directive_from_mod(http_text(join_url(join_url(join_url(proxy, escaped_module), "@v"), f"{escaped_version}.mod")))
            except Exception as exc:
                status(f"could not read fixed go directive for {module}@{fixed_version} from {proxy}: {exc}")
        return ""
    return go_directive_from_mod(mod_file.read_text(encoding="utf-8"))


def cve_aliases(record: dict[str, Any]) -> list[str]:
    return sorted([alias for alias in record.get("aliases", []) or [] if alias.startswith("CVE-")], reverse=True)


def severity_text_and_score(record: dict[str, Any]) -> tuple[str, float]:
    severity_entries = record.get("severity", []) or []
    if not severity_entries:
        return "", 0.0
    rendered: list[str] = []
    best = 0.0
    for item in severity_entries:
        score = str(item.get("score", ""))
        kind = str(item.get("type", ""))
        rendered.append(f"{kind}:{score}" if kind else score)
        numeric = re.search(r"(^|\s)(10(?:\.0)?|[0-9](?:\.[0-9])?)($|\s)", score)
        if numeric:
            best = max(best, float(numeric.group(2)))
    return csv_join(rendered), best


def match_vulnerability(proxy_root: Path, module: DownloadedModule, record: dict[str, Any], proxies: list[str]) -> VulnerabilityMatch | None:
    matches_module = module.module in affected_module_names(record)
    if not matches_module:
        return None

    for affected in record.get("affected", []) or []:
        package = affected.get("package", {}) or {}
        if package.get("ecosystem") != "Go" or package.get("name") != module.module:
            continue
        if not version_in_osv_range(module.version, affected):
            continue

        aliases = record.get("aliases", []) or []
        cves = cve_aliases(record)
        severity, severity_score = severity_text_and_score(record)
        fixed_version = highest_fixed_version(fixed_versions_for_module(affected), module.version)
        return VulnerabilityMatch(
            vuln_id=record.get("id", ""),
            cve=cves[0] if cves else "",
            aliases=list(aliases),
            severity=severity,
            severity_score=severity_score,
            fixed_version=fixed_version,
            fixed_go_version=fixed_go_version(proxy_root, module.module, fixed_version, proxies),
            summary=record.get("summary", ""),
            details_url=(record.get("database_specific", {}) or {}).get("url", ""),
        )
    return None


def choose_highest(matches: list[VulnerabilityMatch]) -> VulnerabilityMatch | None:
    if not matches:
        return None
    return sorted(
        matches,
        key=lambda item: (item.severity_score, item.cve, item.vuln_id),
        reverse=True,
    )[0]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Scan downloaded Go proxy modules against an offline Go vulnerability database.")
    parser.add_argument("--go-proxy-directory", required=True)
    parser.add_argument("--vuln-db", required=True, help="Path to vulndb.zip or an extracted vuln DB directory.")
    parser.add_argument("--download-result", default="", help="Optional JSON output from Get-GoLibrary.py for package-to-module names.")
    parser.add_argument("--output-csv", default="go-vuln-report.csv")
    parser.add_argument("--output-json", default="")
    parser.add_argument("--proxy", action="append", default=[], help="Optional Go proxy URL for fixed-version .mod lookups.")
    args = parser.parse_args(argv)

    proxy_root = Path(args.go_proxy_directory)
    vuln_db = Path(args.vuln_db)
    if not proxy_root.exists():
        raise SystemExit(f"Go proxy directory does not exist: {proxy_root}")
    if not vuln_db.exists():
        raise SystemExit(f"Go vulnerability database does not exist: {vuln_db}")

    package_map = load_package_map(Path(args.download_result) if args.download_result else None)
    modules = discover_downloaded_modules(proxy_root, package_map)
    status(f"discovered {len(modules)} downloaded module versions")

    records_by_module: dict[str, list[dict[str, Any]]] = {}
    for record in iter_vuln_records(vuln_db):
        for module_name in affected_module_names(record):
            records_by_module.setdefault(module_name, []).append(record)
    status(f"loaded vulnerability records for {len(records_by_module)} Go modules")

    rows: list[dict[str, Any]] = []
    for module in modules:
        matches = [
            match
            for record in records_by_module.get(module.module, [])
            for match in [match_vulnerability(proxy_root, module, record, args.proxy)]
            if match is not None
        ]
        highest = choose_highest(matches)
        rows.append(
            {
                "Package": module.package,
                "Module": module.module,
                "Version": module.version,
                "GoVersion": module.go_version,
                "VulnerabilityCount": len(matches),
                "HighestCVE": highest.cve if highest else "",
                "HighestVulnerabilityID": highest.vuln_id if highest else "",
                "Severity": highest.severity if highest else "",
                "CVEScore": f"{highest.severity_score:g}" if highest and highest.severity_score else "",
                "FixedVersion": highest.fixed_version if highest else "",
                "FixedGoVersion": highest.fixed_go_version if highest else "",
                "Aliases": csv_join(highest.aliases) if highest else "",
                "Summary": highest.summary if highest else "",
                "DetailsUrl": highest.details_url if highest else "",
            }
        )

    output_csv = Path(args.output_csv)
    output_csv.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "Package",
        "Module",
        "Version",
        "GoVersion",
        "VulnerabilityCount",
        "HighestCVE",
        "HighestVulnerabilityID",
        "Severity",
        "CVEScore",
        "FixedVersion",
        "FixedGoVersion",
        "Aliases",
        "Summary",
        "DetailsUrl",
    ]
    with output_csv.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    output_json = ""
    if args.output_json:
        json_path = Path(args.output_json)
        json_path.parent.mkdir(parents=True, exist_ok=True)
        json_path.write_text(json.dumps(rows, indent=2), encoding="utf-8")
        output_json = str(json_path)

    result = {
        "GoProxyDirectory": str(proxy_root),
        "VulnDb": str(vuln_db),
        "OutputCsv": str(output_csv),
        "OutputJson": output_json,
        "ScannedModuleVersions": len(rows),
        "AffectedModuleVersions": len([row for row in rows if row["VulnerabilityCount"]]),
    }
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
