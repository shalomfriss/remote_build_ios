const fields = ["workspace", "projectsRoot", "agent", "model", "acpPort", "simulatorPort", "gatewayPort", "simulatorDevice", "ngrokUrl", "ngrok", "startSimulator"];
let state = { running: false, stopping: false, connection: {}, logs: [] };

function settingsFromForm() {
  return Object.fromEntries(fields.map(id => {
    const element = document.getElementById(id);
    return [id, element.type === "checkbox" ? element.checked : element.value.trim()];
  }));
}

function setForm(settings) {
  for (const id of fields) {
    const element = document.getElementById(id);
    if (element.type === "checkbox") element.checked = Boolean(settings[id]);
    else element.value = settings[id] ?? "";
  }
}

function toast(message) {
  const element = document.getElementById("toast");
  element.textContent = message;
  element.classList.add("show");
  setTimeout(() => element.classList.remove("show"), 1800);
}

function render(next) {
  state = { ...state, ...next };
  const connection = state.connection || {};
  const status = document.getElementById("status");
  const mode = state.stopping ? "starting" : state.running ? (connection.ready ? "running" : "starting") : "stopped";
  status.className = `status ${mode}`;
  status.innerHTML = `<span></span>${state.stopping ? "Stopping" : connection.ready ? "Running" : state.running ? "Starting" : "Stopped"}`;
  document.getElementById("headline").textContent = connection.ready ? "Companion is ready" : state.running ? "Starting services…" : "Ready to start";
  document.getElementById("summary").textContent = connection.ready ? "Your phone can connect using the endpoint and PIN below." : state.running ? "Preparing the simulator, stream, tunnel, and ACP agent." : "Start the companion to boot and stream your project simulator.";
  document.getElementById("start").disabled = state.running;
  document.getElementById("stop").disabled = !state.running || state.stopping;
  document.querySelectorAll("#settings input,#settings select,#settings button").forEach(element => element.disabled = state.running);
  document.getElementById("pin").textContent = connection.pin ? connection.pin.split("").join(" ") : "— — — — — —";
  document.getElementById("remote").textContent = connection.remoteEndpoint || connection.lanEndpoint || "Not connected";
  document.getElementById("simulator").textContent = connection.simulatorName || "Not running";
  const open = document.getElementById("open-simulator");
  open.disabled = !connection.simulatorUrl;
  open.dataset.url = connection.simulatorUrl || "";
  const logs = document.getElementById("logs");
  document.getElementById("log-count").textContent = state.logs.length ? `${state.logs.length} messages` : "No messages yet";
  logs.innerHTML = state.logs.length ? state.logs.map(item => `<div class="log ${item.source}"><time>${new Date(item.at).toLocaleTimeString([], {hour:"2-digit",minute:"2-digit",second:"2-digit"})}</time><span class="message"></span></div>`).join("") : '<div class="empty">Companion output will appear here.</div>';
  [...logs.querySelectorAll(".message")].forEach((element, index) => { element.textContent = state.logs[index].line; });
  logs.scrollTop = logs.scrollHeight;
}

document.getElementById("settings").addEventListener("submit", event => event.preventDefault());
document.getElementById("start").addEventListener("click", async () => {
  try { render(await window.companion.start(settingsFromForm())); }
  catch (error) { toast(error.message); }
});
document.getElementById("stop").addEventListener("click", async () => render(await window.companion.stop()));
document.getElementById("clear").addEventListener("click", () => window.companion.clearLogs());
document.getElementById("open-simulator").addEventListener("click", event => window.companion.openUrl(event.currentTarget.dataset.url));
document.querySelectorAll(".browse").forEach(button => button.addEventListener("click", async () => {
  const field = document.getElementById(button.dataset.field);
  const selected = await window.companion.chooseDirectory(field.value);
  if (selected) field.value = selected;
}));
document.querySelectorAll("[data-copy]").forEach(button => button.addEventListener("click", async () => {
  const value = button.dataset.copy === "pin" ? state.connection.pin : (state.connection.remoteEndpoint || state.connection.lanEndpoint);
  if (value) { await navigator.clipboard.writeText(value); toast("Copied"); }
}));
window.companion.onState(render);
Promise.all([window.companion.getSettings(), window.companion.status()]).then(([settings, status]) => { setForm(settings); render(status); });
