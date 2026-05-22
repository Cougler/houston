import type { DashboardData, ActiveSession, InjectResult, ProjectDetail, DevServer, SkillDetail } from "@/lib/types";

declare global {
  interface Window {
    mc: {
      getDashboard: () => Promise<DashboardData>;
      getActiveSessions: () => Promise<ActiveSession[]>;
      getProjectDetail: (projectPath: string) => Promise<ProjectDetail | null>;
      getSkillDetail: (skillName: string) => Promise<SkillDetail | null>;
      getActiveServers: () => Promise<DevServer[]>;
      killServer: (pid: number) => Promise<InjectResult>;
      completeOnboarding: () => Promise<InjectResult>;
      openPath: (p: string) => Promise<InjectResult>;
      openExternal: (url: string) => Promise<InjectResult>;
      hide: () => Promise<void>;
      clearServerCache: (cwd: string) => Promise<{ ok: boolean; cleared?: string[]; error?: string }>;
      startDevServer: (projectPath: string) => Promise<{ ok: boolean; pid?: number; logPath?: string; error?: string }>;
      getSettings: () => Promise<{ terminal: string; projectsDir: string; spawnMode: "tab" | "window" }>;
      setSettings: (
        patch: Partial<{ terminal: string; projectsDir: string; spawnMode: "tab" | "window" }>
      ) => Promise<{
        ok: boolean;
        settings?: { terminal: string; projectsDir: string; spawnMode: "tab" | "window" };
        error?: string;
      }>;
      getTerminalStatus: () => Promise<{ Ghostty: boolean; Terminal: boolean; iTerm2: boolean }>;
      pickDirectory: (opts?: { defaultPath?: string; title?: string }) => Promise<{ ok: boolean; path?: string; canceled?: boolean }>;
      startMission: (
        projectPath: string,
        terminal?: string,
        mode?: "tab" | "window"
      ) => Promise<InjectResult>;
    };
  }
}

export {};
