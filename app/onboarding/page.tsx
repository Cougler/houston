"use client";

import { useEffect, useState } from "react";

type Step =
  | {
      kind?: "default";
      eyebrow: string;
      title: string;
      body?: string | ((ctx: SetupCtx) => string);
      commands?: { name: string; body: string }[];
      features?: { name: string; body: string }[];
    }
  | {
      kind: "terminal";
      eyebrow: string;
      title: string;
      body: string;
    }
  | {
      kind: "projectsDir";
      eyebrow: string;
      title: string;
      body: string;
    };

type Terminal = "Ghostty" | "Terminal" | "iTerm2";

type SetupCtx = {
  terminal: Terminal | null;
  projectsDir: string | null;
};

const STEPS: Step[] = [
  {
    eyebrow: "Mission control for Claude Code",
    title: "Welcome to Houston",
    body: "Track every Claude session's live context, save your progress between sessions, and keep your local dev workflow flowing — all from a single icon in your menubar.",
  },
  {
    kind: "terminal",
    eyebrow: "Setup",
    title: "Which terminal do you use?",
    body: "Houston spawns new Claude sessions in this terminal and uses it to inject mission commands. You can change this later from Settings.",
  },
  {
    kind: "projectsDir",
    eyebrow: "Setup",
    title: "Where do your projects live?",
    body: "Every folder inside this directory will show up as a project card. Most people keep theirs in ~/Apps or ~/Projects.",
  },
  {
    eyebrow: "Projects",
    title: "Every project, at a glance",
    body: (ctx) =>
      `Every folder in ${displayPath(ctx.projectsDir) ?? "~/Apps"} becomes a card. When you start a Claude session in one, Houston tracks it live — how long it's been running and how full the context is. Click any project to drill into its stats and mission log.`,
  },
  {
    eyebrow: "The core workflow",
    title: "The mission lifecycle",
    body: "Three slash commands keep every session clean from start to finish. Houston's Start button injects /start-mission for you; type the other two yourself when you're wrapping up.",
    commands: [
      {
        name: "/start-mission",
        body: "Spins up your project's dev server. Houston injects this when you click Start.",
      },
      {
        name: "/log-mission",
        body: "Saves a status note, appends to the project's mission log, and writes a fresh CLAUDE.md handoff. Type this yourself when finishing a session.",
      },
      {
        name: "/end-mission",
        body: "Stops the dev server and cleanly exits the Claude CLI. Type this last.",
      },
    ],
  },
  {
    eyebrow: "Everything else",
    title: "The other tabs",
    features: [
      {
        name: "Skills",
        body: "Every slash command installed in ~/.claude/skills, with descriptions — a quick way to remember what's available before typing /.",
      },
      {
        name: "Servers",
        body: "Every dev server on your machine, grouped by project. Open one in your browser with a click, or stop a runaway with one tap.",
      },
      {
        name: "MCP",
        body: "Every MCP server you've configured — Figma, Linear, Gmail, whatever — at a glance.",
      },
    ],
  },
  {
    eyebrow: "Welcome aboard",
    title: "You're all set",
    body: "Houston lives in your menubar at the top-right of the screen. Click the icon any time to open it. Right-click for Reload, Help, and Quit. You can revisit this guide any time from Help → Show onboarding.",
  },
];

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
  const [terminal, setTerminal] = useState<Terminal | null>(null);
  const [projectsDir, setProjectsDir] = useState<string | null>(null);
  const [installed, setInstalled] = useState<Record<string, boolean> | null>(
    null
  );

  // Hydrate from existing settings so revisiting onboarding shows current choices.
  useEffect(() => {
    window.mc?.getSettings().then((s) => {
      if (s?.terminal === "Ghostty" || s?.terminal === "Terminal" || s?.terminal === "iTerm2") {
        setTerminal(s.terminal);
      }
      if (s?.projectsDir) setProjectsDir(s.projectsDir);
    });
    window.mc?.getTerminalStatus?.()
      .then(setInstalled)
      .catch(() => {});
  }, []);

  const isLast = step === STEPS.length - 1;
  const current = STEPS[step];
  const ctx: SetupCtx = { terminal, projectsDir };

  const finish = async () => {
    if (terminal) await window.mc?.setSettings({ terminal });
    if (projectsDir) await window.mc?.setSettings({ projectsDir });
    window.mc?.completeOnboarding();
  };

  const canAdvance =
    current.kind === "terminal"
      ? !!terminal
      : current.kind === "projectsDir"
      ? !!projectsDir
      : true;

  const advance = async () => {
    try {
      if (current.kind === "terminal" && terminal) {
        await window.mc?.setSettings({ terminal });
      } else if (current.kind === "projectsDir" && projectsDir) {
        await window.mc?.setSettings({ projectsDir });
      }
    } catch (e) {
      // Don't block step advancement if persistence fails — surface in console
      // so dev knows. The user-facing error path is `finish()` below.
      console.error("Failed to persist setting:", e);
    }
    if (isLast) finish();
    else setStep((s) => s + 1);
  };

  return (
    <div
      className="h-screen w-screen flex flex-col relative"
      style={{ background: "var(--bg)" }}
    >
      {!isLast && (
        <button
          onClick={finish}
          className="absolute top-5 right-6 text-[13px] font-medium transition-opacity z-10"
          style={{ background: "transparent", color: "var(--muted)" }}
          onMouseEnter={(e) => (e.currentTarget.style.opacity = "0.7")}
          onMouseLeave={(e) => (e.currentTarget.style.opacity = "1")}
        >
          Skip
        </button>
      )}

      <div className="flex-1 flex flex-col items-center justify-center px-12 py-8 overflow-y-auto">
        <div className="w-full max-w-[560px]">
          <div
            className="text-[13px] font-semibold text-center"
            style={{ color: "var(--blue)", letterSpacing: "0.01em" }}
          >
            {current.eyebrow}
          </div>
          <h1
            className="text-[40px] font-bold leading-[1.05] mt-3 text-center"
            style={{ color: "var(--text)", letterSpacing: "-0.03em" }}
          >
            {current.title}
          </h1>
          {current.body && (
            <p
              className="text-[16px] leading-[1.55] mt-5 text-center max-w-[480px] mx-auto"
              style={{ color: "var(--dim)" }}
            >
              {typeof current.body === "function"
                ? current.body(ctx)
                : current.body}
            </p>
          )}

          {current.kind === "terminal" && (
            <div className="mt-8 grid grid-cols-3 gap-3">
              {(["Ghostty", "Terminal", "iTerm2"] as Terminal[]).map((t) => (
                <TerminalCard
                  key={t}
                  name={t}
                  selected={terminal === t}
                  installed={installed ? installed[t] : undefined}
                  onSelect={() => setTerminal(t)}
                />
              ))}
            </div>
          )}

          {current.kind === "projectsDir" && (
            <div className="mt-8">
              <ProjectsDirRow
                value={projectsDir}
                onPick={async () => {
                  const r = await window.mc?.pickDirectory({
                    title: "Choose your projects folder",
                    defaultPath: projectsDir || undefined,
                  });
                  if (r?.ok && r.path) setProjectsDir(r.path);
                }}
              />
            </div>
          )}

          {(current.kind === undefined || current.kind === "default") &&
            "commands" in current &&
            current.commands && (
              <div className="mt-8 flex flex-col gap-3">
                {current.commands.map((c) => (
                  <DetailRow
                    key={c.name}
                    name={c.name}
                    body={c.body}
                    mono
                    width={140}
                  />
                ))}
              </div>
            )}
          {(current.kind === undefined || current.kind === "default") &&
            "features" in current &&
            current.features && (
              <div className="mt-8 flex flex-col gap-3">
                {current.features.map((f) => (
                  <DetailRow
                    key={f.name}
                    name={f.name}
                    body={f.body}
                    width={84}
                  />
                ))}
              </div>
            )}
        </div>
      </div>

      <div className="pb-10 flex flex-col items-center gap-6 flex-shrink-0">
        <StepDots count={STEPS.length} current={step} />

        <div className="flex gap-3 items-center">
          <button
            onClick={() => setStep((s) => s - 1)}
            disabled={step === 0}
            className="px-5 h-11 text-[14px] font-medium transition-opacity"
            style={{
              background: "transparent",
              color: "var(--text)",
              opacity: step === 0 ? 0 : 1,
              pointerEvents: step === 0 ? "none" : "auto",
            }}
            onMouseEnter={(e) => (e.currentTarget.style.opacity = "0.6")}
            onMouseLeave={(e) =>
              (e.currentTarget.style.opacity = step === 0 ? "0" : "1")
            }
          >
            Back
          </button>
          <button
            onClick={advance}
            disabled={!canAdvance}
            className="h-11 rounded-full text-[14px] font-semibold transition-opacity disabled:opacity-40"
            style={{
              background: "var(--blue)",
              color: "#ffffff",
              minWidth: 200,
              paddingLeft: 24,
              paddingRight: 24,
            }}
            onMouseEnter={(e) => {
              if (canAdvance) e.currentTarget.style.opacity = "0.85";
            }}
            onMouseLeave={(e) => (e.currentTarget.style.opacity = "1")}
          >
            {isLast ? "Get started" : "Continue"}
          </button>
        </div>
      </div>
    </div>
  );
}

function TerminalCard({
  name,
  selected,
  installed,
  onSelect,
}: {
  name: Terminal;
  selected: boolean;
  installed?: boolean;
  onSelect: () => void;
}) {
  return (
    <button
      onClick={onSelect}
      className="px-4 py-5 rounded-[14px] text-[14px] font-semibold transition-all flex flex-col items-center justify-center gap-2"
      style={{
        background: selected ? "color-mix(in srgb, var(--blue) 8%, var(--bg))" : "var(--surface)",
        color: "var(--text)",
        border: selected ? "1.5px solid var(--blue)" : "1.5px solid transparent",
        letterSpacing: "-0.01em",
      }}
    >
      <span>{name}</span>
      {installed !== undefined && (
        <span
          className="text-[10px] rounded-full px-2 py-0.5 font-semibold"
          style={{
            background: installed
              ? "color-mix(in srgb, var(--green) 12%, transparent)"
              : "color-mix(in srgb, var(--muted) 12%, transparent)",
            color: installed ? "var(--green)" : "var(--muted)",
            letterSpacing: 0,
          }}
        >
          {installed ? "Installed" : "Not installed"}
        </span>
      )}
    </button>
  );
}

function ProjectsDirRow({
  value,
  onPick,
}: {
  value: string | null;
  onPick: () => void;
}) {
  return (
    <div
      className="flex items-center gap-4 px-5 py-4 rounded-[14px]"
      style={{ background: "var(--surface)" }}
    >
      <div className="flex-1 min-w-0">
        <div
          className="text-[12px] uppercase tracking-wider"
          style={{ color: "var(--muted)" }}
        >
          Projects folder
        </div>
        <div
          className="text-[14px] font-semibold mt-1 truncate"
          style={{
            color: value ? "var(--text)" : "var(--dim)",
            fontFamily:
              "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, monospace",
          }}
        >
          {displayPath(value) ?? "Not chosen yet"}
        </div>
      </div>
      <button
        onClick={onPick}
        className="px-4 h-9 rounded-[8px] text-[13px] font-semibold transition-opacity flex-shrink-0"
        style={{ background: "var(--text)", color: "var(--bg)" }}
        onMouseEnter={(e) => (e.currentTarget.style.opacity = "0.85")}
        onMouseLeave={(e) => (e.currentTarget.style.opacity = "1")}
      >
        Choose folder…
      </button>
    </div>
  );
}

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
            background: i === current ? "var(--blue)" : "var(--border2)",
          }}
        />
      ))}
    </div>
  );
}

function DetailRow({
  name,
  body,
  mono,
  width,
}: {
  name: string;
  body: string;
  mono?: boolean;
  width: number;
}) {
  return (
    <div
      className="flex items-start gap-4 px-5 py-4 rounded-[14px]"
      style={{ background: "var(--surface)" }}
    >
      <span
        className={`text-[14px] font-semibold flex-shrink-0 pt-[1px] ${
          mono ? "tabular-nums" : ""
        }`}
        style={{
          color: mono ? "var(--blue)" : "var(--text)",
          width,
          fontFamily: mono
            ? "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, monospace"
            : undefined,
          letterSpacing: mono ? "0" : "-0.01em",
        }}
      >
        {name}
      </span>
      <p
        className="text-[14px] leading-[1.5]"
        style={{ color: "var(--dim)" }}
      >
        {body}
      </p>
    </div>
  );
}
