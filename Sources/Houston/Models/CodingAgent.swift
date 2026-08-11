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
}
