"use client";

import {
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  useCallback,
  type ReactNode,
} from "react";
import type {
  DashboardData,
  ActiveSession,
  Project,
  Skill,
  MCPServer,
  ProjectDetail as ProjectDetailData,
  SkillDetail as SkillDetailData,
  DevServer,
} from "@/lib/types";

type Tab = "projects" | "servers" | "skills" | "settings";

const TAB_ORDER: Tab[] = ["projects", "servers", "skills", "settings"];

const ACTIVE_POLL_MS = 2_000;
const DASHBOARD_POLL_MS = 30_000;
const DETAIL_POLL_MS = 5_000;
const SERVERS_POLL_MS = 4_000;

const WARN_PCT = 25;
const DANGER_PCT = 60;

function ctxColor(pct: number): string {
  if (pct >= DANGER_PCT) return "var(--red)";
  if (pct >= WARN_PCT) return "var(--warn)";
  return "var(--green)";
}

const NAV_DURATION_MS = 280;
const NAV_EASING = "cubic-bezier(0.32, 0.72, 0, 1)";

function NavStack({
  viewKey,
  direction,
  children,
}: {
  viewKey: string;
  direction: "forward" | "back";
  children: ReactNode;
}) {
  const viewKeyRef = useRef(viewKey);
  const childrenRef = useRef<ReactNode>(children);
  const [transition, setTransition] = useState<{
    exitingNode: ReactNode;
    direction: "forward" | "back";
    phase: "initial" | "animating";
  } | null>(null);

  useLayoutEffect(() => {
    if (viewKeyRef.current === viewKey) return;
    setTransition({
      exitingNode: childrenRef.current,
      direction,
      phase: "initial",
    });
    viewKeyRef.current = viewKey;
  }, [viewKey, direction]);

  useEffect(() => {
    childrenRef.current = children;
  });

  useEffect(() => {
    if (!transition) return;
    if (transition.phase === "initial") {
      const raf = requestAnimationFrame(() => {
        setTransition((prev) =>
          prev?.phase === "initial" ? { ...prev, phase: "animating" } : prev
        );
      });
      return () => cancelAnimationFrame(raf);
    }
    const t = setTimeout(() => setTransition(null), NAV_DURATION_MS);
    return () => clearTimeout(t);
  }, [transition]);

  let currentTransform = "translateX(0)";
  let exitingTransform = "translateX(0)";
  let animate = false;

  if (transition?.phase === "initial") {
    currentTransform =
      transition.direction === "back" ? "translateX(-100%)" : "translateX(100%)";
  } else if (transition?.phase === "animating") {
    exitingTransform =
      transition.direction === "back" ? "translateX(100%)" : "translateX(-100%)";
    animate = true;
  }

  const transitionStyle = animate
    ? `transform ${NAV_DURATION_MS}ms ${NAV_EASING}`
    : "none";

  return (
    <div className="flex-1 relative overflow-hidden">
      {transition && (
        <div
          key="nav-exiting"
          className="absolute inset-0 overflow-y-auto scroll-area"
          style={{
            transform: exitingTransform,
            transition: transitionStyle,
            willChange: "transform",
          }}
        >
          {transition.exitingNode}
        </div>
      )}
      <div
        key={viewKey}
        className="absolute inset-0 overflow-y-auto scroll-area"
        style={{
          transform: currentTransform,
          transition: transitionStyle,
          willChange: "transform",
        }}
      >
        {children}
      </div>
    </div>
  );
}

export default function Home() {
  const [tab, setTab] = useState<Tab>("projects");
  const [dashboard, setDashboard] = useState<DashboardData | null>(null);
  const [active, setActive] = useState<ActiveSession[]>([]);
  const [servers, setServers] = useState<DevServer[]>([]);
  const [selectedProjectPath, setSelectedProjectPath] = useState<string | null>(null);
  const [selectedUpdateIndex, setSelectedUpdateIndex] = useState<number | null>(null);
  const [selectedSkillName, setSelectedSkillName] = useState<string | null>(null);
  const [detail, setDetail] = useState<ProjectDetailData | null>(null);
  const [skillDetail, setSkillDetail] = useState<SkillDetailData | null>(null);
  const [navDirection, setNavDirection] = useState<"forward" | "back">("forward");
  const [syncing, setSyncing] = useState(false);

  const refreshDashboard = useCallback(async () => {
    if (typeof window === "undefined" || !window.mc) return;
    try {
      const d = await window.mc.getDashboard();
      setDashboard(d);
    } catch {
      // ignore — surface later via an error state
    }
  }, []);

  const refreshActive = useCallback(async () => {
    if (typeof window === "undefined" || !window.mc) return;
    try {
      const a = await window.mc.getActiveSessions();
      setActive(a);
    } catch {
      // ignore
    }
  }, []);

  const refreshServers = useCallback(async () => {
    if (typeof window === "undefined" || !window.mc) return;
    try {
      const s = await window.mc.getActiveServers();
      setServers(s);
    } catch {
      // ignore
    }
  }, []);

  const refreshDetail = useCallback(async (projectPath: string) => {
    if (typeof window === "undefined" || !window.mc) return;
    try {
      const d = await window.mc.getProjectDetail(projectPath);
      setDetail(d);
    } catch {
      // ignore
    }
  }, []);

  const handleSync = useCallback(async () => {
    setSyncing(true);
    try {
      await Promise.all([refreshDashboard(), refreshActive(), refreshServers()]);
    } finally {
      // Keep the spinner up for a brief beat so the user sees it animate
      setTimeout(() => setSyncing(false), 400);
    }
  }, [refreshDashboard, refreshActive, refreshServers]);

  useEffect(() => {
    refreshDashboard();
    refreshActive();
    refreshServers();
    const t1 = setInterval(refreshDashboard, DASHBOARD_POLL_MS);
    const t2 = setInterval(refreshActive, ACTIVE_POLL_MS);
    const t3 = setInterval(refreshServers, SERVERS_POLL_MS);
    return () => {
      clearInterval(t1);
      clearInterval(t2);
      clearInterval(t3);
    };
  }, [refreshDashboard, refreshActive, refreshServers]);

  useEffect(() => {
    if (!selectedProjectPath) {
      setDetail(null);
      setSelectedUpdateIndex(null);
      return;
    }
    refreshDetail(selectedProjectPath);
    const t = setInterval(() => refreshDetail(selectedProjectPath), DETAIL_POLL_MS);
    return () => clearInterval(t);
  }, [selectedProjectPath, refreshDetail]);

  useEffect(() => {
    if (!selectedSkillName) {
      setSkillDetail(null);
      return;
    }
    if (typeof window === "undefined" || !window.mc) return;
    window.mc
      .getSkillDetail(selectedSkillName)
      .then(setSkillDetail)
      .catch(() => {});
  }, [selectedSkillName]);

  const activeCwds = new Set(active.map((s) => s.cwd).filter(Boolean) as string[]);
  const serverUrlByCwd = new Map<string, string>(
    servers
      .filter((s) => !!s.cwd)
      .map((s) => [s.cwd as string, s.url])
  );
  const inactiveProjects = (dashboard?.projects ?? []).filter(
    (p) => !activeCwds.has(p.path)
  );
  const projectByPath = new Map<string, Project>(
    (dashboard?.projects ?? []).map((p) => [p.path, p])
  );

  const inProjectDetail = !!selectedProjectPath;
  const inSkillDetail = !!selectedSkillName;
  const inAnyDetail = inProjectDetail || inSkillDetail;
  const activeForSelected = inProjectDetail
    ? active.find((s) => s.cwd === selectedProjectPath) ?? null
    : null;
  const selectedEntry =
    inProjectDetail && selectedUpdateIndex !== null && detail
      ? detail.entries[selectedUpdateIndex] ?? null
      : null;
  const inUpdateDetail = !!selectedEntry;

  const headerTitle = inUpdateDetail
    ? "Update"
    : inSkillDetail
    ? skillDetail?.invoke ?? selectedSkillName ?? ""
    : detail?.project.name ?? "";

  const pushProject = (path: string) => {
    setNavDirection("forward");
    setSelectedProjectPath(path);
  };
  const pushSkill = (name: string) => {
    setNavDirection("forward");
    setSelectedSkillName(name);
  };
  const handleTabChange = (next: Tab) => {
    if (next === tab) return;
    const fromIdx = TAB_ORDER.indexOf(tab);
    const toIdx = TAB_ORDER.indexOf(next);
    setNavDirection(toIdx > fromIdx ? "forward" : "back");
    setTab(next);
  };
  const pushUpdate = (i: number) => {
    setNavDirection("forward");
    setSelectedUpdateIndex(i);
  };
  const popView = () => {
    setNavDirection("back");
    if (inUpdateDetail) setSelectedUpdateIndex(null);
    else if (inSkillDetail) setSelectedSkillName(null);
    else setSelectedProjectPath(null);
  };

  const viewKey = inUpdateDetail
    ? `update:${selectedProjectPath}:${selectedUpdateIndex}`
    : inSkillDetail
    ? `skill:${selectedSkillName}`
    : inProjectDetail
    ? `project:${selectedProjectPath}`
    : `tab:${tab}`;

  return (
    <div
      className="h-screen w-screen flex flex-col rounded-[12px] overflow-hidden"
      style={{
        background: "var(--bg)",
        border: "1px solid var(--border)",
        boxShadow: "0 10px 30px rgba(0, 0, 0, 0.15)",
      }}
    >
      <Header
        inDetail={inAnyDetail}
        detailTitle={headerTitle}
        showFinderLink={inProjectDetail && !inUpdateDetail && !!detail}
        onFinderClick={() =>
          detail && window.mc?.openPath(detail.project.path)
        }
        onBack={popView}
        onSync={handleSync}
        syncing={syncing}
      />
      {!inAnyDetail && <Tabs tab={tab} onChange={handleTabChange} />}
      <NavStack viewKey={viewKey} direction={navDirection}>
        {inSkillDetail ? (
          <SkillDetailView detail={skillDetail} />
        ) : inUpdateDetail && selectedEntry ? (
          <UpdateDetailView entry={selectedEntry} />
        ) : inProjectDetail ? (
          <ProjectDetailView
            detail={detail}
            activeSession={activeForSelected}
            onSelectUpdate={pushUpdate}
          />
        ) : (
          <>
            {tab === "projects" && (
              <ProjectsTab
                active={active}
                inactive={inactiveProjects}
                projectByPath={projectByPath}
                serverUrlByCwd={serverUrlByCwd}
                projectsDir={dashboard?.projectsDir ?? null}
                onSelectProject={pushProject}
                onPickProjectsDir={async () => {
                  const r = await window.mc?.pickDirectory({
                    title: "Choose your projects folder",
                    defaultPath: dashboard?.projectsDir,
                  });
                  if (r?.ok && r.path) {
                    await window.mc?.setSettings({ projectsDir: r.path });
                    await refreshDashboard();
                  }
                }}
              />
            )}
            {tab === "servers" && (
              <ServersTab
                servers={servers}
                mcpServers={dashboard?.mcpServers ?? []}
              />
            )}
            {tab === "skills" && (
              <SkillsTab
                skills={dashboard?.skills ?? []}
                onSelectSkill={pushSkill}
              />
            )}
            {tab === "settings" && <SettingsView />}
          </>
        )}
      </NavStack>
    </div>
  );
}

// ── Header ────────────────────────────────────────────────────────────────────

function Header({
  inDetail,
  detailTitle,
  showFinderLink,
  onFinderClick,
  onBack,
  onSync,
  syncing,
}: {
  inDetail: boolean;
  detailTitle: string;
  showFinderLink: boolean;
  onFinderClick: () => void;
  onBack: () => void;
  onSync: () => void;
  syncing: boolean;
}) {
  if (inDetail) {
    return (
      <div className="flex items-center gap-4 px-5 pt-5 pb-6">
        <IconButton aria-label="Back" onClick={onBack}>
          <BackIcon />
        </IconButton>
        <span
          className="text-[16px] font-semibold truncate flex-1 min-w-0"
          style={{ color: "var(--text)", letterSpacing: "-0.01em" }}
        >
          {detailTitle}
        </span>
        {showFinderLink && (
          <button
            onClick={onFinderClick}
            className="flex items-center gap-1 text-[12px] font-medium transition-opacity"
            style={{ color: "var(--dim)" }}
            onMouseEnter={(e) => (e.currentTarget.style.opacity = "0.7")}
            onMouseLeave={(e) => (e.currentTarget.style.opacity = "1")}
          >
            View in finder
            <ExternalLinkIcon />
          </button>
        )}
      </div>
    );
  }
  return (
    <div className="px-5 pt-5 pb-6 flex items-center justify-between gap-3">
      <img
        src="/houstonlogo.png"
        alt="Houston"
        style={{ height: 28, width: "auto", display: "block" }}
      />
      <IconButton aria-label="Sync" onClick={onSync}>
        <SyncIcon spinning={syncing} />
      </IconButton>
    </div>
  );
}

function IconButton({
  children,
  onClick,
  ...rest
}: {
  children: React.ReactNode;
  onClick?: () => void;
  "aria-label": string;
}) {
  return (
    <button
      onClick={onClick}
      {...rest}
      className="w-8 h-8 rounded-[8px] flex items-center justify-center transition-colors flex-shrink-0"
      style={{ color: "var(--text)", background: "transparent" }}
      onMouseEnter={(e) =>
        (e.currentTarget.style.background = "var(--surface)")
      }
      onMouseLeave={(e) =>
        (e.currentTarget.style.background = "transparent")
      }
    >
      {children}
    </button>
  );
}

// ── Tabs ──────────────────────────────────────────────────────────────────────

function Tabs({ tab, onChange }: { tab: Tab; onChange: (t: Tab) => void }) {
  const tabs: { id: Tab; label: string }[] = [
    { id: "projects", label: "Projects" },
    { id: "servers", label: "Servers" },
    { id: "skills", label: "Skills" },
    { id: "settings", label: "Settings" },
  ];
  return (
    <div className="px-5 pb-6">
      <div
        className="flex p-1 rounded-full"
        style={{ background: "var(--surface)" }}
      >
        {tabs.map((t) => {
          const isActive = t.id === tab;
          return (
            <button
              key={t.id}
              onClick={() => onChange(t.id)}
              className="flex-1 py-1.5 text-[12px] font-semibold rounded-full transition-all"
              style={{
                color: isActive ? "var(--text)" : "var(--dim)",
                background: isActive ? "var(--bg)" : "transparent",
                boxShadow: isActive
                  ? "0 1px 2px rgba(0,0,0,0.06), 0 0 0 0.5px rgba(0,0,0,0.04)"
                  : "none",
              }}
            >
              {t.label}
            </button>
          );
        })}
      </div>
    </div>
  );
}

// ── Projects Tab ──────────────────────────────────────────────────────────────

function ProjectsTab({
  active,
  inactive,
  projectByPath,
  serverUrlByCwd,
  projectsDir,
  onSelectProject,
  onPickProjectsDir,
}: {
  active: ActiveSession[];
  inactive: Project[];
  projectByPath: Map<string, Project>;
  serverUrlByCwd: Map<string, string>;
  projectsDir: string | null;
  onSelectProject: (path: string) => void;
  onPickProjectsDir: () => void;
}) {
  return (
    <div className="flex flex-col">
      <Section label="Active sessions">
        {active.length === 0 ? (
          <Empty>No active Claude sessions</Empty>
        ) : (
          active.map((s) => {
            const proj = s.cwd ? projectByPath.get(s.cwd) ?? null : null;
            const devServerUrl = s.cwd ? serverUrlByCwd.get(s.cwd) ?? null : null;
            return (
              <ActiveSessionRow
                key={s.pid}
                session={s}
                icon={proj?.icon ?? null}
                devServerUrl={devServerUrl}
                onSelect={() => s.cwd && onSelectProject(s.cwd)}
              />
            );
          })
        )}
      </Section>

      <Section label="All projects">
        {inactive.length === 0 ? (
          <Empty>
            <div>
              No projects found in{" "}
              {projectsDir ? displayPathForSettings(projectsDir) : "your projects folder"}
            </div>
            <div className="mt-3 flex justify-center">
              <RowActionButton
                variant="secondary"
                onClick={(e) => {
                  e.stopPropagation();
                  onPickProjectsDir();
                }}
              >
                Choose folder…
              </RowActionButton>
            </div>
          </Empty>
        ) : (
          <CardGroup>
            {inactive.map((p) => (
              <ProjectRow
                key={p.path}
                project={p}
                grouped
                onSelect={() => onSelectProject(p.path)}
              />
            ))}
          </CardGroup>
        )}
      </Section>
    </div>
  );
}

function Section({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}) {
  return (
    <div className="mb-6">
      <div
        className="px-5 pb-2 text-[14px] font-semibold"
        style={{ color: "var(--muted)" }}
      >
        {label}
      </div>
      {children}
    </div>
  );
}

function Empty({ children }: { children: React.ReactNode }) {
  return (
    <div
      className="mx-5 mb-2 px-4 py-6 text-[12px] text-center rounded-[12px]"
      style={{ color: "var(--muted)", border: "1px dashed var(--border)" }}
    >
      {children}
    </div>
  );
}

function ActiveSessionRow({
  session,
  devServerUrl,
  onSelect,
}: {
  session: ActiveSession;
  icon: string | null;
  devServerUrl: string | null;
  onSelect: () => void;
}) {
  const pct = session.contextPct;
  const pctColor = ctxColor(pct);
  const ago = session.startedAt ? timeAgo(session.startedAt) : null;
  const [starting, setStarting] = useState(false);

  const startDev = async () => {
    if (starting || !session.cwd) return;
    setStarting(true);
    try {
      await window.mc?.startDevServer(session.cwd);
    } catch {
      // The dev-server-detected effect below will eventually clear `starting`;
      // safety timeout also clears after 30s.
    }
  };

  useEffect(() => {
    if (starting && devServerUrl) setStarting(false);
  }, [starting, devServerUrl]);

  useEffect(() => {
    if (!starting) return;
    const t = setTimeout(() => setStarting(false), 30_000);
    return () => clearTimeout(t);
  }, [starting]);

  const devLabel = devServerUrl
    ? "Open in browser"
    : starting
    ? "Starting…"
    : "Start dev";
  const onDevClick = () => {
    if (devServerUrl) window.mc?.openExternal(devServerUrl);
    else startDev();
  };

  return (
    <Card onSelect={onSelect}>
      <div className="group">
        <div className="flex items-center gap-3">
          <span
            className="h-2 w-2 rounded-full flex-shrink-0"
            style={{ background: pctColor }}
          />
          <div className="min-w-0 flex-1">
            <div
              className="text-[14px] font-semibold truncate"
              style={{ color: "var(--text)", letterSpacing: "-0.01em" }}
            >
              {session.project}
            </div>
            <div
              className="text-[12px] truncate tabular-nums mt-0.5"
              style={{ color: "var(--muted)" }}
            >
              {ago ? `${ago} • ` : ""}Context used:{" "}
              <span style={{ color: pctColor, fontWeight: 600 }}>{pct}%</span>
            </div>
          </div>
          <span
            className="flex-shrink-0"
            style={{ color: "var(--dim)" }}
            aria-hidden
          >
            <ChevronRightIcon />
          </span>
        </div>
        {session.cwd && (
          <div
            className="overflow-hidden transition-all duration-200 max-h-0 opacity-0 group-hover:max-h-[60px] group-hover:opacity-100"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-center gap-2 pt-3">
              <RowActionButton
                variant="primary"
                disabled={starting}
                onClick={(e) => {
                  e.stopPropagation();
                  onDevClick();
                }}
              >
                {devLabel}
              </RowActionButton>
            </div>
          </div>
        )}
      </div>
    </Card>
  );
}

function Card({
  onSelect,
  children,
  title,
}: {
  onSelect?: () => void;
  children: React.ReactNode;
  title?: string;
}) {
  const interactive = !!onSelect;
  return (
    <div
      role={interactive ? "button" : undefined}
      tabIndex={interactive ? 0 : undefined}
      onClick={onSelect}
      onKeyDown={(e) => {
        if (!interactive) return;
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          onSelect?.();
        }
      }}
      title={title}
      className={`mx-5 mb-2 px-4 py-3 rounded-[12px] transition-colors ${
        interactive ? "cursor-pointer" : ""
      }`}
      style={{ border: "1px solid var(--border)", background: "var(--bg)" }}
      onMouseEnter={(e) => {
        if (interactive) e.currentTarget.style.background = "var(--surface)";
      }}
      onMouseLeave={(e) => {
        if (interactive) e.currentTarget.style.background = "var(--bg)";
      }}
    >
      {children}
    </div>
  );
}

function CardGroup({ children }: { children: React.ReactNode }) {
  return (
    <div
      className="mx-5 mb-2 rounded-[12px] overflow-hidden"
      style={{ border: "1px solid var(--border)", background: "var(--bg)" }}
    >
      {children}
    </div>
  );
}

function RowItem({
  onSelect,
  children,
  title,
}: {
  onSelect?: () => void;
  children: React.ReactNode;
  title?: string;
}) {
  const interactive = !!onSelect;
  return (
    <div
      role={interactive ? "button" : undefined}
      tabIndex={interactive ? 0 : undefined}
      onClick={onSelect}
      onKeyDown={(e) => {
        if (!interactive) return;
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          onSelect?.();
        }
      }}
      title={title}
      className={`px-4 py-3 transition-colors border-b last:border-b-0 ${
        interactive ? "cursor-pointer" : ""
      }`}
      style={{ borderColor: "var(--border)", background: "var(--bg)" }}
      onMouseEnter={(e) => {
        if (interactive) e.currentTarget.style.background = "var(--surface)";
      }}
      onMouseLeave={(e) => {
        if (interactive) e.currentTarget.style.background = "var(--bg)";
      }}
    >
      {children}
    </div>
  );
}

function timeAgo(iso: string): string {
  const ms = Date.now() - new Date(iso).getTime();
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h`;
  const d = Math.floor(h / 24);
  return `${d}d`;
}

function formatTokens(n: number): string {
  if (!n || n < 0) return "0";
  if (n < 1_000) return `${n}`;
  if (n < 10_000) return `${(n / 1_000).toFixed(1)}k`;
  if (n < 1_000_000) return `${Math.round(n / 1_000)}k`;
  return `${(n / 1_000_000).toFixed(2)}M`;
}

function ProjectRow({
  project,
  onSelect,
  grouped = false,
}: {
  project: Project;
  onSelect: () => void;
  grouped?: boolean;
}) {
  const Wrapper = grouped ? RowItem : Card;
  return (
    <Wrapper onSelect={onSelect}>
      <div className="flex items-center gap-3">
        <div className="min-w-0 flex-1">
          <div
            className="text-[14px] font-semibold truncate"
            style={{ color: "var(--text)", letterSpacing: "-0.01em" }}
          >
            {project.name}
          </div>
          {project.notes && (
            <div
              className="text-[12px] truncate mt-0.5"
              style={{ color: "var(--muted)" }}
            >
              {project.notes}
            </div>
          )}
        </div>
        <span
          className="flex-shrink-0"
          style={{ color: "var(--dim)" }}
          aria-hidden
        >
          <ChevronRightIcon />
        </span>
      </div>
    </Wrapper>
  );
}

function ProjectIcon({
  name,
  icon,
  dotColor,
}: {
  name: string;
  icon: string | null;
  dotColor?: string;
}) {
  const initial = (name.replace(/^[^a-z0-9]+/i, "")[0] || "?").toUpperCase();
  return (
    <div
      className="flex-shrink-0 relative"
      style={{ width: 28, height: 28 }}
    >
      {icon ? (
        <img
          src={icon}
          alt=""
          width={28}
          height={28}
          className="rounded-md"
          style={{
            objectFit: "cover",
            background: "var(--surface)",
            border: "1px solid var(--border)",
          }}
        />
      ) : (
        <div
          className="w-full h-full rounded-md flex items-center justify-center text-[12px] font-semibold"
          style={{
            background: "var(--surface)",
            color: "var(--dim)",
            border: "1px solid var(--border)",
          }}
        >
          {initial}
        </div>
      )}
      {dotColor && (
        <span
          className="absolute rounded-full"
          style={{
            width: 8,
            height: 8,
            right: -2,
            bottom: -2,
            background: dotColor,
            border: "2px solid var(--bg)",
          }}
        />
      )}
    </div>
  );
}

function PrimaryButton({
  onClick,
  color,
  variant = "filled",
  children,
}: {
  onClick: () => void;
  color: string;
  variant?: "filled" | "outline";
  children: React.ReactNode;
}) {
  const outline = variant === "outline";
  return (
    <button
      onClick={onClick}
      className="flex-1 h-11 rounded-[8px] text-[13px] font-semibold transition-all"
      style={{
        background: outline ? "transparent" : color,
        color: outline ? color : "#ffffff",
        border: outline ? `1.5px solid ${color}` : "1.5px solid transparent",
        letterSpacing: "-0.01em",
      }}
      onMouseEnter={(e) => (e.currentTarget.style.opacity = "0.85")}
      onMouseLeave={(e) => (e.currentTarget.style.opacity = "1")}
    >
      {children}
    </button>
  );
}

// ── Project Detail ────────────────────────────────────────────────────────────

function ProjectDetailView({
  detail,
  activeSession,
  onSelectUpdate,
}: {
  detail: ProjectDetailData | null;
  activeSession: ActiveSession | null;
  onSelectUpdate: (i: number) => void;
}) {
  if (!detail) {
    return <Empty>Loading…</Empty>;
  }
  const { project, entries, stats } = detail;
  const isActive = !!activeSession;

  return (
    <div className="flex flex-col pb-6">
      {isActive && activeSession && (
        <div
          className={`mx-5 flex gap-3 ${
            activeSession.contextPct >= WARN_PCT ? "mb-3" : "mb-6"
          }`}
        >
          <BigStat
            value={`${activeSession.contextPct}%`}
            label="Context used"
            color={ctxColor(activeSession.contextPct)}
          />
          <BigStat
            value={`~${formatTokens(activeSession.contextSize)}`}
            label="Tokens used each time"
            color={ctxColor(activeSession.contextPct)}
          />
        </div>
      )}
      {isActive && activeSession && activeSession.contextPct >= WARN_PCT && (
        <div
          className="mx-5 mb-6 px-6 text-[12px] leading-snug text-center"
          style={{ color: ctxColor(activeSession.contextPct) }}
        >
          Recommend running /log-mission to prevent using
          <br />~{formatTokens(activeSession.contextSize)} tokens in your next prompt.
        </div>
      )}

      <div className="mx-5 mb-6 rounded-[12px] flex py-3" style={{ border: "1px solid var(--border)" }}>
        <SmallStat label="Sessions" value={String(stats.sessionCount)} />
        <div style={{ width: 1, background: "var(--border)" }} />
        <SmallStat label="Last logged" value={stats.lastSessionDate ?? "—"} />
        <div style={{ width: 1, background: "var(--border)" }} />
        <SmallStat label="Since" value={stats.firstSessionDate ?? "—"} />
      </div>

      {!isActive && (
        <div className="px-5 mb-6 flex items-center gap-3">
          <PrimaryButton
            color="var(--text)"
            onClick={() => window.mc?.startMission(project.path)}
          >
            Start mission
          </PrimaryButton>
        </div>
      )}

      {entries.length === 0 ? (
        <Empty>No mission log entries yet</Empty>
      ) : (
        <CardGroup>
          {entries.map((entry, i) => (
            <UpdateRow
              key={`${entry.date}-${i}`}
              entry={entry}
              grouped
              onSelect={() => onSelectUpdate(i)}
            />
          ))}
        </CardGroup>
      )}
    </div>
  );
}

function BigStat({
  value,
  label,
  color,
}: {
  value: string;
  label: string;
  color: string;
}) {
  return (
    <div
      className="flex-1 py-4 rounded-[12px] text-center"
      style={{ background: "var(--bg)", border: "1px solid var(--border)" }}
    >
      <div
        className="text-[24px] font-semibold leading-none tabular-nums"
        style={{ color, letterSpacing: "-0.02em" }}
      >
        {value}
      </div>
      <div
        className="text-[12px] mt-2"
        style={{ color: "var(--muted)" }}
      >
        {label}
      </div>
    </div>
  );
}

function SmallStat({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex-1 px-3 py-1 min-w-0">
      <div
        className="text-[12px]"
        style={{ color: "var(--muted)" }}
      >
        {label}
      </div>
      <div
        className="text-[14px] tabular-nums mt-1 truncate"
        style={{ color: "var(--text)" }}
      >
        {value}
      </div>
    </div>
  );
}

function UpdateRow({
  entry,
  onSelect,
  grouped = false,
}: {
  entry: { date: string; title: string };
  onSelect: () => void;
  grouped?: boolean;
}) {
  const Wrapper = grouped ? RowItem : Card;
  return (
    <Wrapper onSelect={onSelect}>
      <div className="flex items-center gap-3">
        <div className="min-w-0 flex-1">
          <div
            className="text-[12px]"
            style={{ color: "var(--muted)" }}
          >
            {entry.date} update
          </div>
          <div
            className="text-[14px] font-semibold leading-snug mt-1"
            style={{ color: "var(--text)" }}
          >
            {entry.title}
          </div>
        </div>
        <span
          className="flex-shrink-0"
          style={{ color: "var(--dim)" }}
          aria-hidden
        >
          <ChevronRightIcon />
        </span>
      </div>
    </Wrapper>
  );
}

// ── Update Detail ─────────────────────────────────────────────────────────────

function UpdateDetailView({
  entry,
}: {
  entry: {
    date: string;
    title: string;
    summary: string;
    done: string[];
    upNext: string[];
  };
}) {
  return (
    <div className="flex flex-col px-5 pb-5">
      <div className="pt-1 pb-3">
        <div
          className="text-[12px]"
          style={{ color: "var(--muted)" }}
        >
          {entry.date} update
        </div>
        <h2
          className="text-[16px] font-semibold leading-snug mt-1"
          style={{ color: "var(--text)", letterSpacing: "-0.01em" }}
        >
          {entry.title}
        </h2>
      </div>

      {entry.summary && (
        <p
          className="text-[12px] leading-relaxed"
          style={{ color: "var(--text)" }}
        >
          {entry.summary}
        </p>
      )}

      {entry.done.length > 0 && (
        <BulletSection title="Done this session" items={entry.done} />
      )}
      {entry.upNext.length > 0 && (
        <BulletSection title="Up next" items={entry.upNext} />
      )}
    </div>
  );
}

function BulletSection({
  title,
  items,
}: {
  title: string;
  items: string[];
}) {
  return (
    <div className="mt-5">
      <h3
        className="text-[14px] font-semibold mb-2"
        style={{ color: "var(--muted)" }}
      >
        {title}
      </h3>
      <ul className="space-y-1.5">
        {items.map((d, i) => (
          <li
            key={i}
            className="text-[12px] leading-relaxed pl-4 relative"
            style={{ color: "var(--text)" }}
          >
            <span
              className="absolute left-0 top-0"
              style={{ color: "var(--dim)" }}
            >
              •
            </span>
            {d}
          </li>
        ))}
      </ul>
    </div>
  );
}

// ── Icons ─────────────────────────────────────────────────────────────────────

function FloppyIcon() {
  return (
    <svg
      width="15"
      height="15"
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.4"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M3 2.5h7.5L13.5 5.5V13a.5.5 0 0 1-.5.5H3a.5.5 0 0 1-.5-.5V3a.5.5 0 0 1 .5-.5z" />
      <path d="M5 2.5v3h5V2.5" />
      <rect x="5" y="9" width="6" height="4.5" rx="0.3" />
    </svg>
  );
}

function StopSignIcon() {
  // Filled red octagon — classic stop sign silhouette
  return (
    <svg width="15" height="15" viewBox="0 0 16 16" fill="currentColor">
      <path d="M5.4 1.5h5.2L14.5 5.4v5.2L10.6 14.5H5.4L1.5 10.6V5.4z" />
    </svg>
  );
}

function CloseIcon() {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
    >
      <path d="M4 4l8 8M12 4l-8 8" />
    </svg>
  );
}

function BackIcon() {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M10 3L5 8l5 5" />
    </svg>
  );
}

function SyncIcon({ spinning }: { spinning: boolean }) {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      style={spinning ? { animation: "spin 0.9s linear infinite" } : undefined}
    >
      <path d="M13.5 7a5.5 5.5 0 0 0-9.6-2.7" />
      <path d="M13.5 2v3h-3" />
      <path d="M2.5 9a5.5 5.5 0 0 0 9.6 2.7" />
      <path d="M2.5 14v-3h3" />
    </svg>
  );
}

function ChevronRightIcon() {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M6 3l5 5-5 5" />
    </svg>
  );
}

// ── Skills Tab ────────────────────────────────────────────────────────────────

const HOUSTON_SKILLS = ["start-mission", "log-mission", "end-mission"];

function skillDir(s: Skill): string {
  return s.invoke.startsWith("/") ? s.invoke.slice(1) : s.invoke;
}

function SkillsTab({
  skills,
  onSelectSkill,
}: {
  skills: Skill[];
  onSelectSkill: (name: string) => void;
}) {
  if (skills.length === 0) {
    return <Empty>No custom skills installed</Empty>;
  }
  const houstonSet = new Set(HOUSTON_SKILLS);
  const houstonSkills = HOUSTON_SKILLS
    .map((name) => skills.find((s) => skillDir(s) === name))
    .filter((s): s is Skill => !!s);
  const otherSkills = skills.filter((s) => !houstonSet.has(skillDir(s)));

  return (
    <>
      {houstonSkills.length > 0 && (
        <Section label="Core skills">
          <CardGroup>
            {houstonSkills.map((s) => (
              <SkillRowItem
                key={s.invoke}
                skill={s}
                onSelect={() => onSelectSkill(skillDir(s))}
              />
            ))}
          </CardGroup>
        </Section>
      )}
      {otherSkills.length > 0 && (
        <Section label="Custom skills">
          <CardGroup>
            {otherSkills.map((s) => (
              <SkillRowItem
                key={s.invoke}
                skill={s}
                onSelect={() => onSelectSkill(skillDir(s))}
              />
            ))}
          </CardGroup>
        </Section>
      )}
    </>
  );
}

function SkillRowItem({
  skill,
  onSelect,
}: {
  skill: Skill;
  onSelect: () => void;
}) {
  return (
    <RowItem onSelect={onSelect}>
      <div className="flex items-center gap-3">
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2">
            <span
              className="text-[14px] font-semibold truncate"
              style={{ color: "var(--text)", letterSpacing: "-0.01em" }}
            >
              {skill.name}
            </span>
            <span
              className="text-[10px] rounded-full px-2 py-0.5 flex-shrink-0 font-semibold"
              style={{
                background: "color-mix(in srgb, var(--blue) 10%, transparent)",
                color: "var(--blue)",
              }}
            >
              {skill.invoke}
            </span>
          </div>
          {skill.description && (
            <div
              className="text-[12px] mt-1 leading-snug"
              style={{ color: "var(--muted)" }}
            >
              {skill.description}
            </div>
          )}
        </div>
        <span
          className="flex-shrink-0"
          style={{ color: "var(--dim)" }}
          aria-hidden
        >
          <ChevronRightIcon />
        </span>
      </div>
    </RowItem>
  );
}

// ── Skill Detail ──────────────────────────────────────────────────────────────

function SkillDetailView({ detail }: { detail: SkillDetailData | null }) {
  if (!detail) return <Empty>Loading…</Empty>;
  const hasSteps = detail.steps.length > 0;

  return (
    <div className="flex flex-col px-5 pb-6">
      {detail.description && (
        <p
          className="text-[14px] leading-[1.5] mb-6"
          style={{ color: "var(--text)" }}
        >
          {detail.description}
        </p>
      )}

      {hasSteps ? (
        <>
          <div
            className="text-[12px] font-semibold uppercase tracking-[0.06em] mb-5"
            style={{ color: "var(--muted)" }}
          >
            What it does
          </div>
          <TimelineSteps steps={detail.steps} />
        </>
      ) : detail.intro ? (
        <div
          className="text-[12px] leading-[1.6] whitespace-pre-wrap"
          style={{ color: "var(--dim)" }}
        >
          {detail.intro}
        </div>
      ) : (
        <Empty>This skill doesn&apos;t define explicit steps.</Empty>
      )}
    </div>
  );
}

function TimelineSteps({
  steps,
}: {
  steps: { number: number; title: string; body: string }[];
}) {
  return (
    <div className="flex flex-col">
      {steps.map((s, i) => {
        const isLast = i === steps.length - 1;
        return (
          <div key={s.number} className="flex gap-4">
            <div
              className="flex flex-col items-center flex-shrink-0"
              style={{ width: 32 }}
            >
              <div
                className="w-8 h-8 rounded-full flex items-center justify-center text-[12px] font-semibold tabular-nums flex-shrink-0"
                style={{
                  background: "var(--surface)",
                  color: "var(--text)",
                  border: "1px solid var(--border)",
                }}
              >
                {s.number}
              </div>
              {!isLast && (
                <div
                  className="flex-1 w-px mt-1.5 mb-1.5"
                  style={{ background: "var(--border)", minHeight: 24 }}
                />
              )}
            </div>
            <div
              className={`flex-1 min-w-0 ${isLast ? "" : "pb-6"}`}
            >
              <h3
                className="text-[14px] font-semibold leading-snug"
                style={{ color: "var(--text)", letterSpacing: "-0.01em" }}
              >
                {s.title}
              </h3>
              {s.body && (
                <p
                  className="text-[12px] mt-1.5 leading-[1.5]"
                  style={{ color: "var(--muted)" }}
                >
                  {s.body}
                </p>
              )}
            </div>
          </div>
        );
      })}
    </div>
  );
}

// ── Servers Tab ───────────────────────────────────────────────────────────────

function ServersTab({
  servers,
  mcpServers,
}: {
  servers: DevServer[];
  mcpServers: MCPServer[];
}) {
  const [pendingKill, setPendingKill] = useState<number | null>(null);
  const [clearingPids, setClearingPids] = useState<Set<number>>(new Set());

  const handleClearCache = async (server: DevServer) => {
    if (!server.cwd || clearingPids.has(server.pid)) return;
    setClearingPids((prev) => new Set(prev).add(server.pid));
    try {
      await window.mc?.clearServerCache(server.cwd);
    } finally {
      setTimeout(() => {
        setClearingPids((prev) => {
          const next = new Set(prev);
          next.delete(server.pid);
          return next;
        });
      }, 600);
    }
  };

  return (
    <div className="flex flex-col">
      <Section label="Dev">
        {servers.length === 0 ? (
          <Empty>No active dev servers</Empty>
        ) : (
          servers.map((s) => (
            <ServerRow
              key={`${s.pid}-${s.port}`}
              server={s}
              killing={pendingKill === s.pid}
              clearing={clearingPids.has(s.pid)}
              onKill={async () => {
                setPendingKill(s.pid);
                try {
                  await window.mc?.killServer(s.pid);
                } finally {
                  setPendingKill(null);
                }
              }}
              onClearCache={() => handleClearCache(s)}
            />
          ))
        )}
      </Section>

      <Section label="MCP">
        {mcpServers.length === 0 ? (
          <Empty>No MCP servers configured</Empty>
        ) : (
          mcpServers.map((s) => <MCPServerRow key={s.name} server={s} />)
        )}
      </Section>
    </div>
  );
}

function MCPServerRow({ server }: { server: MCPServer }) {
  return (
    <Card>
      <div className="flex items-center gap-3">
        <span
          className="h-2 w-2 rounded-full flex-shrink-0"
          style={{ background: "var(--green)" }}
        />
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2">
            <span
              className="text-[14px] font-semibold truncate"
              style={{ color: "var(--text)", letterSpacing: "-0.01em" }}
            >
              {server.name}
            </span>
            <span
              className="text-[10px] rounded-full px-2 py-0.5 flex-shrink-0 font-semibold"
              style={{
                background: "color-mix(in srgb, var(--blue) 10%, transparent)",
                color: "var(--blue)",
              }}
            >
              {server.type}
            </span>
          </div>
          <div
            className="text-[12px] truncate mt-0.5"
            style={{ color: "var(--muted)" }}
          >
            {server.endpoint}
          </div>
        </div>
      </div>
    </Card>
  );
}

function ServerRow({
  server,
  killing,
  clearing,
  onKill,
  onClearCache,
}: {
  server: DevServer;
  killing: boolean;
  clearing: boolean;
  onKill: () => void;
  onClearCache: () => void;
}) {
  const label = server.project ?? server.command;
  return (
    <Card
      onSelect={() => window.mc?.openExternal(server.url)}
      title={`Open ${server.url}`}
    >
      <div className="group">
        <div className="flex items-center gap-3">
          <span
            className="h-2 w-2 rounded-full flex-shrink-0"
            style={{ background: "var(--green)" }}
          />
          <div className="min-w-0 flex-1">
            <div className="flex items-center gap-2">
              <span
                className="text-[14px] font-semibold truncate"
                style={{ color: "var(--text)", letterSpacing: "-0.01em" }}
              >
                {label}
              </span>
              <span
                className="text-[12px] font-semibold tabular-nums flex-shrink-0"
                style={{ color: "var(--blue)" }}
              >
                :{server.port}
              </span>
              {server.isSelf && (
                <span
                  className="text-[10px] rounded-full px-2 py-0.5 flex-shrink-0 font-semibold"
                  style={{
                    background: "color-mix(in srgb, var(--muted) 12%, transparent)",
                    color: "var(--muted)",
                  }}
                >
                  this app
                </span>
              )}
            </div>
            <div
              className="text-[12px] truncate mt-0.5 tabular-nums"
              style={{ color: "var(--muted)" }}
            >
              {server.command} · pid {server.pid}
              {server.cwd ? ` · ${displayCwd(server.cwd)}` : ""}
            </div>
          </div>
          <span
            className="flex-shrink-0 group-hover:hidden"
            style={{ color: "var(--dim)" }}
            aria-hidden
          >
            <ExternalLinkIcon />
          </span>
        </div>
        <div
          className="overflow-hidden transition-all duration-200 max-h-0 opacity-0 group-hover:max-h-[60px] group-hover:opacity-100"
          onClick={(e) => e.stopPropagation()}
        >
          <div className="flex items-center gap-2 pt-3">
            <RowActionButton
              variant="primary"
              onClick={(e) => {
                e.stopPropagation();
                window.mc?.openExternal(server.url);
              }}
            >
              Open in browser
            </RowActionButton>
            <div className="flex items-center gap-2 ml-auto">
              {server.cwd && (
                <RowActionButton
                  variant="secondary"
                  disabled={clearing}
                  onClick={(e) => {
                    e.stopPropagation();
                    onClearCache();
                  }}
                >
                  {clearing ? "Clearing…" : "Clear cache"}
                </RowActionButton>
              )}
              {!server.isSelf && (
                <RowActionButton
                  variant="destructive"
                  disabled={killing}
                  onClick={(e) => {
                    e.stopPropagation();
                    onKill();
                  }}
                >
                  {killing ? "Stopping…" : "Stop"}
                </RowActionButton>
              )}
            </div>
          </div>
        </div>
      </div>
    </Card>
  );
}

function RowActionButton({
  variant,
  onClick,
  disabled,
  children,
}: {
  variant: "primary" | "secondary" | "destructive";
  onClick: (e: React.MouseEvent) => void;
  disabled?: boolean;
  children: React.ReactNode;
}) {
  const style: React.CSSProperties =
    variant === "primary"
      ? { background: "var(--text)", color: "var(--bg)", border: "1.5px solid var(--text)" }
      : variant === "secondary"
      ? { background: "var(--surface2)", color: "var(--text)", border: "1.5px solid transparent" }
      : {
          background: "transparent",
          color: "var(--red)",
          border: "1.5px solid var(--red)",
        };
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      className="text-[12px] font-semibold px-3 h-8 rounded-[8px] transition-opacity disabled:opacity-60"
      style={{ ...style, letterSpacing: "-0.01em" }}
      onMouseEnter={(e) => {
        if (!disabled) e.currentTarget.style.opacity = "0.85";
      }}
      onMouseLeave={(e) => {
        e.currentTarget.style.opacity = "1";
      }}
    >
      {children}
    </button>
  );
}

function displayCwd(cwd: string): string {
  const home = "/Users/";
  if (cwd.startsWith(home)) {
    const rest = cwd.slice(home.length);
    const slash = rest.indexOf("/");
    if (slash !== -1) return "~" + rest.slice(slash);
  }
  return cwd;
}

function ExternalLinkIcon() {
  return (
    <svg
      width="13"
      height="13"
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M6 3H3.5a.5.5 0 0 0-.5.5V12.5a.5.5 0 0 0 .5.5h9a.5.5 0 0 0 .5-.5V10" />
      <path d="M10 2.5h3.5V6" />
      <path d="M13 2.5L7.5 8" />
    </svg>
  );
}

// ── Settings ──────────────────────────────────────────────────────────────────

type SettingsShape = {
  terminal: string;
  projectsDir: string;
  spawnMode: "tab" | "window";
};

function SettingsView() {
  const [settings, setSettingsState] = useState<SettingsShape | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [installed, setInstalled] = useState<Record<string, boolean> | null>(
    null
  );

  useEffect(() => {
    if (!window.mc?.getSettings) {
      setLoadError(
        "Settings handler not loaded — restart Electron (Ctrl+C then `npm run dev`) to pick up new main-process changes."
      );
      return;
    }
    window.mc
      .getSettings()
      .then(setSettingsState)
      .catch((e) => setLoadError(String(e?.message || e)));
    window.mc
      .getTerminalStatus?.()
      .then(setInstalled)
      .catch(() => {});
  }, []);

  const update = async (patch: Partial<SettingsShape>) => {
    // Terminal.app doesn't reliably tab-spawn on macOS Sequoia, so picking
    // Terminal forces window mode. Apply optimistically so the UI snaps
    // before the IPC round-trip, and send the combined patch so the store
    // sees both fields atomically.
    const finalPatch: Partial<SettingsShape> =
      patch.terminal === "Terminal"
        ? { ...patch, spawnMode: "window" }
        : patch;
    if (settings) {
      setSettingsState({ ...settings, ...finalPatch });
    }
    try {
      const r = await window.mc?.setSettings(finalPatch);
      if (r?.ok && r.settings) setSettingsState(r.settings);
    } catch (e) {
      setLoadError(String((e as Error)?.message || e));
    }
  };

  const pickProjectsDir = async () => {
    const r = await window.mc?.pickDirectory({
      title: "Choose your projects folder",
      defaultPath: settings?.projectsDir,
    });
    if (r?.ok && r.path) update({ projectsDir: r.path });
  };

  if (loadError) return <Empty>{loadError}</Empty>;
  if (!settings) return <Empty>Loading…</Empty>;

  const terminalLocked = settings.terminal === "Terminal";

  return (
    <div className="flex flex-col pb-6">
      <Section label="Terminal emulator">
        <CardGroup>
          {(["Ghostty", "Terminal", "iTerm2"] as const).map((t) => (
            <SettingsTerminalRow
              key={t}
              name={t}
              status={
                installed ? (installed[t] ? "installed" : "not-installed") : undefined
              }
              selected={settings.terminal === t}
              onSelect={() => update({ terminal: t })}
            />
          ))}
        </CardGroup>
      </Section>

      <Section label="Open new sessions in">
        <CardGroup>
          <SettingsTerminalRow
            name="Tab"
            sub={
              terminalLocked
                ? "Not supported by Terminal.app — opens a new window instead"
                : `Opens a new tab in your current ${settings.terminal} window`
            }
            selected={settings.spawnMode === "tab" && !terminalLocked}
            disabled={terminalLocked}
            onSelect={() => update({ spawnMode: "tab" })}
          />
          <SettingsTerminalRow
            name={`New ${settings.terminal} window`}
            sub={`Always opens a fresh ${settings.terminal} window`}
            selected={settings.spawnMode === "window"}
            onSelect={() => update({ spawnMode: "window" })}
          />
        </CardGroup>
      </Section>

      <Section label="Projects folder">
        <Card>
          <div className="flex items-center gap-3">
            <div className="min-w-0 flex-1">
              <div
                className="text-[10px] uppercase tracking-wider mb-1"
                style={{ color: "var(--muted)" }}
              >
                Path
              </div>
              <div
                className="text-[13px] truncate"
                style={{
                  color: "var(--text)",
                  fontFamily:
                    "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, monospace",
                }}
              >
                {displayPathForSettings(settings.projectsDir)}
              </div>
            </div>
            <RowActionButton
              variant="secondary"
              onClick={(e) => {
                e.stopPropagation();
                pickProjectsDir();
              }}
            >
              Change…
            </RowActionButton>
          </div>
        </Card>
      </Section>
    </div>
  );
}

function SettingsTerminalRow({
  name,
  sub,
  status,
  selected,
  disabled,
  onSelect,
}: {
  name: string;
  sub?: string;
  status?: "installed" | "not-installed";
  selected: boolean;
  disabled?: boolean;
  onSelect: () => void;
}) {
  return (
    <RowItem onSelect={disabled ? undefined : onSelect}>
      <div
        className="flex items-center gap-3"
        style={{ opacity: disabled ? 0.5 : 1 }}
      >
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2">
            <span
              className="text-[14px] font-semibold truncate"
              style={{ color: "var(--text)", letterSpacing: "-0.01em" }}
            >
              {name}
            </span>
            {status && <InstallBadge installed={status === "installed"} />}
          </div>
          {sub && (
            <div
              className="text-[12px] truncate mt-0.5"
              style={{ color: "var(--muted)" }}
            >
              {sub}
            </div>
          )}
        </div>
        {selected && (
          <span style={{ color: "var(--blue)" }} aria-label="Selected">
            <CheckIcon />
          </span>
        )}
      </div>
    </RowItem>
  );
}

function InstallBadge({ installed }: { installed: boolean }) {
  return (
    <span
      className="text-[10px] rounded-full px-2 py-0.5 flex-shrink-0 font-semibold"
      style={{
        background: installed
          ? "color-mix(in srgb, var(--green) 12%, transparent)"
          : "color-mix(in srgb, var(--muted) 12%, transparent)",
        color: installed ? "var(--green)" : "var(--muted)",
      }}
    >
      {installed ? "Installed" : "Not installed"}
    </span>
  );
}

function CheckIcon() {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M3 8.5L6.5 12 13 4.5" />
    </svg>
  );
}

function displayPathForSettings(p: string): string {
  const home = "/Users/";
  if (p.startsWith(home)) {
    const rest = p.slice(home.length);
    const slash = rest.indexOf("/");
    if (slash !== -1) return "~" + rest.slice(slash);
  }
  return p;
}
