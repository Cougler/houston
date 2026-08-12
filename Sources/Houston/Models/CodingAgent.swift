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
}

/// The 16pt mark at the left of a Terminals row: a plain terminal glyph for a
/// bare shell, or the running agent's logo from `Resources/icons` (with a
/// tinted-monogram fallback for agents without an asset).
struct TerminalRowIcon: View {
    let agent: CodingAgent?
    /// Point size; 16 for terminal rows, smaller for nested shells.
    var size: CGFloat = 16
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let agent {
            Group {
                if let resource = agent.iconResource,
                   let logo = AgentIconCache.image(
                       named: resource, darkMode: colorScheme == .dark
                   ) {
                    // Cached at 32px (16pt @2x); resizable so smaller display
                    // sizes downscale instead of overflowing the frame.
                    Image(nsImage: logo)
                        .resizable()
                        .interpolation(.high)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: size / 4)
                            .fill(agent.tint)
                        Text(String(agent.label.prefix(1)))
                            .font(.system(
                                size: size * 0.56, weight: .bold, design: .rounded
                            ))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(width: size, height: size)
            .help("\(agent.label) session")
        } else {
            Image(systemName: "terminal")
                .font(.system(size: size * 0.69))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: size, height: size)
                .help("Shell session")
        }
    }
}

/// Logo bitmaps, loaded from the bundle once per appearance and normalised to
/// display size (32px = 16pt @2x) via ImageIO's filtered thumbnailer — 32px
/// exports pass straight through, larger sources downsample cleanly.
///
/// Appearance variants: `<Name> - dark.png` / `<Name> - light.png` are
/// preferred in the matching appearance, with `<Name>.png` as the fallback.
@MainActor
enum AgentIconCache {
    private static var cache: [String: NSImage] = [:]

    static func image(named name: String, darkMode: Bool) -> NSImage? {
        let key = "\(name)|\(darkMode ? "d" : "l")"
        if let hit = cache[key] { return hit }

        let candidates = darkMode
            ? ["\(name) - dark", name]
            : ["\(name) - light", name]
        guard let url = candidates.lazy.compactMap({
            Bundle.module.url(forResource: $0, withExtension: "png", subdirectory: "icons")
        }).first else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        let image = NSImage(cgImage: cg, size: NSSize(width: 16, height: 16))
        cache[key] = image
        return image
    }
}
