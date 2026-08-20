#!/usr/bin/env python3
# Copyright (c) 2026 Pedro Shakour
# SPDX-License-Identifier: Apache-2.0
"""Persist projects that should appear in the phone's Resume Projects menu."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Mapping


REGISTRY_FILENAME = ".grok-build-projects.json"
SESSION_PREFIX = "grok-project:"


def projects_root(env: Mapping[str, str] = os.environ) -> Path:
    configured = env.get("GROK_PROJECTS_ROOT", "").strip()
    return Path(configured).expanduser() if configured else Path.home() / ".projects"


def registry_path(env: Mapping[str, str] = os.environ) -> Path:
    return projects_root(env) / REGISTRY_FILENAME


def _read_registry(env: Mapping[str, str] = os.environ) -> list[dict[str, str]]:
    path = registry_path(env)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    entries = payload.get("projects") if isinstance(payload, dict) else None
    if not isinstance(entries, list):
        return []
    return [entry for entry in entries if isinstance(entry, dict)]


def registered_projects(env: Mapping[str, str] = os.environ) -> list[dict[str, str]]:
    """Return the project catalog, using the configured directory as truth.

    The registry only supplies names and recency metadata. A project does not
    need to have been explicitly registered to appear in Resume Project.
    """
    root = projects_root(env).expanduser()
    projects_by_path: dict[Path, dict[str, str]] = {}
    for entry in _read_registry(env):
        path = entry.get("path")
        name = entry.get("name")
        if not isinstance(path, str) or not isinstance(name, str):
            continue
        resolved = Path(path).expanduser()
        if not resolved.is_dir() or not name.strip():
            continue
        canonical = resolved.resolve()
        projects_by_path[canonical] = {
            "path": str(resolved.resolve()),
            "name": name.strip(),
            "addedAt": str(entry.get("addedAt") or ""),
        }

    try:
        children = list(root.iterdir())
    except OSError:
        children = []
    for child in children:
        if child.name.startswith(".") or not _is_project_directory(child):
            continue
        canonical = child.resolve()
        if canonical in projects_by_path:
            continue
        try:
            modified = datetime.fromtimestamp(
                child.stat().st_mtime,
                timezone.utc,
            ).isoformat()
        except OSError:
            modified = ""
        projects_by_path[canonical] = {
            "path": str(canonical),
            "name": default_project_name(canonical),
            "addedAt": modified,
        }

    return sorted(
        projects_by_path.values(),
        key=lambda project: (project["addedAt"], project["path"]),
    )


def latest_registered_project(
    env: Mapping[str, str] = os.environ,
) -> dict[str, str] | None:
    """Return the project most recently added through Grok Build."""
    projects = registered_projects(env)
    return projects[-1] if projects else None


def default_project_name(path: Path) -> str:
    metadata = path / ".grok-build-project.json"
    try:
        value = json.loads(metadata.read_text(encoding="utf-8")).get("name")
        if isinstance(value, str) and value.strip():
            return value.strip()
    except (OSError, json.JSONDecodeError, AttributeError):
        pass
    xcode_projects = sorted(path.glob("*.xcodeproj"))
    if xcode_projects:
        return xcode_projects[0].stem
    return path.name


def _is_project_directory(path: Path) -> bool:
    if not path.is_dir():
        return False
    if (path / ".grok-build-project.json").is_file():
        return True
    return any(path.glob("*.xcodeproj")) or any(path.glob("*.xcworkspace"))


def register_project(
    path: str | Path,
    name: str | None = None,
    env: Mapping[str, str] = os.environ,
) -> dict[str, str]:
    project_path = Path(path).expanduser().resolve()
    if not project_path.is_dir():
        raise ValueError(f"Project directory does not exist: {project_path}")
    display_name = (name or "").strip() or default_project_name(project_path)
    entry = {
        "path": str(project_path),
        "name": display_name,
        "addedAt": datetime.now(timezone.utc).isoformat(),
    }
    entries = [
        existing for existing in _read_registry(env)
        if Path(str(existing.get("path", ""))).expanduser().resolve() != project_path
    ]
    entries.append(entry)
    destination = registry_path(env)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    temporary.write_text(
        json.dumps({"projects": entries}, indent=2) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, destination)
    return entry


def session_id_for_project(path: str | Path) -> str:
    resolved = str(Path(path).expanduser().resolve()).encode("utf-8")
    return SESSION_PREFIX + hashlib.sha256(resolved).hexdigest()[:20]


def project_for_session_id(
    session_id: str,
    env: Mapping[str, str] = os.environ,
) -> dict[str, str] | None:
    if not session_id.startswith(SESSION_PREFIX):
        return None
    return next(
        (
            project for project in registered_projects(env)
            if session_id_for_project(project["path"]) == session_id
        ),
        None,
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Add an existing project to Grok Build's Resume Projects menu."
    )
    parser.add_argument("path", help="Path to the existing project directory")
    parser.add_argument("--name", help="Display name in Resume Projects")
    parser.add_argument(
        "--projects-root",
        help="Registry root (defaults to GROK_PROJECTS_ROOT or ~/.projects)",
    )
    args = parser.parse_args(argv)
    env: dict[str, str] = dict(os.environ)
    if args.projects_root:
        env["GROK_PROJECTS_ROOT"] = args.projects_root
    try:
        entry = register_project(args.path, args.name, env)
    except ValueError as error:
        parser.error(str(error))
    print(f'Added "{entry["name"]}" ({entry["path"]})')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
