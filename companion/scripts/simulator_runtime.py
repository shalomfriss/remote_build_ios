#!/usr/bin/env python3
# Copyright (c) 2026 Pedro Shakour
# SPDX-License-Identifier: Apache-2.0
"""Boot an iOS Simulator, build GrokApp, and install it."""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time
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


def device_is_booted(data: dict[str, Any], udid: str) -> bool:
    return any(
        device.get("udid") == udid and device.get("state") == "Booted"
        for runtime, entries in data.get("devices", {}).items()
        if "SimRuntime.iOS-" in runtime
        for device in entries
    )


def run_captured(command: list[str], *, timeout: float) -> subprocess.CompletedProcess[str]:
    """Run a command in its own process group so a timeout cannot leak descendants."""
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired as error:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        if process.stdout is not None:
            process.stdout.close()
        if process.stderr is not None:
            process.stderr.close()
        raise subprocess.TimeoutExpired(command, timeout) from error
    return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


def run_quiet_bounded(command: list[str], *, timeout: float) -> int:
    process = subprocess.Popen(
        command,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        return -signal.SIGKILL


def registered_simdevice_services() -> list[str]:
    try:
        result = run_captured(
            ["launchctl", "print", f"user/{os.getuid()}"],
            timeout=10,
        )
    except subprocess.TimeoutExpired:
        return []
    return sorted(set(re.findall(
        r"com\.apple\.CoreSimulator\.SimDevice\.[A-Fa-f0-9-]+",
        result.stdout,
    )))


def restart_coresimulator_service() -> bool:
    """Restart the per-user CoreSimulator service without erasing device data."""
    print(
        "[simulator-runtime] CoreSimulator is not responding; restarting its service",
        file=sys.stderr,
        flush=True,
    )
    domain = f"user/{os.getuid()}"
    recovery_complete = True
    for label in registered_simdevice_services():
        result = run_quiet_bounded(
            ["launchctl", "kickstart", "-k", f"{domain}/{label}"],
            timeout=10,
        )
        recovery_complete = recovery_complete and result == 0
    service = f"{domain}/com.apple.CoreSimulator.CoreSimulatorService"
    result = run_quiet_bounded(["launchctl", "kickstart", "-k", service], timeout=10)
    if result != 0:
        result = run_quiet_bounded(
            ["killall", "-9", "com.apple.CoreSimulator.CoreSimulatorService"],
            timeout=5,
        )
    recovery_complete = recovery_complete and result == 0
    time.sleep(1)
    return recovery_complete


def list_available_devices() -> dict[str, Any]:
    """List devices, recovering once when the CoreSimulator service is wedged."""
    timeout = float(os.environ.get("GROK_SIMCTL_LIST_TIMEOUT", "20"))
    last_error = ""
    recovery_complete = True
    for attempt in range(2):
        try:
            listing = run_captured(
                ["xcrun", "simctl", "list", "devices", "available", "-j"],
                timeout=timeout,
            )
        except subprocess.TimeoutExpired:
            last_error = f"timed out after {timeout:g} seconds"
        else:
            if listing.returncode == 0:
                try:
                    return json.loads(listing.stdout)
                except json.JSONDecodeError as error:
                    raise RuntimeError("simctl returned invalid simulator metadata") from error
            last_error = listing.stderr.strip() or f"exited with status {listing.returncode}"
        if attempt == 0:
            recovery_complete = restart_coresimulator_service()
    suffix = ""
    if not recovery_complete:
        suffix = "; a simulator process could not be stopped, so restart macOS and try again"
    raise RuntimeError(f"Could not list iOS Simulators: {last_error}{suffix}")


def run(command: list[str], *, quiet: bool = False, timeout: float | None = None) -> None:
    print(f"[simulator-runtime] {' '.join(command)}", file=sys.stderr, flush=True)
    kwargs: dict[str, Any] = {"check": True, "stdout": sys.stderr, "timeout": timeout}
    if quiet:
        kwargs.update(stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(command, **kwargs)


def device_is_responsive(udid: str) -> bool:
    """Return whether SpringBoard is running, not merely whether simctl says Booted."""
    try:
        result = subprocess.run(
            [
                "xcrun", "simctl", "spawn", udid, "launchctl", "print",
                "system/com.apple.SpringBoard",
            ],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )
    except subprocess.TimeoutExpired:
        return False
    return result.returncode == 0


def ensure_device_booted(udid: str, *, state: str = "") -> None:
    """Start an exact simulator, recovering once if BackBoard wedges during boot."""
    if state == "Booted" and device_is_responsive(udid):
        return

    timeout = float(os.environ.get("GROK_SIMULATOR_BOOT_TIMEOUT", "60"))
    last_error = ""
    for attempt in range(2):
        if state == "Booted" or attempt > 0:
            print(
                f"[simulator-runtime] simulator {udid} is not responsive; restarting it",
                file=sys.stderr,
                flush=True,
            )
            try:
                subprocess.run(
                    ["xcrun", "simctl", "shutdown", udid],
                    check=False,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=20,
                )
            except subprocess.TimeoutExpired:
                last_error = "timed out shutting down the unresponsive simulator"
                continue
        try:
            subprocess.run(
                ["xcrun", "simctl", "boot", udid],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=20,
            )
        except subprocess.TimeoutExpired:
            last_error = "timed out asking CoreSimulator to boot"
            continue
        try:
            run(["xcrun", "simctl", "bootstatus", udid, "-b"], timeout=timeout)
        except subprocess.TimeoutExpired:
            last_error = f"timed out after {timeout:g} seconds waiting for BackBoard"
            continue
        except subprocess.CalledProcessError as error:
            last_error = f"bootstatus exited with status {error.returncode}"
            continue
        if device_is_responsive(udid):
            return
        last_error = "SpringBoard did not become responsive"
    raise RuntimeError(f"Could not boot iOS Simulator {udid}: {last_error}")


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

    excluded = set(args.exclude_device)
    failed_devices = 0
    while True:
        try:
            device_data = list_available_devices()
        except RuntimeError as error:
            print(str(error), file=sys.stderr)
            return 1
        device = select_device(device_data, args.device, excluded)
        if device is None:
            print(f"No available iOS Simulator matched {args.device!r}", file=sys.stderr)
            return 1

        udid = device["udid"]
        try:
            ensure_device_booted(
                udid,
                state="Booted" if device_is_booted(device_data, udid) else "Shutdown",
            )
            break
        except RuntimeError as error:
            failed_devices += 1
            if args.device or failed_devices >= 2:
                print(str(error), file=sys.stderr)
                return 1
            print(
                f"[simulator-runtime] {error}; trying another available iPhone",
                file=sys.stderr,
                flush=True,
            )
            excluded.add(udid)
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
