# Build Buddy Companion for macOS

Electron control center for `companion/scripts/agent-phone`. It starts and stops
the full companion process group, displays its PIN and endpoints, streams logs,
and persists workspace, project, simulator, coding harness, port, and ngrok settings.

## Development

```bash
cd companion/desktop
npm install
npm start
```

## Build a standalone app

```bash
cd companion/desktop
npm install
npm run dist
```

The DMG and ZIP are written to `companion/desktop/dist`. Packaged builds include
the companion scripts and required upstream runtime resources. Xcode, the chosen
ACP agent, and Node/npm remain host prerequisites. ngrok is optional and only
required when cellular access is enabled in Settings. With ngrok disabled, the
control view displays the local network endpoint.

## Coding harnesses

The Coding harness menu supports Codex, Claude, and OpenCode. Keep Model set to
`default` to use the selected harness's configured default, or enter a supported
model override for the companion session. OpenCode accepts `provider/model`.

Simulator device defaults to `default`. This reuses a responsive booted iPhone
Simulator when available, otherwise it selects and boots the first available
iPhone. Enter a simulator name or UDID to override automatic selection.
