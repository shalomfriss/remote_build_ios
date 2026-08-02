import importlib.util
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "ngrok_endpoint.py"
SPEC = importlib.util.spec_from_file_location("ngrok_endpoint", MODULE_PATH)
assert SPEC and SPEC.loader
NGROK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NGROK)


def test_extracts_latest_endpoint_for_scheme() -> None:
    lines = [
        '{"msg":"started tunnel","url":"tcp://example.test:1234"}',
        '{"msg":"started tunnel","url":"https://example.ngrok.app"}',
    ]
    assert NGROK.endpoint_from_lines(lines, "tcp") == "tcp://example.test:1234"
    assert NGROK.endpoint_from_lines(lines, "https") == "https://example.ngrok.app"


def test_ignores_invalid_log_lines() -> None:
    assert NGROK.endpoint_from_lines(["not json", "{}"], "tcp") is None


def test_extracts_ngrok_error_banner() -> None:
    banner = (
        b"This ngrok account has reached its network bandwidth limit for the month.\r\n\r\n"
        b"ERR_NGROK_725\r\n"
    )
    error = NGROK.ngrok_error_from_bytes(banner)
    assert error is not None
    assert "ERR_NGROK_725" in error
    assert "bandwidth limit" in error


def test_ignores_regular_tunnel_bytes() -> None:
    assert NGROK.ngrok_error_from_bytes(b"regular TLS tunnel bytes") is None
