import importlib.util
import json
from pathlib import Path
from unittest.mock import patch


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "companion_ext.py"
SPEC = importlib.util.spec_from_file_location("companion_ext", MODULE_PATH)
assert SPEC and SPEC.loader
EXT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXT)


def test_simulator_info_returns_runtime_url() -> None:
    request = {
        "jsonrpc": "2.0",
        "id": 7,
        "method": EXT.SIMULATOR_INFO_METHOD,
        "params": {},
    }
    with patch.dict("os.environ", {"GROK_SIMULATOR_URL": "https://simulator.example"}):
        response = EXT.handle_companion_rpc(request, Path("."))
    assert response is not None
    assert json.loads(response) == {
        "jsonrpc": "2.0",
        "id": 7,
        "result": {"url": "https://simulator.example"},
    }
