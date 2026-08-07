#!/usr/bin/env python3
# Copyright (c) 2026 Pedro Shakour
# SPDX-License-Identifier: Apache-2.0
"""Build and launch the workspace's iOS app after a completed ACP turn."""

from __future__ import annotations

import asyncio
import argparse
import json
import os
import plistlib
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from project_registry import latest_registered_project, registered_projects


IOS_POLICY_MARKER = "[grok-build-ios-target]"
IOS_BUILD_POLICY = (
    f"{IOS_POLICY_MARKER} Build only an iOS app for this request. Work in the existing "
    "Xcode project or create one when needed. Use native iOS technologies, keep the "
    "project buildable for an iOS Simulator, and finish only after the implementation "
    "is complete. The companion will compile, install, launch, and serve the app."
)


@dataclass(frozen=True)
class BuildTarget:
    container: Path
    container_flag: str
    scheme: str


def log(message: str) -> None:
    print(f"[ios-build] {message}", file=sys.stderr, flush=True)


def ios_projects_enabled(env: Mapping[str, str] = os.environ) -> bool:
    value = env.get("GROK_IOS_PROJECTS", "").strip().lower()
    return value in {"1", "true", "yes"}


def ios_build_enabled(env: Mapping[str, str] = os.environ) -> bool:
    value = env.get("GROK_AUTO_BUILD_IOS", "").strip().lower()
    return (
        ios_projects_enabled(env)
        and value in {"1", "true", "yes"}
        and bool(env.get("GROK_SIMULATOR_UDID"))
    )


def add_ios_policy(message: dict[str, Any]) -> dict[str, Any]:
    """Append the phone's iOS product contract to an ACP session prompt."""
    if message.get("method") != "session/prompt":
        return message
    params = message.get("params")
    if not isinstance(params, dict):
        return message
    prompt = params.get("prompt")
    if not isinstance(prompt, list):
        return message
    if any(
        isinstance(item, dict) and IOS_POLICY_MARKER in str(item.get("text", ""))
        for item in prompt
    ):
        return message
    prompt.append({"type": "text", "text": IOS_BUILD_POLICY})
    return message


def is_successful_turn(line: bytes) -> bool:
    try:
        message = json.loads(line.decode("utf-8", errors="replace").strip().replace("\\/", "/"))
    except (json.JSONDecodeError, AttributeError):
        return False
    result = message.get("result")
    if not isinstance(result, dict):
        return False
    stop_reason = str(result.get("stopReason") or result.get("stop_reason") or "").lower()
    return stop_reason == "end_turn"


def _ignored(path: Path) -> bool:
    ignored = {".git", "DerivedData", "Pods", "Carthage", "node_modules", "vendor"}
    return any(part in ignored or part.endswith(".xcodeproj") for part in path.parts[:-1])


def _is_valid_xcode_container(path: Path) -> bool:
    if path.suffix == ".xcodeproj":
        return (path / "project.pbxproj").is_file()
    if path.suffix == ".xcworkspace":
        return (path / "contents.xcworkspacedata").is_file()
    return False


def find_xcode_container(workspace: Path, env: Mapping[str, str] = os.environ) -> tuple[Path, str]:
    explicit_workspace = env.get("GROK_IOS_WORKSPACE", "").strip()
    explicit_project = env.get("GROK_IOS_PROJECT", "").strip()
    if explicit_workspace:
        path = Path(explicit_workspace).expanduser()
        path = path if path.is_absolute() else workspace / path
        if not _is_valid_xcode_container(path):
            raise RuntimeError(f"Configured Xcode workspace does not exist: {path}")
        return path.resolve(), "-workspace"
    if explicit_project:
        path = Path(explicit_project).expanduser()
        path = path if path.is_absolute() else workspace / path
        if not _is_valid_xcode_container(path):
            raise RuntimeError(f"Configured Xcode project does not exist: {path}")
        return path.resolve(), "-project"

    workspaces = sorted(
        (
            path for path in workspace.rglob("*.xcworkspace")
            if not _ignored(path) and _is_valid_xcode_container(path)
        ),
        key=lambda path: (len(path.relative_to(workspace).parts), str(path)),
    )
    if workspaces:
        return workspaces[0], "-workspace"
    projects = sorted(
        (
            path for path in workspace.rglob("*.xcodeproj")
            if not _ignored(path) and _is_valid_xcode_container(path)
        ),
        key=lambda path: (len(path.relative_to(workspace).parts), str(path)),
    )
    if projects:
        return projects[0], "-project"
    raise RuntimeError("No iOS Xcode workspace or project was found in the agent workspace")


def resolve_build_workspace(
    workspace: Path,
    env: Mapping[str, str] = os.environ,
) -> Path:
    """Recover from an ACP session whose temporary workspace became stale."""
    requested = workspace.expanduser().resolve()
    try:
        find_xcode_container(requested, env)
        return requested
    except RuntimeError as requested_error:
        for project in reversed(registered_projects(env)):
            candidate = Path(project["path"]).expanduser().resolve()
            try:
                find_xcode_container(candidate, env)
            except RuntimeError:
                continue
            log(f"workspace {requested} is not runnable; using registered project {candidate}")
            return candidate
        raise requested_error


def find_scheme(
    container: Path,
    container_flag: str,
    env: Mapping[str, str] = os.environ,
) -> str:
    explicit = env.get("GROK_IOS_SCHEME", "").strip()
    if explicit:
        return explicit
    result = subprocess.run(
        ["xcodebuild", "-list", "-json", container_flag, str(container)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(_command_error("Could not inspect Xcode schemes", result))
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError("xcodebuild returned invalid scheme metadata") from error
    section = payload.get("workspace") if container_flag == "-workspace" else payload.get("project")
    schemes = section.get("schemes", []) if isinstance(section, dict) else []
    schemes = [str(scheme) for scheme in schemes if str(scheme).strip()]
    if not schemes:
        raise RuntimeError(f"No shared Xcode schemes were found in {container.name}")
    preferred = next((scheme for scheme in schemes if scheme == container.stem), None)
    return preferred or schemes[0]


def discover_build_target(
    workspace: Path,
    env: Mapping[str, str] = os.environ,
) -> BuildTarget:
    container, flag = find_xcode_container(workspace.resolve(), env)
    return BuildTarget(container=container, container_flag=flag, scheme=find_scheme(container, flag, env))


def _command_error(prefix: str, result: subprocess.CompletedProcess[str]) -> str:
    output = (result.stderr or result.stdout or "").strip()
    tail = "\n".join(output.splitlines()[-25:])
    return f"{prefix} (exit {result.returncode})" + (f":\n{tail}" if tail else "")


def _built_apps(derived_data: Path) -> list[Path]:
    products = derived_data / "Build" / "Products" / "Debug-iphonesimulator"
    if not products.is_dir():
        return []
    apps: list[Path] = []
    for app in products.rglob("*.app"):
        relative_parts = app.relative_to(products).parts
        if any(part.endswith(".app") for part in relative_parts[:-1]):
            continue
        info = app / "Info.plist"
        if not info.is_file():
            continue
        try:
            with info.open("rb") as handle:
                plist = plistlib.load(handle)
        except (OSError, plistlib.InvalidFileException):
            continue
        if plist.get("CFBundlePackageType") == "APPL" and not app.name.endswith("Tests.app"):
            apps.append(app)
    return apps


def _bundle_id(app: Path) -> str:
    try:
        with (app / "Info.plist").open("rb") as handle:
            value = plistlib.load(handle).get("CFBundleIdentifier")
    except (OSError, plistlib.InvalidFileException) as error:
        raise RuntimeError(f"Could not read {app.name}/Info.plist") from error
    if not isinstance(value, str) or not value:
        raise RuntimeError(f"Built app {app.name} has no bundle identifier")
    return value


def build_and_launch(
    workspace: Path,
    udid: str,
    derived_data: Path,
    env: Mapping[str, str] = os.environ,
) -> dict[str, str]:
    workspace = resolve_build_workspace(workspace, env)
    target = discover_build_target(workspace, env)
    derived_data.mkdir(parents=True, exist_ok=True)
    command = [
        "xcodebuild",
        "build",
        target.container_flag,
        str(target.container),
        "-scheme",
        target.scheme,
        "-configuration",
        "Debug",
        "-destination",
        f"platform=iOS Simulator,id={udid}",
        "-derivedDataPath",
        str(derived_data),
        "CODE_SIGNING_ALLOWED=NO",
        "-quiet",
    ]
    log(f"building {target.scheme} from {target.container}")
    result = subprocess.run(command, cwd=workspace, check=False, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(_command_error("iOS Simulator build failed", result))

    apps = _built_apps(derived_data)
    if not apps:
        raise RuntimeError("The iOS build succeeded but produced no runnable .app")
    app = max(apps, key=lambda path: path.stat().st_mtime)
    bundle_id = _bundle_id(app)
    install = subprocess.run(
        ["xcrun", "simctl", "install", udid, str(app)],
        check=False,
        capture_output=True,
        text=True,
    )
    if install.returncode != 0:
        raise RuntimeError(_command_error("Could not install the iOS app", install))
    subprocess.run(
        ["xcrun", "simctl", "terminate", udid, bundle_id],
        check=False,
        capture_output=True,
        text=True,
    )
    launch = subprocess.run(
        ["xcrun", "simctl", "launch", udid, bundle_id],
        check=False,
        capture_output=True,
        text=True,
    )
    if launch.returncode != 0:
        raise RuntimeError(_command_error("Could not launch the iOS app", launch))
    log(f"launched {bundle_id} on {udid}")
    return {
        "app": app.name,
        "bundleId": bundle_id,
        "scheme": target.scheme,
        "project": str(target.container),
    }


def write_build_state(state_file: Path, value: dict[str, Any]) -> None:
    state_file.parent.mkdir(parents=True, exist_ok=True)
    temporary = state_file.with_suffix(state_file.suffix + ".tmp")
    temporary.write_text(json.dumps(value, separators=(",", ":")), encoding="utf-8")
    temporary.replace(state_file)


def launch_latest_registered_project(
    env: Mapping[str, str] = os.environ,
) -> dict[str, Any]:
    """Build and launch the newest Grok Build project when the companion starts."""
    project = latest_registered_project(env)
    state_dir = Path(env.get("GROK_COMPANION_STATE_DIR", str(Path.home() / ".grok")))
    state_file = Path(
        env.get("GROK_SIMULATOR_STATE_FILE", str(state_dir / "simulator-build.json"))
    )
    if project is None:
        result: dict[str, Any] = {"status": "idle", "generation": 0}
        write_build_state(state_file, result)
        return result

    udid = env.get("GROK_SIMULATOR_UDID", "").strip()
    if not udid:
        result = {
            "status": "failed",
            "generation": 0,
            "error": "No project simulator is configured.",
        }
        write_build_state(state_file, result)
        return result

    derived_data = Path(
        env.get("GROK_IOS_DERIVED_DATA", str(state_dir / "GeneratedAppDerivedData"))
    )
    write_build_state(state_file, {
        "status": "building",
        "generation": 0,
        "projectName": project["name"],
    })
    try:
        build = build_and_launch(Path(project["path"]), udid, derived_data, env)
    except Exception as error:
        log(str(error))
        result = {
            "status": "failed",
            "generation": 0,
            "projectName": project["name"],
            "error": str(error),
        }
    else:
        result = {
            "status": "ready",
            "generation": 0,
            "projectName": project["name"],
            **build,
        }
    write_build_state(state_file, result)
    return result


class IOSBuildPipeline:
    """Coalesce completed turns into serialized simulator builds."""

    def __init__(self, workspace: Path, env: Mapping[str, str] = os.environ) -> None:
        self.workspace = workspace.resolve()
        self.env = dict(env)
        self.udid = self.env.get("GROK_SIMULATOR_UDID", "")
        state_dir = Path(self.env.get("GROK_COMPANION_STATE_DIR", str(Path.home() / ".grok")))
        self.derived_data = Path(
            self.env.get("GROK_IOS_DERIVED_DATA", str(state_dir / "GeneratedAppDerivedData"))
        )
        self.state_file = Path(
            self.env.get("GROK_SIMULATOR_STATE_FILE", str(state_dir / "simulator-build.json"))
        )
        self.enabled = ios_build_enabled(self.env)
        self._requested = 0
        self._completed = 0
        self._worker: asyncio.Task[None] | None = None

    def observe_agent_line(self, line: bytes) -> None:
        if self.enabled and is_successful_turn(line):
            self.request_build()

    def set_workspace(self, workspace: Path) -> None:
        self.workspace = workspace.resolve()

    def request_build(self) -> None:
        self._requested += 1
        self._write_state({"status": "queued", "generation": self._requested})
        if self._worker is None or self._worker.done():
            self._worker = asyncio.create_task(self._run())

    async def _run(self) -> None:
        while self._completed < self._requested:
            generation = self._requested
            self._write_state({"status": "building", "generation": generation})
            try:
                result = await asyncio.to_thread(
                    build_and_launch,
                    self.workspace,
                    self.udid,
                    self.derived_data,
                    self.env,
                )
            except Exception as error:
                log(str(error))
                self._write_state({
                    "status": "failed",
                    "generation": generation,
                    "error": str(error),
                })
            else:
                self._write_state({"status": "ready", "generation": generation, **result})
            self._completed = generation

    def _write_state(self, value: dict[str, Any]) -> None:
        try:
            write_build_state(self.state_file, value)
        except OSError as error:
            log(f"could not write simulator state: {error}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--launch-latest",
        action="store_true",
        help="Build and launch the most recently registered Grok Build project",
    )
    args = parser.parse_args(argv)
    if not args.launch_latest:
        parser.error("--launch-latest is required")
    print(json.dumps(launch_latest_registered_project()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
