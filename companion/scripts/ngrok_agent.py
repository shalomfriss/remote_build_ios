#!/usr/bin/env python3
# Copyright (c) 2026 Pedro Shakour
# SPDX-License-Identifier: Apache-2.0
"""Inspect and safely retire stale tunnels from a local ngrok Agent API."""

from __future__ import annotations

import argparse
from http.client import RemoteDisconnected
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlsplit
from urllib.request import Request, urlopen


DEFAULT_AGENT_URL = "http://127.0.0.1:4040"
LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1"}


def agent_request(agent_url: str, path: str, method: str = "GET") -> Any:
    request = Request(urljoin(agent_url.rstrip("/") + "/", path.lstrip("/")), method=method)
    with urlopen(request, timeout=1.5) as response:
        data = response.read()
    return json.loads(data) if data else None


def tunnels(agent_url: str) -> list[dict[str, Any]]:
    try:
        payload = agent_request(agent_url, "/api/tunnels")
    except (HTTPError, URLError, TimeoutError, json.JSONDecodeError):
        return []
    values = payload.get("tunnels", []) if isinstance(payload, dict) else []
    return [value for value in values if isinstance(value, dict)]


def target(tunnel: dict[str, Any]) -> tuple[str, int] | None:
    config = tunnel.get("config")
    address = config.get("addr") if isinstance(config, dict) else None
    if not isinstance(address, str) or not address:
        return None
    parsed = urlsplit(address if "://" in address else f"http://{address}")
    if not parsed.hostname or parsed.port is None:
        return None
    return parsed.hostname.lower(), parsed.port


def target_is_reachable(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, port), timeout=0.5):
            return True
    except OSError:
        return False


def local_agent_pid(agent_url: str) -> int | None:
    parsed = urlsplit(agent_url)
    if parsed.hostname not in LOOPBACK_HOSTS or parsed.port is None:
        return None
    try:
        result = subprocess.run(
            ["lsof", "-nP", "-t", f"-iTCP:{parsed.port}", "-sTCP:LISTEN"],
            check=False,
            capture_output=True,
            text=True,
            timeout=1,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    for line in result.stdout.splitlines():
        try:
            pid = int(line.strip())
            command = subprocess.run(
                ["ps", "-p", str(pid), "-o", "comm="],
                check=False,
                capture_output=True,
                text=True,
                timeout=1,
            ).stdout.strip()
        except (ValueError, OSError, subprocess.TimeoutExpired):
            continue
        if Path(command).name == "ngrok":
            return pid
    return None


def find_tunnel(
    agent_url: str,
    port: int,
    scheme: str,
    expected_url: str | None = None,
) -> str | None:
    for tunnel in tunnels(agent_url):
        public_url = tunnel.get("public_url")
        destination = target(tunnel)
        if (
            isinstance(public_url, str)
            and public_url.startswith(f"{scheme}://")
            and (expected_url is None or public_url == expected_url)
            and destination is not None
            and destination[0] in LOOPBACK_HOSTS
            and destination[1] == port
        ):
            return public_url
    return None


def prune_stale_tunnels(
    agent_url: str,
    scheme: str,
    expected_url: str | None = None,
) -> int:
    removed = 0
    local_tunnels = tunnels(agent_url)
    # With no explicit URL, only retire the sole endpoint owned by this local
    # command-line agent. Multiple endpoints may belong to unrelated services.
    if expected_url is None and len(local_tunnels) != 1:
        return 0
    dedicated_agent_pid = local_agent_pid(agent_url) if len(local_tunnels) == 1 else None
    for tunnel in local_tunnels:
        public_url = tunnel.get("public_url")
        uri = tunnel.get("uri")
        destination = target(tunnel)
        if (
            not isinstance(public_url, str)
            or not public_url.startswith(f"{scheme}://")
            or (expected_url is not None and public_url != expected_url)
            or not isinstance(uri, str)
            or destination is None
            or destination[0] not in LOOPBACK_HOSTS
            or target_is_reachable(*destination)
        ):
            continue
        try:
            agent_request(agent_url, uri, method="DELETE")
        except (RemoteDisconnected, ConnectionResetError):
            # A command-line ngrok agent may exit as soon as its only endpoint
            # is deleted, closing the Agent API response before it is flushed.
            pass
        except URLError as error:
            if not isinstance(error.reason, (RemoteDisconnected, ConnectionResetError)):
                continue
        except (TimeoutError, json.JSONDecodeError):
            continue
        print(
            f"agent-phone: stopped stale ngrok endpoint={public_url} "
            f"(dead target {destination[0]}:{destination[1]})",
            file=sys.stderr,
        )
        removed += 1
        if dedicated_agent_pid is not None:
            try:
                os.kill(dedicated_agent_pid, signal.SIGTERM)
            except OSError:
                pass
    return removed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--agent-url", default=DEFAULT_AGENT_URL)
    subparsers = parser.add_subparsers(dest="command", required=True)

    find_parser = subparsers.add_parser("find")
    find_parser.add_argument("--port", type=int, required=True)
    find_parser.add_argument("--scheme", default="https")
    find_parser.add_argument("--url")

    prune_parser = subparsers.add_parser("prune-stale")
    prune_parser.add_argument("--scheme", default="https")
    prune_parser.add_argument("--url")

    args = parser.parse_args()
    if args.command == "find":
        endpoint = find_tunnel(args.agent_url, args.port, args.scheme, args.url)
        if endpoint:
            print(endpoint)
        return 0
    prune_stale_tunnels(args.agent_url, args.scheme, args.url)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
