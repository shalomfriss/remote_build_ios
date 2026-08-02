# grok-ios

iOS ACP client derived from [Grok Build](https://github.com/xai-org/grok-build).

The phone keeps the Grok Build pager UI and ACP harness. Your Mac runs Codex, Claude, or a fully local coding agent through a small TLS bridge. No inference request is sent through xAI's gateway.

**Author:** Pedro Shakour  
**License:** Apache-2.0

![Welcome screen](docs/welcome.png)

## Requirements

- macOS with one supported ACP agent (see below)
- Xcode 16+ (Simulator or device)
- iOS 17+

## Clone

```bash
git clone --recurse-submodules https://github.com/Pedroshakoor/grok-build-ios.git
cd grok-build-ios
```

If you already cloned without submodules:

```bash
git submodule update --init --recursive
```

## Quick start

### 1. Start an agent on your Mac

Codex (default; uses your existing Codex/ChatGPT login or OpenAI key):

```bash
./companion/scripts/agent-phone
```

Claude (uses your existing Claude Code login):

```bash
ACP_AGENT=claude ./companion/scripts/agent-phone
```

Local Ollama model through OpenCode (no hosted inference):

```bash
ollama pull qwen3-coder:30b
ACP_AGENT=local ACP_MODEL=ollama/qwen3-coder:30b ./companion/scripts/agent-phone
```

The bridge prints a six-digit **PIN**. Leave this terminal open. Authenticate with each provider's CLI on the Mac before starting the bridge; provider credentials are never entered into the iOS app.

Agent prerequisites:

| Backend | ACP command used by the bridge |
|---------|--------------------------------|
| Codex | `npx @agentclientprotocol/codex-acp` (maintained adapter with compatible Codex runtime) |
| Claude | `claude-agent-acp`, or `npx @agentclientprotocol/claude-agent-acp` |
| Local | `opencode acp` with an injected, Ollama-only configuration |
| Custom | `ACP_AGENT_COMMAND='your-acp-agent --stdio'` |

### 2. Run the iOS app

Open `ios/GrokApp/GrokApp.xcodeproj` in Xcode → run on Simulator or device.

Or:

```bash
./scripts/run-simulator-demo.sh
```

### 3. Connect

In the app: **Setup** → paste the PIN → **connect** → **continue** → **New worktree**.

| Client | Host | Port |
|--------|------|------|
| Simulator | `127.0.0.1` | `7391` |
| Physical iPhone (same Wi‑Fi) | your Mac LAN IP | `7391` |

## Architecture

```
iOS (SwiftUI) ──ACP / JSON-RPC over TLS──► bridge ──ACP stdio──► Codex / Claude / OpenCode
```

The bridge reuses the existing pairing, permission, session, tool-call, and scrollback harness. Only the model-facing ACP process changes.

## Repo layout

| Path | Purpose |
|------|---------|
| `ios/GrokApp/` | SwiftUI app |
| `companion/` | Provider-neutral ACP TCP/TLS bridge |
| `shared/` | Themes + slash catalog from upstream |
| `upstream-grok-build/` | Pinned [xai-org/grok-build](https://github.com/xai-org/grok-build) submodule |
| `scripts/` | Demo + smoke helpers |
| `docs/` | Screenshots |

## Development

```bash
bash scripts/check-source-rev.sh
bash scripts/smoketest.sh
```

Stub ACP (CI / no API key):

```bash
./scripts/run-simulator-stub-demo.sh
```

## Notes

- Not on the App Store — open-source / sideload / Simulator only.
- Agent runtime and provider credentials stay on the Mac; the phone is a remote pager.
- Codex and Claude may still have their own subscription/API costs. The local Ollama path has no per-token gateway fee.
- Themes and slash names are taken from upstream Grok Build.

## License

Apache-2.0. See `LICENSE`, `NOTICE`, and `THIRD-PARTY-NOTICES`.


./companion/scripts/agent-phone --ngrok