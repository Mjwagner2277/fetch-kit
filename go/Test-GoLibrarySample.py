#!/usr/bin/env python3
"""Randomly sample modules from index.golang.org and test Get-GoLibrary.py."""

from __future__ import annotations

import argparse
import json
import random
import subprocess
import time
import urllib.request
from pathlib import Path


def safe_file_name(value: str) -> str:
    for char in '\\/:*?"<>|@':
        value = value.replace(char, "_")
    return value


def module_index(limit: int = 2000) -> list[dict[str, str]]:
    uri = f"https://index.golang.org/index?limit={limit}"
    with urllib.request.urlopen(uri, timeout=120) as response:
        lines = response.read().decode("utf-8").splitlines()
    return [json.loads(line) for line in lines if line.strip()]


def main() -> int:
    parser = argparse.ArgumentParser(description="Randomly test Get-GoLibrary.py against public Go modules.")
    parser.add_argument("--sample-size", type=int, default=50)
    parser.add_argument("--batch-size", type=int, default=10)
    parser.add_argument("--output-directory", default="sample-results")
    parser.add_argument("--resolve-dependencies", action="store_true", default=True)
    parser.add_argument("--skip-resolve-dependencies", action="store_true")
    parser.add_argument("--expand", action="store_true")
    args = parser.parse_args()

    output_dir = Path(args.output_directory)
    output_dir.mkdir(parents=True, exist_ok=True)
    retriever = Path(__file__).with_name("Get-GoLibrary.py")
    if not retriever.exists():
        raise SystemExit(f"Could not find {retriever}")

    entries = module_index()
    unique_by_path: dict[str, dict[str, str]] = {}
    for entry in entries:
        if entry.get("Path") and entry.get("Version") and entry["Path"] not in unique_by_path:
            unique_by_path[entry["Path"]] = entry
    unique = list(unique_by_path.values())
    if len(unique) < args.sample_size:
        raise SystemExit(f"Only found {len(unique)} unique modules; need {args.sample_size}.")

    sample = random.sample(unique, args.sample_size)
    sample_file = output_dir / "sample.json"
    sample_file.write_text(json.dumps(sample, indent=2), encoding="utf-8")

    results: list[dict[str, object]] = []
    resolve_dependencies = bool(args.resolve_dependencies) and not args.skip_resolve_dependencies

    for index, item in enumerate(sample):
        batch = (index // args.batch_size) + 1
        module = item["Path"]
        version = item["Version"]
        log_file = output_dir / f"{safe_file_name(module + '@' + version)}.log"
        command = [
            "python3",
            str(retriever),
            "--module",
            module,
            "--version",
            version,
            "--output-directory",
            str(Path.cwd() / "go-library-cache-sample"),
        ]
        if resolve_dependencies:
            command.append("--resolve-dependencies")
        if args.expand:
            command.append("--expand")

        started = time.time()
        completed = subprocess.run(command, text=True, capture_output=True, check=False)
        finished = time.time()
        log_file.write_text(completed.stdout + completed.stderr, encoding="utf-8")
        results.append(
            {
                "Batch": batch,
                "Module": module,
                "Version": version,
                "Success": completed.returncode == 0,
                "ExitCode": completed.returncode,
                "Started": started,
                "Finished": finished,
                "DurationSec": round(finished - started, 3),
                "LogFile": str(log_file),
                "Error": "" if completed.returncode == 0 else completed.stdout + completed.stderr,
            }
        )

    results_file = output_dir / "results.json"
    summary_file = output_dir / "summary.json"
    results_file.write_text(json.dumps(results, indent=2), encoding="utf-8")
    summary = {
        "SampleSize": args.sample_size,
        "BatchSize": args.batch_size,
        "ResolveDependencies": resolve_dependencies,
        "Expand": bool(args.expand),
        "Successes": len([item for item in results if item["Success"]]),
        "Failures": len([item for item in results if not item["Success"]]),
        "SampleFile": str(sample_file),
        "ResultsFile": str(results_file),
    }
    summary_file.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))
    return 0 if summary["Failures"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
