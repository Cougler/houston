import type { DashboardData, ActiveSession, InjectResult, ProjectDetail, DevServer, SkillDetail } from "@/lib/types";

type HoustonSettings = {
  terminals: string[];
  projectsDir: string;
  spawnMode: "tab" | "window";
  permissionsRequestedAt: number | null;
};

type PermissionsSnapshot = {
  accessibility: boolean;
  automation: Record<string, boolean>;
  permissionsRequestedAt: number | null;
};

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
      getSettings: () => Promise<HoustonSettings>;
      setSettings: (
        patch: Partial<HoustonSettings>
      ) => Promise<{
        ok: boolean;
        settings?: HoustonSettings;
        error?: string;
      }>;
      getTerminalStatus: () => Promise<{ Ghostty: boolean; Terminal: boolean; iTerm2: boolean }>;
      pickDirectory: (opts?: { defaultPath?: string; title?: string }) => Promise<{ ok: boolean; path?: string; canceled?: boolean }>;
      startMission: (
        projectPath: string,
        terminal?: string,
        mode?: "tab" | "window"
      ) => Promise<InjectResult>;
      checkPermissions: (terminals: string[]) => Promise<PermissionsSnapshot>;
      requestPermissions: (terminals: string[]) => Promise<PermissionsSnapshot & { firstAsk?: boolean }>;
      openPermissionsSettings: (pane: "accessibility" | "automation") => Promise<InjectResult>;
    };
  }
}

export {};
