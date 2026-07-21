#!/usr/bin/env python3
# Copyright (c) 2026 Pedro Shakour
# SPDX-License-Identifier: Apache-2.0
"""Extract a public endpoint from ngrok's JSON agent log."""

from __future__ import annotations

import json
import sys
from pathlib import Path


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


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: ngrok_endpoint.py LOG_FILE SCHEME", file=sys.stderr)
        return 2
    try:
        lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    except OSError:
        lines = []
    endpoint = endpoint_from_lines(lines, sys.argv[2])
    if endpoint:
        print(endpoint)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
