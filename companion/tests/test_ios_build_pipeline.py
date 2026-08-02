import importlib.util
import json
import sys
from pathlib import Path
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
MODULE_PATH = SCRIPTS / "ios_build_pipeline.py"
SPEC = importlib.util.spec_from_file_location("ios_build_pipeline", MODULE_PATH)
assert SPEC and SPEC.loader
PIPELINE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PIPELINE
SPEC.loader.exec_module(PIPELINE)
import acp_tcp_bridge as BRIDGE


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


def test_discovers_generated_project_and_scheme(tmp_path: Path) -> None:
    project = tmp_path / "Example.xcodeproj"
    project.mkdir()
    container, flag = PIPELINE.find_xcode_container(tmp_path, {})
    assert container == project
    assert flag == "-project"
    assert PIPELINE.find_scheme(project, flag, {"GROK_IOS_SCHEME": "Example"}) == "Example"


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
    normalized = BRIDGE.enrich_session_list_response(response, {7})
    session = json.loads(normalized)["result"]["sessions"][0]
    assert session["projectName"] == "Trail Notes"


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
    normalized = BRIDGE.enrich_session_list_response(response, {8})
    session = json.loads(normalized)["result"]["data"]["sessions"][0]
    assert session["projectName"] == "ExistingProject"
