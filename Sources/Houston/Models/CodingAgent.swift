import AppKit
import ImageIO
import SwiftUI

/// A CLI coding agent running inside a Houston pane.
///
/// Houston hosts a plain shell; whatever you type into it is yours. Detection
/// is by process name, so any agent works without an integration — but only
/// Claude Code exposes usage on disk, so context tracking is Claude-only (see
/// `ProcessDetect`). Other agents can be shown as *running* and nothing more.
enum CodingAgent: Equatable, Hashable {
    case claude
    case codex
    case grok
    case gemini
    case opencode
    case aider
    case pi
    case other(String)

    /// Binary basenames Houston recognises. Anything else running in a pane is
    /// just a program, not an agent — we don't badge arbitrary commands.
    static let known: [String: CodingAgent] = [
        "claude": .claude,
        "codex": .codex,
        "grok": .grok,
        "gemini": .gemini,
        "opencode": .opencode,
        "aider": .aider,
        "pi": .pi,
    ]

    /// The agents offered by the header's launch dropdown, in menu order.
    static let launchable: [CodingAgent] = [
        .claude, .codex, .grok, .gemini, .opencode, .aider, .pi,
    ]

    static func from(binaryName: String) -> CodingAgent? {
        known[binaryName.lowercased()]
    }

    /// The CLI to type into a shell to start this agent. `nil` for `.other` —
    /// those are detected, never launched.
    var binary: String? {
        Self.known.first { $0.value == self }?.key
    }

    var label: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .grok: "Grok"
        case .gemini: "Gemini"
        case .opencode: "OpenCode"
        case .aider: "Aider"
        case .pi: "Pi"
        case let .other(name): name
        }
    }

    /// One-word name for the launch button ("Claude", per the design).
    var shortLabel: String {
        switch self {
        case .claude: "Claude"
        default: label
        }
    }

    /// Bundled logo asset in `Resources/icons`, when one exists.
    var iconResource: String? {
        switch self {
        case .claude: "Claude"
        case .codex: "ChatGPT"
        case .grok: "Grok"
        case .gemini: "Gemini"
        case .opencode: "OpenCode"
        case .aider: "Aider"
        case .pi: "Pi"
        case .other: nil
        }
    }

    /// Brand-adjacent tint for the sidebar icon (fallback when no logo asset
    /// exists — `.other` agents).
    var tint: Color {
        switch self {
        case .claude: Color(hex: 0xD97757)
        case .codex: Color(hex: 0x10A37F)
        case .grok: Color(hex: 0x2F2F33)
        case .gemini: Color(hex: 0x4285F4)
        case .opencode: Color(hex: 0x8B5CF6)
        case .aider: Color(hex: 0xC08A26)
        case .pi: Color(hex: 0x3B82F6)
        case .other: Color(hex: 0x8C8C8C)
        }
    }

    /// Shell command that installs this agent's CLI. Shown verbatim in the
    /// confirm prompt before it is ever run, and executed in the user's own
    /// pane — never silently.
    var installCommand: String? {
        switch self {
        case .claude: "npm install -g @anthropic-ai/claude-code"
        case .codex: "npm install -g @openai/codex"
        case .gemini: "npm install -g @google/gemini-cli"
        case .opencode: "npm install -g opencode-ai"
        case .grok: "npm install -g @vibe-kit/grok-cli"
        case .pi: "npm install -g @mariozechner/pi"
        case .aider: "python3 -m pip install aider-install && aider-install"
        case .other: nil
        }
    }

    /// Recent models for the status bar's switcher, newest first, as
    /// (menu label, argument to the harness's /model command). Claude args
    /// are Claude Code's aliases and un-dated IDs; other harnesses get their
    /// current model slugs. Empty for harnesses whose CLIs only offer an
    /// interactive picker (the menu hides itself).
    var modelOptions: [(label: String, arg: String)] {
        switch self {
        case .claude: [
            ("Default", "default"),
            ("Fable 5", "fable"),
            ("Fable 5 · 1M", "fable[1m]"),
            ("Opus 5", "opus"),
            ("Opus 4.8", "claude-opus-4-8"),
            ("Opus 4.7", "claude-opus-4-7"),
            ("Sonnet 5", "sonnet"),
            ("Sonnet 4.6", "claude-sonnet-4-6"),
            ("Haiku 4.5", "haiku"),
        ]
        case .codex: [
            ("GPT-6 Codex", "gpt-6-codex"),
            ("GPT-6 Astra", "gpt-6-astra"),
            ("GPT-5.6 Sol", "gpt-5.6-sol"),
            ("GPT-5.6 Terra", "gpt-5.6-terra"),
            ("GPT-5.6 Luna", "gpt-5.6-luna"),
            ("GPT-5.5", "gpt-5.5"),
        ]
        case .gemini: [
            ("Gemini 3 Pro", "gemini-3-pro-preview"),
            ("Gemini 2.5 Pro", "gemini-2.5-pro"),
            ("Gemini 2.5 Flash", "gemini-2.5-flash"),
            ("Gemini 2.5 Flash-Lite", "gemini-2.5-flash-lite"),
        ]
        case .grok: [
            ("Grok 4.1", "grok-4-1"),
            ("Grok 4", "grok-4"),
            ("Grok 4 Fast", "grok-4-fast"),
            ("Grok Code Fast", "grok-code-fast-1"),
        ]
        case .aider: [
            ("Claude Sonnet", "sonnet"),
            ("Claude Opus", "opus"),
            ("Claude Haiku", "haiku"),
            ("GPT-5.1", "openai/gpt-5.1"),
            ("Gemini 2.5 Pro", "gemini/gemini-2.5-pro"),
        ]
        case .opencode, .pi, .other: []
        }
    }
}

