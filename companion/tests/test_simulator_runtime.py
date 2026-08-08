import importlib.util
import signal
import subprocess
from pathlib import Path
from unittest.mock import Mock, call, patch


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


def test_detects_exact_booted_ios_device() -> None:
    assert RUNTIME.device_is_booted(DEVICES, "booted") is True
    assert RUNTIME.device_is_booted(DEVICES, "shutdown") is False
    assert RUNTIME.device_is_booted(DEVICES, "tv") is False


def test_ready_simulator_is_reused_without_booting() -> None:
    with patch.object(RUNTIME, "device_is_responsive", return_value=True), patch.object(
        RUNTIME.subprocess, "run"
    ) as run:
        RUNTIME.ensure_device_booted("booted", state="Booted")

    run.assert_not_called()


def test_stuck_boot_is_shutdown_and_retried() -> None:
    with patch.object(
        RUNTIME,
        "run",
        side_effect=[subprocess.TimeoutExpired("bootstatus", 60), None],
    ) as wait_for_boot, patch.object(
        RUNTIME, "device_is_responsive", return_value=True
    ), patch.object(RUNTIME.subprocess, "run", return_value=Mock(returncode=0)) as run:
        RUNTIME.ensure_device_booted("stuck", state="Shutdown")

    assert wait_for_boot.call_count == 2
    assert call(
        ["xcrun", "simctl", "shutdown", "stuck"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=20,
    ) in run.call_args_list


def test_device_listing_restarts_wedged_coresimulator_once() -> None:
    listing = Mock(returncode=0, stdout='{"devices": {}}', stderr="")
    with patch.object(
        RUNTIME,
        "run_captured",
        side_effect=[subprocess.TimeoutExpired("simctl list", 20), listing],
    ), patch.object(RUNTIME, "restart_coresimulator_service") as restart:
        assert RUNTIME.list_available_devices() == {"devices": {}}

    restart.assert_called_once_with()


def test_coresimulator_restart_targets_user_launchd_domain() -> None:
    with patch.object(RUNTIME.os, "getuid", return_value=501), patch.object(
        RUNTIME, "run_quiet_bounded", return_value=0
    ) as run, patch.object(
        RUNTIME, "registered_simdevice_services", return_value=[]
    ), patch.object(RUNTIME.time, "sleep"):
        assert RUNTIME.restart_coresimulator_service() is True

    run.assert_called_once_with(
        [
            "launchctl",
            "kickstart",
            "-k",
            "user/501/com.apple.CoreSimulator.CoreSimulatorService",
        ],
        timeout=10,
    )


def test_coresimulator_restart_reports_unstoppable_simdevice() -> None:
    label = "com.apple.CoreSimulator.SimDevice.DEAD-BEEF"
    with patch.object(RUNTIME.os, "getuid", return_value=501), patch.object(
        RUNTIME, "registered_simdevice_services", return_value=[label]
    ), patch.object(
        RUNTIME, "run_quiet_bounded", side_effect=[-signal.SIGKILL, 0]
    ), patch.object(RUNTIME.time, "sleep"):
        assert RUNTIME.restart_coresimulator_service() is False
