import importlib.util
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "workstream_project.py"
SPEC = importlib.util.spec_from_file_location("workstream_project", MODULE_PATH)
assert SPEC and SPEC.loader
PROJECT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROJECT)


def test_default_projects_root_is_dot_projects() -> None:
    assert PROJECT.projects_root({}) == Path.home() / ".projects"


def test_projects_root_is_configurable(tmp_path: Path) -> None:
    custom = tmp_path / "custom"
    assert PROJECT.projects_root({"GROK_PROJECTS_ROOT": str(custom)}) == custom


def test_creates_runnable_xcode_project_shape(tmp_path: Path) -> None:
    workstream = PROJECT.create_workstream_project(
        "My New App",
        {"GROK_PROJECTS_ROOT": str(tmp_path)},
    )
    assert workstream.parent == tmp_path
    assert workstream.name.startswith("my-new-app-")
    assert (workstream / "WorkstreamApp.xcodeproj/project.pbxproj").is_file()
    assert (workstream / "WorkstreamApp/WorkstreamApp.swift").is_file()
    assert (workstream / "WorkstreamApp/ContentView.swift").is_file()
