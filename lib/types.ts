export interface MCPServer {
  name: string;
  type: string;
  endpoint: string;
}

export interface Skill {
  name: string;
  invoke: string;
  description: string;
  added: string;
}

export interface Project {
  name: string;
  path: string;
  display: string;
  description: string;
  status: string;
  stack: string[];
  notes: string;
  url: string;
  lastUsed: string | null;
  icon: string | null;
}

export interface DashboardData {
  lastUpdated: string;
  projectsDir: string;
  mcpServers: MCPServer[];
  skills: Skill[];
  projects: Project[];
}

export interface ActiveSession {
  pid: number;
  sessionId: string | null;
  jsonl: string | null;
  cwd: string | null;
  tty: string | null;
  project: string;
  firstUserMessage: string | null;
  model: string | null;
  contextSize: number;
  contextWindow: number;
  contextPct: number;
  terminal: string;
  lastActivity: string | null;
  startedAt: string | null;
}

export type MissionAction = "start" | "log" | "end";

export interface InjectResult {
  ok: boolean;
  error?: string;
  fallbackUsed?: boolean;
}

export interface MissionLogEntry {
  date: string;
  title: string;
  summary: string;
  done: string[];
  upNext: string[];
}

export interface ProjectStats {
  sessionCount: number;
  lastSessionDate: string | null;
  firstSessionDate: string | null;
}

export interface ProjectDetail {
  project: Project;
  entries: MissionLogEntry[];
  stats: ProjectStats;
}

export interface SkillStep {
  number: number;
  title: string;
  body: string;
}

export interface SkillDetail {
  name: string;
  invoke: string;
  description: string;
  intro: string;
  steps: SkillStep[];
}

export interface DevServer {
  pid: number;
  port: number;
  command: string;
  cwd: string | null;
  project: string | null;
  url: string;
  isSelf: boolean;
}
