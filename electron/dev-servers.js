const { execFileSync } = require("node:child_process");
const path = require("node:path");

const HOME = process.env.HOME || "";
const DEFAULT_APPS_DIR = path.join(HOME, "Apps");

const MIN_PORT = 3000;
const MAX_PORT = 9999;

// macOS background services that happen to bind dev-range ports (AirPlay Receiver
// on 5000/7000, Continuity, etc.) — exclude so they don't pollute the list.
const SYSTEM_COMMANDS = new Set([
  "ControlCenter",
  "mDNSResponder",
  "rapportd",
  "sharingd",
  "AirPlayXPCH",
  "remoted",
  "identityservicesd",
]);

function getListenSockets() {
  let out;
  try {
    out = execFileSync(
      "lsof",
      ["-iTCP", "-sTCP:LISTEN", "-P", "-n", "+c", "0"],
      { encoding: "utf-8" }
    );
  } catch {
    return [];
  }
  const lines = out.split("\n");
  if (lines.length <= 1) return [];
  const rows = [];
  for (const line of lines.slice(1)) {
    if (!line.trim()) continue;
    // COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
    // NAME is the last field. With +c 0, COMMAND may contain no spaces.
    const parts = line.split(/\s+/);
    if (parts.length < 9) continue;
    const command = parts[0];
    const pid = parseInt(parts[1], 10);
    if (!Number.isFinite(pid)) continue;
    // NAME might be "host:port (LISTEN)" — split off the (LISTEN) suffix.
    const nameIdx = parts.findIndex((p, i) => i >= 8 && /:(\d+)$/.test(p));
    if (nameIdx === -1) continue;
    const name = parts[nameIdx];
    const m = name.match(/:(\d+)$/);
    if (!m) continue;
    const port = parseInt(m[1], 10);
    if (!Number.isFinite(port) || port < MIN_PORT || port > MAX_PORT) continue;
    if (SYSTEM_COMMANDS.has(command)) continue;
    rows.push({ command, pid, port });
  }
  return rows;
}

const cwdCache = new Map();
function getCwd(pid) {
  if (cwdCache.has(pid)) return cwdCache.get(pid);
  let cwd = null;
  try {
    const out = execFileSync(
      "lsof",
      ["-a", "-p", String(pid), "-d", "cwd", "-Fn"],
      { encoding: "utf-8" }
    );
    for (const line of out.split("\n")) {
      if (line.startsWith("n")) {
        cwd = line.slice(1);
        break;
      }
    }
  } catch {
    // process gone or permission denied
  }
  cwdCache.set(pid, cwd);
  return cwd;
}

function projectFromCwd(cwd, appsDir) {
  if (!cwd) return null;
  if (!cwd.startsWith(appsDir + path.sep) && cwd !== appsDir) return null;
  const rel = cwd.slice(appsDir.length + 1);
  if (!rel) return null;
  return rel.split(path.sep)[0] || null;
}

function getActiveServers(projectsDir = DEFAULT_APPS_DIR) {
  // Refresh cwd cache each call so killed PIDs don't leak stale cwds.
  cwdCache.clear();
  const selfCwd = process.cwd();
  const rows = getListenSockets();
  const seen = new Set();
  const servers = [];
  for (const r of rows) {
    const key = `${r.pid}:${r.port}`;
    if (seen.has(key)) continue;
    seen.add(key);
    const cwd = getCwd(r.pid);
    servers.push({
      pid: r.pid,
      port: r.port,
      command: r.command,
      cwd,
      project: projectFromCwd(cwd, projectsDir),
      url: `http://localhost:${r.port}`,
      isSelf: !!cwd && cwd === selfCwd,
    });
  }
  // Project-matched first, then by port asc; ties by pid for stability.
  servers.sort((a, b) => {
    const ap = a.project ? 0 : 1;
    const bp = b.project ? 0 : 1;
    if (ap !== bp) return ap - bp;
    if (a.port !== b.port) return a.port - b.port;
    return a.pid - b.pid;
  });
  return servers;
}

module.exports = { getActiveServers };
