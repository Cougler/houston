import SwiftUI
import UniformTypeIdentifiers

/// The capsule shelf and capsule view, in the right sheet like Git and
/// Skills. The shelf lists a project's sealed chats; clicking one opens
/// the capsule view — the sealed chat's FULL transcript — where the user
/// either attaches the whole capsule or drags a fragment of it into the
/// composer. Both land as small chips, never raw text.
struct CapsulePanel: View {
    let projectPath: String
    /// Capsule id to open straight into the transcript view (a chip
    /// click); nil lands on the shelf.
    var focus: String? = nil
    /// Click a capsule row: a new chat with this capsule attached.
    let onAttach: (ChatCapsule) -> Void
    /// Reopen a sealed chat: the capsule dissolves, the transcript opens.
    let onOpenChat: (String) -> Void
    /// Push reference text into the chat composer (the insert buttons).
    let onInsert: (String) -> Void

    @ObservedObject private var store = CapsuleStore.shared
    @State private var viewing: ChatCapsule?

    var body: some View {
        Group {
            if let viewing {
                CapsuleTranscriptView(
                    capsule: viewing,
                    onBack: {
                        withAnimation(.easeOut(duration: 0.18)) {
                            self.viewing = nil
                        }
                    },
                    onAttach: { onAttach(viewing) },
                    onInsert: onInsert
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                shelf
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
        // A chip click retargets an already-open panel to its capsule; a
        // focus-less open (the sidebar row) lands back on the shelf.
        .task(id: focus) {
            if let focus {
                viewing = store.capsules.first { $0.id == focus }
            } else {
                viewing = nil
            }
        }
    }

    private var shelf: some View {
        let capsules = store.capsules(for: projectPath)
        return Group {
            if capsules.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(capsules) { capsule in
                            CapsuleShelfRow(
                                capsule: capsule,
                                onAttach: { onAttach(capsule) },
                                onView: {
                                    withAnimation(.easeOut(duration: 0.18)) {
                                        viewing = capsule
                                    }
                                },
                                onReopen: {
                                    store.unseal(capsule)
                                    onOpenChat(capsule.sourceFile)
                                },
                                onDelete: { delete(capsule) }
                            )
                        }
                    }
                    .padding(.top, 2)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    /// Delete is the destructive one: capsule AND transcript go (the
    /// transcript to the Trash, so it's recoverable).
    private func delete(_ capsule: ChatCapsule) {
        store.unseal(capsule)
        ChatSessionHub.shared.forget(file: capsule.sourceFile)
        ChatMetaStore.shared.forget(capsule.sourceFile)
        try? FileManager.default.trashItem(
            at: URL(fileURLWithPath: capsule.sourceFile), resultingItemURL: nil
        )
        ChatIndexStore.shared.refresh(projectPath, force: true)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "capsule")
                .font(.system(size: 18))
                .foregroundStyle(Theme.textSecondary)
            Text("No capsules yet")
                .font(Theme.Fonts.bodyMedium)
                .foregroundStyle(Theme.text)
            Text("Chats seal into capsules once they go quiet. Click one "
                + "to open it, then attach the whole chat or drag a piece "
                + "of the old conversation in.")
                .font(Theme.Fonts.secondary)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One shelf row. The row click opens the transcript view (attach and
/// fragment-drag live there); dragging the row stages the whole capsule.
private struct CapsuleShelfRow: View {
    let capsule: ChatCapsule
    let onAttach: () -> Void
    let onView: () -> Void
    let onReopen: () -> Void
    let onDelete: () -> Void

    @State private var hovered = false
    @State private var viewHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "capsule")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(capsule.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovered {
                Button(action: onView) {
                    Image(systemName: "eye")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(viewHovered ? Theme.text : Theme.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.radiusControl)
                                .fill(viewHovered ? Theme.controlHovered : Theme.rowHovered)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { viewHovered = $0 }
                .help("Open capsule view — the full transcript")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSurface)
                .fill(Theme.buttonFill)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusSurface)
                        .fill(hovered ? Theme.rowHovered : .clear)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.radiusSurface))
        .onHover { hovered = $0 }
        .onTapGesture { onView() }
        .onDrag { NSItemProvider(object: capsule.referenceText as NSString) }
        .help("Open the capsule — attach the whole chat or drag a piece of it in")
        .contextMenu {
            Button("Open Capsule View") { onView() }
            Button("New Chat with Capsule") { onAttach() }
            Button("Reopen Chat") { onReopen() }
            Button("Reveal Transcript in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: capsule.sourceFile)]
                )
            }
            Divider()
            Button("Delete Chat and Capsule") { onDelete() }
        }
    }

    private var subtitle: String {
        let date = capsule.sealedAt.formatted(.dateTime.month(.abbreviated).day())
        return "\(date) · \(capsule.harness)"
    }
}

/// The capsule view: the sealed chat's full transcript, compact for the
/// sheet's width. Every message drags into the composer as quoted
/// context (the hover + inserts the same without the drag).
private struct CapsuleTranscriptView: View {
    let capsule: ChatCapsule
    let onBack: () -> Void
    let onAttach: () -> Void
    let onInsert: (String) -> Void

    @State private var messages: [ChatMessage]?
    @State private var backHovered = false
    /// The first-use explainer: shows on every capsule open until its
    /// "don't show this again" box is checked (persisted in settings).
    @State private var hintDismissed = HoustonSettings.read().capsuleHintDismissed
    @State private var hintSuppress = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Capsules")
                            .font(Theme.Fonts.secondaryMedium)
                    }
                    .foregroundStyle(backHovered ? Theme.text : Theme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { backHovered = $0 }
                Spacer(minLength: 4)
                // THE way to carry the whole conversation forward — a
                // filled CTA, not a link, so it can't be missed.
                Button(action: onAttach) {
                    HStack(spacing: 5) {
                        Image(systemName: "capsule")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Start a chat with this capsule")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.ctaFill))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Opens a new chat with this whole conversation "
                    + "attached as context")
            }
            .padding(.bottom, 8)

            Text(capsule.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .padding(.bottom, 8)

            if let messages {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { message in
                            CapsuleMessageRow(
                                message: message,
                                capsuleTitle: capsule.title,
                                onInsert: onInsert
                            )
                        }
                    }
                    .padding(.bottom, 12)
                }
                // Like the chat: open on the latest exchange, scroll up
                // for history.
                .defaultScrollAnchor(.bottom)
                .thinScrollbar()
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .bottom) {
            if !hintDismissed { hintCard }
        }
        .task(id: capsule.sourceFile) {
            let ref = ChatSessionRef(
                harness: ChatHarness(rawValue: capsule.harness) ?? .claude,
                filePath: capsule.sourceFile,
                title: capsule.title, modified: capsule.sealedAt
            )
            messages = ChatArchive.cachedTranscript(ref)
            let parsed = await Task.detached(priority: .userInitiated) {
                ChatArchive.transcript(ref)
            }.value
            messages = parsed
        }
    }

    /// What a capsule is and what to do with it, floated over the
    /// transcript's tail. "Got it" dismisses this open; the checkbox
    /// retires it for good.
    private var hintCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "capsule")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.buttonActiveStroke)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.buttonActiveFill))
                Text("This chat is sealed into a capsule")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            Text("Drag any bubble into the composer to quote that piece, "
                + "or start a chat with the whole capsule attached. To "
                + "keep chatting here, right-click the capsule in the "
                + "sidebar and choose Reopen Chat.")
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Toggle("Don't show this again", isOn: $hintSuppress)
                    .toggleStyle(.checkbox)
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 4)
                Button {
                    if hintSuppress {
                        var settings = HoustonSettings.read()
                        settings.capsuleHintDismissed = true
                        HoustonSettings.write(settings)
                    }
                    withAnimation(Theme.quick) {
                        hintDismissed = true
                    }
                } label: {
                    Text("Got it")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Theme.ctaFill))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSurface)
                .fill(Theme.panelFill)
                .shadow(
                    color: Theme.floatShadowColor,
                    radius: Theme.floatShadowRadius,
                    x: 0, y: Theme.floatShadowY
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSurface)
                .strokeBorder(Theme.buttonStroke, lineWidth: 1)
        )
        .padding(.bottom, 8)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

/// One message of the sealed chat, laid out like the chat itself: the
/// user's bubble pushed right in the chat's bubble color, the agent's
/// left. The whole bubble drags as quoted context; the hover + inserts
/// the same.
private struct CapsuleMessageRow: View {
    let message: ChatMessage
    let capsuleTitle: String
    let onInsert: (String) -> Void

    @ObservedObject private var style = ChatStyleStore.shared
    @State private var hovered = false
    @State private var insertHovered = false

    /// Prose and code only — tool chips and nested capsule markers are
    /// plumbing, not quotable content.
    private var text: String {
        message.blocks.compactMap { block -> String? in
            switch block {
            case let .text(t): t
            case let .code(c, lang): "```\(lang ?? "")\n\(c)\n```"
            case .tool, .capsule, .fragment: nil
            }
        }.joined(separator: "\n\n")
    }

    /// What dragging this section into the composer inserts. The
    /// `[Fragment "…"]` wrapper renders back as a small chip
    /// (`ChatArchive.userBlocks`); the model gets the whole quote.
    private var referenceText: String {
        let role = message.role == .user ? "the user said" : "the assistant said"
        let body = text.count > 6_000
            ? String(text.prefix(6_000)) + "\n… (trimmed; the full exchange is in the transcript)"
            : text
        let label = Self.fragmentLabel(for: text)
        return "[Fragment \"\(label)\"]\n"
            + "[From the earlier chat \"\(capsuleTitle)\", \(role):]\n"
            + body + "\n[/Fragment]"
    }

    /// The chip's label: the quote's first ~20 meaningful characters.
    static func fragmentLabel(for text: String) -> String {
        let line = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? text
        let flat = line
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\"", with: "'")
        return flat.count > 20 ? String(flat.prefix(19)) + "…" : flat
    }

    private var isUser: Bool { message.role == .user }

    var body: some View {
        if text.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 0) {
                if isUser { Spacer(minLength: 24) }
                bubble
                if !isUser { Spacer(minLength: 24) }
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        }
    }

    private var bubble: some View {
        Text(text)
            // Chat-scale prose (the transcript reads like the chat it
            // was), with the same dark-mode step-down.
            .font(.system(size: 16))
            .lineSpacing(4)
            .foregroundStyle(isUser ? style.text : Theme.chatProse)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .lineLimit(nil)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusSurface)
                    .fill(isUser ? style.bubble : Theme.attachedWellFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusSurface)
                    .strokeBorder(
                        hovered ? Theme.buttonStroke : .clear, lineWidth: 1
                    )
            )
            // Floats on the bubble's corner, so hover never shifts layout.
            .overlay(alignment: .topTrailing) {
                if hovered { insertButton.padding(3) }
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusSurface))
            .onHover { hovered = $0 }
            .onDrag { NSItemProvider(object: referenceText as NSString) }
            .help("Drag into the composer to quote this section")
    }

    private var insertButton: some View {
        Button {
            onInsert(referenceText)
        } label: {
            Image(systemName: "plus.bubble")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(insertHovered ? Theme.text : Theme.textSecondary)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusControl)
                        .fill(insertHovered
                            ? Theme.controlHovered : Theme.rowHovered)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { insertHovered = $0 }
        .help("Add this section to the chat as context")
    }
}
