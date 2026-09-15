import SwiftUI
import UniformTypeIdentifiers

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
        // ACP harnesses (Gemini, Grok) choose model/effort by the model id
        // itself (Pro vs Flash, Grok 4 vs Fast); no separate effort flag.
        case .gemini, .grok: []
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
        switch harness {
        case .codex: openAI[0]
        case .gemini: providerFallback(.gemini)
        case .grok: providerFallback(.grok)
        case .claude: claude[0]
        }
    }

    private static func providerFallback(_ provider: ChatProvider) -> ChatModelChoice {
        ChatModelChoice(
            label: provider.models[0].label, harness: provider.harness,
            arg: provider.models[0].arg, provider: provider.id
        )
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
    /// Projects the new-chat composer's project chip offers — a chat
    /// opened without a project (sidebar New Chat, path = home) picks its
    /// home here before the first send.
    var projects: [String] = []

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
    /// The earliest rollover segment currently expanded into the
    /// transcript (nil = only the chain head is shown).
    @State private var chainEarliest: String?
    /// Whether the transcript follows the stream. Latching with hysteresis
    /// (not a bare "is the sentinel visible" recompute): a chunky append
    /// briefly shoves the sentinel far below the fold, and the old
    /// recompute latched false there and never recovered — the stream
    /// stopped following mid-answer. Now it only turns OFF when the user
    /// scrolls up past a wide margin, and back ON when they return near
    /// the bottom; growth-driven blips inside the margin don't flip it.
    @State private var stickToBottom = true
    /// The floating composer's measured height — the transcript's content
    /// insets by it (via safeAreaInset) and the "fill the viewport" floor
    /// subtracts it, so a short chat still reads from the top.
    @State private var composerHeight: CGFloat = 120

    /// The selection is derived synchronously from the file path — going
    /// through a directory listing first flashed the empty state over
    /// every chat open.
    init(
        projectPath: String, initialSessionFile: String? = nil,
        projects: [String] = []
    ) {
        self.projectPath = projectPath
        self.initialSessionFile = initialSessionFile
        self.projects = projects
        _selected = State(initialValue: initialSessionFile.map(Self.quickRef))
    }

    /// The project the next send runs in — the composer's project chip
    /// can redirect a not-yet-started chat away from the path the view
    /// opened with.
    @State private var chosenProject: String?
    private var activeProject: String { chosenProject ?? projectPath }

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
            } else if let draft = hub.drafts[activeProject] {
                draftView(draft)
            } else {
                newChatView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.gitPanelFill)
        // No teardown on close: warm processes now outlive the browser
        // (the hub's TTL sweep reclaims them), so returning to a chat
        // doesn't pay a CLI cold start.
        // The file is part of the identity so retargeting (another sidebar
        // row, a run finishing in a fresh file) reloads into it.
        .task(id: projectPath + "|" + (initialSessionFile ?? "")) {
            historyShown = 150
            chainEarliest = nil
            // A fresh chat always opens following its tail — the latch
            // must not carry over from a chat the user had scrolled up in.
            stickToBottom = true
            selected = initialSessionFile.map(Self.quickRef)
            // The cached parse renders immediately (no spinner flash on
            // reopen); the real read still runs and lands only if the
            // file changed. Trimmed the same way as `reload` so a chat
            // reopened mid-turn doesn't double-show the running exchange.
            messages = selected.flatMap { ref in
                ChatArchive.cachedTranscript(ref).map { committed($0, ref) }
            }
            guard let selected else { return }
            if let session = hub.sessions[selected.filePath],
               session.phase == .settling {
                // A turn finished while this chat wasn't on screen — the
                // session kept it (the sweep spares live content).
                // Absorb it now, or the transcript and the live section
                // would both render it.
                reloadThenClear(selected, session)
            } else {
                reload(selected)
            }
            // Boot the agent while the user is still reading/typing —
            // the first send then costs a keystroke, not a CLI start +
            // session load. This is what makes chat feel like a warm
            // terminal pane.
            hub.prewarm(selected, project: activeProject)
        }
    }

    private func open(_ ref: ChatSessionRef) {
        selected = ref
        messages = ChatArchive.cachedTranscript(ref)
        historyShown = 150
        chainEarliest = nil
        stickToBottom = true
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
            if token == loadToken {
                messages = committed(parsed, ref)
                // A plain reload can supersede an in-flight absorb (its
                // token check makes it stand down) — if the session is
                // still holding a finished turn, absorb it now instead of
                // leaving the live section stranded next to a transcript
                // that may already contain the same turn.
                if let session = hub.sessions[ref.filePath],
                   !session.running, session.hasUnabsorbedTurn {
                    reloadThenClear(ref, session)
                }
            }
        }
    }

    /// The transcript minus the turn the live section is already showing.
    /// The CLI persists the user message (and each completed assistant
    /// step) as the turn runs, so a full re-read mid-turn would render the
    /// running exchange twice — once from disk, once live. Everything from
    /// the running turn's user message onward belongs to the live section,
    /// so trim it off. Idle sessions get the whole transcript.
    private func committed(
        _ parsed: [ChatMessage], _ ref: ChatSessionRef
    ) -> [ChatMessage] {
        guard let session = hub.sessions[ref.filePath],
              session.running,
              let pending = session.pendingUserText else { return parsed }
        // Compare in parsed space: the transcript stores the message as
        // blocks — capsule/fragment markers become chips — so a raw-text
        // needle would miss any send that led with an attachment. Match
        // on the pending message's first text RUN instead.
        let needle = ChatArchive.userBlocks(pending)
            .compactMap { block -> String? in
                if case let .text(text) = block, !text.isEmpty {
                    return String(text.prefix(60))
                }
                return nil
            }
            .first
        // The running turn's user message can only be the transcript's
        // LAST user message (only assistant output follows it) — anything
        // else matching the needle is an older duplicate; trimming there
        // would eat committed history.
        guard let lastUser = parsed.lastIndex(where: { $0.role == .user })
        else { return parsed }
        let candidate = parsed[lastUser]
        let matches: Bool
        if let needle {
            matches = candidate.blocks.contains { block in
                if case let .text(text) = block { return text.contains(needle) }
                return false
            }
        } else {
            // A chips-only send (pure attachment): match a chips-only
            // last user message.
            matches = !candidate.blocks.contains { block in
                if case .text = block { return true }
                return false
            }
        }
        return matches ? Array(parsed.prefix(lastUser)) : parsed
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
                                // A rolled-over chat presents as one
                                // conversation — this walks the chain one
                                // sealed segment back per click, like
                                // "load earlier messages" anywhere else.
                                if meta.continuations[chainEarliest ?? ref.filePath] != nil {
                                    Button("Show earlier conversation") {
                                        expandChain(ref)
                                    }
                                    .buttonStyle(.plain)
                                    .font(Theme.Fonts.body)
                                    .foregroundStyle(Theme.link)
                                    .frame(maxWidth: .infinity)
                                }
                                if messages.count > historyShown {
                                    Button("Show earlier messages") {
                                        historyShown += 200
                                    }
                                    .buttonStyle(.plain)
                                    .font(Theme.Fonts.body)
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
                                    LiveTurnView(
                                        session: session, harness: ref.harness,
                                        onGrow: {
                                            guard stickToBottom else { return }
                                            proxy.scrollTo("chat-bottom", anchor: .bottom)
                                        }
                                    ) {
                                        reloadThenClear(ref, session)
                                    }
                                }
                                Color.clear.frame(height: 1).id("chat-bottom")
                                    .background(GeometryReader { sentinel in
                                        Color.clear.preference(
                                            key: ChatBottomYKey.self,
                                            value: sentinel.frame(in: .named("chatScroll")).minY
                                        )
                                    })
                            }
                            .padding(.horizontal, 32)
                            .padding(.top, 22)
                            .padding(.bottom, 18)
                            .frame(maxWidth: 800)
                            .frame(maxWidth: .infinity)
                            // Stretched to at least the visible viewport
                            // (the pane minus the floating composer),
                            // content pinned to its top: a short chat
                            // reads from the top instead of dropping to
                            // the bottom, while the bottom anchor still
                            // follows growth once the content overflows.
                            .frame(
                                minHeight: max(0, geo.size.height - composerHeight),
                                alignment: .top
                            )
                            .thinScrollbar()
                        }
                        .defaultScrollAnchor(.bottom)
                        .coordinateSpace(name: "chatScroll")
                        // The composer floats over the transcript on
                        // frosted glass: safeAreaInset keeps the resting
                        // content above it while the scroll view itself
                        // runs full height, so text slides behind the
                        // blur mid-scroll.
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            transcriptComposer(ref)
                                .background(GeometryReader { bar in
                                    Color.clear.preference(
                                        key: ComposerHeightKey.self,
                                        value: bar.size.height
                                    )
                                })
                        }
                        .onPreferenceChange(ComposerHeightKey.self) {
                            composerHeight = $0
                        }
                        .onPreferenceChange(ChatBottomYKey.self) { y in
                            // Distance of the sentinel below the viewport
                            // bottom. Wide hysteresis so a growth blip
                            // never latches "not following": only a real
                            // scroll-up past 240pt turns it off; returning
                            // within 80pt turns it back on.
                            // Guarded writes: this fires per scroll/growth
                            // frame, so the steady state must cost a
                            // comparison, not a state write.
                            let distance = y - geo.size.height
                            if distance <= 80 {
                                if !stickToBottom { stickToBottom = true }
                            } else if distance > 240, stickToBottom {
                                stickToBottom = false
                            }
                        }
                        .onChange(of: messages.count) {
                            guard stickToBottom else { return }
                            proxy.scrollTo("chat-bottom", anchor: .bottom)
                        }
                        .onChange(of: sendScrollTick) {
                            // A send always re-follows the stream.
                            stickToBottom = true
                            proxy.scrollTo("chat-bottom", anchor: .bottom)
                        }
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                transcriptComposer(ref)
            }
        }
    }

    /// The transcript's composer — one construction for the loaded
    /// transcript (where it floats via safeAreaInset) and the momentary
    /// loading state (where it sits below the spinner).
    private func transcriptComposer(_ ref: ChatSessionRef) -> some View {
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
                Text(activeProject == NSHomeDirectory()
                    ? "What's the mission?"
                    : "What's the mission for \(projectName)?")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.skyText)
                    .opacity(skyRevealed ? 1 : 0)
                    .offset(y: skyRevealed ? 0 : 8)
                ChatComposer(
                    placeholder: "Let's do it…",
                    initialModel: .fallback(for: .claude),
                    ghostContext: nil,
                    projectChoices: projects,
                    selectedProject: activeProject,
                    onSelectProject: { chosenProject = $0 },
                    attached: false,
                    onSend: { text, model in
                        hub.draft(in: activeProject, harness: model.harness)
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
        activeProject == NSHomeDirectory()
            ? "~" : (activeProject as NSString).lastPathComponent
    }

    // MARK: - New chat (draft)

    /// A chat that doesn't have a transcript file yet: the live turn is
    /// the whole conversation. Once its first turn lands, the draft is
    /// promoted onto its real file and this becomes a normal transcript.
    private func draftView(_ session: ChatAgentSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                LiveTurnView(session: session, harness: session.harness) {
                    promoteDraft(session)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 22)
            .padding(.bottom, 18)
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
            .thinScrollbar()
        }
        // Same floating-glass composer as the transcript view.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ChatComposer(
                placeholder: "What's next?",
                initialModel: session.lastModel ?? .fallback(for: session.harness),
                ghostContext: nil,
                runningSession: session,
                onSend: { text, model in
                    hub.draft(in: activeProject, harness: model.harness)
                        .send(text: text, model: model)
                }
            )
        }
    }

    /// First turn finished: find the transcript file the run created and
    /// rekey the draft session onto it.
    private func promoteDraft(_ session: ChatAgentSession) {
        Task {
            let project = activeProject
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
                case .gemini, .grok:
                    // Houston names the file itself from the ACP session id.
                    file = session.sessionID.map {
                        ChatArchive.acpSessionFile(
                            for: project, id: $0, harness: session.harness)
                    }
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
            hub.session(for: ref, project: activeProject)
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
            let project = activeProject
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
                switch target {
                case .claude:
                    guard let id = ChatArchive.exportToClaude(toExport, projectPath: project)
                    else { return nil }
                    return (id, ChatArchive.claudeProjectDir(for: project) + "/" + id + ".jsonl")
                case .codex:
                    guard let id = ChatArchive.exportToCodex(toExport, projectPath: project),
                          let file = ChatArchive.codexRolloutPath(id: id) else { return nil }
                    return (id, file)
                case .gemini, .grok:
                    // exportToACP returns the file path; the id is its
                    // basename (Houston names it <id>.jsonl).
                    guard let file = ChatArchive.exportToACP(
                        toExport, projectPath: project, harness: target)
                    else { return nil }
                    let id = ((file as NSString).lastPathComponent as NSString)
                        .deletingPathExtension
                    return (id, file)
                }
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
            NotificationCenter.default.post(
                name: .houstonChatRekeyed, object: nil,
                userInfo: ["project": project, "file": file]
            )
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
            // A queued send may already be running by now (the session
            // drains itself at turn end) — trim its exchange the same as
            // any other mid-turn read.
            // The clear is gated on the SAME token as the messages write:
            // clearing after a newer load superseded this one wiped the
            // live section while the on-screen transcript never received
            // the turn — the reply visibly vanished until the next reload.
            // A superseded absorb leaves the live section intact; whoever
            // owns the newer token re-absorbs (reload re-arms it).
            if token == loadToken {
                messages = committed(parsed, ref)
                session.dropCarried(absorbedBy: parsed)
                session.clearTurn()
                rolloverIfNeeded(ref, session)
            }
            ChatIndexStore.shared.refresh(activeProject, force: true)
        }
    }

    // MARK: - Context rollover

    /// Walk the rollover chain one segment back: prepend the superseded
    /// transcript above what's shown. The seam is deduped — rollover
    /// seeds the new session with the parent's verbatim tail, so the
    /// parent's trailing copies of those messages are dropped (showing
    /// them twice, adjacent, is exactly the confusion this view exists
    /// to avoid).
    private func expandChain(_ ref: ChatSessionRef) {
        let current = chainEarliest ?? ref.filePath
        guard let parentFile = meta.continuations[current] else { return }
        let parentRef = ChatSessionRef(
            harness: ref.harness, filePath: parentFile,
            title: "", modified: .distantPast
        )
        Task {
            let parsed = await Task.detached(priority: .userInitiated) {
                ChatArchive.transcript(parentRef)
            }.value
            guard let shown = messages, !parsed.isEmpty else { return }
            let headKeys = Set(shown.prefix(20).compactMap(Self.seamKey))
            var parent = parsed
            while let last = parent.last,
                  let key = Self.seamKey(last), headKeys.contains(key) {
                parent.removeLast()
            }
            messages = parent + shown
            historyShown += parent.count + 1
            chainEarliest = parentFile
        }
    }

    /// Identity of a message across the rollover seam: role + the head
    /// of its first text run.
    private static func seamKey(_ message: ChatMessage) -> String? {
        for block in message.blocks {
            if case let .text(text) = block, !text.isEmpty {
                return (message.role == .user ? "u:" : "a:") + String(text.prefix(60))
            }
        }
        return nil
    }

    /// Fraction of the context window at which the chat rolls over.
    private static let rolloverFraction = 0.8

    /// Context-pressure rollover: past the threshold, the chat's history
    /// seals into a capsule and the conversation continues in a fresh
    /// session seeded with a handoff brief + the recent verbatim tail
    /// (plus the sealed transcript's path, so the model can read the
    /// full history on demand). To the user it's still "the one chat" —
    /// same title, same place — it just never fills up. Claude-only:
    /// codex publishes no cumulative usage to trigger on. Runs only
    /// between turns; a queued send postpones it to the next turn end.
    private func rolloverIfNeeded(_ ref: ChatSessionRef, _ session: ChatAgentSession) {
        guard ref.harness == .claude,
              session.phase == .idle,
              session.queued.isEmpty,
              let tokens = session.contextTokens,
              Double(tokens) >= Double(session.contextWindow) * Self.rolloverFraction
        else { return }
        Task {
            let project = activeProject
            let source = await Task.detached(priority: .userInitiated) {
                ChatArchive.transcript(ref)
            }.value
            guard !source.isEmpty else { return }
            let (chunks, tail) = ChatArchive.splitForHandoff(source)
            let brief = await ChatTitler.handoffBrief(chunks)
                ?? "(The earlier part of this conversation lives in the "
                + "attached transcript — read it for anything you're missing.)"
            let payload = [ChatArchive.handoffMessage(
                brief: brief, from: ref.harness, fullTranscript: ref.filePath
            )] + tail
            let exported = await Task.detached(priority: .userInitiated) { () -> (String, String)? in
                guard let id = ChatArchive.exportToClaude(payload, projectPath: project)
                else { return nil }
                return (id, ChatArchive.claudeProjectDir(for: project) + "/" + id + ".jsonl")
            }.value
            // Export failed → keep the old session; nothing changed.
            guard let (id, file) = exported else { return }
            // The chain presents as ONE chat: the new file takes the
            // chat's identity (title, pin ride along in
            // markContinuation), the old segment hides as superseded,
            // reachable via "Show earlier conversation".
            let title = titler.displayTitle(ref)
            titler.setCustomTitle(title, for: file)
            ChatMetaStore.shared.markContinuation(file, of: ref.filePath)
            hub.forget(file: ref.filePath)
            let newRef = ChatSessionRef(
                harness: .claude, filePath: file, title: title, modified: Date()
            )
            selected = newRef
            reload(newRef)
            // Warm the fresh session immediately, on the model the user
            // was just driving — the roll must not reintroduce the cold
            // start it exists to hide.
            hub.adopt(file: file, harness: .claude, project: project, id: id)
                .warmUp(model: session.lastModel ?? .fallback(for: .claude))
            NotificationCenter.default.post(
                name: .houstonChatRekeyed, object: nil,
                userInfo: ["project": project, "file": file]
            )
            ChatIndexStore.shared.refresh(project, force: true)
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
        // The stream is raw markdown but the parse splits fenced code into
        // `.code` blocks — a reply ENDING in code never matched a
        // text-only search, so every such turn burned the full retry loop
        // and then cleared against whatever the last read held. Compare in
        // a normalized space instead: fence lines dropped, whitespace
        // collapsed, text and code searched together.
        let tail = String(normalizedForMatch(finalText ?? "").suffix(60))
        return messages[index...].contains { message in
            guard message.role == .assistant else { return false }
            let flat = normalizedForMatch(
                message.blocks.compactMap { block -> String? in
                    switch block {
                    case let .text(text): text
                    case let .code(code, _): code
                    default: nil
                    }
                }.joined(separator: " ")
            )
            // A turn with no streamed text (tool-only, or one that
            // errored out) settles for any assistant text.
            return tail.isEmpty ? !flat.isEmpty : flat.contains(tail)
        }
    }

    /// Match space for stream-vs-parse comparison: fence lines gone
    /// (they exist only on the stream side), all whitespace runs a single
    /// space (block boundaries re-join differently than the raw stream).
    private static func normalizedForMatch(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// The transcript's autocomplete context: the tail of the conversation.
    /// Non-nil ONLY while the assistant's last message ends in a question —
    /// the ghost text (typed completion and the pre-typed suggested reply)
    /// exists to answer a pending question, not to guess mid-thought.
    private var ghostContext: String? {
        guard let messages, let last = messages.last,
              last.role == .assistant, Self.endsInQuestion(last)
        else { return nil }
        var parts: [String] = []
        let tail = Array(messages.suffix(3))
        for (index, message) in tail.enumerated() {
            for block in message.blocks {
                if case let .text(text) = block {
                    let role = message.role == .user ? "User" : "Assistant"
                    // The last message clips from the END — that's where
                    // the question lives, and it's what the ghost answers.
                    let clipped = index == tail.count - 1
                        ? String(text.suffix(400)) : String(text.prefix(400))
                    parts.append("\(role): \(clipped)")
                }
            }
        }
        let joined = parts.suffix(4).joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    /// Whether a message's final text block reads as a question — trailing
    /// markdown dressing (emphasis, quotes, parens) stripped first.
    private static func endsInQuestion(_ message: ChatMessage) -> Bool {
        for block in message.blocks.reversed() {
            if case let .text(text) = block {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                return trimmed
                    .trimmingCharacters(in: CharacterSet(charactersIn: "*_`\"'“”’)] \n\t"))
                    .hasSuffix("?")
            }
        }
        return false
    }

}

/// The floating composer bar's measured height — drives the transcript's
/// "fill the visible viewport" floor.
private struct ComposerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 120
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// The bottom sentinel's offset within the transcript's viewport — how
/// far down the user is scrolled, measured against the viewport height.
private struct ChatBottomYKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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
    /// `asBranch` marks the copy as a fork of the original — same
    /// mechanics, but it reads as "this conversation diverges here" (the
    /// sidebar gives it the branch glyph) instead of a plain backup.
    static func duplicate(_ ref: ChatSessionRef, project: String, asBranch: Bool = false) {
        let title = ChatTitler.shared.displayTitle(ref)
            + (asBranch ? " branch" : " copy")
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
            case .gemini, .grok:
                ChatArchive.exportToACP(
                    messages, projectPath: project, harness: ref.harness)
            }
            await MainActor.run {
                if let file {
                    ChatTitler.shared.setCustomTitle(title, for: file)
                    if asBranch {
                        ChatMetaStore.shared.markBranch(file, of: ref.filePath)
                    }
                }
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
                    case let .capsule(title, _): "*[Capsule: \(title)]*"
                    case let .fragment(title, _): "*[Fragment: \(title)]*"
                    case let .image(path): "![image](\(path))"
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
    /// Fired as the live turn grows — the transcript follows the stream.
    var onGrow: () -> Void = {}
    /// Fired when a turn completes — the owner re-reads the transcript.
    let onTurnEnd: () -> Void

    var body: some View {
        Group {
            // Exchanges a newer send superseded before the transcript
            // caught up — without these, the earlier message vanished.
            ForEach(session.carriedTurns) { message in
                MessageView(message: message, harness: harness)
            }
            if let pending = session.pendingUserText {
                // Through userBlocks so an attached capsule shows as its
                // chip while the turn streams, same as it will on disk.
                MessageView(
                    message: ChatMessage(
                        role: .user, blocks: ChatArchive.userBlocks(pending)
                    ),
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
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            // Held messages: sent while the turn was running, waiting their
            // turn (like the terminal's queued line). Dimmed, with a clock
            // and a ✕ to drop one before it runs.
            ForEach(session.queued) { held in
                QueuedMessageRow(text: held.text) {
                    session.cancelQueued(held.id)
                }
            }
            if let error = session.lastError {
                if session.needsLogin {
                    // A signed-out CLI, not a failed turn: offer the login
                    // flow instead of a dead end. The button opens the
                    // project's terminal and starts the provider's own
                    // sign-in (claude /login or codex login).
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        InlineNotice(
                            kind: .error,
                            title: "\(session.harness.rawValue) isn't signed in",
                            message: error
                        )
                        HStack(spacing: Theme.Space.s) {
                            Button {
                                PromptDelivery.login(
                                    session.harness,
                                    project: session.projectPath
                                )
                            } label: {
                                Text("Sign in from Terminal")
                                    .font(Theme.Fonts.secondaryMedium)
                                    .foregroundStyle(Theme.text)
                                    .padding(.horizontal, Theme.Space.s)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(
                                            cornerRadius: Theme.radiusControl
                                        )
                                        .fill(Theme.buttonFill)
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Opens the project's terminal and runs the "
                                + "provider's sign-in; send again once you're in")
                            Button("Dismiss") { session.dismissError() }
                                .buttonStyle(.plain)
                                .font(Theme.Fonts.body)
                                .foregroundStyle(Theme.link)
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        Text(error)
                            .font(Theme.Fonts.body)
                            .foregroundStyle(Theme.textDanger)
                            .lineLimit(3)
                        Button("Dismiss") { session.dismissError() }
                            .buttonStyle(.plain)
                            .font(Theme.Fonts.body)
                            .foregroundStyle(Theme.link)
                    }
                }
            }
        }
        // Level-triggered, not edge-triggered: `.task(id:)` runs on MOUNT
        // as well as on every bump, so a turn that ended while this view
        // wasn't on screen (first open still parsing, a navigation flash)
        // is absorbed the moment it appears — the old `.onChange` fired
        // into the void then, and the reply didn't show until the user
        // navigated away and back. The guard keeps a mount of an
        // already-absorbed session from re-reading for nothing.
        .task(id: session.completedTurns) {
            guard session.completedTurns > 0, session.hasUnabsorbedTurn
            else { return }
            onTurnEnd()
        }
        .onChange(of: session.streamText) { onGrow() }
        .onChange(of: session.liveBlocks.count) { onGrow() }
        .onChange(of: session.pendingUserText) { onGrow() }
        .onChange(of: session.approval != nil) { onGrow() }
        .onChange(of: session.queued.count) { onGrow() }
    }
}

/// A held message: sent while a turn was running, shown dimmed on the
/// trailing edge (where the user's bubbles sit) until it's its turn.
private struct QueuedMessageRow: View {
    let text: String
    let onCancel: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Spacer(minLength: 40)
            if hovered {
                CircleIconButton(
                    systemName: "xmark", iconSize: 9,
                    help: "Remove this held message",
                    action: onCancel
                )
            }
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text)
                    // No clamp — a clipped queued message read as the
                    // input being truncated (it never was on the wire).
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusSurface)
                    .fill(Theme.attachedWellFill)
            )
            .opacity(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onHover { hovered = $0 }
        .help("Queued — sends when the current turn finishes")
    }
}

/// I-beam over the composer's input well. `pointerStyle` needs macOS 15;
/// on 14 the well keeps the arrow (the field itself still I-beams once
/// focused) rather than fighting AppKit's cursor rects.
private struct IBeamCursor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.horizontalText)
        } else {
            content
        }
    }
}

/// How full the model's context window is, in the composer's corner — so
/// a chat maxing out is visible before compaction hits. Claude only (the
/// session publishes no usage for codex) and hidden until usage lands;
/// same bar + color ramp as the terminal status strip.
private struct ContextMeter: View {
    @ObservedObject var session: ChatAgentSession

    var body: some View {
        if let tokens = session.contextTokens, session.contextWindow > 0 {
            let fraction = min(1, Double(tokens) / Double(session.contextWindow))
            HStack(spacing: 6) {
                ContextBar(
                    pct: fraction,
                    color: Theme.Context.color(for: fraction),
                    trackWidth: 56,
                    trackHeight: 4
                )
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(Theme.Fonts.meta)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
            .help(
                "\(formatTokens(tokens)) of "
                + "\(formatTokens(session.contextWindow)) context used"
            )
        }
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
                    .font(Theme.Fonts.monoSmall)
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
                        .background(RoundedRectangle(cornerRadius: Theme.radiusControl).fill(Theme.ctaFill))
                }
                .buttonStyle(.plain)
                Button(action: onDeny) {
                    Text("Deny")
                        .font(Theme.Fonts.secondaryMedium)
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.radiusControl)
                                .fill(Theme.buttonFill)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusSurface).fill(Theme.panelFill))
    }
}

// MARK: - Composer

/// A quoted fragment staged in the composer: the full marker-wrapped
/// quote for the send, a short label for the chip.
private struct StagedFragment: Identifiable {
    let id = UUID()
    let label: String
    let text: String

    /// The label out of the wire format's `[Fragment "…"]` first line.
    static func label(from text: String) -> String {
        guard let open = text.range(of: "[Fragment \""),
              let close = text.range(of: "\"", range: open.upperBound..<text.endIndex)
        else { return "fragment" }
        let label = String(text[open.upperBound..<close.lowerBound])
        return label.isEmpty ? "fragment" : label
    }
}

/// The chat input bar: image attach, model picker, ghost-text autocomplete
/// (on-device model — dimmed inline continuation, Tab accepts), send.
private struct ChatComposer: View {
    let placeholder: String
    /// Menu selection before the user touches it — the session's harness.
    let initialModel: ChatModelChoice
    /// Conversation tail for autocomplete — non-nil only while the
    /// assistant's last message ended in a question; nil disables the
    /// ghost text entirely (both typed completion and the empty-field
    /// suggested reply).
    let ghostContext: String?
    /// The chat's live session, when one exists — the send button turns
    /// into Stop while its turn runs.
    var runningSession: ChatAgentSession? = nil
    /// Projects the leading chip offers (nil hides the chip — a
    /// transcript's composer already belongs to a project). Home stands
    /// in for "no project".
    var projectChoices: [String]? = nil
    var selectedProject: String? = nil
    var onSelectProject: ((String) -> Void)? = nil
    /// Attached bars sit flush on the window's bottom edge — square
    /// bottom corners, no gap. The new-chat composer floats mid-sky and
    /// keeps the all-round radius.
    var attached: Bool = true
    let onSend: (String, ChatModelChoice) -> Void

    @ObservedObject private var localModels = LocalModelStore.shared
    @ObservedObject private var providerAuth = ProviderAuthStore.shared
    @State private var draft = ""
    @State private var picked: ChatModelChoice?
    /// Chosen effort level (flag value); nil = the model's default. Only
    /// applied when the current model's harness supports the level.
    @State private var effort: String?
    /// nil = follow the initial model's mode (the session's last send).
    @State private var permission: ChatPermissionMode?
    @State private var suggestion = ""
    @State private var ghostTask: Task<Void, Never>?
    @State private var dropTargeted = false
    /// Images (or files) staged for the next send — shown as thumbnails,
    /// sent as quoted paths appended to the message text.
    @State private var attachments: [URL] = []
    /// Capsules staged for the next send — shown as chips, sent as their
    /// reference marker lines (which render back as chips).
    @State private var stagedCapsules: [ChatCapsule] = []
    /// Quoted fragments staged for the next send — shown as small chips
    /// (the full quote never touches the draft editor; big pasted text
    /// there made every keystroke re-run layout + ghost autocomplete).
    @State private var stagedFragments: [StagedFragment] = []
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
        VStack(alignment: .leading, spacing: 6) {
            // Staged capsules/fragments/images float ABOVE the input,
            // outside the composer's surface — the chips carry their own
            // chrome, so they read as riding on top of the bar.
            if !attachments.isEmpty || !stagedCapsules.isEmpty
                || !stagedFragments.isEmpty {
                attachmentRow
            }
            VStack(alignment: .leading, spacing: 4) {
                inputField
                // Controls live UNDER the input: project + attach +
                // pickers on the left, meter and send on the right.
                HStack(alignment: .center, spacing: 6) {
                    if projectChoices != nil { projectMenu }
                    Button(action: attachImage) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .frame(width: 24, height: 24)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Attach an image (inserts its path)")
                    modelMenu
                    harnessMenu
                    if model.provider == nil { effortMenu }
                    Spacer(minLength: 0)
                    if let runningSession {
                        ContextMeter(session: runningSession)
                    }
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
            .padding(.horizontal, 12)
            .padding(.top, 8)
            // Bottom padding matches the side padding (12) so the controls
            // sit evenly inset; the input height drops to compensate.
            .padding(.bottom, 12)
            // Frosted glass: the transcript scrolls behind the bar and
            // reads through the blur. The sidebarFill wash on top keeps
            // the chips and text at full contrast (bare material washed
            // them out over bright message text).
            .background(
                ZStack {
                    barShape.fill(.ultraThinMaterial)
                    barShape.fill(Theme.sidebarFill.opacity(0.6))
                }
                // On the background, not the bar — a whole-view shadow
                // would shadow the input text and chips too.
                .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 6)
            )
            // A hairline catches the glass edge against whatever slides
            // under it; the drop-target rose replaces it during a drag.
            .overlay(
                barShape
                    .strokeBorder(
                        dropTargeted ? Theme.link : Theme.text.opacity(0.09),
                        lineWidth: dropTargeted ? 1.5 : 1
                    )
            )
        }
        .onDrop(
            of: [.fileURL, .image, .plainText], isTargeted: $dropTargeted,
            perform: handleDrop
        )
        // Capsule-view insert buttons route here; drags land via onDrop
        // instead.
        .onReceive(
            NotificationCenter.default.publisher(for: .houstonComposerInsert)
        ) { note in
            guard let text = note.object as? String else { return }
            stageText(text)
        }
        // Clicking a capsule on the shelf stages it as a chip here.
        .onReceive(
            NotificationCenter.default.publisher(for: .houstonComposerAttachCapsule)
        ) { note in
            guard let capsule = note.object as? ChatCapsule,
                  !stagedCapsules.contains(where: { $0.id == capsule.id })
            else { return }
            stagedCapsules.append(capsule)
            inputFocused = true
        }
        // Same column as the transcript: 800 cap, and the bar's 20px
        // gutter plus its 12px inner padding lands the input text on the
        // transcript text's own 32px line — the glass extends wider, the
        // words align.
        .padding(.horizontal, 20)
        .frame(maxWidth: 800)
        .frame(maxWidth: .infinity)
        .padding(.bottom, attached ? 0 : 12)
        .padding(.top, 8)
        .onAppear { localModels.refresh() }
    }

    /// Attached: docked to the window's bottom edge, rounded on top only
    /// (a step up from radiusFloat), square where it meets the edge.
    /// Floating (the new-chat sky): the original all-round radius.
    private var barShape: UnevenRoundedRectangle {
        attached
            ? UnevenRoundedRectangle(
                topLeadingRadius: 16, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: 16
            )
            : UnevenRoundedRectangle(
                topLeadingRadius: Theme.radiusFloat,
                bottomLeadingRadius: Theme.radiusFloat,
                bottomTrailingRadius: Theme.radiusFloat,
                topTrailingRadius: Theme.radiusFloat
            )
    }

    // MARK: Control chips

    /// Where the chat runs — the leading chip on a new chat. Home stands
    /// in for "no project".
    private var projectMenu: some View {
        Menu {
            Toggle("No project", isOn: Binding(
                get: { effectiveProject == NSHomeDirectory() },
                set: { _ in onSelectProject?(NSHomeDirectory()) }
            ))
            Divider()
            ForEach(projectChoices ?? [], id: \.self) { path in
                Toggle((path as NSString).lastPathComponent, isOn: Binding(
                    get: { effectiveProject == path },
                    set: { _ in onSelectProject?(path) }
                ))
            }
        } label: {
            chip(effectiveProject == NSHomeDirectory()
                ? "No project"
                : (effectiveProject as NSString).lastPathComponent)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Project this chat runs in")
    }

    private var effectiveProject: String {
        selectedProject ?? NSHomeDirectory()
    }

    /// The top-level choice: every model across both harnesses (picking
    /// one selects its harness), with the permission modes riding along.
    private var modelMenu: some View {
        Menu {
            // One submenu per provider, each carrying its own sign-in
            // path at the bottom.
            Menu("Claude") {
                ForEach(ChatModelChoice.claude, id: \.self) { choice in
                    modelItem(choice)
                }
                Divider()
                Button("Sign in to Claude…") { providerAuth.signInClaude() }
            }
            Menu("OpenAI") {
                ForEach(ChatModelChoice.openAI, id: \.self) { choice in
                    modelItem(choice)
                }
                Divider()
                Button("Sign in to OpenAI…") { providerAuth.signInOpenAI() }
            }
            ForEach(ChatProvider.cloud) { provider in
                cloudProviderMenu(provider)
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
            Section("Permissions") {
                ForEach(ChatPermissionMode.allCases, id: \.self) { mode in
                    Toggle(isOn: Binding(
                        get: { activePermission == mode },
                        set: { _ in permission = mode }
                    )) {
                        Text(mode.label)
                        Text(mode.detail)
                    }
                }
            }
        } label: {
            chip(model.label,
                 tint: activePermission == .full ? Theme.textWarning : nil)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Model for this message, and what it may do without asking")
    }

    /// A cloud provider's submenu: its models (usable once signed in and
    /// the provider's API speaks the Responses wire codex needs), with
    /// sign-in / sign-out at the bottom. Sign-in opens the provider's
    /// console in the browser; the key pastes back into Houston.
    private func cloudProviderMenu(_ provider: ChatProvider) -> some View {
        Menu(provider.name) {
            ForEach(provider.models, id: \.arg) { m in
                modelItem(ChatModelChoice(
                    label: m.label, harness: provider.harness, arg: m.arg,
                    provider: provider.id
                ))
                .disabled(!provider.compatible || !providerAuth.signedIn(provider.id))
            }
            if !provider.compatible {
                Button("Models coming soon — the \(provider.name) harness "
                    + "is in progress") {}
                    .disabled(true)
            }
            Divider()
            if providerAuth.signedIn(provider.id) {
                Button("Sign out of \(provider.name)") {
                    providerAuth.clearKey(for: provider.id)
                }
            } else if provider.harness == .gemini {
                // Gemini: real browser OAuth through its CLI's ACP surface;
                // the key console stays as the fallback.
                Button("Sign in with Google…") { providerAuth.signInGemini() }
                Button("Use an API Key…") { providerAuth.beginSignIn(provider) }
            } else if provider.harness == .grok {
                // Grok Build owns its own browser OAuth (`grok login`).
                Button("Sign in to Grok…") {
                    PromptDelivery.login(.grok, project: effectiveProject)
                }
            } else {
                Button("Sign in to \(provider.name)…") {
                    providerAuth.beginSignIn(provider)
                }
            }
        }
    }

    /// Which CLI runs the send — decided by the model (each model runs on
    /// exactly one CLI today), so the incompatible option is disabled.
    private var harnessMenu: some View {
        Menu {
            harnessItem("Claude Code", .claude)
            harnessItem("Codex", .codex)
            harnessItem("Gemini CLI", .gemini)
            harnessItem("Grok Build", .grok)
        } label: {
            chip(harnessLabel(model.harness))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Which CLI runs this chat (follows the model)")
    }

    private func harnessItem(_ label: String, _ harness: ChatHarness) -> some View {
        Toggle(label, isOn: .constant(model.harness == harness))
            .disabled(harness != model.harness)
    }

    private func harnessLabel(_ harness: ChatHarness) -> String {
        switch harness {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .grok: "Grok Build"
        }
    }

    /// Reasoning effort, its own chip — hidden for local models (the
    /// local server decides).
    private var effortMenu: some View {
        Menu {
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
        } label: {
            chip(activeEffort?.label ?? "Effort")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Reasoning effort for this message")
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
                        .background(RoundedRectangle(cornerRadius: Theme.radiusSurface).fill(Theme.ctaFill))
                        .contentShape(RoundedRectangle(cornerRadius: Theme.radiusSurface))
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
                    .background(RoundedRectangle(cornerRadius: Theme.radiusSurface).fill(Theme.ctaFill))
                    .contentShape(RoundedRectangle(cornerRadius: Theme.radiusSurface))
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
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
        .contentShape(RoundedRectangle(cornerRadius: Theme.radiusControl))
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
            // Suppress the placeholder while a ghost suggestion is showing:
            // the dimmed suggestion IS the affordance (Tab accepts), and a
            // live placeholder underneath it just printed two strings on
            // the same line.
            TextField(suggestion.isEmpty ? placeholder : "", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...10)
                .focused($inputFocused)
                .onSubmit(send)
                // Shift+Enter breaks the line; plain Enter still submits
                // via onSubmit.
                .onKeyPress(keys: [.return], phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    draft += "\n"
                    return .handled
                }
                .onKeyPress(.tab) {
                    guard !suggestion.isEmpty else { return .ignored }
                    draft += suggestion
                    suggestion = ""
                    return .handled
                }
                .onChange(of: draft) { _, text in refreshGhost(text) }
                // A finished turn changes the tail (a question appears or
                // the old one clears) — re-derive the empty-field ghost.
                .onChange(of: ghostContext) { _, _ in refreshGhost(draft) }
                .onAppear { refreshGhost(draft) }
        }
        // A text AREA, not a field: the line sits at the top of a 64px
        // well with open space under it (more lines grow it further, to
        // 10). The whole well is the click target for focus. No
        // horizontal inset — the text's left edge lines up with the +
        // circle below it.
        .padding(.top, 10)
        .padding(.bottom, 8)
        .padding(.horizontal, 2)
        // Shortened to offset the extra bottom padding added under the
        // controls, so the bar's overall height holds.
        .frame(minHeight: 58, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: Theme.radiusSurface))
        .onTapGesture { inputFocused = true }
        // The whole well is a text target — cursor says so. NOT an
        // onHover + NSCursor.set(): AppKit's cursor-rect pass resets the
        // cursor on every mouse move until the field is first responder,
        // so set() just flickered. pointerStyle is the system-managed way.
        .modifier(IBeamCursor())
    }

    /// A menu row that carries the native checkmark on the current pick.
    private func modelItem(_ choice: ChatModelChoice) -> some View {
        Toggle(choice.label, isOn: Binding(
            get: { model == choice },
            set: { _ in picked = choice }
        ))
    }

    /// Debounced on-device completion; anything typed since the request
    /// went out invalidates the answer. An EMPTY field gets a suggested
    /// reply to the assistant's pending question ("Yes, build it" — Tab
    /// drops it into the prompt, Enter sends); a partial one gets the
    /// continuation. Both exist only while ghostContext is non-nil, i.e.
    /// the assistant actually asked something.
    private func refreshGhost(_ text: String) {
        suggestion = ""
        ghostTask?.cancel()
        guard let ghostContext else { return }
        if text.isEmpty {
            ghostTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                // Post-send the field is empty too, but the turn is
                // running — no suggestion for a question already answered.
                // (.settling passes: that's a FINISHED turn absorbing, the
                // moment a fresh question lands.)
                guard !Task.isCancelled, runningSession?.phase != .working
                else { return }
                let reply = await ChatTitler.suggestReply(context: ghostContext)
                guard !Task.isCancelled, draft.isEmpty, let reply else { return }
                suggestion = reply
            }
            return
        }
        guard text.count >= 3, !text.hasSuffix("\n") else { return }
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
            && attachments.isEmpty && stagedCapsules.isEmpty
            && stagedFragments.isEmpty
    }

    private func send() {
        let base = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Attachments travel as file paths in the message text — both
        // CLIs read images straight off disk, same as the terminal.
        // Capsules lead as their marker lines, fragments as their marker
        // blocks (so the transcript renders both back as chips).
        let paths = attachments.map { url in
            url.path.contains(" ") ? "\"\(url.path)\"" : url.path
        }
        let body = ((base.isEmpty ? [] : [base]) + paths).joined(separator: " ")
        let parts = stagedCapsules.map(\.referenceText)
            + stagedFragments.map(\.text)
            + (body.isEmpty ? [] : [body])
        let text = parts.joined(separator: "\n")
        guard !text.isEmpty else { return }
        draft = ""
        suggestion = ""
        attachments = []
        stagedCapsules = []
        stagedFragments = []
        onSend(text, model.applying(effort: effort, permission: activePermission))
    }

    private func attachImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        stage(url)
    }

    private func stage(_ url: URL) {
        guard !attachments.contains(url) else { return }
        attachments.append(url)
    }

    /// Staged capsule/fragment chips and file thumbnails, each removable
    /// before the send.
    private var attachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(stagedCapsules) { capsule in
                    CapsuleChip(
                        title: capsule.shortTitle, file: capsule.sourceFile,
                        onRemove: {
                            stagedCapsules.removeAll { $0.id == capsule.id }
                        }
                    )
                }
                ForEach(stagedFragments) { fragment in
                    FragmentChip(
                        title: fragment.label,
                        onRemove: {
                            stagedFragments.removeAll { $0.id == fragment.id }
                        }
                    )
                }
                ForEach(attachments, id: \.self) { url in
                    ZStack(alignment: .topTrailing) {
                        AttachmentThumb(url: url)
                        Button {
                            attachments.removeAll { $0 == url }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .padding(2)
                        .help("Remove")
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    /// Reference text (a dragged capsule or fragment, an insert button)
    /// stages as a chip — never into the draft editor, where a 6KB quote
    /// slowed every keystroke (layout + ghost autocomplete over all of
    /// it). Plain dropped text still joins the draft.
    private func stageText(_ text: String) {
        if text.hasPrefix("[Capsule \""),
           let capsule = CapsuleStore.shared.capsules
               .first(where: { $0.referenceText == text }) {
            if !stagedCapsules.contains(where: { $0.id == capsule.id }) {
                stagedCapsules.append(capsule)
            }
            inputFocused = true
        } else if text.hasPrefix("[Fragment \"") {
            stagedFragments.append(StagedFragment(
                label: StagedFragment.label(from: text), text: text
            ))
            inputFocused = true
        } else {
            appendToDraft(text)
        }
    }

    private func appendToDraft(_ text: String) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = trimmed.isEmpty ? text : trimmed + "\n\n" + text
        suggestion = ""
        inputFocused = true
    }

    /// Dropped files stage as attachments; raw image data (a drag from a
    /// browser or a screenshot thumbnail) is saved to a temp PNG first;
    /// dropped text stages capsules/fragments as chips, else appends to
    /// the draft.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(
                    forTypeIdentifier: UTType.fileURL.identifier, options: nil
                ) { item, _ in
                    let url: URL? = switch item {
                    case let data as Data: URL(dataRepresentation: data, relativeTo: nil)
                    case let url as URL: url
                    default: nil
                    }
                    guard let url else { return }
                    DispatchQueue.main.async { stage(url) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                provider.loadDataRepresentation(
                    forTypeIdentifier: UTType.image.identifier
                ) { data, _ in
                    guard let data, let saved = Self.saveDroppedImage(data) else { return }
                    DispatchQueue.main.async { stage(URL(fileURLWithPath: saved)) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(
                UTType.plainText.identifier
            ) {
                handled = true
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let text = object as? String, !text.isEmpty else { return }
                    DispatchQueue.main.async { stageText(text) }
                }
            }
        }
        return handled
    }

    /// One staged attachment: the image itself when it decodes, else the
    /// file's Finder icon (non-image drops stage too).
    private struct AttachmentThumb: View {
        let url: URL

        var body: some View {
            Group {
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSurface))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusSurface)
                    .stroke(Theme.buttonStroke, lineWidth: 1)
            )
            .help((url.path as NSString).abbreviatingWithTildeInPath)
        }
    }

    private nonisolated static func saveDroppedImage(_ data: Data) -> String? {
        guard let rep = NSBitmapImageRep(data: data),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoustonDrops", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let file = dir.appendingPathComponent(
            "drop-\(UUID().uuidString.prefix(8)).png"
        )
        guard (try? png.write(to: file)) != nil else { return nil }
        return file.path
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

/// One rendered message — user bubble or agent prose. Internal (not
/// private) so the capsule dialog renders its transcript identically.
struct MessageView: View {
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
                .padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: Theme.radiusFloat).fill(style.bubble))
                .frame(maxWidth: 500, alignment: .trailing)
            }
        } else {
            // The agent's turn: plain rich text on the page.
            VStack(alignment: .leading, spacing: 8) {
                Text(harness.rawValue.uppercased())
                    .font(Theme.Fonts.label)
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
                    color: message.role == .user ? style.text : Theme.chatProse,
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
                            .font(Theme.Fonts.mono)
                            .lineLimit(1)
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
            case let .capsule(title, file):
                CapsuleChip(
                    title: title, file: file,
                    accent: message.role == .user
                )
            case let .fragment(title, _):
                FragmentChip(title: title, accent: message.role == .user)
            case let .image(path):
                ChatImageBlock(path: path)
            }
        }
    }

}

/// An attached image in a transcript bubble: a real thumbnail (the path
/// still travels in the message text for the CLI). Click opens the file;
/// a deleted temp file degrades to a filename chip.
private struct ChatImageBlock: View {
    let path: String

    /// Decoded thumbnails, keyed by path — transcripts re-render often
    /// and screenshots are megabytes; decode each at most once.
    @MainActor private static var cache: [String: NSImage] = [:]

    private var image: NSImage? {
        if let hit = Self.cache[path] { return hit }
        guard let loaded = NSImage(contentsOfFile: path) else { return nil }
        Self.cache[path] = loaded
        return loaded
    }

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(
                    maxWidth: min(280, max(80, image.size.width)),
                    maxHeight: 220,
                    alignment: .leading
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSurface))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusSurface)
                        .strokeBorder(Color.black.opacity(0.15), lineWidth: 1)
                )
                .onTapGesture {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
                .help((path as NSString).abbreviatingWithTildeInPath)
        } else {
            HStack(spacing: 5) {
                Image(systemName: "photo")
                    .font(.system(size: 10, weight: .medium))
                Text((path as NSString).lastPathComponent)
                    .font(Theme.Fonts.bodyMedium)
                    .lineLimit(1)
            }
            .foregroundStyle(Color.white.opacity(0.8))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusControl)
                    .fill(Color.white.opacity(0.22))
            )
            .help("The image file is no longer on disk")
        }
    }
}

/// A capsule attachment in a chat: icon + short title. Click (or the
/// context menu) opens the capsule view in the right sheet, which shows
/// the sealed chat's full transcript.
struct CapsuleChip: View {
    let title: String
    let file: String
    /// On the user bubble — chip chrome adapts to the bubble color.
    var accent = false
    /// Staged in the composer: shows the remove ✕.
    var onRemove: (() -> Void)? = nil

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "capsule")
                .font(.system(size: 10, weight: .medium))
            Text(title)
                .font(Theme.Fonts.bodyMedium)
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .opacity(0.7)
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        .foregroundStyle(accent ? .white : Theme.text)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusControl)
                .fill(accent
                    ? Color.white.opacity(hovered ? 0.3 : 0.22)
                    : (hovered ? Theme.rowHovered : Theme.panelFill))
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.radiusControl))
        .onHover { hovered = $0 }
        .onTapGesture { openCapsuleView() }
        .contextMenu {
            Button("Open Capsule View") { openCapsuleView() }
        }
        .help("Open the capsule view — the sealed chat's full transcript")
    }

    private func openCapsuleView() {
        NotificationCenter.default.post(name: .houstonOpenCapsule, object: file)
    }
}

/// A quoted fragment in a chat or the composer: quote icon + a short
/// label. Just a marker — the quote itself is for the model, not the
/// reader (rendering 6KB of it froze the transcript).
struct FragmentChip: View {
    let title: String
    /// On the user bubble — chip chrome adapts to the bubble color.
    var accent = false
    /// Staged in the composer: shows the remove ✕.
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "text.quote")
                .font(.system(size: 10, weight: .medium))
            Text(title)
                .font(Theme.Fonts.bodyMedium)
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .opacity(0.7)
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        .foregroundStyle(accent ? .white : Theme.text)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusControl)
                .fill(accent ? Color.white.opacity(0.22) : Theme.panelFill)
        )
        .help("A quoted piece of an earlier chat, attached as context")
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
        .background(RoundedRectangle(cornerRadius: Theme.radiusSurface).fill(Theme.attachedWellFill))
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
    /// The user bubble skips it entirely — a return in the input reads as
    /// a line break, not a paragraph; only agent prose gets paragraph air.
    private func gap(after part: Part) -> CGFloat {
        if accent { return 2 }
        switch part {
        case .bullet, .numbered: return 8
        case .heading: return 6
        default: return 16
        }
    }

    /// Extra points between lines. The user bubble (`accent`) sits at a
    /// tight ~1.2 line height — 16pt SF's natural leading is already
    /// ~1.2×, so barely any extra; assistant prose keeps its airier 1.4×.
    private var proseGap: CGFloat { accent ? 1 : 8 }

    @ViewBuilder
    private func partView(_ part: Part) -> some View {
        switch part {
        case let .paragraph(body):
            styled(body, size: 16)
                .lineSpacing(proseGap)
        case let .heading(level, body):
            styled(body, size: level <= 1 ? 20 : (level == 2 ? 18 : 16), weight: .semibold)
                .padding(.top, 4)
        case let .bullet(indent, body):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("•")
                    .font(.system(size: 16))
                    .foregroundStyle(color.opacity(0.65))
                styled(body, size: 16)
                    .lineSpacing(proseGap)
            }
            .padding(.leading, 12 + CGFloat(indent) * 18)
        case let .numbered(indent, marker, body):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(marker)
                    .font(.system(size: 15))
                    .monospacedDigit()
                    .foregroundStyle(color.opacity(0.65))
                styled(body, size: 16)
                    .lineSpacing(proseGap)
            }
            .padding(.leading, 12 + CGFloat(indent) * 18)
        case let .quote(body):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color.opacity(0.3))
                    .frame(width: 3)
                styled(body, size: 15)
                    .lineSpacing(accent ? 1 : 6)
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
                    .background(RoundedRectangle(cornerRadius: Theme.radiusControl).fill(Theme.rowHovered))
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.host() ?? url.absoluteString)
                        .font(Theme.Fonts.title)
                        .foregroundStyle(Theme.text)
                    Text(url.absoluteString)
                        .font(Theme.Fonts.secondary)
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
                RoundedRectangle(cornerRadius: Theme.radiusSurface)
                    .fill(hovered ? Theme.rowHovered : Theme.panelFill)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusSurface))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(url.absoluteString)
    }
}
