const { app, BrowserWindow, dialog, ipcMain, powerSaveBlocker, shell } = require("electron");
const { execFile, spawn } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const readline = require("node:readline");
const { buildLaunchSpec, configuredPorts, defaultSettings, normalizeSettings, parseLogLine, parseLsofOutput } = require("./runtime.cjs");

let window;
let companion;
let stopping = false;
let powerBlocker;
let connection = {};
let recentLogs = [];
let portConflicts = [];

function repoRoot() {
  return app.isPackaged
    ? path.join(process.resourcesPath, "runtime")
    : path.resolve(__dirname, "../../..");
}

function settingsPath() {
  return path.join(app.getPath("userData"), "settings.json");
}

function readSettings() {
  const defaults = defaultSettings(app.isPackaged ? "" : repoRoot());
  try {
    const saved = JSON.parse(fs.readFileSync(settingsPath(), "utf8"));
    return normalizeSettings(saved, defaults);
  } catch {
    return defaults;
  }
}

function writeSettings(settings) {
  fs.mkdirSync(path.dirname(settingsPath()), { recursive: true });
  fs.writeFileSync(settingsPath(), JSON.stringify(settings, null, 2));
}

function snapshot(extra = {}) {
  return {
    running: Boolean(companion),
    stopping,
    pid: companion?.pid || null,
    connection,
    portConflicts,
    logs: recentLogs,
    ...extra,
  };
}

function lsofListeners(port) {
  return new Promise((resolve, reject) => {
    execFile("/usr/sbin/lsof", ["-nP", `-iTCP:${port}`, "-sTCP:LISTEN", "-Fpcn"], (error, stdout) => {
      if (error && error.code !== 1) return reject(error);
      resolve(parseLsofOutput(stdout, port));
    });
  });
}

async function inspectConfiguredPorts(settings) {
  const configured = configuredPorts(settings);
  const listeners = await Promise.all(configured.map(async entry => {
    const found = await lsofListeners(entry.port);
    return found.map(listener => ({ ...listener, labels: entry.labels }));
  }));
  return listeners.flat().filter(listener => listener.pid !== process.pid && listener.pid !== companion?.pid);
}

function wait(milliseconds) {
  return new Promise(resolve => setTimeout(resolve, milliseconds));
}

async function killConfiguredPortProcesses(settings) {
  const conflicts = await inspectConfiguredPorts(settings);
  const pids = [...new Set(conflicts.map(item => item.pid))]
    .filter(pid => Number.isInteger(pid) && pid > 1 && pid !== process.pid && pid !== companion?.pid);
  for (const pid of pids) {
    try { process.kill(pid, "SIGTERM"); } catch (error) {
      if (error.code !== "ESRCH") throw error;
    }
  }
  if (pids.length) await wait(700);
  let remaining = await inspectConfiguredPorts(settings);
  const remainingPids = new Set(remaining.map(item => item.pid));
  for (const pid of pids.filter(value => remainingPids.has(value))) {
    try { process.kill(pid, "SIGKILL"); } catch (error) {
      if (error.code !== "ESRCH") throw error;
    }
  }
  if (remainingPids.size) await wait(200);
  portConflicts = await inspectConfiguredPorts(settings);
  publish();
  return snapshot({ killedPids: pids });
}

function publish(extra = {}) {
  if (!window?.isDestroyed()) window.webContents.send("companion:state", snapshot(extra));
}

function appendLog(source, value) {
  const lines = String(value).split(/\r?\n/).filter(Boolean);
  for (const line of lines) {
    recentLogs.push({ source, line, at: new Date().toISOString() });
    recentLogs = recentLogs.slice(-1000);
    connection = parseLogLine(line, connection);
  }
  publish();
}

function stopCompanion() {
  if (!companion || stopping) return;
  stopping = true;
  publish();
  const processToStop = companion;
  try { process.kill(-processToStop.pid, "SIGTERM"); } catch { processToStop.kill("SIGTERM"); }
  setTimeout(() => {
    if (companion === processToStop) {
      try { process.kill(-processToStop.pid, "SIGKILL"); } catch { processToStop.kill("SIGKILL"); }
    }
  }, 5000).unref();
}

async function startCompanion(settings) {
  if (companion) return snapshot();
  if (!settings.projectsRoot) throw new Error("Choose a projects folder.");
  fs.mkdirSync(settings.projectsRoot, { recursive: true });
  if (!settings.workspace || !fs.existsSync(settings.workspace) || !fs.statSync(settings.workspace).isDirectory()) {
    throw new Error(`Workspace does not exist: ${settings.workspace || "(empty)"}`);
  }
  portConflicts = await inspectConfiguredPorts(settings);
  if (portConflicts.length) {
    publish();
    return snapshot();
  }
  writeSettings(settings);
  connection = {};
  recentLogs = [];
  stopping = false;
  portConflicts = [];
  const spec = buildLaunchSpec(settings, repoRoot());
  companion = spawn(spec.command, spec.args, {
    cwd: spec.cwd,
    env: spec.env,
    detached: true,
    stdio: ["ignore", "pipe", "pipe"],
  });
  powerBlocker = powerSaveBlocker.start("prevent-app-suspension");
  readline.createInterface({ input: companion.stdout }).on("line", line => appendLog("stdout", line));
  readline.createInterface({ input: companion.stderr }).on("line", line => appendLog("stderr", line));
  companion.on("error", error => appendLog("stderr", `Could not start companion: ${error.message}`));
  companion.on("exit", (code, signal) => {
    appendLog("system", `Companion stopped${signal ? ` (${signal})` : ` (exit ${code})`}`);
    companion = undefined;
    stopping = false;
    connection.ready = false;
    if (powerBlocker && powerSaveBlocker.isStarted(powerBlocker)) powerSaveBlocker.stop(powerBlocker);
    powerBlocker = undefined;
    publish({ exitCode: code, exitSignal: signal });
  });
  publish();
  return snapshot();
}

function createWindow() {
  window = new BrowserWindow({
    width: 1080,
    height: 760,
    minWidth: 680,
    minHeight: 620,
    title: "Build Buddy Companion",
    backgroundColor: "#f2f0e8",
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  window.loadFile(path.join(__dirname, "renderer", "index.html"));
}

ipcMain.handle("settings:get", () => readSettings());
ipcMain.handle("settings:save", (_event, settings) => { writeSettings(settings); return settings; });
ipcMain.handle("directory:choose", async (_event, current) => {
  const result = await dialog.showOpenDialog(window, {
    defaultPath: current || app.getPath("home"),
    properties: ["openDirectory", "createDirectory"],
  });
  return result.canceled ? null : result.filePaths[0];
});
ipcMain.handle("companion:start", (_event, settings) => startCompanion(settings));
ipcMain.handle("companion:stop", () => { stopCompanion(); return snapshot(); });
ipcMain.handle("companion:status", () => snapshot());
ipcMain.handle("companion:kill-ports", (_event, settings) => killConfiguredPortProcesses(settings));
ipcMain.handle("logs:clear", () => { recentLogs = []; publish(); });
ipcMain.handle("url:open", (_event, url) => {
  if (/^https?:\/\//.test(url)) return shell.openExternal(url);
  return false;
});

app.whenReady().then(() => {
  createWindow();
  app.on("activate", () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
});
app.on("before-quit", stopCompanion);
app.on("window-all-closed", () => { if (process.platform !== "darwin") app.quit(); });
