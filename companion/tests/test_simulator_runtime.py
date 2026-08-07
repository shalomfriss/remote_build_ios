import importlib.util
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "simulator_runtime.py"
SPEC = importlib.util.spec_from_file_location("simulator_runtime", MODULE_PATH)
assert SPEC and SPEC.loader
RUNTIME = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNTIME)


DEVICES = {
    "devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
            {"name": "iPhone 17 Pro", "udid": "booted", "state": "Booted", "isAvailable": True},
            {"name": "iPhone Air", "udid": "shutdown", "state": "Shutdown", "isAvailable": True},
        ],
        "com.apple.CoreSimulator.SimRuntime.tvOS-27-0": [
            {"name": "Apple TV", "udid": "tv", "state": "Booted", "isAvailable": True},
        ],
    }
}


def test_prefers_booted_ios_device() -> None:
    assert RUNTIME.select_device(DEVICES) == {"name": "iPhone 17 Pro", "udid": "booted"}


def test_resolves_preferred_name_or_udid() -> None:
    assert RUNTIME.select_device(DEVICES, "iPhone Air") == {"name": "iPhone Air", "udid": "shutdown"}
    assert RUNTIME.select_device(DEVICES, "missing") is None


def test_excludes_controller_simulator_for_project_app() -> None:
    assert RUNTIME.select_device(DEVICES, excluded_udids={"booted"}) == {
        "name": "iPhone Air",
        "udid": "shutdown",
    }
