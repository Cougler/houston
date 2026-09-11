import SwiftUI

/// One entry in the composer's model menu — the harness decides which CLI
/// the send runs, the arg rides its --model flag (nil = that CLI's default).
/// `effort` is the reasoning-effort level riding alongside (nil = the
/// model's default): `--effort` for Claude, `model_reasoning_effort` for
/// Codex.
/// How much a chat's agent may do without asking, mapped onto each CLI's
/// own controls: claude's `--permission-mode` (a spawn flag — changing it
/// respawns, like a model change), codex's per-turn approvalPolicy +
/// sandboxPolicy.
enum ChatPermissionMode: String, CaseIterable, Hashable {
    case ask, edits, full

    var label: String {
        switch self {
        case .ask: "Ask first"
        case .edits: "Auto edits"
        case .full: "Full access"
        }
    }

    var detail: String {
        switch self {
        case .ask: "Approve edits and commands as they come"
        case .edits: "Edits run free; risky commands still ask"
        case .full: "No sandbox, no questions"
        }
    }
}

struct ChatModelChoice: Hashable {
    let label: String
    let harness: ChatHarness
    let arg: String?
    var effort: String? = nil
    var permission: ChatPermissionMode = .ask
    /// Local-engine provider id (`LocalModelStore.mlxProviderID`) — makes
    /// the codex spawn carry the provider's config override and the thread
    /// start with `modelProvider`. nil = the harness's cloud default.
    var provider: String? = nil

    static let claude: [ChatModelChoice] = [
        .init(label: "Fable 5", harness: .claude, arg: "fable"),
        .init(label: "Opus 5", harness: .claude, arg: "opus"),
        .init(label: "Sonnet 5", harness: .claude, arg: "sonnet"),
        .init(label: "Haiku 4.5", harness: .claude, arg: "haiku"),
    ]
    static let openAI: [ChatModelChoice] = [
        .init(label: "GPT-6 Astra", harness: .codex, arg: "gpt-6-astra"),
        .init(label: "GPT-5.6 Sol", harness: .codex, arg: "gpt-5.6-sol"),
        .init(label: "GPT-5.6 Terra", harness: .codex, arg: "gpt-5.6-terra"),
        .init(label: "GPT-5.6 Luna", harness: .codex, arg: "gpt-5.6-luna"),
        .init(label: "GPT-5.5", harness: .codex, arg: "gpt-5.5"),
    ]

    /// A local MLX Core model — runs through codex against the local
    /// server, so everything downstream (streaming, approvals, resume)
    /// is the codex path.
    static func mlx(_ model: String) -> ChatModelChoice {
        .init(label: LocalModelStore.displayName(model), harness: .codex,
              arg: model, provider: LocalModelStore.mlxProviderID)
    }

    /// Effort levels each CLI accepts, as (menu label, flag value).
    static func efforts(for harness: ChatHarness) -> [(label: String, arg: String)] {
        switch harness {
        case .claude: [
            ("Low", "low"), ("Medium", "medium"), ("High", "high"),
            ("XHigh", "xhigh"), ("Max", "max"),
        ]
        case .codex: [
            ("Minimal", "minimal"), ("Low", "low"), ("Medium", "medium"),
            ("High", "high"), ("XHigh", "xhigh"),
        ]
        }
    }

    /// Same model, one harness's effort levels only carry to that harness.
    /// Local models take no effort level — the local server decides.
    func applying(effort chosen: String?, permission mode: ChatPermissionMode) -> ChatModelChoice {
        var out = self
        out.effort = provider == nil ? chosen.flatMap { pick in
            Self.efforts(for: harness).contains { $0.arg == pick } ? pick : nil
        } : nil
        out.permission = mode
        return out
    }

    static func fallback(for harness: ChatHarness) -> ChatModelChoice {
        harness == .codex ? openAI[0] : claude[0]
    }

    /// The flags this choice adds to its CLI invocation. Codex takes
    /// effort as a config override; the unquoted value reaches it intact
    /// (a non-TOML value is used as a literal string).
    var cliFlags: String {
        var out = ""
        if let arg { out += " --model \(arg)" }
        if let effort {
            out += harness == .claude
                ? " --effort \(effort)"
                : " -c model_reasoning_effort=\(effort)"
        }
        return out
    }
}

/// The detail pane's chat browser: every session either harness has written
/// for this project, listed newest-first, opening into a clean rich-text
/// transcript — the same history the terminal shows, in chat form.
/// Sends run through `ChatSessionHub`: a persistent agent process per open
/// chat, streaming into the view — no terminal, no polling.
struct ChatBrowserView: View {
    let projectPath: String
    /// Jump straight into this transcript (a sidebar chat row); nil opens
    /// the new-chat empty state — the sidebar IS the chat list.
    var initialSessionFile: String? = nil

    @ObservedObject private var titler = ChatTitler.shared
    @ObservedObject private var hub = ChatSessionHub.shared
    @ObservedObject private var meta = ChatMetaStore.shared
    @State private var selected: ChatSessionRef?
    @State private var messages: [ChatMessage]?
    @State private var loadToken = 0
    /// Entrance for the empty state's greeting and composer.
    @State private var skyRevealed = false
    /// Messages rendered at the transcript's tail; "Show earlier" raises it.
    @State private var historyShown = 150
    /// Bumped on every send so the transcript scrolls the new bubble into view.
    @State private var sendScrollTick = 0

    /// The selection is derived synchronously from the file path — going
    /// through a directory listing first flashed the empty state over
    /// every chat open.
    init(projectPath: String, initialSessionFile: String? = nil) {
        self.projectPath = projectPath
        self.initialSessionFile = initialSessionFile
        _selected = State(initialValue: initialSessionFile.map(Self.quickRef))
    }

    private static func quickRef(_ file: String) -> ChatSessionRef {
        ChatSessionRef(
            harness: file.contains("/.codex/") ? .codex : .claude,
            filePath: file, title: "", modified: .distantPast
        )
    }

    var body: some View {
        Group {
            if let selected {
                transcriptView(selected)
            } else if let draft = hub.drafts[projectPath] {
                draftView(draft)
            } else {
                newChatView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.gitPanelFill)
        // Closing the browser drops idle agent processes; mid-turn ones
        // stay so their turn can finish writing the transcript.
        .onDisappear { hub.releaseIdle() }
        // The file is part of the identity so retargeting (another sidebar
        // row, a run finishing in a fresh file) reloads into it.
        .task(id: projectPath + "|" + (initialSessionFile ?? "")) {
            messages = nil
            historyShown = 150
            selected = initialSessionFile.map(Self.quickRef)
            if let selected { reload(selected) }
        }
    }

    private func open(_ ref: ChatSessionRef) {
        selected = ref
        messages = nil
        historyShown = 150
        reload(ref)
    }

    /// Re-parse the transcript; the current render stays up until the new
    /// one lands, so live refreshes don't flicker.
    private func reload(_ ref: ChatSessionRef) {
        loadToken += 1
        let token = loadToken
        Task {
            let parsed = await Task.detached(priority: .userInitiated) {
                ChatArchive.transcript(ref)
            }.value
            if token == loadToken { messages = parsed }
        }
    }

    // MARK: - Transcript

    private func transcriptView(_ ref: ChatSessionRef) -> some View {
        // No header — the sidebar row is the chat's name and way out.
        VStack(spacing: 0) {
            if let messages {
                // A plain VStack, bounded by `historyShown` — LazyVStack
                // plus scroll-to-bottom is what left the viewport blank
                // until a nudge; eager layout can't. The cap keeps giant
                // transcripts from eagerly building thousands of views.
                // Tool-only messages would render as a bare role label
                // with the chips hidden — skip them entirely.
                let visible = Array(messages.suffix(historyShown)).filter { message in
                    message.blocks.contains { block in
                        if case .tool = block { return false }
                        return true
                    }
                }
                GeometryReader { geo in
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 28) {
                                if messages.count > historyShown {
                                    Button("Show earlier messages") {
                                        historyShown += 200
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.link)
                                    .frame(maxWidth: .infinity)
                                }
                                ForEach(visible) { message in
                                    MessageView(
                                        message: message, harness: ref.harness,
                                        showTools: false
                                    )
                                    .id(message.id)
                                }
                                if let session = hub.sessions[ref.filePath] {
                                    LiveTurnView(session: session, harness: ref.harness) {
                                        reloadThenClear(ref, session)
                                    }
                                }
                                Color.clear.frame(height: 1).id("chat-bottom")
                            }
                            .padding(.horizontal, 32)
                            .padding(.vertical, 18)
                            .frame(maxWidth: 800)
                            .frame(maxWidth: .infinity)
                            // Stretched to at least the viewport, content
                            // pinned to its top: a short chat reads from
                            // the top instead of dropping to the bottom,
                            // while the bottom anchor still follows growth
                            // once the content actually overflows.
                            .frame(minHeight: geo.size.height, alignment: .top)
                            .thinScrollbar()
                        }
                        .defaultScrollAnchor(.bottom)
                        .onChange(of: messages.count) {
                            proxy.scrollTo("chat-bottom", anchor: .bottom)
                        }
                        .onChange(of: sendScrollTick) {
                            proxy.scrollTo("chat-bottom", anchor: .bottom)
                        }
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ChatComposer(
                placeholder: "What's next?",
                initialModel: hub.sessions[ref.filePath]?.lastModel
                    ?? .fallback(for: ref.harness),
                ghostContext: ref.harness == .claude ? ghostContext : nil,
                runningSession: hub.sessions[ref.filePath],
                onSend: { text, model in
                    handleSend(ref, text: text, model: model)
                }
            )
        }
    }

    // MARK: - New chat empty state

    /// The project "+" landing: the night sky and solar system with a
    /// greeting and the composer floating mid-pane — a chat begins here,
    /// no terminal anywhere.
    private var newChatView: some View {
        ZStack {
            NightSky()
            SolarSystem()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: -70)
            VStack(spacing: 20) {
                Spacer()
                Spacer()
                Text("What's the mission for \(projectName)?")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.skyText)
                    .opacity(skyRevealed ? 1 : 0)
                    .offset(y: skyRevealed ? 0 : 8)
                ChatComposer(
                    placeholder: "Let's do it…",
                    initialModel: .fallback(for: .claude),
                    ghostContext: nil,
                    onSend: { text, model in
                        hub.draft(in: projectPath, harness: model.harness)
                            .send(text: text, model: model)
                    }
                )
                .frame(maxWidth: 640)
                .opacity(skyRevealed ? 1 : 0)
                .offset(y: skyRevealed ? 0 : 8)
                Spacer()
            }
            .padding(.top, 120)
        }
        .background(Theme.emptyStateBackground)
        .clipped()
        .onAppear {
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.5).delay(0.15)) {
                    skyRevealed = true
                }
            }
        }
    }

    private var projectName: String {
        projectPath == NSHomeDirectory()
            ? "~" : (projectPath as NSString).lastPathComponent
    }

    // MARK: - New chat (draft)

    /// A chat that doesn't have a transcript file yet: the live turn is
    /// the whole conversation. Once its first turn lands, the draft is
    /// promoted onto its real file and this becomes a normal transcript.
    private func draftView(_ session: ChatAgentSession) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    LiveTurnView(session: session, harness: session.harness) {
                        promoteDraft(session)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 18)
                .frame(maxWidth: 800)
                .frame(maxWidth: .infinity)
                .thinScrollbar()
            }
            ChatComposer(
                placeholder: "What's next?",
                initialModel: session.lastModel ?? .fallback(for: session.harness),
                ghostContext: nil,
                runningSession: session,
                onSend: { text, model in
                    hub.draft(in: projectPath, harness: model.harness)
                        .send(text: text, model: model)
                }
            )
        }
    }

    /// First turn finished: find the transcript file the run created and
    /// rekey the draft session onto it.
    private func promoteDraft(_ session: ChatAgentSession) {
        Task {
            let project = projectPath
            // The transcript file may lag the turn-done event by a beat —
            // giving up on the first miss left the draft stuck on its
            // live turn forever.
            var found: String?
            for attempt in 0..<10 {
                let file: String?
                switch session.harness {
                case .claude:
                    file = session.sessionID.map {
                        ChatArchive.claudeProjectDir(for: project) + "/" + $0 + ".jsonl"
                    }
                case .codex:
                    file = await Task.detached(priority: .userInitiated) {
                        ChatArchive.sessions(for: project)
                            .first { $0.harness == .codex }?.filePath
                    }.value
                }
                if let file, FileManager.default.fileExists(atPath: file) {
                    found = file
                    break
                }
                if attempt < 9 { try? await Task.sleep(nanoseconds: 500_000_000) }
            }
            guard let file = found else { return }
            hub.promoteDraft(in: project, to: file)
            let ref = ChatSessionRef(
                harness: session.harness, filePath: file,
                title: session.pendingUserText.map { String($0.prefix(80)) } ?? "New chat",
                modified: Date()
            )
            selected = ref
            reloadThenClear(ref, session)
        }
    }

    // MARK: - Sends

    /// Same harness resumes in place; the other harness transplants the
    /// transcript into a fresh native session first, then continues there.
    private func handleSend(_ ref: ChatSessionRef, text: String, model: ChatModelChoice) {
        sendScrollTick += 1
        if model.harness == ref.harness {
            hub.session(for: ref, project: projectPath)
                .send(text: text, model: model)
        } else {
            transplantAndSend(ref, text: text, model: model)
        }
    }

    private func transplantAndSend(
        _ ref: ChatSessionRef, text: String, model: ChatModelChoice
    ) {
        Task {
            let target = model.harness
            let project = projectPath
            let source = await Task.detached(priority: .userInitiated) {
                ChatArchive.transcript(ref)
            }.value
            // Long chats travel as handoff brief + verbatim tail so the
            // target model doesn't ingest (or get billed for) the whole
            // history; short ones copy whole.
            var payload = source
            if ChatArchive.flatSize(source) > ChatArchive.fullTransplantMax {
                let (chunks, tail) = ChatArchive.splitForHandoff(source)
                let brief = await ChatTitler.handoffBrief(chunks)
                    ?? "(The earlier part of this conversation was truncated "
                    + "in transfer. Ask the user for anything you're missing.)"
                payload = [ChatArchive.handoffMessage(brief: brief, from: ref.harness)]
                    + tail
            }
            let toExport = payload
            let exported = await Task.detached(priority: .userInitiated) { () -> (String, String)? in
                guard let id = target == .claude
                    ? ChatArchive.exportToClaude(toExport, projectPath: project)
                    : ChatArchive.exportToCodex(toExport, projectPath: project)
                else { return nil }
                let file = target == .claude
                    ? ChatArchive.claudeProjectDir(for: project) + "/" + id + ".jsonl"
                    : ChatArchive.codexRolloutPath(id: id)
                return file.map { (id, $0) }
            }.value
            guard let (id, file) = exported else {
                // Transplant failed — fall back to a fresh chat there.
                hub.draft(in: project, harness: target).send(text: text, model: model)
                selected = nil
                return
            }
            let newRef = ChatSessionRef(
                harness: target, filePath: file,
                title: titler.displayTitle(ref), modified: Date()
            )
            selected = newRef
            reload(newRef)
            hub.adopt(file: file, harness: target, project: project, id: id)
                .send(text: text, model: model)
            ChatIndexStore.shared.refresh(project, force: true)
        }
    }

    /// Turn finished: absorb it into the transcript, then clear the live
    /// section (order matters — clearing first would flash the turn away).
    /// The CLI's turn-done event can beat its transcript flush, so the
    /// read retries until the file actually contains the finished turn —
    /// clearing against a stale read is what ate the first response.
    private func reloadThenClear(_ ref: ChatSessionRef, _ session: ChatAgentSession) {
        loadToken += 1
        let token = loadToken
        let userText = session.pendingUserText
        let finalText = Self.finalAssistantText(session)
        Task {
            var parsed: [ChatMessage] = []
            for attempt in 0..<15 {
                parsed = await Task.detached(priority: .userInitiated) {
                    ChatArchive.transcript(ref)
                }.value
                if Self.containsTurn(parsed, for: userText, finalText: finalText)
                    || attempt == 14 { break }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            if token == loadToken { messages = parsed }
            session.clearTurn()
            ChatIndexStore.shared.refresh(projectPath, force: true)
        }
    }

    /// The last chunk of assistant text the live turn holds — the marker
    /// that the transcript flush actually reached the end of the turn.
    private static func finalAssistantText(_ session: ChatAgentSession) -> String? {
        if !session.streamText.isEmpty { return session.streamText }
        for block in session.liveBlocks.reversed() {
            if case let .text(text) = block { return text }
        }
        return nil
    }

    /// Does the parsed transcript already hold the turn that just ended —
    /// the user's message followed by the turn's FINAL assistant text?
    /// Matching any assistant text is not enough: a turn's opening line
    /// flushes to disk before its tool calls run, so an early match let
    /// `clearTurn` wipe the still-unflushed tail of the response.
    private static func containsTurn(
        _ messages: [ChatMessage], for userText: String?, finalText: String?
    ) -> Bool {
        guard let userText, !userText.isEmpty else { return !messages.isEmpty }
        let needle = String(userText.prefix(60))
        guard let index = messages.lastIndex(where: { message in
            message.role == .user && message.blocks.contains { block in
                if case let .text(text) = block { return text.contains(needle) }
                return false
            }
        }) else { return false }
        let tail = String(
            (finalText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).suffix(60)
        )
        return messages[index...].contains { message in
            message.role == .assistant && message.blocks.contains { block in
                if case let .text(text) = block {
                    // A turn with no streamed text (tool-only, or one that
                    // errored out) settles for any assistant text.
                    return tail.isEmpty || text.contains(tail)
                }
                return false
            }
        }
    }

    /// The transcript's autocomplete context: the tail of the conversation.
    private var ghostContext: String {
        guard let messages else { return "" }
        var parts: [String] = []
        for message in messages.suffix(3) {
            for block in message.blocks {
                if case let .text(text) = block {
                    let role = message.role == .user ? "User" : "Assistant"
                    parts.append("\(role): \(String(text.prefix(400)))")
                }
            }
        }
        return parts.suffix(4).joined(separator: "\n")
    }

}

// MARK: - Row actions

/// Chat actions shared by the sidebar's context menu and the browser
/// list's — rename, duplicate, copy; pin/archive live in `ChatMetaStore`.
@MainActor
enum ChatRowActions {
    static func promptRename(_ ref: ChatSessionRef) {
        let alert = NSAlert()
        alert.messageText = "Rename Chat"
        let field = NSTextField(string: ChatTitler.shared.displayTitle(ref))
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        // The title overlay is @Published — every list re-renders on it.
        ChatTitler.shared.setCustomTitle(name, for: ref.filePath)
    }

    /// A fork: the transcript re-exported as a fresh native session for
    /// the same harness, named "<title> copy".
    static func duplicate(_ ref: ChatSessionRef, project: String) {
        let title = ChatTitler.shared.displayTitle(ref) + " copy"
        Task.detached(priority: .userInitiated) {
            let messages = ChatArchive.transcript(ref)
            let file: String? = switch ref.harness {
            case .claude:
                ChatArchive.exportToClaude(messages, projectPath: project)
                    .map { ChatArchive.claudeProjectDir(for: project) + "/" + $0 + ".jsonl" }
            case .codex:
                ChatArchive.exportToCodex(
                    messages, projectPath: project, originator: "Houston-Fork"
                ).flatMap { ChatArchive.codexRolloutPath(id: $0) }
            }
            await MainActor.run {
                if let file { ChatTitler.shared.setCustomTitle(title, for: file) }
                ChatIndexStore.shared.refresh(project, force: true)
            }
        }
    }

    /// The whole conversation as markdown on the clipboard.
    static func copyTranscript(_ ref: ChatSessionRef) {
        Task.detached(priority: .userInitiated) {
            let messages = ChatArchive.transcript(ref)
            let text = messages.map { message in
                let heading = message.role == .user ? "## User" : "## Assistant"
                let body = message.blocks.compactMap { block -> String? in
                    switch block {
                    case let .text(t): t
                    case let .code(c, lang): "```" + (lang ?? "") + "\n" + c + "\n```"
                    case let .tool(name, detail):
                        detail.isEmpty ? "*[\(name)]*" : "*[\(name): \(detail)]*"
                    }
                }.joined(separator: "\n\n")
                return heading + "\n\n" + body
            }.joined(separator: "\n\n")
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }
}

// MARK: - Live turn

/// The streaming tail of a conversation: the just-sent user message, the
/// turn's finished blocks, the text still streaming in, an approval
/// prompt when the agent asks, and the working/stop row. Renders nothing
/// when the session is idle and empty.
private struct LiveTurnView: View {
    @ObservedObject var session: ChatAgentSession
    let harness: ChatHarness
    /// Fired when a turn completes — the owner re-reads the transcript.
    let onTurnEnd: () -> Void

    var body: some View {
        Group {
            if let pending = session.pendingUserText {
                MessageView(
                    message: ChatMessage(role: .user, blocks: [.text(pending)]),
                    harness: harness
                )
            }
            if !session.liveBlocks.isEmpty {
                MessageView(
                    message: ChatMessage(role: .assistant, blocks: session.liveBlocks),
                    harness: harness
                )
            }
            if !session.streamText.isEmpty {
                MessageView(
                    message: ChatMessage(role: .assistant, blocks: [.text(session.streamText)]),
                    harness: harness
                )
            }
            if let approval = session.approval {
                ApprovalCard(
                    request: approval,
                    onAllow: { session.respond(to: approval, allow: true) },
                    onDeny: { session.respond(to: approval, allow: false) }
                )
            }
            if session.running {
                // Stop lives in the composer (the send button's slot).
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Working…")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            if let error = session.lastError {
                HStack(spacing: 10) {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textDanger)
                        .lineLimit(3)
                    Button("Dismiss") { session.dismissError() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.link)
                }
            }
        }
        .onChange(of: session.completedTurns) { onTurnEnd() }
    }
}

/// The agent asked to use a tool — the same decision the terminal would
/// prompt for, rendered as a card in the chat.
private struct ApprovalCard: View {
    let request: ChatAgentSession.ApprovalRequest
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(request.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text)
            if !request.detail.isEmpty {
                Text(request.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button(action: onAllow) {
                    Text("Allow")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.ctaFill))
                }
                .buttonStyle(.plain)
                Button(action: onDeny) {
                    Text("Deny")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Theme.buttonStroke, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panelFill))
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(Theme.buttonStroke, lineWidth: 1)
        )
    }
}

// MARK: - Composer

/// The chat input bar: image attach, model picker, ghost-text autocomplete
/// (on-device model — dimmed inline continuation, Tab accepts), send.
private struct ChatComposer: View {
    let placeholder: String
    /// Menu selection before the user touches it — the session's harness.
    let initialModel: ChatModelChoice
    /// Conversation tail for autocomplete; nil disables the ghost text.
    let ghostContext: String?
    /// The chat's live session, when one exists — the send button turns
    /// into Stop while its turn runs.
    var runningSession: ChatAgentSession? = nil
    let onSend: (String, ChatModelChoice) -> Void

    @ObservedObject private var localModels = LocalModelStore.shared
    @State private var draft = ""
    @State private var picked: ChatModelChoice?
    /// Each harness's last pick in this composer, so toggling the harness
    /// back restores the model that was chosen there.
    @State private var perHarness: [ChatHarness: ChatModelChoice] = [:]
    /// Chosen effort level (flag value); nil = the model's default. Only
    /// applied when the current model's harness supports the level.
    @State private var effort: String?
    /// nil = follow the initial model's mode (the session's last send).
    @State private var permission: ChatPermissionMode?
    @State private var suggestion = ""
    @State private var ghostTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool

    private var model: ChatModelChoice { picked ?? initialModel }
    private var activePermission: ChatPermissionMode {
        permission ?? initialModel.permission
    }

    /// The effort actually in force for the current model's harness.
    private var activeEffort: (label: String, arg: String)? {
        ChatModelChoice.efforts(for: model.harness).first { $0.arg == effort }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: attachImage) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.rowHovered))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Attach an image (inserts its path)")
                harnessMenu
                modelMenu
                permissionMenu
                Spacer(minLength: 0)
            }
            HStack(alignment: .center, spacing: 8) {
                inputField
                if let runningSession {
                    SendStopButton(
                        session: runningSession, sendDisabled: draftEmpty,
                        onSendTap: send
                    )
                } else {
                    SendGlyphButton(disabled: draftEmpty, action: send)
                }
            }
        }
        // Even 12px frame; the well's own vertical padding closes the
        // bottom, so the bar reads balanced around both rows.
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
        // Same surface as the sidebar so the bar sits on the chrome, the
        // stroke alone defining it.
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.sidebarFill))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.buttonStroke, lineWidth: 1))
        // Same column as the transcript: 800 cap including 32px gutters.
        .padding(.horizontal, 32)
        .frame(maxWidth: 800)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
        .padding(.top, 8)
        .onAppear { localModels.refresh() }
    }

    // MARK: Control chips

    /// Which CLI runs the send; switching restores that harness's last
    /// pick here (or its default model).
    private var harnessMenu: some View {
        Menu {
            harnessItem("Claude Code", .claude)
            harnessItem("Codex", .codex)
        } label: {
            chip(model.harness == .claude ? "Claude Code" : "Codex")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Which CLI runs this chat")
    }

    private func harnessItem(_ label: String, _ harness: ChatHarness) -> some View {
        Toggle(label, isOn: Binding(
            get: { model.harness == harness },
            set: { _ in
                guard model.harness != harness else { return }
                perHarness[model.harness] = model
                picked = perHarness[harness] ?? .fallback(for: harness)
            }
        ))
    }

    /// The active harness's models only — cloud list, plus the Local
    /// engines on the codex side, plus effort levels.
    private var modelMenu: some View {
        Menu {
            if model.harness == .claude {
                ForEach(ChatModelChoice.claude, id: \.self) { choice in
                    modelItem(choice)
                }
            } else {
                Section("OpenAI") {
                    ForEach(ChatModelChoice.openAI, id: \.self) { choice in
                        modelItem(choice)
                    }
                }
                Section("Local") {
                    if localModels.mlxModels.isEmpty {
                        Button(localModels.mlxPlaceholder) {}.disabled(true)
                    } else {
                        Menu("MLX Core") {
                            ForEach(localModels.mlxModels, id: \.self) { name in
                                modelItem(.mlx(name))
                            }
                        }
                    }
                    Button("Ollama — Coming soon") {}.disabled(true)
                    Button("LM Studio — Coming soon") {}.disabled(true)
                }
            }
            if model.provider == nil {
                Section("Effort") {
                    Toggle("Default", isOn: Binding(
                        get: { activeEffort == nil },
                        set: { _ in effort = nil }
                    ))
                    ForEach(ChatModelChoice.efforts(for: model.harness), id: \.arg) { level in
                        Toggle(level.label, isOn: Binding(
                            get: { activeEffort?.arg == level.arg },
                            set: { _ in effort = level.arg }
                        ))
                    }
                }
            }
        } label: {
            chip(activeEffort.map { "\(model.label) · \($0.label)" } ?? model.label)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Model for this message")
    }

    /// What the agent may do without asking; Full access reads as the
    /// warning it is.
    private var permissionMenu: some View {
        Menu {
            ForEach(ChatPermissionMode.allCases, id: \.self) { mode in
                Toggle(isOn: Binding(
                    get: { activePermission == mode },
                    set: { _ in permission = mode }
                )) {
                    Text(mode.label)
                    Text(mode.detail)
                }
            }
        } label: {
            chip(activePermission.label,
                 tint: activePermission == .full ? Theme.textWarning : nil)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("What the agent may do without asking")
    }

    /// Send while idle, Stop while the session's turn runs — one slot,
    /// observed so the swap tracks the stream live.
    private struct SendStopButton: View {
        @ObservedObject var session: ChatAgentSession
        let sendDisabled: Bool
        let onSendTap: () -> Void

        var body: some View {
            if session.running {
                Button(action: { session.interrupt() }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ctaFill))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("Stop this turn")
            } else {
                SendGlyphButton(disabled: sendDisabled, action: onSendTap)
            }
        }
    }

    private struct SendGlyphButton: View {
        let disabled: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ctaFill))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled ? 0.4 : 1)
        }
    }

    private func chip(_ text: String, tint: Color? = nil) -> some View {
        HStack(spacing: 3) {
            Text(text)
                .font(.system(size: 13))
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(tint ?? Theme.text)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.rowHovered))
        .contentShape(RoundedRectangle(cornerRadius: 7))
    }

    /// The field with the ghost suggestion painted behind it: the typed
    /// prefix rendered clear so the dimmed continuation lands exactly
    /// where the caret is, wrapping included.
    private var inputField: some View {
        ZStack(alignment: .topLeading) {
            if !suggestion.isEmpty {
                (Text(draft).foregroundColor(.clear)
                    + Text(suggestion).foregroundColor(Theme.textSecondary.opacity(0.55)))
                    .font(.system(size: 14))
                    .lineLimit(10)
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...10)
                .focused($inputFocused)
                .onSubmit(send)
                .onKeyPress(.tab) {
                    guard !suggestion.isEmpty else { return .ignored }
                    draft += suggestion
                    suggestion = ""
                    return .handled
                }
                .onChange(of: draft) { _, text in refreshGhost(text) }
        }
        // Its own 44px well, the send button riding outside it. One line
        // sits centered; more lines grow the well downward (to 10). The
        // whole well is the click target for focus. No horizontal inset —
        // the text's left edge lines up with the + circle above it.
        .padding(.vertical, 8)
        .frame(minHeight: 44, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { inputFocused = true }
    }

    /// A menu row that carries the native checkmark on the current pick.
    private func modelItem(_ choice: ChatModelChoice) -> some View {
        Toggle(choice.label, isOn: Binding(
            get: { model == choice },
            set: { _ in picked = choice }
        ))
    }

    /// Debounced on-device completion; anything typed since the request
    /// went out invalidates the answer.
    private func refreshGhost(_ text: String) {
        suggestion = ""
        ghostTask?.cancel()
        guard let ghostContext, text.count >= 3, !text.hasSuffix("\n") else { return }
        ghostTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let completed = await ChatTitler.completeDraft(
                context: ghostContext, draft: text
            )
            guard !Task.isCancelled, draft == text, let completed else { return }
            suggestion = completed
        }
    }

    private var draftEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        suggestion = ""
        onSend(text, model.applying(effort: effort, permission: activePermission))
    }

    private func attachImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let quoted = url.path.contains(" ") ? "\"\(url.path)\"" : url.path
        draft = draft.isEmpty ? quoted + " " : draft + " " + quoted
    }
}

// MARK: - Chat style

/// The user-picked colors for their side of the chat, persisted in
/// settings.json. Empty hex = the brand defaults.
@MainActor
final class ChatStyleStore: ObservableObject {
    static let shared = ChatStyleStore()

    @Published private(set) var bubbleHex: String
    @Published private(set) var textHex: String

    private init() {
        let settings = HoustonSettings.read()
        bubbleHex = settings.chatBubbleColor
        textHex = settings.chatTextColor
    }

    var bubble: Color { Self.color(bubbleHex) ?? Theme.chatUserFill }
    var text: Color { Self.color(textHex) ?? .white }
    var isDefault: Bool { bubbleHex.isEmpty && textHex.isEmpty }

    func setBubble(_ color: Color) {
        bubbleHex = Self.hex(color)
        persist()
    }

    func setText(_ color: Color) {
        textHex = Self.hex(color)
        persist()
    }

    func reset() {
        bubbleHex = ""
        textHex = ""
        persist()
    }

    private func persist() {
        var settings = HoustonSettings.read()
        settings.chatBubbleColor = bubbleHex
        settings.chatTextColor = textHex
        HoustonSettings.write(settings)
    }

    private static func color(_ hex: String) -> Color? {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return Color(hex: value)
    }

    private static func hex(_ color: Color) -> String {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return "" }
        return String(
            format: "%02X%02X%02X",
            Int(round(ns.redComponent * 255)),
            Int(round(ns.greenComponent * 255)),
            Int(round(ns.blueComponent * 255))
        )
    }
}

// MARK: - Messages

private struct MessageView: View {
    let message: ChatMessage
    let harness: ChatHarness
    /// Tool chips show during a live turn (the "it's working" feedback)
    /// and drop out of finished transcripts — prose only, like the
    /// desktop apps.
    var showTools = true

    @ObservedObject var style = ChatStyleStore.shared

    var body: some View {
        if message.role == .user {
            // The user's turn: a brand-orange card pushed right; white
            // text — chatUserFill is picked to hold 4.5:1 under it.
            HStack {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 8) {
                    blocksView
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 12).fill(style.bubble))
                .frame(maxWidth: 500, alignment: .trailing)
            }
        } else {
            // The agent's turn: plain rich text on the page.
            VStack(alignment: .leading, spacing: 8) {
                Text(harness.rawValue.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(Theme.heading)
                blocksView
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var blocksView: some View {
        ForEach(message.blocks) { block in
            switch block {
            case let .text(text):
                MarkdownBlockView(
                    text: text,
                    color: message.role == .user ? style.text : Theme.text,
                    accent: message.role == .user
                )
            case let .code(code, lang):
                CodeCard(code: code, lang: lang)
            case let .tool(name, detail):
                if showTools {
                    HStack(spacing: 6) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 10, weight: .medium))
                        Text(detail.isEmpty ? name : "\(name) · \(detail)")
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

}

/// The stylized snippet every piece of code rides in: a header strip with
/// the language and a copy button, monospace body scrolling sideways
/// instead of wrapping into soup.
private struct CodeCard: View {
    let code: String
    var lang: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text((lang ?? "code").lowercased())
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 8)
                CopyIconButton(text: code, help: "Copy code")
            }
            .padding(.leading, 12)
            .padding(.trailing, 5)
            .padding(.vertical, 3)
            Rectangle().fill(Theme.buttonStroke).frame(height: 1)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.attachedWellFill))
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(Theme.buttonStroke, lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Markdown blocks

/// Block-level markdown for a chat text run: headings, bullet and
/// numbered lists (with nesting), quotes, and standalone links as
/// clickable cards. Inline styling (bold, code, links) rides
/// AttributedString on each piece.
private struct MarkdownBlockView: View {
    let text: String
    let color: Color
    /// On the user bubble — links and inline code adapt to the custom
    /// bubble color instead of assuming the page background.
    var accent: Bool = false

    private enum Part: Identifiable {
        case paragraph(String)
        case heading(Int, String)
        case bullet(indent: Int, text: String)
        case numbered(indent: Int, marker: String, text: String)
        case quote(String)
        case linkCard(URL)
        /// A run of `$ command` lines — a shell snippet, not prose.
        case shell(String)

        var id: String {
            switch self {
            case let .paragraph(t): "p:\(t.hashValue)"
            case let .heading(l, t): "h\(l):\(t.hashValue)"
            case let .bullet(i, t): "b\(i):\(t.hashValue)"
            case let .numbered(i, m, t): "n\(i)\(m):\(t.hashValue)"
            case let .quote(t): "q:\(t.hashValue)"
            case let .linkCard(u): "l:\(u.absoluteString)"
            case let .shell(t): "s:\(t.hashValue)"
            }
        }
    }

    var body: some View {
        let parts = Self.parse(text)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                partView(part)
                    // The paragraph gap is BETWEEN parts — a trailing one
                    // padded every one-line user bubble to two lines tall.
                    .padding(.bottom, index == parts.count - 1 ? 0 : gap(after: part))
            }
        }
        // User bubbles hug their text (the 500 cap still applies from the
        // bubble); assistant prose fills the column.
        .frame(maxWidth: accent ? nil : .infinity, alignment: .leading)
    }

    /// The blank-line feel after each paragraph-grade part; list items
    /// get their own smaller air so a list breathes without falling apart.
    private func gap(after part: Part) -> CGFloat {
        switch part {
        case .bullet, .numbered: 8
        case .heading: 6
        default: 16
        }
    }

    @ViewBuilder
    private func partView(_ part: Part) -> some View {
        switch part {
        case let .paragraph(body):
            styled(body, size: 16)
                .lineSpacing(8)
        case let .heading(level, body):
            styled(body, size: level <= 1 ? 20 : (level == 2 ? 18 : 16), weight: .semibold)
                .padding(.top, 4)
        case let .bullet(indent, body):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("•")
                    .font(.system(size: 16))
                    .foregroundStyle(color.opacity(0.65))
                styled(body, size: 16)
                    .lineSpacing(8)
            }
            .padding(.leading, 12 + CGFloat(indent) * 18)
        case let .numbered(indent, marker, body):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(marker)
                    .font(.system(size: 15))
                    .monospacedDigit()
                    .foregroundStyle(color.opacity(0.65))
                styled(body, size: 16)
                    .lineSpacing(8)
            }
            .padding(.leading, 12 + CGFloat(indent) * 18)
        case let .quote(body):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color.opacity(0.3))
                    .frame(width: 3)
                styled(body, size: 15)
                    .lineSpacing(6)
                    .opacity(0.85)
            }
        case let .linkCard(url):
            LinkCard(url: url)
        case let .shell(commands):
            CodeCard(code: commands, lang: "shell")
        }
    }

    private func styled(_ body: String, size: CGFloat, weight: Font.Weight = .regular) -> some View {
        Text(Self.inline(body, onAccent: accent))
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .tint(accent ? color : Theme.link)
            .textSelection(.enabled)
            // User bubbles (accent) hug their text; assistant prose fills
            // the column.
            .frame(maxWidth: accent ? nil : .infinity, alignment: .leading)
    }

    /// Inline markdown, with bare URLs promoted to tappable links and
    /// `code` spans tinted monospace so they read as code inline.
    private static func inline(_ text: String, onAccent: Bool) -> AttributedString {
        let linked = text.replacingOccurrences(
            of: #"(?<![("\[<])(https?://[^\s)\]>"']+)"#,
            with: "[$1]($1)",
            options: .regularExpression
        )
        guard var attr = try? AttributedString(
            markdown: linked,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return AttributedString(text) }
        for run in attr.runs
        where run.inlinePresentationIntent?.contains(.code) == true {
            attr[run.range].font = .system(size: 13.5, design: .monospaced)
            attr[run.range].backgroundColor = onAccent
                ? Color.white.opacity(0.22)
                : Theme.attachedWellFill
        }
        return attr
    }

    private static func parse(_ text: String) -> [Part] {
        var parts: [Part] = []
        var paragraph: [String] = []
        var shell: [String] = []
        func flush() {
            let joined = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { parts.append(.paragraph(joined)) }
            paragraph = []
        }
        func flushShell() {
            if !shell.isEmpty { parts.append(.shell(shell.joined(separator: "\n"))) }
            shell = []
        }
        for rawLine in text.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            // Consecutive "$ command" lines gather into one shell snippet.
            if trimmed.hasPrefix("$ ") {
                flush()
                shell.append(String(trimmed.dropFirst(2)))
                continue
            }
            flushShell()
            if trimmed.isEmpty { flush(); continue }
            let leading = rawLine.prefix { $0 == " " }.count
            let indent = min(leading / 2, 4)
            // A line that is exactly one URL becomes a clickable card.
            if trimmed.range(
                of: #"^https?://\S+$"#, options: .regularExpression
            ) != nil, let url = URL(string: trimmed) {
                flush()
                parts.append(.linkCard(url))
            } else if let match = trimmed.range(
                of: #"^#{1,4} "#, options: .regularExpression
            ) {
                flush()
                let level = trimmed.distance(from: trimmed.startIndex, to: match.upperBound) - 1
                parts.append(.heading(level, String(trimmed[match.upperBound...])))
            } else if let match = trimmed.range(
                of: #"^[-*•] "#, options: .regularExpression
            ) {
                flush()
                parts.append(.bullet(
                    indent: indent, text: String(trimmed[match.upperBound...])
                ))
            } else if let match = trimmed.range(
                of: #"^\d{1,3}[.)] "#, options: .regularExpression
            ) {
                flush()
                parts.append(.numbered(
                    indent: indent,
                    marker: String(trimmed[match.lowerBound..<match.upperBound])
                        .trimmingCharacters(in: .whitespaces),
                    text: String(trimmed[match.upperBound...])
                ))
            } else if trimmed.hasPrefix("> ") {
                flush()
                parts.append(.quote(String(trimmed.dropFirst(2))))
            } else {
                paragraph.append(rawLine)
            }
        }
        flush()
        flushShell()
        return parts
    }
}

/// A standalone URL rendered as a clickable preview chip — favicon-less
/// but instantly recognizable: domain up top, full address under it.
private struct LinkCard: View {
    let url: URL

    @State private var hovered = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.link)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.rowHovered))
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.host() ?? url.absoluteString)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(url.absoluteString)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(8)
            .frame(maxWidth: 420, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(hovered ? Theme.rowHovered : Theme.panelFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.buttonStroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(url.absoluteString)
    }
}
