#!/usr/bin/env python3
"""Download the Go vulnerability database for offline module-version scans."""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import urllib.error
import urllib.request
import zipfile
from pathlib import Path
from typing import Any


def status(message: str) -> None:
    print(f"[go-vulndb] {message}", file=sys.stderr)


def download_file(url: str, output_path: Path) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": "fetch-kit-go-vulndb"})
    try:
        with urllib.request.urlopen(request, timeout=300) as response:
            output_path.parent.mkdir(parents=True, exist_ok=True)
            with output_path.open("wb") as handle:
                shutil.copyfileobj(response, handle)
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"HTTP {exc.code} from {url}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"{exc.reason} from {url}") from exc


def extract_zip(zip_path: Path, extract_dir: Path) -> None:
    extract_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path) as archive:
        archive.extractall(extract_dir)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Download vuln.go.dev/vulndb.zip for offline Go vulnerability scans.")
    parser.add_argument("--url", default="https://vuln.go.dev/vulndb.zip")
    parser.add_argument("--output", default="go-vulndb/vulndb.zip")
    parser.add_argument("--extract-dir", default="")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args(argv)

    output_path = Path(args.output)
    if output_path.exists() and not args.force:
        status(f"using cached vulnerability database: {output_path}")
    else:
        status(f"downloading vulnerability database from {args.url}")
        download_file(args.url, output_path)
        status(f"saved vulnerability database to {output_path}")

    extracted_to = ""
    if args.extract_dir:
        extract_dir = Path(args.extract_dir)
        status(f"extracting {output_path} to {extract_dir}")
        extract_zip(output_path, extract_dir)
        extracted_to = str(extract_dir)

    result: dict[str, Any] = {
        "Url": args.url,
        "Output": str(output_path),
        "SizeBytes": output_path.stat().st_size,
        "ExtractedTo": extracted_to,
    }
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
