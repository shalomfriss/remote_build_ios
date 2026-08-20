const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("companion", {
  getSettings: () => ipcRenderer.invoke("settings:get"),
  saveSettings: settings => ipcRenderer.invoke("settings:save", settings),
  chooseDirectory: current => ipcRenderer.invoke("directory:choose", current),
  start: settings => ipcRenderer.invoke("companion:start", settings),
  stop: () => ipcRenderer.invoke("companion:stop"),
  status: () => ipcRenderer.invoke("companion:status"),
  killPorts: settings => ipcRenderer.invoke("companion:kill-ports", settings),
  clearLogs: () => ipcRenderer.invoke("logs:clear"),
  openUrl: url => ipcRenderer.invoke("url:open", url),
  onState: callback => ipcRenderer.on("companion:state", (_event, state) => callback(state)),
});
