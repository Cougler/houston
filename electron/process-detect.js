const { execSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const HOME = process.env.HOME || "";
const PROJECTS_DIR = path.join(HOME, ".claude", "projects");
const SESSIONS_DIR = path.join(HOME, ".claude", "sessions");

// Conservative default context window. Refined per-session when we can read
// the model from the JSONL (Opus 1M = 1,000,000; default = 200,000).
const CONTEXT_WINDOWS = {
  default: 200_000,
  opus1m: 1_000_000,
};

// Tolerance: a JSONL must have been created within N ms of the PID's start
// time to be considered "this PID's session." Claude writes the JSONL within
// the first second or two of startup, so 30s is generous.
const SESSION_MATCH_TOLERANCE_MS = 30_000;

function safeExec(cmd) {
  try {
    return execSync(cmd, { encoding: "utf-8", stdio: ["ignore", "pipe", "ignore"] });
  } catch {
    return "";
  }
}

// Claude encodes a cwd into a directory name by replacing every "/" with "-".
// e.g. "/Users/aaroncougle" -> "-Users-aaroncougle"
function encodeCwd(cwd) {
  if (!cwd) return null;
  return cwd.replace(/\//g, "-");
}

// `ps -o lstart=` outputs e.g. "Tue May 11 14:47:32 2026" — parse to epoch ms.
function parsePsTime(str) {
  if (!str) return null;
  const ms = Date.parse(str.trim());
  return Number.isFinite(ms) ? ms : null;
}

// Single ps call gives us all running processes; index by pid for parent walks.
function snapshotProcesses() {
  const raw = safeExec("ps -axo pid=,ppid=,lstart=,command=");
  const map = new Map();
  for (const line of raw.split("\n")) {
    // lstart is 5 whitespace-separated tokens: "Tue May 11 14:47:32 2026"
    const m = line.match(/^\s*(\d+)\s+(\d+)\s+(\S+\s+\S+\s+\S+\s+\S+\s+\S+)\s+(.+)$/);
    if (!m) continue;
    const pid = Number(m[1]);
    map.set(pid, {
      pid,
      ppid: Number(m[2]),
      startMs: parsePsTime(m[3]),
      command: m[4].trim(),
    });
  }
  return map;
}

function isClaudeCmd(cmd) {
  const exe = cmd.split(/\s+/)[0];
  return path.basename(exe) === "claude";
}

// Top-level `claude` processes only — skip child claudes (subagents, helpers).
function listClaudeProcesses(procs) {
  const all = Array.from(procs.values()).filter((p) => isClaudeCmd(p.command));
  return all.filter((p) => {
    const parent = procs.get(p.ppid);
    return !parent || !isClaudeCmd(parent.command);
  });
}

function getPidCwd(pid) {
  const raw = safeExec(`lsof -a -p ${pid} -d cwd -Fn 2>/dev/null`);
  for (const line of raw.split("\n")) {
    if (line.startsWith("n")) return line.slice(1);
  }
  return null;
}

function getPidTty(pid) {
  const raw = safeExec(`ps -o tty= -p ${pid}`).trim();
  if (!raw || raw === "?") return null;
  return raw.startsWith("/dev/") ? raw : `/dev/${raw}`;
}

// Stat birth time in epoch seconds (macOS-specific format flag).
function fileBirthMs(filePath) {
  try {
    const stat = fs.statSync(filePath);
    // birthtimeMs is supported on macOS APFS.
    return stat.birthtimeMs || stat.ctimeMs;
  } catch {
    return null;
  }
}

function fileMtimeMs(filePath) {
  try {
    return fs.statSync(filePath).mtimeMs;
  } catch {
    return null;
  }
}

// Claude Code writes ~/.claude/sessions/<pid>.json for each interactive
// session at startup. When present, this gives us a definitive sessionId +
// cwd mapping without any guessing.
function readSessionFile(pid) {
  const filePath = path.join(SESSIONS_DIR, `${pid}.json`);
  try {
    const raw = fs.readFileSync(filePath, "utf-8");
    const obj = JSON.parse(raw);
    if (obj && obj.sessionId && obj.cwd) return obj;
  } catch {
    // file missing or unparseable — caller will fall back
  }
  return null;
}

// Find the JSONL that belongs to this specific PID. Claude writes
// ~/.claude/sessions/<pid>.json on startup with a sessionId, but does NOT
// update it when /clear creates a new session — so trusting that sessionId
// gives stale context readings. The active JSONL is whichever one in the
// project's encoded-cwd dir is being appended to right now (latest mtime).
function findJsonlForPid(pid, cwd, startMs) {
  const session = readSessionFile(pid);
  const targetCwd = session?.cwd || cwd;
  if (!targetCwd) return null;
  const dirName = encodeCwd(targetCwd);
  if (!dirName) return null;
  const dirPath = path.join(PROJECTS_DIR, dirName);
  if (!fs.existsSync(dirPath)) return null;

  const candidates = [];
  for (const entry of fs.readdirSync(dirPath)) {
    if (!entry.endsWith(".jsonl")) continue;
    const filePath = path.join(dirPath, entry);
    const sessionId = path.basename(entry, ".jsonl");
    const mtime = fileMtimeMs(filePath);
    const birth = fileBirthMs(filePath);
    if (mtime == null) continue;
    candidates.push({ filePath, sessionId, mtime, birth });
  }
  if (candidates.length === 0) return null;

  candidates.sort((a, b) => b.mtime - a.mtime);
  const latest = candidates[0];

  // Prefer the latest-mtime JSONL when it's been touched during this PID's
  // lifetime — that's the one Claude is actively appending to (post-/clear
  // or otherwise). Guard with startMs so we don't grab a stale JSONL from a
  // previous claude in the same cwd.
  if (startMs && latest.mtime >= startMs) return latest.filePath;

  // No mtime is recent enough — fall back to whatever the session file points
  // at (could be a brand-new session that hasn't written its first turn yet).
  if (session?.sessionId) {
    const fromSession = candidates.find((c) => c.sessionId === session.sessionId);
    if (fromSession) return fromSession.filePath;
  }

  // Last resort: birth-time correlation with this PID's start, for older
  // claude versions that didn't write session files.
  if (!startMs) return null;
  let bestPath = null;
  let bestDelta = Infinity;
  for (const c of candidates) {
    if (!c.birth) continue;
    const delta = Math.abs(c.birth - startMs);
    if (delta < bestDelta) {
      bestDelta = delta;
      bestPath = c.filePath;
    }
  }
  if (bestDelta > SESSION_MATCH_TOLERANCE_MS) return null;
  return bestPath;
}

// Single pass over a JSONL: pull the latest usage block AND the first real
// user message (so we can disambiguate sessions that share a cwd).
function readSessionSummary(jsonlPath) {
  let raw;
  try {
    raw = fs.readFileSync(jsonlPath, "utf-8");
  } catch {
    return null;
  }
  const lines = raw.split("\n");
  let usage = null;
  let firstUserMessage = null;

  // Forward pass: find first user message (typically near the top of the file).
  for (const line of lines) {
    if (!line || firstUserMessage) break;
    try {
      const obj = JSON.parse(line);
      if (obj?.type !== "user") continue;
      const content = obj?.message?.content;
      let text = null;
      if (typeof content === "string") {
        text = content;
      } else if (Array.isArray(content)) {
        const block = content.find((c) => c?.type === "text" && typeof c.text === "string");
        if (block) text = block.text;
      }
      if (text && text.trim()) {
        // Skip system-injected reminders that start with tags
        const trimmed = text.trim();
        if (!trimmed.startsWith("<")) {
          firstUserMessage = trimmed;
        }
      }
    } catch {
      // skip
    }
  }

  // Reverse pass: find the latest assistant message with usage data.
  for (let i = lines.length - 1; i >= 0; i--) {
    if (!lines[i]) continue;
    try {
      const obj = JSON.parse(lines[i]);
      const u = obj?.message?.usage;
      if (!u) continue;
      const input = u.input_tokens || 0;
      const cacheRead = u.cache_read_input_tokens || 0;
      const cacheCreate = u.cache_creation_input_tokens || 0;
      const output = u.output_tokens || 0;
      usage = {
        contextSize: input + cacheRead + cacheCreate,
        outputTokens: output,
        model: obj?.message?.model || null,
        timestamp: obj?.timestamp || null,
      };
      break;
    } catch {
      // skip
    }
  }

  return { usage, firstUserMessage };
}

function projectNameFromCwd(cwd) {
  if (!cwd) return "(unknown)";
  if (cwd === "/") return "(root)";
  if (cwd === HOME) return "~";
  return path.basename(cwd) || "(root)";
}

function contextWindowFor(model) {
  if (!model) return CONTEXT_WINDOWS.default;
  // Opus 4.x with 1M context — model id varies, match liberally.
  if (/opus.*-4-7|opus.*\[1m\]|opus.*4-7\[1m\]/.test(model)) return CONTEXT_WINDOWS.opus1m;
  return CONTEXT_WINDOWS.default;
}

// Walk parent process tree until we hit a known terminal emulator.
const TERMINALS = {
  ghostty: "Ghostty",
  Ghostty: "Ghostty",
  Terminal: "Terminal",
  iTerm2: "iTerm2",
  "iTerm.app": "iTerm2",
  WarpTerminal: "Warp",
  alacritty: "Alacritty",
  kitty: "kitty",
  Code: "VSCode",
  "Code Helper": "VSCode",
  Cursor: "Cursor",
  "tmux: server": "tmux",
  tmux: "tmux",
};

function identifyTerminal(pid, procs) {
  let current = procs.get(pid);
  let hops = 0;
  while (current && hops < 12) {
    const exe = path.basename(current.command.split(/\s+/)[0]);
    if (TERMINALS[exe]) return TERMINALS[exe];
    for (const [needle, label] of Object.entries(TERMINALS)) {
      if (current.command.includes(needle)) return label;
    }
    current = procs.get(current.ppid);
    hops++;
  }
  return "unknown";
}

function getActiveSessions() {
  const procs = snapshotProcesses();
  const claudes = listClaudeProcesses(procs);

  const sessions = claudes.map((p) => {
    const sessionFile = readSessionFile(p.pid);
    const cwd = sessionFile?.cwd || getPidCwd(p.pid);
    const jsonl = findJsonlForPid(p.pid, cwd, p.startMs);
    const summary = jsonl ? readSessionSummary(jsonl) : null;
    const usage = summary?.usage || null;
    const sessionId = sessionFile?.sessionId || (jsonl ? path.basename(jsonl, ".jsonl") : null);
    const window = contextWindowFor(usage?.model);
    // Include output_tokens of the latest turn — those become cache_read on
    // the next turn so they're part of the upcoming context.
    const baseContext = usage?.contextSize || 0;
    const recentOutput = usage?.outputTokens || 0;
    const contextSize = baseContext + recentOutput;
    const pct = window > 0 ? Math.min(100, Math.round((contextSize / window) * 100)) : 0;
    const mtime = jsonl ? fileMtimeMs(jsonl) : null;
    return {
      pid: p.pid,
      sessionId,
      jsonl,
      cwd,
      tty: getPidTty(p.pid),
      project: projectNameFromCwd(cwd),
      firstUserMessage: summary?.firstUserMessage || null,
      model: usage?.model || null,
      contextSize,
      contextWindow: window,
      contextPct: pct,
      terminal: identifyTerminal(p.pid, procs),
      lastActivity: usage?.timestamp || (mtime ? new Date(mtime).toISOString() : null),
      startedAt: p.startMs ? new Date(p.startMs).toISOString() : null,
    };
  });

  // Sort hottest first (most recent activity).
  return sessions.sort((a, b) => {
    const ta = a.lastActivity ? new Date(a.lastActivity).getTime() : 0;
    const tb = b.lastActivity ? new Date(b.lastActivity).getTime() : 0;
    return tb - ta;
  });
}

module.exports = {
  getActiveSessions,
  listClaudeProcesses: () => listClaudeProcesses(snapshotProcesses()),
  identifyTerminal: (pid) => identifyTerminal(pid, snapshotProcesses()),
};
