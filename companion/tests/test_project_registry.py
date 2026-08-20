import importlib.util
import json
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "project_registry.py"
SPEC = importlib.util.spec_from_file_location("project_registry_test", MODULE_PATH)
assert SPEC and SPEC.loader
REGISTRY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REGISTRY)


def test_registers_and_renames_existing_project(tmp_path: Path) -> None:
    root = tmp_path / "registry"
    project = tmp_path / "existing"
    project.mkdir()
    env = {"GROK_PROJECTS_ROOT": str(root)}

    REGISTRY.register_project(project, "First Name", env)
    REGISTRY.register_project(project, "Project From CLI", env)

    payload = json.loads((root / ".grok-build-projects.json").read_text())
    assert len(payload["projects"]) == 1
    assert payload["projects"][0]["name"] == "Project From CLI"
    assert REGISTRY.registered_projects(env)[0]["path"] == str(project.resolve())


def test_project_session_ids_resolve_back_to_registry_entry(tmp_path: Path) -> None:
    root = tmp_path / "registry"
    project = tmp_path / "existing"
    project.mkdir()
    env = {"GROK_PROJECTS_ROOT": str(root)}
    REGISTRY.register_project(project, "Existing App", env)

    session_id = REGISTRY.session_id_for_project(project)

    assert session_id.startswith("grok-project:")
    assert REGISTRY.project_for_session_id(session_id, env)["name"] == "Existing App"


def test_latest_registered_project_returns_last_added_project(tmp_path: Path) -> None:
    root = tmp_path / "registry"
    first = tmp_path / "first"
    second = tmp_path / "second"
    first.mkdir()
    second.mkdir()
    env = {"GROK_PROJECTS_ROOT": str(root)}

    REGISTRY.register_project(first, "First", env)
    REGISTRY.register_project(second, "Second", env)

    latest = REGISTRY.latest_registered_project(env)
    assert latest is not None
    assert latest["name"] == "Second"
    assert latest["path"] == str(second.resolve())


def test_discovers_unregistered_xcode_projects_from_projects_root(tmp_path: Path) -> None:
    project = tmp_path / "unregistered-app"
    project.mkdir()
    (project / "UnregisteredApp.xcodeproj").mkdir()
    env = {"GROK_PROJECTS_ROOT": str(tmp_path)}

    projects = REGISTRY.registered_projects(env)

    assert len(projects) == 1
    assert projects[0]["path"] == str(project.resolve())
    assert projects[0]["name"] == "UnregisteredApp"


def test_discovered_project_uses_metadata_name(tmp_path: Path) -> None:
    project = tmp_path / "generated-folder-name"
    project.mkdir()
    (project / ".grok-build-project.json").write_text('{"name":"Readable Name"}')
    env = {"GROK_PROJECTS_ROOT": str(tmp_path)}

    assert REGISTRY.registered_projects(env)[0]["name"] == "Readable Name"
