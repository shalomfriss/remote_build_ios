import importlib.util
import json
from pathlib import Path
from unittest.mock import patch


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "acp_tcp_bridge.py"
SPEC = importlib.util.spec_from_file_location("acp_tcp_bridge", MODULE_PATH)
assert SPEC and SPEC.loader
BRIDGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BRIDGE)


def test_codex_command_uses_maintained_acp_adapter() -> None:
    def which(name: str) -> str | None:
        return "/bin/npx" if name == "npx" else None

    with patch.object(BRIDGE.shutil, "which", side_effect=which):
        command = BRIDGE.find_agent("codex", model="gpt-test")
    assert command is not None
    assert command[0] == "/usr/bin/env"
    assert json.loads(command[1].removeprefix("CODEX_CONFIG=")) == {"model": "gpt-test"}
    assert command[-3:] == ["/bin/npx", "--yes", "@agentclientprotocol/codex-acp"]


def test_codex_command_falls_back_to_installed_binary() -> None:
    def which(name: str) -> str | None:
        return "/bin/codex-acp" if name == "codex-acp" else None

    with patch.object(BRIDGE.shutil, "which", side_effect=which):
        command = BRIDGE.find_agent("codex")
    assert command == ["/bin/codex-acp"]


def test_claude_command_falls_back_to_npx() -> None:
    def which(name: str) -> str | None:
        return "/bin/npx" if name == "npx" else None

    with patch.object(BRIDGE.shutil, "which", side_effect=which):
        command = BRIDGE.find_agent("claude")
    assert command == ["/bin/npx", "--yes", "@agentclientprotocol/claude-agent-acp"]


def test_local_command_is_pinned_to_ollama_provider() -> None:
    with patch.object(BRIDGE.shutil, "which", return_value="/bin/opencode"):
        command = BRIDGE.find_agent("local")
    assert command is not None
    assert command[0] == "/usr/bin/env"
    assert command[-2:] == ["/bin/opencode", "acp"]
    config = json.loads(command[1].removeprefix("OPENCODE_CONFIG_CONTENT="))
    assert config["model"] == "ollama/qwen3-coder:30b"
    assert config["provider"]["ollama"]["options"]["baseURL"] == "http://127.0.0.1:11434/v1"


def test_local_command_rejects_hosted_provider() -> None:
    with patch.object(BRIDGE.shutil, "which", return_value="/bin/opencode"):
        assert BRIDGE.find_agent("local", model="openai/gpt-test") is None


def test_custom_command_wins() -> None:
    assert BRIDGE.find_agent("codex", command="my-agent --stdio") == ["my-agent", "--stdio"]
