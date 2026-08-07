#!/usr/bin/env python3
# Copyright (c) 2026 Pedro Shakour
# SPDX-License-Identifier: Apache-2.0
"""Boot an iOS Simulator, build GrokApp, and install it."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any


def select_device(
    data: dict[str, Any],
    preferred: str = "",
    excluded_udids: set[str] | None = None,
) -> dict[str, str] | None:
    excluded = excluded_udids or set()
    devices = [
        device
        for runtime, entries in data.get("devices", {}).items()
        if "SimRuntime.iOS-" in runtime
        for device in entries
        if device.get("isAvailable", True) and device.get("udid") not in excluded
    ]
    if preferred:
        match = next(
            (device for device in devices if preferred in (device.get("udid"), device.get("name"))),
            None,
        )
        if match:
            return {"udid": match["udid"], "name": match["name"]}
        return None
    match = next((device for device in devices if device.get("state") == "Booted"), None)
    if match is None:
        match = next((device for device in devices if str(device.get("name", "")).startswith("iPhone")), None)
    if match:
        return {"udid": match["udid"], "name": match["name"]}
    return None


def run(command: list[str], *, quiet: bool = False) -> None:
    print(f"[simulator-runtime] {' '.join(command)}", file=sys.stderr, flush=True)
    kwargs: dict[str, Any] = {"check": True, "stdout": sys.stderr}
    if quiet:
        kwargs.update(stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(command, **kwargs)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project")
    parser.add_argument("--scheme", default="GrokApp")
    parser.add_argument("--bundle-id", default="app.grokbuild.ios")
    parser.add_argument("--derived-data")
    parser.add_argument("--device", default="")
    parser.add_argument("--exclude-device", action="append", default=[])
    parser.add_argument(
        "--boot-only",
        action="store_true",
        help="Select and boot a simulator without building or installing Grok Build",
    )
    args = parser.parse_args()

    listing = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "-j"],
        check=True,
        capture_output=True,
        text=True,
    )
    device = select_device(
        json.loads(listing.stdout),
        args.device,
        set(args.exclude_device),
    )
    if device is None:
        print(f"No available iOS Simulator matched {args.device!r}", file=sys.stderr)
        return 1

    udid = device["udid"]
    subprocess.run(["xcrun", "simctl", "boot", udid], check=False, capture_output=True)
    run(["xcrun", "simctl", "bootstatus", udid, "-b"])
    if args.boot_only:
        print(json.dumps({"udid": udid, "name": device["name"]}))
        return 0
    if not args.project or not args.derived_data:
        parser.error("--project and --derived-data are required unless --boot-only is used")
    run([
        "xcodebuild", "build",
        "-project", args.project,
        "-scheme", args.scheme,
        "-configuration", "Debug",
        "-destination", f"platform=iOS Simulator,id={udid}",
        "-derivedDataPath", args.derived_data,
        "CODE_SIGNING_ALLOWED=NO",
        "-quiet",
    ])
    app_path = Path(args.derived_data) / "Build/Products/Debug-iphonesimulator/GrokApp.app"
    if not app_path.is_dir():
        print(f"Built app not found at {app_path}", file=sys.stderr)
        return 1
    run(["xcrun", "simctl", "install", udid, str(app_path)])
    print(json.dumps({"udid": udid, "name": device["name"], "bundleId": args.bundle_id}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
