import importlib.util
import json
import sys
from pathlib import Path
from unittest.mock import Mock, patch


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
MODULE_PATH = SCRIPTS / "ios_build_pipeline.py"
SPEC = importlib.util.spec_from_file_location("ios_build_pipeline", MODULE_PATH)
assert SPEC and SPEC.loader
PIPELINE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PIPELINE
SPEC.loader.exec_module(PIPELINE)
import acp_tcp_bridge as BRIDGE
import companion_ext as COMPANION_EXT


def test_ios_build_requires_opt_in_and_simulator() -> None:
    assert not PIPELINE.ios_build_enabled({})
    assert not PIPELINE.ios_build_enabled({
        "GROK_IOS_PROJECTS": "1",
        "GROK_AUTO_BUILD_IOS": "1",
    })
    assert PIPELINE.ios_build_enabled({
        "GROK_IOS_PROJECTS": "1",
        "GROK_AUTO_BUILD_IOS": "1",
        "GROK_SIMULATOR_UDID": "device",
    })


def test_ensure_simulator_booted_waits_for_selected_device() -> None:
    listing = {
        "devices": {"iOS": [{
            "udid": "project-simulator",
            "state": "Shutdown",
        }]},
    }
    with patch.object(PIPELINE, "list_available_devices", return_value=listing), patch.object(
        PIPELINE, "ensure_device_booted"
    ) as ensure:
        PIPELINE.ensure_simulator_booted("project-simulator")

    ensure.assert_called_once_with("project-simulator", state="Shutdown")


def test_ensure_simulator_booted_does_not_reboot_running_device() -> None:
    listing = {
        "devices": {"iOS": [{
            "udid": "project-simulator",
            "state": "Booted",
        }]},
    }
    with patch.object(PIPELINE, "list_available_devices", return_value=listing) as devices, patch.object(
        PIPELINE, "ensure_device_booted"
    ) as ensure:
        PIPELINE.ensure_simulator_booted("project-simulator")

    devices.assert_called_once_with()
    ensure.assert_called_once_with("project-simulator", state="Booted")
def test_companion_startup_launches_latest_registered_project(tmp_path: Path) -> None:
    from project_registry import register_project

    projects_root = tmp_path / "projects"
    first = tmp_path / "first"
    latest = tmp_path / "latest"
    first.mkdir()
    latest.mkdir()
    env = {
        "GROK_PROJECTS_ROOT": str(projects_root),
        "GROK_COMPANION_STATE_DIR": str(tmp_path / "state"),
        "GROK_SIMULATOR_UDID": "project-simulator",
    }
    register_project(first, "First", env)
    register_project(latest, "Latest", env)

    build_result = {
        "app": "Latest.app",
        "bundleId": "app.example.latest",
        "scheme": "Latest",
        "project": str(latest / "Latest.xcodeproj"),
    }
    with patch.object(PIPELINE, "build_and_launch", return_value=build_result) as build:
        result = PIPELINE.launch_latest_registered_project(env)

    assert result["status"] == "ready"
    assert result["projectName"] == "Latest"
    assert build.call_args.args[0] == latest.resolve()
    assert build.call_args.args[1] == "project-simulator"
    state = json.loads((tmp_path / "state" / "simulator-build.json").read_text())
    assert state["bundleId"] == "app.example.latest"


def test_companion_startup_without_project_leaves_simulator_idle(tmp_path: Path) -> None:
    env = {
        "GROK_PROJECTS_ROOT": str(tmp_path / "projects"),
        "GROK_COMPANION_STATE_DIR": str(tmp_path / "state"),
        "GROK_SIMULATOR_UDID": "project-simulator",
    }

    result = PIPELINE.launch_latest_registered_project(env)

    assert result == {"status": "idle", "generation": 0}


def test_ios_policy_is_added_once() -> None:
    message = {
        "method": "session/prompt",
        "params": {"prompt": [{"type": "text", "text": "Build a timer"}]},
    }
    PIPELINE.add_ios_policy(message)
    PIPELINE.add_ios_policy(message)
    prompt = message["params"]["prompt"]
    assert len(prompt) == 2
    assert PIPELINE.IOS_POLICY_MARKER in prompt[-1]["text"]


def test_only_end_turn_triggers_build() -> None:
    completed = (json.dumps({"id": 4, "result": {"stopReason": "end_turn"}}) + "\n").encode()
    cancelled = json.dumps({"id": 4, "result": {"stopReason": "cancelled"}}).encode()
    assert PIPELINE.is_successful_turn(completed)
    assert not PIPELINE.is_successful_turn(cancelled)
    assert not PIPELINE.is_successful_turn(b"not json")


def test_simulator_run_rpc_queues_pipeline_without_agent_prompt() -> None:
    class Pipeline:
        enabled = True
        requests = 0

        def request_build(self) -> None:
            self.requests += 1

    pipeline = Pipeline()
    response = BRIDGE.handle_simulator_run_rpc({
        "jsonrpc": "2.0",
        "id": 12,
        "method": BRIDGE.SIMULATOR_RUN_METHOD,
        "params": {},
    }, pipeline)
    assert response is not None
    payload = json.loads(response)
    assert payload["result"]["status"] == "queued"
    assert pipeline.requests == 1


def test_simulator_run_rpc_reports_unconfigured_pipeline() -> None:
    response = BRIDGE.handle_simulator_run_rpc({
        "jsonrpc": "2.0",
        "id": 13,
        "method": BRIDGE.SIMULATOR_RUN_METHOD,
    }, None)
    assert response is not None
    assert json.loads(response)["error"]["code"] == -32000


def test_build_pipelines_use_project_scoped_state_and_derived_data(tmp_path: Path) -> None:
    first = tmp_path / "projects" / "first"
    second = tmp_path / "projects" / "second"
    first.mkdir(parents=True)
    second.mkdir(parents=True)
    env = {
        "GROK_IOS_DERIVED_DATA": str(tmp_path / "state" / "DerivedData"),
        "GROK_SIMULATOR_STATE_FILE": str(tmp_path / "state" / "simulator-build.json"),
    }

    first_pipeline = PIPELINE.IOSBuildPipeline(first, env)
    second_pipeline = PIPELINE.IOSBuildPipeline(second, env)

    assert first_pipeline.derived_data != second_pipeline.derived_data
    assert first_pipeline.state_file != second_pipeline.state_file
    assert first_pipeline.state_file.parent == second_pipeline.state_file.parent


def test_simulator_info_rpc_reads_current_project_pipeline(tmp_path: Path) -> None:
    workspace = tmp_path / "project"
    workspace.mkdir()
    pipeline = PIPELINE.IOSBuildPipeline(workspace, {
        "GROK_SIMULATOR_URL": "https://example.test",
        "GROK_SIMULATOR_STATE_FILE": str(tmp_path / "simulator-build.json"),
    })
    PIPELINE.write_build_state(pipeline.state_file, {"status": "building"})
    pipeline.output_file.write_text("Compile App.swift\nBUILD FAILED\n", encoding="utf-8")

    response = BRIDGE.handle_simulator_run_rpc({
        "jsonrpc": "2.0",
        "id": 15,
        "method": COMPANION_EXT.SIMULATOR_INFO_METHOD,
    }, pipeline)

    assert response is not None
    result = json.loads(response)["result"]
    assert result["status"] == "building"
    assert result["workspace"] == str(workspace)
    assert result["output"] == "Compile App.swift\nBUILD FAILED\n"


def test_streaming_command_forwards_command_and_every_output_line(tmp_path: Path) -> None:
    output: list[str] = []

    result = PIPELINE._run_streaming(
        [sys.executable, "-c", "print('first'); print('second')"],
        cwd=tmp_path,
        on_output=output.append,
    )

    assert result.returncode == 0
    assert output[0].startswith("$ ")
    assert output[1:] == ["first\n", "second\n"]
    assert result.stdout == "first\nsecond\n"


def test_discovers_generated_project_and_scheme(tmp_path: Path) -> None:
    project = tmp_path / "Example.xcodeproj"
    project.mkdir()
    (project / "project.pbxproj").touch()
    container, flag = PIPELINE.find_xcode_container(tmp_path, {})
    assert container == project
    assert flag == "-project"
    assert PIPELINE.find_scheme(project, flag, {"GROK_IOS_SCHEME": "Example"}) == "Example"


def test_stale_workspace_falls_back_to_latest_runnable_registered_project(
    tmp_path: Path,
) -> None:
    from project_registry import register_project

    projects_root = tmp_path / "projects"
    stale = tmp_path / "temporary-session"
    stale.mkdir()
    (stale / "Broken.xcodeproj").mkdir()

    runnable = projects_root / "fitness-app"
    xcode_project = runnable / "FitnessApp.xcodeproj"
    xcode_project.mkdir(parents=True)
    (xcode_project / "project.pbxproj").touch()
    env = {"GROK_PROJECTS_ROOT": str(projects_root)}
    register_project(runnable, "Fitness App", env)

    assert PIPELINE.resolve_build_workspace(stale, env) == runnable.resolve()


def test_new_session_creates_and_selects_project(tmp_path: Path) -> None:
    pipeline = PIPELINE.IOSBuildPipeline(tmp_path, {})
    message = (json.dumps({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "session/new",
        "params": {"cwd": ".", "projectName": "Trail Notes"},
    }) + "\n").encode()
    with patch.dict("os.environ", {
        "GROK_IOS_PROJECTS": "1",
        "GROK_PROJECTS_ROOT": str(tmp_path),
    }, clear=False):
        normalized = BRIDGE.normalize_acp_line(message, tmp_path, pipeline)
    cwd = Path(json.loads(normalized)["params"]["cwd"])
    assert cwd.parent == tmp_path
    assert cwd.name.startswith("trail-notes-")
    assert (cwd / "TrailNotes.xcodeproj/project.pbxproj").is_file()
    assert "projectName" not in json.loads(normalized)["params"]
    assert pipeline.workspace == cwd


def test_setup_session_uses_workspace_without_creating_project(tmp_path: Path) -> None:
    workspace = tmp_path / "companion-workspace"
    workspace.mkdir()
    pipeline = PIPELINE.IOSBuildPipeline(workspace, {})
    message = (json.dumps({
        "jsonrpc": "2.0",
        "id": 3,
        "method": "session/new",
        "params": {
            "cwd": str(workspace),
            "mcpServers": [],
            "setupOnly": True,
        },
    }) + "\n").encode()
    with patch.dict("os.environ", {
        "GROK_IOS_PROJECTS": "1",
        "GROK_PROJECTS_ROOT": str(tmp_path / "projects"),
    }, clear=False):
        normalized = BRIDGE.normalize_acp_line(message, workspace, pipeline)
    request = json.loads(normalized)
    assert request["params"]["cwd"] == str(workspace)
    assert "setupOnly" not in request["params"]
    assert not (tmp_path / "projects").exists()
    assert pipeline.workspace == workspace


def test_session_list_response_uses_project_metadata_name(tmp_path: Path) -> None:
    project = tmp_path / "trail-notes-20260802-abc123"
    project.mkdir()
    (project / ".grok-build-project.json").write_text('{"name":"Trail Notes"}')
    response = (json.dumps({
        "jsonrpc": "2.0",
        "id": 7,
        "result": {"sessions": [{
            "sessionId": "session-1",
            "cwd": str(project),
            "projectName": "Provider Generated Name",
        }]},
    }) + "\n").encode()
    with patch.dict("os.environ", {"GROK_PROJECTS_ROOT": str(tmp_path)}, clear=False):
        normalized = BRIDGE.enrich_session_list_response(response, {7})
    session = json.loads(normalized)["result"]["sessions"][0]
    assert session["projectName"] == "Trail Notes"
    assert session["sessionId"].startswith("grok-project:")


def test_session_list_response_adds_cli_registered_project(tmp_path: Path) -> None:
    project = tmp_path / "existing-project"
    project.mkdir()
    with patch.dict("os.environ", {"GROK_PROJECTS_ROOT": str(tmp_path)}, clear=False):
        from project_registry import register_project
        register_project(project, "CLI Project")
        response = (json.dumps({
            "jsonrpc": "2.0",
            "id": 9,
            "result": {"sessions": []},
        }) + "\n").encode()
        normalized = BRIDGE.enrich_session_list_response(response, {9})
    session = json.loads(normalized)["result"]["sessions"][0]
    assert session["projectName"] == "CLI Project"
    assert session["cwd"] == str(project)
    assert session["sessionId"].startswith("grok-project:")


def test_last_project_rpc_returns_most_recent_registered_project(tmp_path: Path) -> None:
    first = tmp_path / "first"
    second = tmp_path / "second"
    first.mkdir()
    second.mkdir()
    with patch.dict("os.environ", {"GROK_PROJECTS_ROOT": str(tmp_path)}, clear=False):
        from project_registry import register_project
        register_project(first, "First")
        register_project(second, "Second")
        response = COMPANION_EXT.handle_companion_rpc({
            "jsonrpc": "2.0",
            "id": 14,
            "method": COMPANION_EXT.LAST_PROJECT_METHOD,
            "params": {},
        }, tmp_path)
    assert response is not None
    result = json.loads(response)["result"]
    assert result["projectName"] == "Second"
    assert result["cwd"] == str(second)
    assert result["sessionId"].startswith("grok-project:")


def test_registered_project_load_opens_new_session_in_existing_directory(tmp_path: Path) -> None:
    project = tmp_path / "existing-project"
    project.mkdir()
    with patch.dict("os.environ", {
        "GROK_IOS_PROJECTS": "1",
        "GROK_PROJECTS_ROOT": str(tmp_path),
    }, clear=False):
        from project_registry import register_project, session_id_for_project
        register_project(project, "CLI Project")
        message = (json.dumps({
            "jsonrpc": "2.0",
            "id": 10,
            "method": "session/load",
            "params": {
                "sessionId": session_id_for_project(project),
                "cwd": str(project),
            },
        }) + "\n").encode()
        pipeline = PIPELINE.IOSBuildPipeline(tmp_path, {})
        normalized = BRIDGE.normalize_acp_line(message, tmp_path, pipeline)
    request = json.loads(normalized)
    assert request["method"] == "session/new"
    assert request["params"]["cwd"] == str(project)
    assert pipeline.workspace == project


def test_session_list_response_falls_back_to_xcode_project_name(tmp_path: Path) -> None:
    project = tmp_path / "existing-project"
    project.mkdir()
    (project / "ExistingProject.xcodeproj").mkdir()
    response = json.dumps({
        "jsonrpc": "2.0",
        "id": 8,
        "result": {"data": {"sessions": [{"sessionId": "session-2", "cwd": str(project)}]}},
    }).encode()
    with patch.dict("os.environ", {"GROK_PROJECTS_ROOT": str(tmp_path)}, clear=False):
        normalized = BRIDGE.enrich_session_list_response(response, {8})
    session = json.loads(normalized)["result"]["data"]["sessions"][0]
    assert session["projectName"] == "ExistingProject"
    assert session["sessionId"].startswith("grok-project:")


def test_resume_projects_excludes_sessions_outside_projects_root(tmp_path: Path) -> None:
    projects = tmp_path / "projects"
    project = projects / "fitness-app"
    unrelated = tmp_path / "other-workspace"
    project.mkdir(parents=True)
    (project / "Fitness.xcodeproj").mkdir()
    unrelated.mkdir()
    response = (json.dumps({
        "jsonrpc": "2.0",
        "id": 11,
        "result": {"sessions": [
            {"sessionId": "inside", "cwd": str(project)},
            {"sessionId": "outside", "cwd": str(unrelated)},
        ]},
    }) + "\n").encode()

    with patch.dict("os.environ", {"GROK_PROJECTS_ROOT": str(projects)}, clear=False):
        normalized = BRIDGE.enrich_session_list_response(response, {11})

    sessions = json.loads(normalized)["result"]["sessions"]
    assert len(sessions) == 1
    assert sessions[0]["cwd"] == str(project)
    assert sessions[0]["sessionId"].startswith("grok-project:")
