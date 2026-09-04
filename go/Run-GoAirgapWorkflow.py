#!/usr/bin/env python3
"""Run Go package download, vulnerability DB mirror, archive, and CSV scan."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any


def status(message: str) -> None:
    print(f"[go-airgap] {message}", file=sys.stderr)


def run(command: list[str], *, stdout_path: Path | None = None) -> None:
    status("running: " + " ".join(command))
    if stdout_path:
        stdout_path.parent.mkdir(parents=True, exist_ok=True)
        with stdout_path.open("w", encoding="utf-8") as handle:
            completed = subprocess.run(command, text=True, stdout=handle, check=False)
    else:
        completed = subprocess.run(command, text=True, check=False)
    if completed.returncode != 0:
        raise RuntimeError(f"command failed with exit code {completed.returncode}: {' '.join(command)}")


def main(argv: list[str] | None = None) -> int:
    script_dir = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description="Download Go modules, mirror vuln DB, archive proxy cache, and write vuln CSV.")
    parser.add_argument("--package-list-path", required=True)
    parser.add_argument("--go-version", required=True)
    parser.add_argument("--output-directory", default="go-airgap-output")
    parser.add_argument("--proxy", action="append", default=[])
    parser.add_argument("--resolve-dependencies", action="store_true")
    parser.add_argument("--refresh-vuln-db", action="store_true")
    parser.add_argument("--vuln-db-url", default="https://vuln.go.dev/vulndb.zip")
    parser.add_argument("--vuln-db-zip", default="")
    parser.add_argument("--go-proxy-directory", default="")
    parser.add_argument("--archive-output", default="")
    parser.add_argument("--report-csv", default="")
    parser.add_argument("--report-json", default="")
    args = parser.parse_args(argv)

    output_dir = Path(args.output_directory)
    go_proxy_directory = Path(args.go_proxy_directory) if args.go_proxy_directory else output_dir / "go-proxy-cache"
    archive_output = Path(args.archive_output) if args.archive_output else output_dir / "go-proxy-cache.tar.gz"
    vuln_db_zip = Path(args.vuln_db_zip) if args.vuln_db_zip else output_dir / "go-vulndb" / "vulndb.zip"
    report_csv = Path(args.report_csv) if args.report_csv else output_dir / "go-vuln-report.csv"
    report_json = Path(args.report_json) if args.report_json else output_dir / "go-vuln-report.json"
    download_result = output_dir / "download-result.json"
    vuln_db_result = output_dir / "vulndb-result.json"
    scan_result = output_dir / "scan-result.json"

    output_dir.mkdir(parents=True, exist_ok=True)

    download_command = [
        sys.executable,
        str(script_dir / "Get-GoLibrary.py"),
        "--package-list-path",
        args.package_list_path,
        "--go-version",
        args.go_version,
        "--go-proxy-directory",
        str(go_proxy_directory),
        "--archive-output",
        str(archive_output),
    ]
    for proxy in args.proxy:
        download_command.extend(["--proxy", proxy])
    if args.resolve_dependencies:
        download_command.append("--resolve-dependencies")
    run(download_command, stdout_path=download_result)

    vuln_command = [
        sys.executable,
        str(script_dir / "Get-GoVulnDb.py"),
        "--url",
        args.vuln_db_url,
        "--output",
        str(vuln_db_zip),
    ]
    if args.refresh_vuln_db:
        vuln_command.append("--force")
    run(vuln_command, stdout_path=vuln_db_result)

    scan_command = [
        sys.executable,
        str(script_dir / "Scan-GoProxyVulns.py"),
        "--go-proxy-directory",
        str(go_proxy_directory),
        "--vuln-db",
        str(vuln_db_zip),
        "--download-result",
        str(download_result),
        "--output-csv",
        str(report_csv),
        "--output-json",
        str(report_json),
    ]
    for proxy in args.proxy:
        scan_command.extend(["--proxy", proxy])
    run(scan_command, stdout_path=scan_result)

    result: dict[str, Any] = {
        "PackageListPath": args.package_list_path,
        "GoVersion": args.go_version,
        "OutputDirectory": str(output_dir),
        "GoProxyDirectory": str(go_proxy_directory),
        "ArchiveOutput": str(archive_output),
        "VulnDbZip": str(vuln_db_zip),
        "ReportCsv": str(report_csv),
        "ReportJson": str(report_json),
        "DownloadResult": str(download_result),
        "VulnDbResult": str(vuln_db_result),
        "ScanResult": str(scan_result),
    }
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
