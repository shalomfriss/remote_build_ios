const os = require("node:os");
const path = require("node:path");

function defaultSettings(repoRoot = "") {
  return {
    workspace: repoRoot || path.join(os.homedir(), ".projects"),
    projectsRoot: path.join(os.homedir(), ".projects"),
    agent: "codex",
    model: "",
    acpPort: "7391",
    simulatorPort: "3200",
    gatewayPort: "7392",
    simulatorDevice: "",
    ngrok: true,
    ngrokUrl: "",
    startSimulator: true,
  };
}

function buildLaunchSpec(settings, root, inheritedEnv = process.env) {
  const script = path.join(root, "companion", "scripts", "agent-phone");
  const args = [script];
  if (settings.ngrok) args.push("--ngrok");
  if (settings.ngrokUrl) args.push("--ngrok-url", settings.ngrokUrl);
  if (!settings.startSimulator) args.push("--no-simulator");
  args.push("--projects-root", settings.projectsRoot, "--port", settings.acpPort);

  const executablePath = [
    path.join(os.homedir(), ".local", "bin"),
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin",
    inheritedEnv.PATH || "",
  ].filter(Boolean).join(":");

  return {
    command: "/bin/bash",
    args,
    cwd: settings.workspace,
    env: {
      ...inheritedEnv,
      PATH: executablePath,
      ACP_AGENT: settings.agent,
      ACP_MODEL: settings.model,
      GROK_COMPANION_CWD: settings.workspace,
      GROK_PROJECTS_ROOT: settings.projectsRoot,
      GROK_ACP_PORT: settings.acpPort,
      GROK_SIMULATOR_PORT: settings.simulatorPort,
      GROK_GATEWAY_PORT: settings.gatewayPort,
      GROK_PROJECT_SIMULATOR_DEVICE: settings.simulatorDevice,
      GROK_START_SIMULATOR: settings.startSimulator ? "1" : "0",
    },
  };
}

function parseLogLine(line, current = {}) {
  const next = { ...current };
  let match = line.match(/\[start-acp-bridge\] PIN: (\d{6})/);
  if (match) next.pin = match[1];
  match = line.match(/agent-phone: companion LAN=(\S+)/);
  if (match) next.lanEndpoint = match[1].replaceAll("\\/", "/");
  match = line.match(/agent-phone: companion remote=(\S+)/);
  if (match) next.remoteEndpoint = match[1];
  match = line.match(/\[start-acp-bridge\] ngrok endpoint: (\S+)/);
  if (match && !next.remoteEndpoint) next.remoteEndpoint = match[1];
  match = line.match(/agent-phone: simulator preview=(\S+)/);
  if (match) next.simulatorUrl = match[1];
  match = line.match(/agent-phone: project simulator=(.+) \(([-A-Fa-f0-9]+)\)/);
  if (match) {
    next.simulatorName = match[1];
    next.simulatorUdid = match[2];
  }
  if (line.includes("latest project preview and the agent are ready")) next.ready = true;
  return next;
}

module.exports = { buildLaunchSpec, defaultSettings, parseLogLine };
