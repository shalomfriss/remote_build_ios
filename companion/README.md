# Provider-neutral companion

TCP/TLS + Bonjour bridge from the iOS ACP client to an ACP stdio agent.

Codex:

```bash
./companion/scripts/agent-phone
```

`agent-phone` boots one project simulator and launches the most recently added
Grok Build project in it. It does not build or launch the Grok Build controller
app. The pinned `serve-sim` preview follows the project simulator, and its LAN
URL is sent to the connected phone for the Simulator tab. If no project exists
yet, the simulator stays ready until the phone creates one.
The phone and Mac must be on the same trusted network;
set `GROK_SIMULATOR_ADVERTISE_HOST` if automatic LAN-address discovery chooses
the wrong interface. Pass `--no-simulator` to run only the ACP bridge, or set
`GROK_PROJECT_SIMULATOR_DEVICE` to choose the project simulator. The older
`GROK_SIMULATOR_DEVICE` setting remains a fallback for compatibility.

Each new phone project asks for a name and gets a fresh SwiftUI Xcode project
under `~/.projects`. The name prefixes the project folder and becomes the
sanitized Xcode project, target, and scheme name.
Change the root with `--projects-root /path/to/projects` or the
`GROK_PROJECTS_ROOT` environment variable. After a successful agent turn, the
companion builds that project's iOS app, installs and launches it in the
Simulator, and keeps it available in the phone's Simulator tab.

Add an existing project to the phone's Resume Projects menu from the command
line:

```bash
./companion/scripts/agent-phone add-project /path/to/MyApp --name "My App"
```

The name is optional; Grok Build falls back to `.grok-build-project.json`, the
Xcode project name, or the folder name. Registrations are stored under the
configured projects root, so use `--projects-root /path/to/projects` on the
command or set `GROK_PROJECTS_ROOT` when using a non-default root. Selecting a
registered project starts a new agent session in that existing directory.

Remote access through ngrok (the bridge's TLS + PIN protection remains active):

```bash
./companion/scripts/agent-phone --ngrok
```

Paste the printed `tcp://...` endpoint into the app's Advanced host field and
paste the PIN normally. To keep the same public address between runs, reserve a
TCP address in ngrok and pass `--ngrok-url host:port` or set `GROK_NGROK_URL`.
With `--ngrok`, the serve-sim web preview is also exposed over HTTPS and sent
to the connected iOS app automatically. If that HTTP tunnel is unavailable or
over its bandwidth limit, `agent-phone` falls back to the LAN preview and prints
a warning.

Claude:

```bash
ACP_AGENT=claude ./companion/scripts/agent-phone
```

Local Ollama model through OpenCode:

```bash
ACP_AGENT=local ACP_MODEL=ollama/qwen3-coder:30b ./companion/scripts/agent-phone
```

Stub (tests only):

```bash
export GROK_COMPANION_INSECURE=1
python3 companion/scripts/acp_tcp_bridge.py --stub --no-tls --no-pair --host 127.0.0.1 --port 7391
```
