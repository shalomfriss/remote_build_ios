import importlib.util
from pathlib import Path
from unittest.mock import patch

import pytest


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "phone_endpoint.py"
SPEC = importlib.util.spec_from_file_location("phone_endpoint", MODULE_PATH)
assert SPEC and SPEC.loader
ENDPOINT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ENDPOINT)


def test_rejects_loopback_and_invalid_addresses() -> None:
    assert ENDPOINT.usable_ipv4("127.0.0.1") is None
    assert ENDPOINT.usable_ipv4("not-an-address") is None
    assert ENDPOINT.usable_ipv4("192.168.1.8") == "192.168.1.8"


def test_explicit_phone_host_takes_precedence() -> None:
    with patch.object(ENDPOINT, "route_address") as route:
        assert ENDPOINT.phone_host("10.0.0.9") == "10.0.0.9"
        route.assert_not_called()


def test_falls_back_from_route_to_interface() -> None:
    with (
        patch.object(ENDPOINT, "route_address", return_value=None),
        patch.object(ENDPOINT, "interface_address", return_value="192.168.1.9"),
    ):
        assert ENDPOINT.phone_host() == "192.168.1.9"


def test_missing_phone_address_has_actionable_error() -> None:
    with (
        patch.object(ENDPOINT, "route_address", return_value=None),
        patch.object(ENDPOINT, "interface_address", return_value=None),
        pytest.raises(RuntimeError, match="--ngrok"),
    ):
        ENDPOINT.phone_host()
