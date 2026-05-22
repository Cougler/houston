const fs = require("node:fs");
const path = require("node:path");

const HOME = process.env.HOME || "";
const CLAUDE_JSON = path.join(HOME, ".claude.json");
const SKILLS_DIR = path.join(HOME, ".claude", "skills");
const DEFAULT_APPS_DIR = path.join(HOME, "Apps");

function toDisplay(p) {
  return p.replace(HOME, "~");
}

function readJSON(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf-8"));
  } catch {
    return {};
  }
}

function getMCPServers() {
  const data = readJSON(CLAUDE_JSON);
  const servers = data.mcpServers || {};
  return Object.entries(servers).map(([name, cfg]) => {
    const type = cfg.type || "stdio";
    let endpoint = "";
    if (type === "stdio") {
      const cmd = cfg.command || "";
      endpoint = cmd.includes("Pencil.app") ? "Pencil Desktop App" : path.basename(cmd) || "local";
    } else {
      endpoint = (cfg.url || "").replace(/^https?:\/\//, "");
    }
    return { name, type, endpoint };
  });
}

function getSkills() {
  if (!fs.existsSync(SKILLS_DIR)) return [];
  const skills = [];
  for (const dir of fs.readdirSync(SKILLS_DIR)) {
    const skillMd = path.join(SKILLS_DIR, dir, "SKILL.md");
    if (!fs.existsSync(skillMd)) continue;
    let name = dir;
    let description = "";
    let added = "";
    try {
      const content = fs.readFileSync(skillMd, "utf-8");
      const fm = content.match(/^---\n([\s\S]*?)\n---/);
      if (fm) {
        const nameM = fm[1].match(/^name:\s*(.+)$/m);
        const descM = fm[1].match(/^description:\s*(.+)$/m);
        if (nameM) name = nameM[1].trim();
        if (descM) {
          const d = descM[1].trim();
          description = d.length > 120 ? d.slice(0, 120) + "…" : d;
        }
      }
      added = new Date(fs.statSync(skillMd).mtimeMs).toISOString().slice(0, 10);
    } catch {
      // skip
    }
    skills.push({ name, invoke: `/${dir}`, description, added });
  }
  return skills.sort((a, b) => a.name.localeCompare(b.name));
}

const ICON_MAX_BYTES = 512 * 1024; // skip anything bigger than 512KB
const ICON_CANDIDATES = [
  // project-level explicit
  "icon.png",
  "icon.svg",
  "logo.png",
  "logo.svg",
  // electron / build outputs
  "electron/icons/icon.png",
  "electron/icons/tray.png",
  "build/icon.png",
  // Next.js conventions
  "app/icon.png",
  "app/icon.svg",
  "app/apple-icon.png",
  "app/favicon.ico",
  // CRA / Vite public dirs
  "public/icon.png",
  "public/icon.svg",
  "public/logo.png",
  "public/logo.svg",
  "public/favicon.svg",
  "public/favicon.png",
  "public/favicon.ico",
  "public/apple-touch-icon.png",
  // misc
  "assets/icon.png",
  "assets/logo.png",
];

const MIME_BY_EXT = {
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
};

const iconCache = new Map(); // path -> { mtimeMs, size, dataUrl }

function readIconDataUrl(filePath) {
  let stat;
  try {
    stat = fs.statSync(filePath);
  } catch {
    return null;
  }
  if (!stat.isFile() || stat.size === 0 || stat.size > ICON_MAX_BYTES) return null;
  const cached = iconCache.get(filePath);
  if (cached && cached.mtimeMs === stat.mtimeMs && cached.size === stat.size) {
    return cached.dataUrl;
  }
  const ext = path.extname(filePath).toLowerCase();
  const mime = MIME_BY_EXT[ext];
  if (!mime) return null;
  let buf;
  try {
    buf = fs.readFileSync(filePath);
  } catch {
    return null;
  }
  const dataUrl =
    ext === ".svg"
      ? `data:${mime};utf8,${encodeURIComponent(buf.toString("utf-8"))}`
      : `data:${mime};base64,${buf.toString("base64")}`;
  iconCache.set(filePath, { mtimeMs: stat.mtimeMs, size: stat.size, dataUrl });
  return dataUrl;
}

function findProjectIcon(projectPath) {
  for (const rel of ICON_CANDIDATES) {
    const full = path.join(projectPath, rel);
    const url = readIconDataUrl(full);
    if (url) return url;
  }
  return null;
}

function latestLogTimestamp(logPath) {
  try {
    const text = fs.readFileSync(logPath, "utf-8");
    const dates = [...text.matchAll(/^##\s+(\d{4}-\d{2}-\d{2})\b/gm)].map((m) => m[1]);
    if (dates.length === 0) return 0;
    dates.sort();
    // Treat the entry date as end-of-day UTC so a same-day file mtime never wins by a few hours.
    return new Date(`${dates[dates.length - 1]}T23:59:59Z`).getTime();
  } catch {
    return 0;
  }
}

function safeMtime(p) {
  try {
    return fs.statSync(p).mtimeMs;
  } catch {
    return 0;
  }
}

function getProjects(projectsDir = DEFAULT_APPS_DIR) {
  if (!fs.existsSync(projectsDir)) return [];
  const projects = fs
    .readdirSync(projectsDir)
    .filter((name) => {
      if (name.startsWith(".")) return false;
      try {
        return fs.statSync(path.join(projectsDir, name)).isDirectory();
      } catch {
        return false;
      }
    })
    .map((name) => {
      const projectPath = path.join(projectsDir, name);
      const mcFile = path.join(projectPath, ".mc.json");
      const logFile = path.join(projectPath, "missionlog.md");
      let description = "";
      let status = "";
      let stack = [];
      let notes = "";
      let url = "";
      try {
        const meta = JSON.parse(fs.readFileSync(mcFile, "utf-8"));
        description = meta.description || "";
        status = meta.status || "";
        stack = meta.stack || [];
        notes = meta.notes || "";
        url = meta.url || "";
      } catch {
        // no metadata
      }
      const lastUsedMs = Math.max(
        latestLogTimestamp(logFile),
        safeMtime(mcFile),
        safeMtime(projectPath)
      );
      return {
        name,
        path: projectPath,
        display: toDisplay(projectPath),
        description,
        status,
        stack,
        notes,
        url,
        lastUsed: lastUsedMs > 0 ? new Date(lastUsedMs).toISOString() : null,
        icon: findProjectIcon(projectPath),
      };
    });
  // Most recently used first; alphabetical tiebreaker so the order is stable.
  projects.sort((a, b) => {
    const ta = a.lastUsed ? new Date(a.lastUsed).getTime() : 0;
    const tb = b.lastUsed ? new Date(b.lastUsed).getTime() : 0;
    if (tb !== ta) return tb - ta;
    return a.name.localeCompare(b.name);
  });
  return projects;
}

function getDashboardData(projectsDir = DEFAULT_APPS_DIR) {
  return {
    lastUpdated: new Date().toISOString(),
    projectsDir,
    mcpServers: getMCPServers(),
    skills: getSkills(),
    projects: getProjects(projectsDir),
  };
}

function extractBullets(body, sectionLabel) {
  const escaped = sectionLabel.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re = new RegExp(`\\*\\*${escaped}:?\\*\\*\\s*\\n([\\s\\S]*?)(?=\\n\\*\\*|$)`, "i");
  const m = body.match(re);
  if (!m) return [];
  return m[1]
    .split("\n")
    .map((line) => line.replace(/^[-*]\s+/, "").trim())
    .filter((line) => line.length > 0);
}

function extractSummary(body) {
  // Summary is the leading paragraph(s) before the first **Section:** marker.
  const idx = body.search(/\n\*\*[^*]+\*\*/);
  const head = idx === -1 ? body : body.slice(0, idx);
  return head.trim();
}

function parseMissionLog(filePath) {
  if (!fs.existsSync(filePath)) return [];
  let text;
  try {
    text = fs.readFileSync(filePath, "utf-8");
  } catch {
    return [];
  }
  const sections = text.split(/\n(?=## )/);
  const entries = [];
  for (const section of sections) {
    if (!section.startsWith("## ")) continue;
    const lines = section.split("\n");
    const header = lines[0].replace(/^## /, "").trim();
    const m = header.match(/^(\d{4}-\d{2}-\d{2})\s*[—–-]\s*(.+)$/);
    if (!m) continue;
    const date = m[1];
    const title = m[2].trim();
    let body = lines.slice(1).join("\n").trim();
    // Strip trailing horizontal rule that separates entries
    body = body.replace(/\n*---\s*$/, "").trim();
    entries.push({
      date,
      title,
      summary: extractSummary(body),
      done: extractBullets(body, "Done this session"),
      upNext: extractBullets(body, "Up next"),
    });
  }
  // Newest first
  entries.sort((a, b) => b.date.localeCompare(a.date));
  return entries;
}

function parseSkillSteps(body) {
  const re = /^###\s+(\d+)\.\s+(.+?)\s*$/gm;
  const matches = [];
  let m;
  while ((m = re.exec(body)) !== null) {
    matches.push({ number: parseInt(m[1], 10), title: m[2].trim(), start: m.index, end: re.lastIndex });
  }
  const steps = [];
  for (let i = 0; i < matches.length; i++) {
    const cur = matches[i];
    const sliceStart = cur.end;
    const sliceEnd = i + 1 < matches.length ? matches[i + 1].start : body.length;
    const raw = body.slice(sliceStart, sliceEnd).trim();
    // Stop at the next ## heading (end of Steps section).
    const nextSection = raw.match(/^##\s+/m);
    const stepBody = nextSection ? raw.slice(0, nextSection.index).trim() : raw;
    // Use only the first line/sentence of prose so the timeline stays scannable.
    // Skip leading blank lines, then take everything up to a blank line or a
    // bullet/code marker — whichever comes first.
    const lines = stepBody.split("\n");
    const firstProseLines = [];
    for (const line of lines) {
      const t = line.trim();
      if (!t) {
        if (firstProseLines.length > 0) break;
        continue;
      }
      if (t.startsWith("- ") || t.startsWith("* ") || t.startsWith("```") || /^\d+\.\s/.test(t) || t.startsWith("#")) {
        if (firstProseLines.length > 0) break;
        continue;
      }
      firstProseLines.push(t);
      if (firstProseLines.join(" ").length > 200) break;
    }
    const summary = firstProseLines.join(" ").trim();
    steps.push({ number: cur.number, title: cur.title, body: summary });
  }
  return steps;
}

function getSkillDetail(skillName) {
  if (!skillName || typeof skillName !== "string") return null;
  // Guard against path traversal — only accept simple folder names.
  if (skillName.includes("/") || skillName.includes("..")) return null;
  const skillMd = path.join(SKILLS_DIR, skillName, "SKILL.md");
  if (!fs.existsSync(skillMd)) return null;
  let content;
  try {
    content = fs.readFileSync(skillMd, "utf-8");
  } catch {
    return null;
  }

  let displayName = skillName;
  let description = "";
  const fm = content.match(/^---\n([\s\S]*?)\n---/);
  let bodyAfterFm = content;
  if (fm) {
    const nameMatch = fm[1].match(/^name:\s*(.+)$/m);
    const descMatch = fm[1].match(/^description:\s*(.+)$/m);
    if (nameMatch) displayName = nameMatch[1].trim();
    if (descMatch) description = descMatch[1].trim();
    bodyAfterFm = content.slice(fm[0].length);
  }

  // Intro = the prose between the first H1 and the next H2.
  let intro = "";
  const h1Match = bodyAfterFm.match(/^#\s+.+$/m);
  if (h1Match && typeof h1Match.index === "number") {
    const afterH1 = bodyAfterFm.slice(h1Match.index + h1Match[0].length);
    const nextH2Match = afterH1.match(/^##\s/m);
    const slice =
      nextH2Match && typeof nextH2Match.index === "number"
        ? afterH1.slice(0, nextH2Match.index)
        : afterH1;
    intro = slice
      .split(/\n\s*\n/)
      .map((p) => p.trim())
      .filter(Boolean)
      .join("\n\n");
  }

  return {
    name: displayName,
    invoke: `/${skillName}`,
    description,
    intro,
    steps: parseSkillSteps(bodyAfterFm),
  };
}

function getProjectDetail(projectPath, projectsDir) {
  if (!projectPath) return null;
  const projects = getProjects(projectsDir);
  const project = projects.find((p) => p.path === projectPath);
  if (!project) return null;
  const logPath = path.join(projectPath, "missionlog.md");
  const entries = parseMissionLog(logPath);
  return {
    project,
    entries,
    stats: {
      sessionCount: entries.length,
      lastSessionDate: entries[0]?.date ?? null,
      firstSessionDate: entries[entries.length - 1]?.date ?? null,
    },
  };
}

module.exports = { getDashboardData, getProjects, getSkills, getMCPServers, getProjectDetail, getSkillDetail };
