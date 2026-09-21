import SwiftUI

/// The capsule shelf, in the right sheet like Git and Skills. It lists a
/// project's sealed chats; clicking one opens the capsule DIALOG — a
/// centered modal owned by MainWindowView — where the user attaches the
/// whole capsule or selects fragments. Both land as small chips, never
/// raw text.
struct CapsulePanel: View {
    let projectPath: String
    /// Click a capsule row: a new chat with this capsule attached.
    let onAttach: (ChatCapsule) -> Void
    /// Reopen a sealed chat: the capsule dissolves, the transcript opens.
    let onOpenChat: (String) -> Void
    /// Open the centered capsule dialog on this capsule.
    let onView: (ChatCapsule) -> Void

    @ObservedObject private var store = CapsuleStore.shared

    var body: some View {
        shelf
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity, alignment: .top)
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
                                onView: { onView(capsule) },
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
                + "to open it, then add the entire capsule to a chat or "
                + "select the pieces you want as fragments.")
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

/// The capsule dialog: a centered modal (MainWindowView owns the scrim
/// and presentation) showing the sealed chat's full transcript. Bubbles
/// select like a checklist; the bottom bar adds the selection as
/// fragments or attaches the entire capsule. First open shows the
/// "Introducing Capsules" explainer in its place.
struct CapsuleDialog: View {
    let capsule: ChatCapsule
    let onClose: () -> Void
    let onAttach: () -> Void
    /// Selected fragments' reference texts, in transcript order.
    let onInsert: ([String]) -> Void

    @State private var messages: [ChatMessage]?
    @State private var selected: Set<String> = []
    /// The first-use explainer: fronts the dialog on every capsule open
    /// until its "don't show this again" box is checked. The OPENER reads
    /// the persisted flag once — a settings read in a property initializer
    /// would re-hit disk on every parent body evaluation.
    @State private var showIntro: Bool
    @State private var hintSuppress = false

    init(
        capsule: ChatCapsule,
        showIntroInitially: Bool,
        onClose: @escaping () -> Void,
        onAttach: @escaping () -> Void,
        onInsert: @escaping ([String]) -> Void
    ) {
        self.capsule = capsule
        self.onClose = onClose
        self.onAttach = onAttach
        self.onInsert = onInsert
        _showIntro = State(initialValue: showIntroInitially)
    }

    var body: some View {
        Group {
            if showIntro {
                introView
                    .frame(width: 420)
            } else {
                capsuleContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Same surface as the chat itself (near-black in dark) so the
        // capsule reads as the conversation it was, not a panel.
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusFloat)
                .fill(Theme.gitPanelFill)
                .shadow(
                    color: Theme.floatShadowColor,
                    radius: Theme.floatShadowRadius,
                    x: 0, y: Theme.floatShadowY
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusFloat)
                .strokeBorder(Theme.borderSidebar, lineWidth: 1)
        )
        .onExitCommand { onClose() }
        .task(id: capsule.sourceFile) {
            let ref = ChatSessionRef(
                harness: ChatHarness(rawValue: capsule.harness) ?? .claude,
                filePath: capsule.sourceFile,
                title: capsule.title, modified: capsule.sealedAt
            )
            // Filtered ONCE here — running quotableText over the whole
            // transcript in the render path made every selection toggle
            // pay an O(messages × blocks) string pass.
            messages = ChatArchive.cachedTranscript(ref).map(Self.contentOnly)
            let parsed = await Task.detached(priority: .userInitiated) {
                ChatArchive.transcript(ref)
            }.value
            messages = Self.contentOnly(parsed)
        }
    }

    /// Prose/code messages only — tool-only messages would render as a
    /// bare role label with nothing quotable.
    private static func contentOnly(_ all: [ChatMessage]) -> [ChatMessage] {
        all.filter { !CapsuleMessageRow.quotableText(of: $0).isEmpty }
    }

    // MARK: - Intro

    /// "Introducing Capsules" — a traditional first-run dialog, centered
    /// copy, buttons at the bottom.
    private var introView: some View {
        VStack(spacing: 14) {
            Image(systemName: "capsule")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Theme.buttonActiveStroke)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Theme.buttonActiveFill))
            Text("Introducing Capsules")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("A finished chat seals into a capsule: the whole "
                + "conversation, ready to reuse. Select the pieces you "
                + "want and add them to a chat as fragments, or add the "
                + "entire capsule as context. To pick up where it left "
                + "off, right-click the capsule and choose Reopen Chat.")
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Toggle("Don't show this again", isOn: $hintSuppress)
                    .toggleStyle(.checkbox)
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 4)
                DialogButton(title: "Got it", primary: true) {
                    if hintSuppress {
                        var settings = HoustonSettings.read()
                        settings.capsuleHintDismissed = true
                        HoustonSettings.write(settings)
                    }
                    withAnimation(Theme.quick) { showIntro = false }
                }
            }
            .padding(.top, 6)
        }
        .padding(24)
    }

    // MARK: - Capsule content

    private var capsuleContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "capsule")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.buttonActiveStroke)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.buttonActiveFill))
                VStack(alignment: .leading, spacing: 1) {
                    Text(capsule.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(sealedLine)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 8)
                // Own hover state (CircleIconButton) — a dialog-level
                // hover flag re-diffed the whole transcript per enter/leave.
                CircleIconButton(
                    systemName: "xmark", size: 24,
                    help: "Close", action: onClose
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            hairline

            if let messages {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(messages) { message in
                            CapsuleMessageRow(
                                message: message,
                                harness: harness,
                                capsuleTitle: capsule.title,
                                isSelected: selected.contains(message.id),
                                onToggle: { toggle(message) },
                                onAdd: { onInsert([reference(for: message)]) }
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    // Chat-width reading column: agent prose gets a max
                    // width, no min, and centers in the wider dialog.
                    .frame(maxWidth: 780)
                    .frame(maxWidth: .infinity)
                }
                // Like the chat: open on the latest exchange, scroll up
                // for history.
                .defaultScrollAnchor(.bottom)
                .thinScrollbar()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            hairline

            // Traditional dialog footer: status on the left, actions
            // bottom-right, primary on the outside.
            HStack(spacing: 12) {
                if !selected.isEmpty {
                    Text("\(selected.count) selected")
                        .font(Theme.Fonts.secondary)
                        .foregroundStyle(Theme.textSecondary)
                    LinkButton(title: "Clear", size: 11) { selected = [] }
                }
                Spacer(minLength: 8)
                DialogButton(
                    title: "Add entire capsule",
                    primary: selected.isEmpty,
                    action: onAttach
                )
                if !selected.isEmpty {
                    DialogButton(
                        title: selected.count == 1
                            ? "Add 1 fragment"
                            : "Add \(selected.count) fragments",
                        primary: true,
                        action: { onInsert(selectedReferences) }
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private var hairline: some View {
        Rectangle().fill(Theme.borderSidebar).frame(height: 1)
    }

    private var harness: ChatHarness {
        ChatHarness(rawValue: capsule.harness) ?? .claude
    }

    private var sealedLine: String {
        let date = capsule.sealedAt.formatted(.dateTime.month(.abbreviated).day())
        return "Sealed \(date) · \(capsule.harness)"
    }

    private func toggle(_ message: ChatMessage) {
        if selected.contains(message.id) {
            selected.remove(message.id)
        } else {
            selected.insert(message.id)
        }
    }

    /// The ONE place a fragment's reference string is built — the quick
    /// add and the multi-select footer must produce identical chips.
    private func reference(for message: ChatMessage) -> String {
        CapsuleMessageRow.referenceText(for: message, capsuleTitle: capsule.title)
    }

    private var selectedReferences: [String] {
        (messages ?? [])
            .filter { selected.contains($0.id) }
            .map { reference(for: $0) }
    }
}

/// One message of the sealed chat, rendered through the chat's own
/// `MessageView` so the capsule reads exactly like the conversation:
/// agent replies as plain prose (no min width, a reading max width, no
/// well), the user's turn as the orange bubble. The whole message is a
/// hover row — it washes under the pointer and surfaces its controls
/// (select toggle, quick add) at the top-right; a selected row keeps a
/// quiet accent wash and its check.
private struct CapsuleMessageRow: View {
    let message: ChatMessage
    let harness: ChatHarness
    let capsuleTitle: String
    let isSelected: Bool
    let onToggle: () -> Void
    /// Insert just this fragment, immediately.
    let onAdd: () -> Void

    @State private var hovered = false
    @State private var toggleHovered = false

    /// Prose and code only — tool chips and nested capsule markers are
    /// plumbing, not quotable content.
    static func quotableText(of message: ChatMessage) -> String {
        message.blocks.compactMap { block -> String? in
            switch block {
            case let .text(t): t
            case let .code(c, lang): "```\(lang ?? "")\n\(c)\n```"
            case .tool, .capsule, .fragment, .image: nil
            }
        }.joined(separator: "\n\n")
    }

    /// What a selected section inserts into the composer. The
    /// `[Fragment "…"]` wrapper renders back as a small chip
    /// (`ChatArchive.userBlocks`); the model gets the whole quote.
    static func referenceText(
        for message: ChatMessage, capsuleTitle: String
    ) -> String {
        let text = quotableText(of: message)
        let role = message.role == .user ? "the user said" : "the assistant said"
        let body = text.count > 6_000
            ? String(text.prefix(6_000)) + "\n… (trimmed; the full exchange is in the transcript)"
            : text
        let label = fragmentLabel(for: text)
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // The controls live in a fixed gutter OUTSIDE the message and
            // its wash — they never overlap content, and the reserved
            // width keeps every message's left edge aligned. They fade in
            // on hover; the check stays visible while selected.
            HStack(spacing: 4) {
                if hovered { addButton }
                selectToggle
            }
            .frame(width: 48, alignment: .trailing)
            .padding(.top, 12)
            .opacity(hovered || isSelected ? 1 : 0)
            MessageView(message: message, harness: harness, showTools: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                // The message is the fragment's surface: it washes under
                // the pointer; a selected one holds a quiet accent tint.
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusSurface)
                        .fill(isSelected
                            ? Theme.buttonActiveFill
                            : hovered ? Theme.cardHovered : .clear)
                )
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    private var selectToggle: some View {
        Button(action: onToggle) {
            ZStack {
                if isSelected {
                    Circle().fill(Theme.buttonActiveStroke)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Circle()
                        .fill(Theme.controlChip)
                    Circle()
                        .strokeBorder(
                            toggleHovered
                                ? Theme.buttonActiveStroke : Theme.buttonStroke,
                            lineWidth: 1.5
                        )
                }
            }
            .frame(width: 20, height: 20)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { toggleHovered = $0 }
        .help(isSelected
            ? "Remove from the selection"
            : "Select this section to add as a fragment")
    }

    private var addButton: some View {
        CircleIconButton(
            systemName: "plus",
            help: "Add just this fragment to the chat",
            action: onAdd
        )
    }
}
