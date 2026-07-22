#!/usr/bin/env python3
"""Resolve a LAN address that a physical phone can use to reach this Mac."""

from __future__ import annotations

import argparse
import ipaddress
import os
import socket
import subprocess


def usable_ipv4(value: str | None) -> str | None:
    if not value:
        return None
    try:
        address = ipaddress.ip_address(value.strip())
    except ValueError:
        return None
    if address.version != 4 or address.is_loopback or address.is_unspecified:
        return None
    return str(address)


def route_address() -> str | None:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect(("1.1.1.1", 80))
            return usable_ipv4(probe.getsockname()[0])
    except OSError:
        return None


def interface_address() -> str | None:
    for interface in ("en0", "en1"):
        try:
            result = subprocess.run(
                ["ipconfig", "getifaddr", interface],
                check=False,
                capture_output=True,
                text=True,
            )
        except OSError:
            return None
        address = usable_ipv4(result.stdout)
        if address:
            return address
    return None


def phone_host(explicit: str | None = None) -> str:
    override = usable_ipv4(explicit)
    if explicit and not override:
        raise ValueError("GROK_SIMULATOR_ADVERTISE_HOST must be a non-loopback IPv4 address")
    address = override or route_address() or interface_address()
    if not address:
        raise RuntimeError(
            "could not determine a phone-reachable LAN address; set "
            "GROK_SIMULATOR_ADVERTISE_HOST or use --ngrok"
        )
    return address


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    host = phone_host(os.environ.get("GROK_SIMULATOR_ADVERTISE_HOST"))
    print(f"http://{host}:{args.port}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, ValueError) as error:
        raise SystemExit(str(error)) from error
