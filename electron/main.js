const { app, BrowserWindow, Tray, Menu, nativeImage, ipcMain, screen, shell, dialog, protocol, net, systemPreferences } = require("electron");
const path = require("node:path");
const fs = require("node:fs");
const { spawn, execFile } = require("node:child_process");
const { promisify } = require("node:util");
const { pathToFileURL } = require("node:url");

const execFileP = promisify(execFile);

const isDev = process.env.NODE_ENV === "development";
const DEV_URL = "http://localhost:3401";
const PROD_OUT_DIR = path.join(__dirname, "..", "out");

// Register app:// before app is ready so the protocol handler is available at load time.
// Root-relative paths in the Next.js export (e.g. /_next/static/..., /houstonlogo.png) resolve
// to filesystem root under file://, which breaks all CSS/JS/images. Mapping them through app://
// lets us anchor them to the bundled out/ directory.
protocol.registerSchemesAsPrivileged([
  { scheme: "app", privileges: { standard: true, secure: true, supportFetchAPI: true } },
]);

const WINDOW_WIDTH = 445;
const WINDOW_HEIGHT = 751;

let tray = null;
let win = null;
let onboardingWin = null;

function createWindow() {
  win = new BrowserWindow({
    width: WINDOW_WIDTH,
    height: WINDOW_HEIGHT,
    show: false,
    frame: false,
    fullscreenable: false,
    resizable: false,
    transparent: true,
    hasShadow: true,
    skipTaskbar: true,
    backgroundColor: "#00000000",
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });

  if (isDev) {
    win.loadURL(DEV_URL);
  } else {
    win.loadURL("app://-/index.html");
  }

  win.on("blur", () => {
    if (!win.webContents.isDevToolsOpened()) {
      // Drop focus from whatever element was last interacted with, otherwise
      // macOS draws its accent-colored focus ring around it when the popover
      // reopens.
      win.webContents
        .executeJavaScript(
          "if (document.activeElement && document.activeElement !== document.body) document.activeElement.blur();",
          true
        )
        .catch(() => {});
      win.hide();
    }
  });
}

function positionWindow(trayBounds) {
  const { x, y, width } = trayBounds;
  const display = screen.getDisplayNearestPoint({ x, y });
  const workArea = display.workArea;

  // Center horizontally under the tray icon
  let posX = Math.round(x + width / 2 - WINDOW_WIDTH / 2);
  // Position just below the menubar (tray bottom + small gap)
  const posY = Math.round(y + 24);

  // Clamp to screen so we don't overflow the right edge
  const maxX = workArea.x + workArea.width - WINDOW_WIDTH - 8;
  if (posX > maxX) posX = maxX;
  if (posX < workArea.x + 8) posX = workArea.x + 8;

  win.setPosition(posX, posY, false);
}

function toggleWindow(bounds) {
  if (win.isVisible()) {
    win.hide();
    return;
  }
  positionWindow(bounds);
  win.show();
  win.focus();
}

// ── Onboarding ────────────────────────────────────────────────────────────────

function onboardingFlagPath() {
  return path.join(app.getPath("userData"), "onboarded.json");
}

function hasOnboarded() {
  try {
    return fs.existsSync(onboardingFlagPath());
  } catch {
    return false;
  }
}

function markOnboarded() {
  try {
    fs.mkdirSync(app.getPath("userData"), { recursive: true });
    fs.writeFileSync(
      onboardingFlagPath(),
      JSON.stringify({ completedAt: new Date().toISOString() })
    );
  } catch {
    // swallow — worst case we show onboarding next launch
  }
}

function createOnboardingWindow() {
  if (onboardingWin && !onboardingWin.isDestroyed()) {
    onboardingWin.focus();
    return;
  }
  onboardingWin = new BrowserWindow({
    width: 800,
    height: 600,
    center: true,
    resizable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    title: "",
    backgroundColor: "#ffffff",
    // Hide the title bar but keep the native traffic-light controls floating
    // over our white canvas — matches the Figma's clean-white window chrome.
    titleBarStyle: "hiddenInset",
    trafficLightPosition: { x: 14, y: 14 },
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });

  if (isDev) {
    onboardingWin.loadURL(DEV_URL + "/onboarding");
  } else {
    onboardingWin.loadURL("app://-/onboarding/index.html");
  }

  // Block Next.js's <title>Houston</title> from bubbling up to the OS window
  // title — we want the chrome to feel borderless and unlabeled.
  onboardingWin.on("page-title-updated", (e) => e.preventDefault());

  // Show the dock icon while onboarding is open so the user can cmd-tab back
  // to it if they click away. Re-hide on close to return to menubar-only mode.
  if (process.platform === "darwin" && app.dock) {
    app.dock.show().catch(() => {});
  }

  onboardingWin.on("closed", () => {
    // User closed the window any way — count it as done.
    markOnboarded();
    onboardingWin = null;
    if (process.platform === "darwin" && app.dock) {
      app.dock.hide();
    }
  });
}

function createTray() {
  const iconPath = path.join(__dirname, "icons", "tray.png");
  const icon = nativeImage.createFromPath(iconPath);
  // 22pt is the macOS menubar slot height. Resize so the icon fits cleanly.
  const sized = icon.resize({ width: 22, height: 22 });
  tray = new Tray(sized);
  tray.setToolTip("Houston");

  tray.on("click", (_event, bounds) => {
    toggleWindow(bounds);
  });
  tray.on("right-click", () => {
    if (win && win.isVisible()) win.hide();
    const menu = Menu.buildFromTemplate([
      {
        label: "Reload",
        click: () => {
          if (win && !win.isDestroyed()) {
            win.webContents.reloadIgnoringCache();
          }
        },
      },
      {
        label: "Help",
        submenu: [
          {
            label: "Show onboarding",
            click: () => createOnboardingWindow(),
          },
        ],
      },
      { type: "separator" },
      {
        label: "Quit Houston",
        accelerator: "Cmd+Q",
        click: () => {
          app.quit();
        },
      },
    ]);
    tray.popUpContextMenu(menu);
  });
}

// ── IPC handlers ──────────────────────────────────────────────────────────────

const { getDashboardData, getProjectDetail, getSkillDetail } = require("./data");
const { getActiveSessions } = require("./process-detect");
const { getActiveServers } = require("./dev-servers");
const { startMission } = require("./terminal");
const settings = require("./settings");

ipcMain.handle("dashboard:get", async () => {
  return getDashboardData(settings.read(app).projectsDir);
});

ipcMain.handle("sessions:active", async () => {
  return getActiveSessions();
});

ipcMain.handle("project:detail", async (_e, projectPath) => {
  return getProjectDetail(projectPath, settings.read(app).projectsDir);
});

ipcMain.handle("skill:detail", async (_e, skillName) => {
  return getSkillDetail(skillName);
});

ipcMain.handle("shell:openPath", async (_e, p) => {
  if (!p || typeof p !== "string") return { ok: false, error: "missing path" };
  try {
    const err = await shell.openPath(p);
    if (err) return { ok: false, error: err };
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e?.message || e) };
  }
});

ipcMain.handle("shell:openExternal", async (_e, url) => {
  if (!url || typeof url !== "string") return { ok: false, error: "missing url" };
  if (!/^https?:\/\//.test(url)) return { ok: false, error: "url must be http(s)" };
  try {
    await shell.openExternal(url);
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e?.message || e) };
  }
});

ipcMain.handle("servers:active", async () => {
  return getActiveServers(settings.read(app).projectsDir);
});

ipcMain.handle("dialog:pickDirectory", async (_e, payload) => {
  const opts = {
    properties: ["openDirectory", "createDirectory"],
    title: (payload && payload.title) || "Choose a folder",
  };
  if (payload && typeof payload.defaultPath === "string") {
    opts.defaultPath = payload.defaultPath;
  }
  const result = await dialog.showOpenDialog(opts);
  if (result.canceled || result.filePaths.length === 0) {
    return { ok: false, canceled: true };
  }
  return { ok: true, path: result.filePaths[0] };
});

ipcMain.handle("onboarding:complete", () => {
  markOnboarded();
  if (onboardingWin && !onboardingWin.isDestroyed()) {
    onboardingWin.close();
  }
  return { ok: true };
});

ipcMain.handle("servers:kill", async (_e, payload) => {
  const pid = payload && Number(payload.pid);
  if (!Number.isFinite(pid) || pid <= 1) {
    return { ok: false, error: "invalid pid" };
  }
  if (pid === process.pid) {
    return { ok: false, error: "refusing to kill Houston itself" };
  }
  try {
    process.kill(pid, "SIGTERM");
  } catch (e) {
    return { ok: false, error: String(e?.message || e) };
  }
  // Give it a moment, then escalate to SIGKILL if still alive.
  await new Promise((r) => setTimeout(r, 1500));
  try {
    process.kill(pid, 0); // signal 0 = existence check
    try {
      process.kill(pid, "SIGKILL");
    } catch {
      // already gone between the check and the kill
    }
  } catch {
    // ESRCH — process already exited cleanly from SIGTERM
  }
  return { ok: true };
});

ipcMain.handle("window:hide", () => {
  if (win) win.hide();
});

// Per-server cache dirs we know how to clear. Each is resolved relative to
// the server's cwd; missing dirs are silently skipped (force: true).
const SERVER_CACHE_DIRS = [
  ".next/cache",
  "node_modules/.vite",
  "node_modules/.cache",
  ".turbo",
];

// Start `npm run dev` for a project in the background, detached so it survives
// Houston quitting. Output goes to /tmp/<project>-dev.log. We invoke through
// `zsh -lc` so the user's profile-set PATH (NVM, Homebrew, Volta) is available.
ipcMain.handle("dev:start", async (_e, payload) => {
  const projectPath = payload && typeof payload.projectPath === "string" ? payload.projectPath : null;
  if (!projectPath || !path.isAbsolute(projectPath) || projectPath.split(path.sep).length < 3) {
    return { ok: false, error: "invalid projectPath" };
  }
  if (!fs.existsSync(path.join(projectPath, "package.json"))) {
    return { ok: false, error: "no package.json in project" };
  }
  const projectName = path.basename(projectPath);
  const logPath = path.join("/tmp", `${projectName}-dev.log`);
  try {
    const logFd = fs.openSync(logPath, "a");
    const child = spawn("/bin/zsh", ["-lc", "npm run dev"], {
      cwd: projectPath,
      detached: true,
      stdio: ["ignore", logFd, logFd],
    });
    child.unref();
    return { ok: true, pid: child.pid, logPath };
  } catch (e) {
    return { ok: false, error: String(e?.message || e) };
  }
});

ipcMain.handle("servers:clearCache", async (_e, payload) => {
  const cwd = payload && typeof payload.cwd === "string" ? payload.cwd : null;
  if (!cwd || !path.isAbsolute(cwd) || cwd.split(path.sep).length < 3) {
    return { ok: false, error: "invalid cwd" };
  }
  const cleared = [];
  for (const rel of SERVER_CACHE_DIRS) {
    const target = path.resolve(cwd, rel);
    if (!target.startsWith(cwd + path.sep)) continue;
    try {
      const existed = fs.existsSync(target);
      await fs.promises.rm(target, { recursive: true, force: true });
      if (existed) cleared.push(rel);
    } catch (e) {
      return { ok: false, error: `${rel}: ${String(e?.message || e)}` };
    }
  }
  return { ok: true, cleared };
});

ipcMain.handle("mission:start", async (_e, payload) => {
  try {
    const { projectPath, terminal, mode } = payload || {};
    if (!projectPath) return { ok: false, error: "missing projectPath" };
    if (win) win.hide();
    const s = settings.read(app);
    const chosen = terminal || (s.terminals && s.terminals[0]) || "Ghostty";
    const spawnMode = mode === "tab" || mode === "window" ? mode : s.spawnMode || "window";
    return await startMission(projectPath, chosen, spawnMode);
  } catch (e) {
    return { ok: false, error: String(e?.message || e) };
  }
});

// ── Permissions ───────────────────────────────────────────────────────────────
//
// macOS requires two permissions for Houston's mission spawning to work:
//   - Accessibility: needed to issue System Events keystrokes (Cmd+T, typing
//     /start-mission). Without it, osascript calls into System Events silently
//     no-op — Ghostty focuses but nothing else happens.
//   - Automation (per target app): needed to send Apple Events to a specific
//     terminal app. macOS scopes Automation grants per (caller bundle, target
//     bundle) pair. We probe with a benign `get name`; first call triggers the
//     macOS prompt, subsequent denials throw with errAEEventNotPermitted (-1743).
//
// Neither permission can be granted programmatically. We can only (a) trigger
// the native prompt the first time, and (b) deep-link to System Settings if the
// user already denied.

// Probe Automation by sending a no-op Apple Event. Returns true if granted,
// false if denied/prompted-and-canceled. Note: on a truly first ask, macOS
// shows the prompt and the call blocks briefly until the user picks.
async function probeAutomation(targetApp) {
  try {
    await execFileP("osascript", ["-e", `tell application "${targetApp}" to get name`]);
    return true;
  } catch {
    return false;
  }
}

ipcMain.handle("permissions:check", async (_e, payload) => {
  const terminals = Array.isArray(payload?.terminals) ? payload.terminals : [];
  const accessibility = systemPreferences.isTrustedAccessibilityClient(false);
  const automation = {};
  for (const t of terminals) {
    automation[t] = await probeAutomation(t);
  }
  const s = settings.read(app);
  return {
    accessibility,
    automation,
    permissionsRequestedAt: s.permissionsRequestedAt ?? null,
  };
});

// "Allow permissions" CTA. Behavior depends on prior state:
//   - First call (permissionsRequestedAt == null): trigger native prompts for
//     Accessibility and Automation (one per selected terminal), then mark
//     requestedAt so future calls take the deep-link path.
//   - Subsequent calls with anything still missing: deep-link to System
//     Settings. We open Accessibility first (more common), then Automation
//     if any terminals are missing.
ipcMain.handle("permissions:request", async (_e, payload) => {
  const terminals = Array.isArray(payload?.terminals) ? payload.terminals : [];
  const s = settings.read(app);
  const firstAsk = s.permissionsRequestedAt == null;

  if (firstAsk) {
    // isTrustedAccessibilityClient(true) shows the native prompt (with an
    // "Open System Settings" button) if not already granted. It's
    // non-blocking — returns the current grant state immediately.
    systemPreferences.isTrustedAccessibilityClient(true);
    // Trigger Automation prompts. Each probe blocks until the user dismisses
    // the prompt. We do them in parallel so the prompts queue up rather than
    // forcing one-at-a-time interaction.
    await Promise.all(terminals.map((t) => probeAutomation(t)));
    settings.write(app, { permissionsRequestedAt: Date.now() });
  } else {
    // Re-check state. If anything is still missing, deep-link to Settings.
    const accessibility = systemPreferences.isTrustedAccessibilityClient(false);
    const automation = {};
    for (const t of terminals) automation[t] = await probeAutomation(t);
    const anyAutomationMissing = Object.values(automation).some((v) => !v);
    if (!accessibility) {
      await shell.openExternal(
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
      );
    } else if (anyAutomationMissing) {
      await shell.openExternal(
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
      );
    }
  }

  // Always return a fresh state.
  const accessibility = systemPreferences.isTrustedAccessibilityClient(false);
  const automation = {};
  for (const t of terminals) automation[t] = await probeAutomation(t);
  return {
    accessibility,
    automation,
    firstAsk,
    permissionsRequestedAt: settings.read(app).permissionsRequestedAt ?? null,
  };
});

ipcMain.handle("permissions:openSettings", async (_e, pane) => {
  const target =
    pane === "automation"
      ? "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
      : "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility";
  try {
    await shell.openExternal(target);
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e?.message || e) };
  }
});

ipcMain.handle("settings:get", () => settings.read(app));

ipcMain.handle("terminal:status", () => settings.getInstalledTerminals());

ipcMain.handle("settings:set", (_e, patch) => {
  try {
    if (!patch || typeof patch !== "object") {
      return { ok: false, error: "invalid patch" };
    }
    const next = settings.write(app, patch);
    return { ok: true, settings: next };
  } catch (e) {
    return { ok: false, error: String(e?.message || e) };
  }
});

// ── App lifecycle ─────────────────────────────────────────────────────────────

app.whenReady().then(() => {
  protocol.handle("app", (request) => {
    const url = new URL(request.url);
    let pathname = decodeURIComponent(url.pathname);
    if (!pathname || pathname === "/") pathname = "/index.html";
    const filePath = path.join(PROD_OUT_DIR, pathname);
    return net.fetch(pathToFileURL(filePath).toString());
  });

  if (process.platform === "darwin" && app.dock) {
    app.dock.hide();
  }
  createWindow();
  createTray();
  if (!hasOnboarded()) {
    createOnboardingWindow();
  }
});

app.on("window-all-closed", (e) => {
  // Don't quit when the popover closes — this is a menubar app.
  e.preventDefault();
});
