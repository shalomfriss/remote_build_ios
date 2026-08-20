const os = require("node:os");
const path = require("node:path");

const CODING_HARNESSES = new Set(["codex", "claude", "opencode"]);

function defaultSettings(repoRoot = "") {
  return {
    workspace: repoRoot || path.join(os.homedir(), ".projects"),
    projectsRoot: path.join(os.homedir(), ".projects"),
    codingHarness: "codex",
    model: "default",
    acpPort: "7391",
    simulatorPort: "3200",
    gatewayPort: "7392",
    simulatorDevice: "default",
    ngrok: true,
    ngrokUrl: "",
    startSimulator: true,
  };
}

function normalizeSettings(saved = {}, defaults = defaultSettings()) {
  const settings = { ...defaults, ...saved };
  const codingHarness = String(saved.codingHarness || saved.agent || defaults.codingHarness).trim().toLowerCase();
  settings.codingHarness = CODING_HARNESSES.has(codingHarness) ? codingHarness : defaults.codingHarness;
  settings.model = String(saved.model || defaults.model).trim() || defaults.model;
  settings.simulatorDevice = String(saved.simulatorDevice || defaults.simulatorDevice).trim() || defaults.simulatorDevice;
  delete settings.agent;
  return settings;
}

function optionalOverride(value) {
  const candidate = String(value || "").trim();
  return /^(default|automatic)$/i.test(candidate) ? "" : candidate;
}

function buildLaunchSpec(settings, root, inheritedEnv = process.env) {
  const codingHarness = String(settings.codingHarness || settings.agent || "codex").trim().toLowerCase();
  if (!CODING_HARNESSES.has(codingHarness)) {
    throw new Error("Coding harness must be Codex, Claude, or OpenCode.");
  }
  const script = path.join(root, "companion", "scripts", "agent-phone");
  const model = optionalOverride(settings.model);
  const simulatorDevice = optionalOverride(settings.simulatorDevice);
  const args = [script];
  if (settings.ngrok) args.push("--ngrok");
  if (settings.ngrokUrl) args.push("--ngrok-url", settings.ngrokUrl);
  if (!settings.startSimulator) args.push("--no-simulator");
  args.push("--projects-root", settings.projectsRoot, "--port", settings.acpPort);

  const executablePath = [
    path.join(os.homedir(), ".local", "bin"),
    path.join(os.homedir(), ".opencode", "bin"),
    path.join(os.homedir(), ".bun", "bin"),
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
      ACP_AGENT: codingHarness,
      ACP_MODEL: model,
      GROK_COMPANION_CWD: settings.workspace,
      GROK_PROJECTS_ROOT: settings.projectsRoot,
      GROK_ACP_PORT: settings.acpPort,
      GROK_SIMULATOR_PORT: settings.simulatorPort,
      GROK_GATEWAY_PORT: settings.gatewayPort,
      GROK_PROJECT_SIMULATOR_DEVICE: simulatorDevice,
      GROK_START_SIMULATOR: settings.startSimulator ? "1" : "0",
    },
  };
}

function configuredPorts(settings) {
  const candidates = [
    { key: "acpPort", label: "ACP", enabled: true },
    { key: "simulatorPort", label: "Simulator stream", enabled: settings.startSimulator !== false },
    { key: "gatewayPort", label: "Gateway", enabled: Boolean(settings.ngrok) },
  ];
  const ports = new Map();
  for (const candidate of candidates) {
    if (!candidate.enabled) continue;
    const raw = String(settings[candidate.key] ?? "").trim();
    const port = Number(raw);
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      throw new Error(`${candidate.label} port must be between 1 and 65535.`);
    }
    const current = ports.get(port);
    if (current) current.labels.push(candidate.label);
    else ports.set(port, { port, labels: [candidate.label] });
  }
  return [...ports.values()];
}

function parseLsofOutput(output, configuredPort) {
  const listeners = [];
  let current;
  for (const line of String(output).split(/\r?\n/)) {
    const kind = line[0];
    const value = line.slice(1);
    if (kind === "p") {
      const pid = Number(value);
      current = Number.isInteger(pid) ? { port: configuredPort, pid, command: "Unknown process" } : undefined;
      if (current) listeners.push(current);
    } else if (kind === "c" && current) {
      current.command = value || current.command;
    } else if (kind === "n" && current) {
      current.endpoint = value;
    }
  }
  return listeners;
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

module.exports = { buildLaunchSpec, configuredPorts, defaultSettings, normalizeSettings, parseLogLine, parseLsofOutput };
