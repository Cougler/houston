const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("mc", {
  getDashboard: () => ipcRenderer.invoke("dashboard:get"),
  getActiveSessions: () => ipcRenderer.invoke("sessions:active"),
  getProjectDetail: (projectPath) => ipcRenderer.invoke("project:detail", projectPath),
  getSkillDetail: (skillName) => ipcRenderer.invoke("skill:detail", skillName),
  getActiveServers: () => ipcRenderer.invoke("servers:active"),
  killServer: (pid) => ipcRenderer.invoke("servers:kill", { pid }),
  completeOnboarding: () => ipcRenderer.invoke("onboarding:complete"),
  openPath: (p) => ipcRenderer.invoke("shell:openPath", p),
  openExternal: (url) => ipcRenderer.invoke("shell:openExternal", url),
  hide: () => ipcRenderer.invoke("window:hide"),
  clearServerCache: (cwd) => ipcRenderer.invoke("servers:clearCache", { cwd }),
  startDevServer: (projectPath) => ipcRenderer.invoke("dev:start", { projectPath }),
  getSettings: () => ipcRenderer.invoke("settings:get"),
  setSettings: (patch) => ipcRenderer.invoke("settings:set", patch),
  getTerminalStatus: () => ipcRenderer.invoke("terminal:status"),
  pickDirectory: (opts) => ipcRenderer.invoke("dialog:pickDirectory", opts || {}),
  startMission: (projectPath, terminal, mode) =>
    ipcRenderer.invoke("mission:start", { projectPath, terminal, mode }),
});
