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
        "GROK_IOS_WORKSTREAMS": "1",
        "GROK_AUTO_BUILD_IOS": "1",
    })
    assert PIPELINE.ios_build_enabled({
        "GROK_IOS_WORKSTREAMS": "1",
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


def test_new_session_creates_and_selects_workstream_project(tmp_path: Path) -> None:
    pipeline = PIPELINE.IOSBuildPipeline(tmp_path, {})
    message = (json.dumps({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "session/new",
        "params": {"cwd": "."},
    }) + "\n").encode()
    with patch.dict("os.environ", {
        "GROK_IOS_WORKSTREAMS": "1",
        "GROK_PROJECTS_ROOT": str(tmp_path),
    }, clear=False):
        normalized = BRIDGE.normalize_acp_line(message, tmp_path, pipeline)
    cwd = Path(json.loads(normalized)["params"]["cwd"])
    assert cwd.parent == tmp_path
    assert (cwd / "WorkstreamApp.xcodeproj/project.pbxproj").is_file()
    assert pipeline.workspace == cwd
