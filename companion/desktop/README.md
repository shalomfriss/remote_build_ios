# Build Buddy Companion for macOS

Electron control center for `companion/scripts/agent-phone`. It starts and stops
the full companion process group, displays its PIN and endpoints, streams logs,
and persists workspace, project, simulator, agent, port, and ngrok settings.

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
ACP agent, Node/npm, and ngrok (when enabled) remain host prerequisites.
