const fields = ["workspace", "projectsRoot", "codingHarness", "model", "acpPort", "simulatorPort", "gatewayPort", "simulatorDevice", "ngrokUrl", "ngrok", "startSimulator"];
let state = { running: false, stopping: false, connection: {}, logs: [] };
let currentSettings = { ngrok: false };

const harnessModelHelp = {
  codex: "Default uses the model configured by Codex.",
  claude: "Default uses the model configured by Claude.",
  opencode: "Default uses the provider and model configured by OpenCode.",
};

function settingsFromForm() {
  return Object.fromEntries(fields.map(id => {
    const element = document.getElementById(id);
    return [id, element.type === "checkbox" ? element.checked : element.value.trim()];
  }));
}

function updateHarnessDefaults() {
  const harness = document.getElementById("codingHarness").value;
  document.getElementById("model-help").textContent = harnessModelHelp[harness] || "Uses the selected harness default.";
}

function updateConnectionMode() {
  const ngrokEnabled = document.getElementById("ngrok").checked;
  currentSettings = { ...currentSettings, ngrok: ngrokEnabled };
  document.getElementById("ngrok-options").classList.toggle("visible", ngrokEnabled);
  document.getElementById("ngrokUrl").disabled = state.running || !ngrokEnabled;
  document.getElementById("endpoint-label").textContent = ngrokEnabled ? "Remote endpoint" : "Local endpoint";
}

function setForm(settings) {
  currentSettings = { ...settings };
  for (const id of fields) {
    const element = document.getElementById(id);
    if (element.type === "checkbox") element.checked = Boolean(settings[id]);
    else element.value = settings[id] ?? "";
  }
  updateHarnessDefaults();
  updateConnectionMode();
}

function setView(name) {
  for (const viewName of ["control", "settings"]) {
    const selected = viewName === name;
    const view = document.getElementById(`${viewName}-view`);
    view.hidden = !selected;
    view.classList.toggle("active", selected);
  }
  document.querySelectorAll(".nav-button").forEach(button => {
    const selected = button.dataset.viewTarget === name;
    button.classList.toggle("active", selected);
    if (selected) button.setAttribute("aria-current", "page");
    else button.removeAttribute("aria-current");
  });
  window.scrollTo({ top: 0, behavior: "smooth" });
}

function toast(message) {
  const element = document.getElementById("toast");
  element.textContent = message;
  element.classList.add("show");
  setTimeout(() => element.classList.remove("show"), 1800);
}

function activeEndpoint(connection) {
  return currentSettings.ngrok ? (connection.remoteEndpoint || connection.lanEndpoint) : connection.lanEndpoint;
}

function render(next) {
  state = { ...state, ...next };
  const connection = state.connection || {};
  const conflicts = state.portConflicts || [];
  const status = document.getElementById("status");
  const mode = state.stopping ? "starting" : state.running ? (connection.ready ? "running" : "starting") : "stopped";
  status.className = `status ${mode}`;
  status.innerHTML = `<span></span>${state.stopping ? "Stopping" : connection.ready ? "Connected" : state.running ? "Starting" : "Offline"}`;
  document.getElementById("headline").textContent = conflicts.length ? "A port needs attention." : connection.ready ? "Your phone is connected." : state.running ? "Making the connection…" : "Ready when you are.";
  document.getElementById("summary").textContent = conflicts.length
    ? "Stop the listed process and Build Buddy can continue."
    : connection.ready
      ? `Connect with the ${currentSettings.ngrok ? "remote" : "local"} endpoint and pairing PIN below.`
      : state.running
        ? `Preparing your simulator, ${currentSettings.ngrok ? "secure tunnel" : "local bridge"}, and coding agent.`
        : "Start the companion to bring your project, simulator, and coding agent onto your phone.";
  document.getElementById("start").disabled = state.running;
  document.getElementById("stop").disabled = !state.running || state.stopping;
  document.querySelectorAll("#settings input,#settings select,#settings .browse,#save-settings").forEach(element => { element.disabled = state.running; });
  updateConnectionMode();
  document.getElementById("pin").textContent = connection.pin ? connection.pin.split("").join(" ") : "· · · · · ·";
  document.getElementById("remote").textContent = activeEndpoint(connection) || "Not connected";
  document.getElementById("simulator").textContent = connection.simulatorName || "Not running";

  const conflictPanel = document.getElementById("port-conflicts");
  conflictPanel.hidden = conflicts.length === 0;
  const conflictList = document.getElementById("port-conflict-list");
  conflictList.replaceChildren(...conflicts.map(conflict => {
    const item = document.createElement("li");
    const services = (conflict.labels || []).join(" / ");
    item.textContent = `${services} :${conflict.port} · ${conflict.command} (PID ${conflict.pid})`;
    return item;
  }));

  const open = document.getElementById("open-simulator");
  open.disabled = !connection.simulatorUrl;
  open.dataset.url = connection.simulatorUrl || "";
  const logs = document.getElementById("logs");
  document.getElementById("log-count").textContent = state.logs.length ? `${state.logs.length} messages` : "No messages yet";
  logs.innerHTML = state.logs.length
    ? state.logs.map(item => `<div class="log ${item.source}"><time>${new Date(item.at).toLocaleTimeString([], {hour:"2-digit",minute:"2-digit",second:"2-digit"})}</time><span class="message"></span></div>`).join("")
    : '<div class="empty"><span>Quiet for now</span><small>Build and runtime events will appear here.</small></div>';
  [...logs.querySelectorAll(".message")].forEach((element, index) => { element.textContent = state.logs[index].line; });
  logs.scrollTop = logs.scrollHeight;
}

document.querySelectorAll("[data-view-target]").forEach(button => button.addEventListener("click", () => setView(button.dataset.viewTarget)));
document.getElementById("codingHarness").addEventListener("change", updateHarnessDefaults);
document.getElementById("ngrok").addEventListener("change", () => { updateConnectionMode(); render({}); });
document.getElementById("settings").addEventListener("input", () => {
  currentSettings = settingsFromForm();
  document.getElementById("settings-state").textContent = "Unsaved changes";
});
document.getElementById("settings").addEventListener("submit", async event => {
  event.preventDefault();
  try {
    currentSettings = await window.companion.saveSettings(settingsFromForm());
    document.getElementById("settings-state").textContent = "Settings saved. Changes apply on the next start.";
    render({});
    toast("Settings saved");
  } catch (error) { toast(error.message); }
});
document.getElementById("start").addEventListener("click", async () => {
  try {
    currentSettings = settingsFromForm();
    render(await window.companion.start(currentSettings));
  } catch (error) { toast(error.message); }
});
document.getElementById("stop").addEventListener("click", async () => render(await window.companion.stop()));
document.getElementById("kill-ports").addEventListener("click", async event => {
  const button = event.currentTarget;
  button.disabled = true;
  button.textContent = "Stopping processes…";
  try {
    const settings = settingsFromForm();
    const result = await window.companion.killPorts(settings);
    render(result);
    if ((result.portConflicts || []).length) toast("Some processes could not be stopped");
    else {
      toast("Ports cleared. Starting companion…");
      render(await window.companion.start(settings));
    }
  } catch (error) { toast(error.message); }
  finally {
    button.disabled = false;
    button.textContent = "Stop processes and retry";
  }
});
document.getElementById("clear").addEventListener("click", () => window.companion.clearLogs());
document.getElementById("open-simulator").addEventListener("click", event => window.companion.openUrl(event.currentTarget.dataset.url));
document.querySelectorAll(".browse").forEach(button => button.addEventListener("click", async () => {
  const field = document.getElementById(button.dataset.field);
  const selected = await window.companion.chooseDirectory(field.value);
  if (selected) {
    field.value = selected;
    field.dispatchEvent(new Event("input", { bubbles: true }));
  }
}));
document.querySelectorAll("[data-copy]").forEach(button => button.addEventListener("click", async () => {
  const value = button.dataset.copy === "pin" ? state.connection.pin : activeEndpoint(state.connection || {});
  if (value) { await navigator.clipboard.writeText(value); toast("Copied"); }
}));

window.companion.onState(render);
Promise.all([window.companion.getSettings(), window.companion.status()]).then(([settings, status]) => {
  setForm(settings);
  render(status);
});
