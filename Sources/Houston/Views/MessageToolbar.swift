import SwiftUI

/// What a finished message's toolbar can do (2026-10-21, the row of
/// small actions under each message in Claude Code's desktop chat).
/// Every closure is optional: the toolbar shows the buttons it was
/// given, so a harness or a context that can't retry (a live turn, a
/// capsule view) just passes fewer.
struct MessageActions {
    /// Send the prompt again (an assistant reply: the prompt that
    /// produced it; a user message: itself).
    var onRetry: (() -> Void)?
    /// Put a user message's text back in the composer to change it.
    var onEdit: (() -> Void)?
    /// Fork the chat so an alternative continues apart from this one.
    var onBranch: (() -> Void)?
}

/// The toolbar: copy, retry, edit, branch — icon buttons that fade in
/// when the pointer is over the message, under the reply (assistant) or
/// under the bubble, right-aligned (user).
struct MessageToolbar: View {
    let message: ChatMessage
    let actions: MessageActions
    var visible: Bool

    @State private var copied = false

    /// The message as plain markdown — prose and code, no step chips.
    static func copyText(_ message: ChatMessage) -> String {
        message.blocks.compactMap { block -> String? in
            switch block {
            case let .text(t): t
            case let .code(c, lang): "```" + (lang ?? "") + "\n" + c + "\n```"
            default: nil
            }
        }.joined(separator: "\n\n")
    }

    var body: some View {
        HStack(spacing: 2) {
            ToolbarIcon(icon: copied ? "check" : "copy", help: "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.copyText(message), forType: .string)
                withAnimation(.easeOut(duration: 0.12)) { copied = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.2))
                    withAnimation(.easeOut(duration: 0.2)) { copied = false }
                }
            }
            if let onEdit = actions.onEdit {
                ToolbarIcon(icon: "square-pen", help: "Edit and resend", action: onEdit)
            }
            if let onRetry = actions.onRetry {
                ToolbarIcon(
                    icon: "refresh-cw",
                    help: message.role == .user ? "Send again" : "Retry this reply",
                    action: onRetry
                )
            }
            if let onBranch = actions.onBranch {
                ToolbarIcon(icon: "git-branch", help: "Branch the chat from here", action: onBranch)
            }
        }
        .opacity(visible || copied ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: visible)
        .accessibilityHidden(!visible)
    }
}

/// One toolbar glyph with the hover wash.
struct ToolbarIcon: View {
    let icon: String
    let help: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            LucideIcon(icon, size: 13)
                .foregroundStyle(hovered ? Theme.text : Theme.textSecondary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusControl)
                        .fill(hovered ? Theme.rowHovered : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}
