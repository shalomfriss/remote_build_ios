const assert = require("node:assert/strict");
const test = require("node:test");
const { buildLaunchSpec, parseLogLine } = require("../src/runtime.cjs");

test("builds the ngrok companion command and environment", () => {
  const settings = {
    workspace: "/tmp/workspace", projectsRoot: "/tmp/projects", agent: "codex", model: "",
    acpPort: "7391", simulatorPort: "3200", gatewayPort: "7392", simulatorDevice: "iPhone 17 Pro",
    ngrok: true, ngrokUrl: "example.ngrok.app", startSimulator: true,
  };
  const spec = buildLaunchSpec(settings, "/runtime", { PATH: "/custom" });
  assert.equal(spec.command, "/bin/bash");
  assert.deepEqual(spec.args.slice(0, 4), ["/runtime/companion/scripts/agent-phone", "--ngrok", "--ngrok-url", "example.ngrok.app"]);
  assert.equal(spec.env.GROK_PROJECT_SIMULATOR_DEVICE, "iPhone 17 Pro");
  assert.equal(spec.env.GROK_COMPANION_CWD, "/tmp/workspace");
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
