const assert = require("node:assert/strict");
const test = require("node:test");
const { buildLaunchSpec, configuredPorts, defaultSettings, normalizeSettings, parseLogLine, parseLsofOutput } = require("../src/runtime.cjs");

test("builds the ngrok companion command and environment", () => {
  const settings = {
    workspace: "/tmp/workspace", projectsRoot: "/tmp/projects", codingHarness: "codex", model: "",
    acpPort: "7391", simulatorPort: "3200", gatewayPort: "7392", simulatorDevice: "iPhone 17 Pro",
    ngrok: true, ngrokUrl: "example.ngrok.app", startSimulator: true,
  };
  const spec = buildLaunchSpec(settings, "/runtime", { PATH: "/custom" });
  assert.equal(spec.command, "/bin/bash");
  assert.deepEqual(spec.args.slice(0, 4), ["/runtime/companion/scripts/agent-phone", "--ngrok", "--ngrok-url", "example.ngrok.app"]);
  assert.equal(spec.env.GROK_PROJECT_SIMULATOR_DEVICE, "iPhone 17 Pro");
  assert.equal(spec.env.GROK_COMPANION_CWD, "/tmp/workspace");
  assert.equal(spec.env.ACP_AGENT, "codex");
  assert.match(spec.env.PATH, /\.opencode\/bin/);
});

test("selects each supported coding harness", () => {
  const settings = {
    workspace: "/tmp/workspace", projectsRoot: "/tmp/projects", model: "",
    acpPort: "7391", simulatorPort: "3200", gatewayPort: "7392", simulatorDevice: "",
    ngrok: false, ngrokUrl: "", startSimulator: true,
  };
  for (const codingHarness of ["codex", "claude", "opencode"]) {
    const spec = buildLaunchSpec({ ...settings, codingHarness }, "/runtime", { PATH: "/custom" });
    assert.equal(spec.env.ACP_AGENT, codingHarness);
  }
  assert.throws(
    () => buildLaunchSpec({ ...settings, codingHarness: "unknown" }, "/runtime", { PATH: "/custom" }),
    /Coding harness must be Codex, Claude, or OpenCode/,
  );
});

test("migrates the previous agent setting to coding harness", () => {
  const defaults = defaultSettings("/workspace");
  assert.equal(normalizeSettings({ agent: "claude" }, defaults).codingHarness, "claude");
  assert.equal(normalizeSettings({ codingHarness: "opencode", agent: "codex" }, defaults).codingHarness, "opencode");
  assert.equal(normalizeSettings({ agent: "local" }, defaults).codingHarness, "codex");
  assert.equal("agent" in normalizeSettings({ agent: "claude" }, defaults), false);
});

test("uses harness and simulator defaults without overrides", () => {
  const defaults = defaultSettings("/workspace");
  assert.equal(defaults.model, "default");
  assert.equal(defaults.simulatorDevice, "default");
  assert.equal(defaults.startSimulator, true);
  const spec = buildLaunchSpec(defaults, "/runtime", { PATH: "/custom" });
  assert.equal(spec.env.ACP_MODEL, "");
  assert.equal(spec.env.GROK_PROJECT_SIMULATOR_DEVICE, "");

  const migrated = normalizeSettings({ model: "", simulatorDevice: "" }, defaults);
  assert.equal(migrated.model, "default");
  assert.equal(migrated.simulatorDevice, "default");
});

test("passes explicit model and simulator overrides", () => {
  const settings = {
    ...defaultSettings("/workspace"),
    codingHarness: "opencode",
    model: "openai/gpt-5",
    simulatorDevice: "iPhone 17 Pro",
  };
  const spec = buildLaunchSpec(settings, "/runtime", { PATH: "/custom" });
  assert.equal(spec.env.ACP_MODEL, "openai/gpt-5");
  assert.equal(spec.env.GROK_PROJECT_SIMULATOR_DEVICE, "iPhone 17 Pro");
});

test("extracts connection details from companion output", () => {
  let state = parseLogLine("[start-acp-bridge] PIN: 123456");
  state = parseLogLine("agent-phone: companion remote=wss://example.ngrok.app/acp", state);
  state = parseLogLine("agent-phone: project simulator=iPhone 17 Pro (AAAA-BBBB)", state);
  state = parseLogLine("agent-phone: latest project preview and the agent are ready", state);
  assert.deepEqual(state, {
    pin: "123456", remoteEndpoint: "wss://example.ngrok.app/acp",
    simulatorName: "iPhone 17 Pro", simulatorUdid: "AAAA-BBBB", ready: true,
  });
});

test("selects only ports used by the enabled desktop services", () => {
  assert.deepEqual(configuredPorts({
    acpPort: "7391", simulatorPort: "3200", gatewayPort: "7392",
    startSimulator: false, ngrok: false,
  }), [{ port: 7391, labels: ["ACP"] }]);
  assert.deepEqual(configuredPorts({
    acpPort: "7391", simulatorPort: "3200", gatewayPort: "7392",
    startSimulator: true, ngrok: true,
  }), [
    { port: 7391, labels: ["ACP"] },
    { port: 3200, labels: ["Simulator stream"] },
    { port: 7392, labels: ["Gateway"] },
  ]);
  assert.deepEqual(configuredPorts({
    acpPort: "7391", simulatorPort: "7391", gatewayPort: "7392",
    startSimulator: true, ngrok: false,
  }), [{ port: 7391, labels: ["ACP", "Simulator stream"] }]);
});

test("rejects invalid configured ports before launching", () => {
  assert.throws(() => configuredPorts({ acpPort: "nope", startSimulator: false, ngrok: false }), /ACP port/);
  assert.throws(() => configuredPorts({ acpPort: "70000", startSimulator: false, ngrok: false }), /ACP port/);
});

test("parses lsof field output into listener details", () => {
  assert.deepEqual(parseLsofOutput("p123\ncnode\nn*:7391\np456\ncPython\nn127.0.0.1:7391\n", 7391), [
    { port: 7391, pid: 123, command: "node", endpoint: "*:7391" },
    { port: 7391, pid: 456, command: "Python", endpoint: "127.0.0.1:7391" },
  ]);
});
