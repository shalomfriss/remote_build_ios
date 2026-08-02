#!/usr/bin/env python3
# Copyright (c) 2026 Pedro Shakour
# SPDX-License-Identifier: Apache-2.0
"""Extract a public endpoint from ngrok's JSON agent log."""

from __future__ import annotations

import json
import socket
import sys
from pathlib import Path
from urllib.parse import urlsplit


def endpoint_from_lines(lines: list[str], scheme: str) -> str | None:
    prefix = f"{scheme}://"
    for line in reversed(lines):
        try:
            endpoint = json.loads(line).get("url", "")
        except (json.JSONDecodeError, AttributeError):
            continue
        if isinstance(endpoint, str) and endpoint.startswith(prefix):
            return endpoint
    return None


def ngrok_error_from_bytes(data: bytes) -> str | None:
    text = data.decode("utf-8", errors="replace")
    if "ERR_NGROK_" not in text:
        return None
    first_line = next((line.strip() for line in text.splitlines() if line.strip()), "")
    code = next((part for part in text.split() if part.startswith("ERR_NGROK_")), "")
    return " — ".join(part for part in (code, first_line) if part)


def tunnel_error(endpoint: str, timeout: float = 1.5) -> str | None:
    parsed = urlsplit(endpoint)
    if parsed.scheme != "tcp" or not parsed.hostname or parsed.port is None:
        return None
    try:
        with socket.create_connection((parsed.hostname, parsed.port), timeout=timeout) as connection:
            connection.settimeout(timeout)
            return ngrok_error_from_bytes(connection.recv(1024))
    except (OSError, TimeoutError):
        return None


def main() -> int:
    if len(sys.argv) not in (3, 4):
        print("usage: ngrok_endpoint.py LOG_FILE SCHEME [--check]", file=sys.stderr)
        return 2
    try:
        lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    except OSError:
        lines = []
    endpoint = endpoint_from_lines(lines, sys.argv[2])
    if endpoint:
        if len(sys.argv) == 4 and sys.argv[3] == "--check":
            error = tunnel_error(endpoint)
            if error:
                print(error)
        else:
            print(endpoint)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
