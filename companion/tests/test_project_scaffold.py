import importlib.util
import json
import sys
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "project_scaffold.py"
sys.path.insert(0, str(MODULE_PATH.parent))
SPEC = importlib.util.spec_from_file_location("project_scaffold", MODULE_PATH)
assert SPEC and SPEC.loader
PROJECT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROJECT)


def test_default_projects_root_is_dot_projects() -> None:
    assert PROJECT.projects_root({}) == Path.home() / ".projects"


def test_projects_root_is_configurable(tmp_path: Path) -> None:
    custom = tmp_path / "custom"
    assert PROJECT.projects_root({"GROK_PROJECTS_ROOT": str(custom)}) == custom


def test_creates_runnable_xcode_project_shape(tmp_path: Path) -> None:
    project = PROJECT.create_project(
        "My New App",
        {"GROK_PROJECTS_ROOT": str(tmp_path)},
    )
    assert project.parent == tmp_path
    assert project.name.startswith("my-new-app-")
    assert (project / "MyNewApp.xcodeproj/project.pbxproj").is_file()
    assert (project / "MyNewApp/MyNewApp.swift").is_file()
    assert (project / "MyNewApp/ContentView.swift").is_file()
    metadata = json.loads((project / ".grok-build-project.json").read_text())
    assert metadata["name"] == "My New App"
    registry = json.loads((tmp_path / ".grok-build-projects.json").read_text())
    assert registry["projects"][0]["name"] == "My New App"
    assert registry["projects"][0]["path"] == str(project)


def test_target_name_is_a_valid_identifier() -> None:
    assert PROJECT._target_name("123 photo journal") == "App123PhotoJournal"
    assert PROJECT._target_name("***") == "IOSApp"
