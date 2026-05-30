"use client";

import { useCallback, useEffect, useRef, useState } from "react";

type Terminal = "Ghostty" | "Terminal" | "iTerm2";
const ALL_TERMINALS: Terminal[] = ["Ghostty", "Terminal", "iTerm2"];

type Step =
  | { kind: "welcome" }
  | { kind: "projectsDir" }
  | { kind: "terminal" }
  | { kind: "permissions" }
  | { kind: "howItWorks" }
  | { kind: "tabProjects" }
  | { kind: "tabSkills" }
  | { kind: "tabServers" }
  | { kind: "tabSettings" }
  | { kind: "done" };

const STEPS: Step[] = [
  { kind: "welcome" },
  { kind: "projectsDir" },
  { kind: "terminal" },
  { kind: "permissions" },
  { kind: "howItWorks" },
  { kind: "tabProjects" },
  { kind: "tabSkills" },
  { kind: "tabServers" },
  { kind: "tabSettings" },
  { kind: "done" },
];

// Figma color tokens. Hardcoded so the onboarding renders consistently
// regardless of the rest of the app's theme.
const C = {
  bg: "#ffffff",
  text: "#000000",
  body: "#737373",
  small: "#424242",
  hint: "rgba(0,0,0,0.78)",
  label: "rgba(0,0,0,0.56)",
  accent: "#5900ff",
  surface1: "#f0f0f0",
  surface2: "#f5f5f7",
  surface3: "#f6f6f6",
  border1: "#cfcfcf",
  border2: "#d5d5d5",
  green: "#34c759",
  muted: "#a0a0a0",
} as const;

type PermissionsState = {
  accessibility: boolean;
  automation: Record<string, boolean>;
  permissionsRequestedAt: number | null;
};

function displayPath(p: string | null): string | null {
  if (!p) return null;
  const home = "/Users/";
  if (p.startsWith(home)) {
    const rest = p.slice(home.length);
    const slash = rest.indexOf("/");
    if (slash !== -1) return "~" + rest.slice(slash);
  }
  return p;
}

export default function Onboarding() {
  const [step, setStep] = useState(0);
  const [terminals, setTerminals] = useState<Terminal[]>([]);
  const [projectsDir, setProjectsDir] = useState<string | null>(null);

  useEffect(() => {
    window.mc?.getSettings().then((s) => {
      if (Array.isArray(s?.terminals)) {
        const filtered = s.terminals.filter((t: string): t is Terminal =>
          ALL_TERMINALS.includes(t as Terminal)
        );
        if (filtered.length) setTerminals(filtered);
      }
      if (s?.projectsDir) setProjectsDir(s.projectsDir);
    });
  }, []);

  const isLast = step === STEPS.length - 1;
  const current = STEPS[step];

  const persistTerminals = useCallback(async (next: Terminal[]) => {
    try {
      await window.mc?.setSettings({ terminals: next });
    } catch (e) {
      console.error("Failed to persist terminals:", e);
    }
  }, []);

  const toggleTerminal = (t: Terminal) => {
    setTerminals((prev) => {
      const next = prev.includes(t) ? prev.filter((x) => x !== t) : [...prev, t];
      persistTerminals(next);
      return next;
    });
  };

  const finish = async () => {
    if (projectsDir) await window.mc?.setSettings({ projectsDir });
    window.mc?.completeOnboarding();
  };

  const canAdvance =
    current.kind === "terminal"
      ? terminals.length > 0
      : current.kind === "projectsDir"
      ? !!projectsDir
      : true;

  const advance = async () => {
    try {
      if (current.kind === "projectsDir" && projectsDir) {
        await window.mc?.setSettings({ projectsDir });
      }
    } catch (e) {
      console.error("Failed to persist setting:", e);
    }
    if (isLast) finish();
    else setStep((s) => s + 1);
  };

  return (
    <div
      className="h-screen w-screen relative overflow-hidden"
      style={{ background: C.bg, color: C.text }}
    >
      {/* Drag handle covering the traffic-light row — leaves space on the left
          for the native controls and lets the user move the window from any
          other point in the strip. */}
      <div
        className="absolute top-0 left-0 right-0 h-[40px] z-20"
        style={{ WebkitAppRegion: "drag" } as React.CSSProperties}
      />

      {/* Top chrome: Back (left), step dots (center), Skip (right). Hidden on
          welcome since that step auto-advances. */}
      {current.kind !== "welcome" && (
        <>
          <button
            onClick={() => setStep((s) => s - 1)}
            disabled={step <= 1}
            className="absolute top-[14px] left-[80px] z-40 text-[13px] transition-opacity"
            style={{
              background: "transparent",
              color: C.body,
              WebkitAppRegion: "no-drag",
              opacity: step <= 1 ? 0 : 1,
              pointerEvents: step <= 1 ? "none" : "auto",
            } as React.CSSProperties}
            onMouseEnter={(e) => (e.currentTarget.style.opacity = "0.6")}
            onMouseLeave={(e) =>
              (e.currentTarget.style.opacity = step <= 1 ? "0" : "1")
            }
          >
            Back
          </button>

          <div
            className="absolute top-[20px] left-1/2 z-40"
            style={{
              transform: "translateX(-50%)",
              WebkitAppRegion: "no-drag",
            } as React.CSSProperties}
          >
            <StepDots count={STEPS.length} current={step} />
          </div>

          {!isLast && (
            <button
              onClick={finish}
              className="absolute top-[14px] right-[20px] z-40 text-[13px] transition-opacity"
              style={{
                background: "transparent",
                color: C.body,
                WebkitAppRegion: "no-drag",
              } as React.CSSProperties}
              onMouseEnter={(e) => (e.currentTarget.style.opacity = "0.6")}
              onMouseLeave={(e) => (e.currentTarget.style.opacity = "1")}
            >
              Skip
            </button>
          )}

          {/* Continue arrow — circular button floating at right vertical center. */}
          <button
            onClick={advance}
            disabled={!canAdvance}
            aria-label={isLast ? "Get started" : "Continue"}
            className="absolute z-40 flex items-center justify-center transition-opacity disabled:opacity-30"
            style={{
              right: 24,
              top: "50%",
              transform: "translateY(-50%)",
              width: 44,
              height: 44,
              borderRadius: "50%",
              background: C.text,
              color: "#ffffff",
              WebkitAppRegion: "no-drag",
            } as React.CSSProperties}
            onMouseEnter={(e) => {
              if (canAdvance) e.currentTarget.style.opacity = "0.85";
            }}
            onMouseLeave={(e) => (e.currentTarget.style.opacity = "1")}
          >
            <ArrowRightIcon />
          </button>
        </>
      )}

      {/* Background art layer. Sits below everything (z-0) and is decoupled
          from step content so it can never push, distort, or overlap UI. */}
      <BackgroundLayer kind={current.kind} />

      <div className="absolute inset-0 z-10">
        <main className="absolute inset-0">
          {current.kind === "welcome" && (
            <WelcomeStep onComplete={() => setStep(1)} />
          )}
          {current.kind === "projectsDir" && (
            <ProjectsDirStep
              value={projectsDir}
              onPick={async () => {
                const r = await window.mc?.pickDirectory({
                  title: "Choose your projects folder",
                  defaultPath: projectsDir || undefined,
                });
                if (r?.ok && r.path) setProjectsDir(r.path);
              }}
            />
          )}
          {current.kind === "terminal" && (
            <TerminalStep selected={terminals} onToggle={toggleTerminal} />
          )}
          {current.kind === "permissions" && (
            <PermissionsStepView terminals={terminals} />
          )}
          {current.kind === "howItWorks" && <HowItWorksStep />}
          {current.kind === "tabProjects" && <TabProjectsStep />}
          {current.kind === "tabSkills" && <TabSkillsStep />}
          {current.kind === "tabServers" && <TabServersStep />}
          {current.kind === "tabSettings" && <TabSettingsStep />}
          {current.kind === "done" && <DoneStep />}
        </main>
      </div>
    </div>
  );
}

// ── Background art ─────────────────────────────────────────────────────────
//
// All decorative imagery lives in this single layer at z-0, sized in absolute
// pixels and pinned with care so it can never overlap the footer's nav row
// (which sits in the bottom ~94px of the 600px window). Aspect ratio is
// preserved by setting only one dimension on each <img>.

const FOOTER_RESERVE = 100; // px — keep art above this band

function BackgroundLayer({ kind }: { kind: Step["kind"] }) {
  // Astronaut only appears on the two steps where the Figma shows it. The
  // Welcome step owns its own background art so the fade-in animates together
  // with the title and subtitle.
  const wantsAstronaut = kind === "projectsDir" || kind === "terminal";

  return (
    <div
      aria-hidden
      className="absolute inset-0 pointer-events-none overflow-hidden z-0"
    >
      {wantsAstronaut && (
        // Anchored bottom-right and pushed past both edges so the visible
        // astronaut figure (which ends ~87% down inside the SVG's viewBox)
        // actually touches the window bottom, and a healthy chunk hangs off
        // the right. Only height is set — aspect ratio is preserved.
        <img
          src="/onboarding/astronaut.svg"
          alt=""
          className="absolute"
          style={{
            right: -170,
            bottom: -80,
            height: 560,
            opacity: 0.6,
          }}
        />
      )}
    </div>
  );
}

// ── Steps ──────────────────────────────────────────────────────────────────

// Welcome animation timeline (ms from mount):
//   200   — title fades in + slides up
//   1100  — subtitle fades in + slides up
//   1800  — rocket + smoke fade in (no motion, behind text)
//   4500  — auto-advance to the next step
const WELCOME_TITLE_MS = 200;
const WELCOME_SUBTITLE_MS = 1100;
const WELCOME_ART_MS = 1800;
const WELCOME_ADVANCE_MS = 4500;

function WelcomeStep({ onComplete }: { onComplete: () => void }) {
  // 0 = nothing visible, 1 = title, 2 = +subtitle, 3 = +art
  const [phase, setPhase] = useState(0);

  useEffect(() => {
    const t1 = setTimeout(() => setPhase(1), WELCOME_TITLE_MS);
    const t2 = setTimeout(() => setPhase(2), WELCOME_SUBTITLE_MS);
    const t3 = setTimeout(() => setPhase(3), WELCOME_ART_MS);
    const t4 = setTimeout(onComplete, WELCOME_ADVANCE_MS);
    return () => {
      clearTimeout(t1);
      clearTimeout(t2);
      clearTimeout(t3);
      clearTimeout(t4);
    };
  }, [onComplete]);

  const titleIn = phase >= 1;
  const subtitleIn = phase >= 2;
  const artIn = phase >= 3;

  // Rocket + smoke use the Figma's natural sizes (rocket 61×108, smoke 365×162
  // inside an 800×600 frame). Only one dimension is set so the browser keeps
  // the SVG's intrinsic aspect ratio — no distortion. Smoke is anchored to the
  // very bottom; rocket sits just above it.
  return (
    <div className="absolute inset-0">
      <img
        src="/onboarding/smoke.svg"
        alt=""
        aria-hidden
        className="absolute"
        style={{
          left: "50%",
          bottom: 0,
          transform: "translateX(-50%)",
          width: 365,
          opacity: artIn ? 1 : 0,
          transition: "opacity 1200ms ease",
        }}
      />
      <img
        src="/onboarding/rocket.svg"
        alt=""
        aria-hidden
        className="absolute"
        style={{
          left: "50%",
          bottom: 168,
          transform: "translateX(-50%)",
          height: 108,
          opacity: artIn ? 1 : 0,
          transition: "opacity 1200ms ease",
        }}
      />

      <div
        className="absolute text-center"
        style={{ left: 0, right: 0, top: 175 }}
      >
        <h1
          style={{
            fontSize: 23,
            color: C.text,
            letterSpacing: "-0.01em",
            fontWeight: 400,
            opacity: titleIn ? 1 : 0,
            transform: titleIn ? "translateY(0)" : "translateY(16px)",
            transition:
              "opacity 700ms cubic-bezier(0.22, 1, 0.36, 1), transform 700ms cubic-bezier(0.22, 1, 0.36, 1)",
          }}
        >
          This is <span style={{ fontWeight: 700 }}>Houston,</span>
        </h1>
        <p
          className="mt-2"
          style={{
            fontSize: 23,
            color: C.body,
            letterSpacing: "-0.01em",
            opacity: subtitleIn ? 1 : 0,
            transform: subtitleIn ? "translateY(0)" : "translateY(16px)",
            transition:
              "opacity 700ms cubic-bezier(0.22, 1, 0.36, 1), transform 700ms cubic-bezier(0.22, 1, 0.36, 1)",
          }}
        >
          We are go for launch.
        </p>
      </div>
    </div>
  );
}

function StepShell({
  title,
  body,
  children,
}: {
  title: string;
  body: string;
  children?: React.ReactNode;
}) {
  return (
    <div className="absolute inset-0 flex items-center">
      <div style={{ marginLeft: 80, width: 497 }}>
        <h2
          className="font-bold"
          style={{ fontSize: 23, color: C.text, lineHeight: 1.15 }}
        >
          {title}
        </h2>
        <p
          className="mt-5"
          style={{ fontSize: 15, color: C.body, lineHeight: 1.45 }}
        >
          {body}
        </p>
        {children && <div className="mt-7">{children}</div>}
      </div>
    </div>
  );
}

function ProjectsDirStep({
  value,
  onPick,
}: {
  value: string | null;
  onPick: () => void;
}) {
  return (
    <StepShell
      title="Welcome to Houston"
      body="Your mission control for organizing all your messy coding projects. First things first, where do you save projects locally?"
    >
      <div
        className="flex items-center justify-between"
        style={{
          background: C.surface1,
          borderRadius: 12,
          padding: "8px 8px 8px 16px",
          width: 408,
        }}
      >
        <div className="flex flex-col">
          <span
            style={{
              fontSize: 12,
              color: C.label,
              textTransform: "uppercase",
              letterSpacing: "0.02em",
            }}
          >
            Projects folder
          </span>
          <span
            style={{
              fontSize: 15,
              fontWeight: 700,
              color: C.text,
              marginTop: 2,
              fontFamily: value
                ? "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, monospace"
                : undefined,
            }}
          >
            {displayPath(value) ?? "Select a folder"}
          </span>
        </div>
        <button
          onClick={onPick}
          className="transition-opacity"
          style={{
            background: C.text,
            color: "#ffffff",
            borderRadius: 8,
            padding: "8px 14px",
            fontSize: 14,
            fontWeight: 500,
          }}
          onMouseEnter={(e) => (e.currentTarget.style.opacity = "0.85")}
          onMouseLeave={(e) => (e.currentTarget.style.opacity = "1")}
        >
          Browse folders
        </button>
      </div>
      <div
        className="mt-4 flex items-center gap-[6px]"
        style={{ fontSize: 13, color: C.hint }}
      >
        <span>Ideally, a folder in your home folder</span>
        <HouseIcon />
        <span
          style={{
            fontFamily:
              "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, monospace",
          }}
        >
          ~/projects/
        </span>
      </div>
    </StepShell>
  );
}

function TerminalStep({
  selected,
  onToggle,
}: {
  selected: Terminal[];
  onToggle: (t: Terminal) => void;
}) {
  return (
    <StepShell
      title="Which terminal apps do you use?"
      body="Houston spawns new Claude sessions in your terminal. You can pick more than one — change this later from the Settings tab."
    >
      <div className="flex gap-[18px]">
        {ALL_TERMINALS.map((t) => (
          <TerminalCard
            key={t}
            name={t}
            selected={selected.includes(t)}
            onToggle={() => onToggle(t)}
          />
        ))}
      </div>
    </StepShell>
  );
}

function TerminalCard({
  name,
  selected,
  onToggle,
}: {
  name: Terminal;
  selected: boolean;
  onToggle: () => void;
}) {
  const iconSrc =
    name === "Ghostty"
      ? "/onboarding/icon-ghostty.png"
      : name === "iTerm2"
      ? "/onboarding/icon-iterm.png"
      : "/onboarding/icon-terminal.png";
  return (
    <button
      onClick={onToggle}
      className="flex flex-col items-center justify-center gap-2 transition-all relative"
      style={{
        width: 125,
        padding: "10px 8px",
        background: selected ? "#ffffff" : C.surface3,
        border: selected ? `1.5px solid ${C.accent}` : `1px solid ${C.border1}`,
        borderRadius: 11,
        boxShadow: selected ? `0 0 0 3px rgba(89,0,255,0.12)` : "none",
      }}
    >
      {selected && (
        <span
          aria-hidden
          className="absolute flex items-center justify-center"
          style={{
            top: 6,
            right: 6,
            width: 18,
            height: 18,
            borderRadius: 999,
            background: C.accent,
            color: "#ffffff",
            fontSize: 11,
            fontWeight: 700,
          }}
        >
          ✓
        </span>
      )}
      <img
        src={iconSrc}
        alt=""
        aria-hidden
        style={{ width: 52, height: 52, borderRadius: 12, objectFit: "cover" }}
      />
      <span style={{ fontSize: 15, color: C.text }}>{name}</span>
    </button>
  );
}

function PermissionsStepView({ terminals }: { terminals: Terminal[] }) {
  const [state, setState] = useState<PermissionsState | null>(null);
  const [requesting, setRequesting] = useState(false);
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const refresh = useCallback(async () => {
    try {
      const s = await window.mc?.checkPermissions(terminals);
      if (s) setState(s);
    } catch {
      // older Electron without these IPC handlers — fall through silently
    }
  }, [terminals]);

  useEffect(() => {
    refresh();
    pollRef.current = setInterval(refresh, 1500);
    return () => {
      if (pollRef.current) clearInterval(pollRef.current);
    };
  }, [refresh]);

  const allGood =
    !!state &&
    state.accessibility &&
    terminals.every((t) => state.automation[t]);

  const handleAllow = async () => {
    if (!window.mc?.requestPermissions) return;
    setRequesting(true);
    try {
      const s = await window.mc.requestPermissions(terminals);
      if (s) setState(s);
    } finally {
      setRequesting(false);
    }
  };

  return (
    <StepShell
      title="Grant Houston permission to drive your terminal"
      body="macOS needs two permissions so Houston can open a new terminal window and type /start-mission for you. Houston only uses these to drive the terminals you picked."
    >
      <div className="flex flex-col gap-2" style={{ width: 497 }}>
        <PermissionRow
          name="Accessibility"
          sub="Lets Houston type /start-mission after spawning your terminal."
          granted={state?.accessibility ?? null}
          onFix={() => window.mc?.openPermissionsSettings?.("accessibility")}
        />
        {terminals.map((t) => (
          <PermissionRow
            key={t}
            name={`Control ${t}`}
            sub={`Lets Houston open a new ${t} window in your project directory.`}
            granted={state?.automation[t] ?? null}
            onFix={() => window.mc?.openPermissionsSettings?.("automation")}
          />
        ))}
      </div>
      <div className="mt-4 flex items-center gap-3">
        <button
          onClick={handleAllow}
          disabled={requesting || allGood}
          className="transition-opacity disabled:opacity-40"
          style={{
            background: allGood ? C.green : C.text,
            color: "#ffffff",
            borderRadius: 999,
            padding: "8px 18px",
            fontSize: 13,
            fontWeight: 600,
          }}
          onMouseEnter={(e) => {
            if (!requesting && !allGood) e.currentTarget.style.opacity = "0.85";
          }}
          onMouseLeave={(e) => (e.currentTarget.style.opacity = "1")}
        >
          {allGood
            ? "All permissions granted"
            : requesting
            ? "Waiting…"
            : state?.permissionsRequestedAt
            ? "Open System Settings"
            : "Allow permissions"}
        </button>
        {state?.permissionsRequestedAt && !allGood && (
          <span style={{ fontSize: 12, color: C.body, maxWidth: 280 }}>
            macOS won&apos;t re-prompt once asked — toggle Houston on in Settings.
          </span>
        )}
      </div>
    </StepShell>
  );
}

function PermissionRow({
  name,
  sub,
  granted,
  onFix,
}: {
  name: string;
  sub: string;
  granted: boolean | null;
  onFix: () => void;
}) {
  const status =
    granted === null ? "unknown" : granted ? "granted" : "missing";
  return (
    <div
      className="flex items-center gap-3"
      style={{
        background: C.surface2,
        borderRadius: 11,
        padding: "10px 14px",
      }}
    >
      <span
        aria-hidden
        style={{
          width: 9,
          height: 9,
          borderRadius: 999,
          background:
            status === "granted"
              ? C.green
              : status === "missing"
              ? C.muted
              : C.border1,
          flexShrink: 0,
        }}
      />
      <div className="flex-1 min-w-0">
        <div style={{ fontSize: 13, fontWeight: 600, color: C.text }}>
          {name}
        </div>
        <div style={{ fontSize: 11.5, color: C.small, marginTop: 1 }}>
          {sub}
        </div>
      </div>
      {status === "missing" && (
        <button
          onClick={onFix}
          className="transition-opacity"
          style={{
            background: "transparent",
            color: C.accent,
            fontSize: 12,
            fontWeight: 600,
          }}
          onMouseEnter={(e) => (e.currentTarget.style.opacity = "0.7")}
          onMouseLeave={(e) => (e.currentTarget.style.opacity = "1")}
        >
          Open Settings
        </button>
      )}
    </div>
  );
}

function HowItWorksStep() {
  return (
    <StepShell
      title="How it works"
      body="Once Houston knows what terminal you use and where you store your projects, it's a one-click flow to start a session, check dev servers, and keep an eye on context while you're working."
    >
      <div className="flex flex-col gap-[14px]" style={{ width: 620 }}>
        <CommandRow
          name="/start-mission"
          body="Initializes your development environment by opening your terminal, navigating to the project root, pulling the latest changes from Github, starting Claude, referencing the missionlog.md file, and starting a dev server for your project."
        />
        <CommandRow
          name="/new"
          body="Clears the current session and initiates a fresh context. This process involves the system reading the 'claude.md' file to establish a new context for the session."
        />
        <CommandRow
          name="/end-mission"
          body="Will git commit and push, log any mission changes to missionlog.md, and kill the dev server. Will ask before committing your changes."
        />
      </div>
    </StepShell>
  );
}

function CommandRow({ name, body }: { name: string; body: string }) {
  return (
    <div
      className="flex items-start"
      style={{
        background: C.surface2,
        borderRadius: 11,
        padding: 10,
        gap: 24,
      }}
    >
      <span
        style={{
          fontSize: 13,
          fontWeight: 700,
          color: C.accent,
          width: 120,
          textAlign: "right",
          flexShrink: 0,
          whiteSpace: "nowrap",
          fontFamily:
            "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, monospace",
          paddingTop: 1,
        }}
      >
        {name}
      </span>
      <p style={{ fontSize: 12, color: C.small, lineHeight: 1.66, flex: 1 }}>
        {body}
      </p>
    </div>
  );
}

function TabSectionShell({
  title,
  body,
  children,
}: {
  title: string;
  body: string;
  children: React.ReactNode;
}) {
  return (
    <div className="absolute inset-0 flex items-center">
      <div style={{ marginLeft: 80, marginRight: 80, flex: 1 }}>
        <h2
          className="font-bold"
          style={{ fontSize: 23, color: C.text, lineHeight: 1.15 }}
        >
          {title}
        </h2>
        <p
          className="mt-4"
          style={{ fontSize: 12, color: C.small, lineHeight: 1.66, maxWidth: 497 }}
        >
          {body}
        </p>
        <div className="mt-6">{children}</div>
      </div>
    </div>
  );
}

function TabProjectsStep() {
  return (
    <TabSectionShell
      title="The Projects tab"
      body="View the projects you're actively working on, their current context, and the cost of your next prompt, in tokens. On the project details page, you can start inactive projects, view data about the project, and see previous updates and summaries."
    >
      <div className="flex gap-8">
        <ScreenshotFrame src="/onboarding/screenshot-projects.png" />
        <ScreenshotFrame src="/onboarding/screenshot-detail.png" />
      </div>
    </TabSectionShell>
  );
}

function ScreenshotFrame({ src }: { src: string }) {
  // Aspect ratio matches the screenshot source (794:1140 ≈ 0.696). Height is
  // capped so the two frames + title + body fit above the footer at ~y=506.
  return (
    <div
      className="overflow-hidden"
      style={{
        width: 223,
        height: 320,
        borderRadius: 14,
        border: `1px solid ${C.border2}`,
        boxShadow: "0 18px 28px -14px rgba(0,0,0,0.18)",
        background: "#ffffff",
        flexShrink: 0,
      }}
    >
      <img
        src={src}
        alt=""
        aria-hidden
        style={{
          width: "100%",
          height: "100%",
          objectFit: "cover",
          objectPosition: "top",
        }}
      />
    </div>
  );
}

function TabSkillsStep() {
  return (
    <TabSectionShell
      title="The Skills tab"
      body="Every slash command installed in ~/.claude/skills, with a one-line description of what it does. A quick way to remember what's available before you type /."
    >
      <div className="flex flex-col gap-[10px]" style={{ width: 560 }}>
        {[
          { name: "/start-mission", body: "Spin up a project's dev server and kick off a session." },
          { name: "/end-mission", body: "Wrap a session: status note, git commit/push, kill dev server." },
          { name: "/init", body: "Generate a project handoff CLAUDE.md from the current codebase." },
          { name: "/review", body: "Run an automated code review on the current branch." },
          { name: "/foundation", body: "Stand up Terms, Privacy, and a marketing site for a new app." },
        ].map((s) => (
          <SkillPreviewRow key={s.name} name={s.name} body={s.body} />
        ))}
        <div style={{ fontSize: 11, color: C.label, marginTop: 4, textAlign: "right" }}>
          + every other skill in ~/.claude/skills
        </div>
      </div>
    </TabSectionShell>
  );
}

function SkillPreviewRow({ name, body }: { name: string; body: string }) {
  return (
    <div
      className="flex items-center gap-4"
      style={{ background: C.surface2, borderRadius: 10, padding: "8px 14px" }}
    >
      <span
        style={{
          fontSize: 12,
          fontWeight: 700,
          color: C.accent,
          width: 130,
          fontFamily: "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, monospace",
        }}
      >
        {name}
      </span>
      <span style={{ fontSize: 12, color: C.small, flex: 1 }}>{body}</span>
    </div>
  );
}

function TabServersStep() {
  return (
    <TabSectionShell
      title="The Servers tab"
      body="Every dev server on your machine, grouped by project. Open one in your browser with a click, or stop a runaway with one tap."
    >
      <div className="flex flex-col gap-[10px]" style={{ width: 560 }}>
        <ServerPreviewRow name="houston" port="3401" running />
        <ServerPreviewRow name="portfolio" port="3000" running />
        <ServerPreviewRow name="mission-control" port="3300" running={false} />
      </div>
    </TabSectionShell>
  );
}

function ServerPreviewRow({
  name,
  port,
  running,
}: {
  name: string;
  port: string;
  running: boolean;
}) {
  return (
    <div
      className="flex items-center gap-4"
      style={{ background: C.surface2, borderRadius: 10, padding: "10px 14px" }}
    >
      <span
        aria-hidden
        style={{
          width: 9,
          height: 9,
          borderRadius: 999,
          background: running ? C.green : C.muted,
          flexShrink: 0,
        }}
      />
      <span style={{ fontSize: 13, fontWeight: 600, color: C.text, flex: 1 }}>
        {name}
      </span>
      <span
        style={{
          fontSize: 12,
          color: C.body,
          fontFamily: "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, monospace",
        }}
      >
        :{port}
      </span>
      <span
        style={{
          fontSize: 12,
          color: running ? C.accent : C.muted,
          fontWeight: 600,
          width: 60,
          textAlign: "right",
        }}
      >
        {running ? "Open" : "Stopped"}
      </span>
    </div>
  );
}

function TabSettingsStep() {
  return (
    <TabSectionShell
      title="The Settings tab"
      body="Change your terminal preferences, swap your projects folder, and tweak how Houston spawns new sessions — any time. Everything you set in this guide can be edited later."
    >
      <div className="flex flex-col gap-[10px]" style={{ width: 560 }}>
        <SettingPreviewRow label="Terminal" value="Ghostty, iTerm2" />
        <SettingPreviewRow label="Projects folder" value="~/Apps" mono />
        <SettingPreviewRow label="Spawn mode" value="New window" />
      </div>
    </TabSectionShell>
  );
}

function SettingPreviewRow({
  label,
  value,
  mono,
}: {
  label: string;
  value: string;
  mono?: boolean;
}) {
  return (
    <div
      className="flex items-center justify-between"
      style={{ background: C.surface2, borderRadius: 10, padding: "10px 14px" }}
    >
      <span style={{ fontSize: 13, color: C.body }}>{label}</span>
      <span
        style={{
          fontSize: 13,
          fontWeight: 600,
          color: C.text,
          fontFamily: mono
            ? "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, monospace"
            : undefined,
        }}
      >
        {value}
      </span>
    </div>
  );
}

function DoneStep() {
  return (
    <div className="absolute inset-0 flex flex-col items-center justify-center">
      <div className="relative z-10 text-center" style={{ marginTop: -20 }}>
        <h1
          className="font-bold"
          style={{ fontSize: 28, color: C.text, letterSpacing: "-0.01em" }}
        >
          You&apos;re all set.
        </h1>
        <p
          className="mt-3 mx-auto"
          style={{ fontSize: 15, color: C.body, maxWidth: 440, lineHeight: 1.5 }}
        >
          Houston lives in your menubar at the top right of the screen. Click
          the icon any time to open it, or revisit this guide from Help → Show
          onboarding.
        </p>
      </div>
    </div>
  );
}

// ── Primitives ─────────────────────────────────────────────────────────────

function StepDots({ count, current }: { count: number; current: number }) {
  return (
    <div className="flex gap-[6px]">
      {Array.from({ length: count }).map((_, i) => (
        <div
          key={i}
          className="rounded-full transition-all duration-300 ease-out"
          style={{
            width: i === current ? 22 : 6,
            height: 6,
            background: i === current ? C.accent : "rgba(0,0,0,0.15)",
          }}
        />
      ))}
    </div>
  );
}

function ArrowRightIcon() {
  return (
    <svg
      width="16"
      height="16"
      viewBox="0 0 24 24"
      fill="none"
      aria-hidden
      stroke="currentColor"
      strokeWidth="2.2"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M5 12h14" />
      <path d="m13 6 6 6-6 6" />
    </svg>
  );
}

function HouseIcon() {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 16 16"
      fill="none"
      aria-hidden
      style={{ display: "inline-block" }}
    >
      <path
        d="M2 7.2 8 2l6 5.2V14a.8.8 0 0 1-.8.8H9.6V10H6.4v4.8H2.8A.8.8 0 0 1 2 14V7.2Z"
        stroke={C.hint}
        strokeWidth="1.2"
        strokeLinejoin="round"
        fill="none"
      />
    </svg>
  );
}
