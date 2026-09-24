import AppKit
import Foundation

/// Persistent chat engines — the architecture the desktop apps use.
///
/// One long-lived agent process per open chat instead of a CLI boot per
/// message: Claude Code speaks its `--input-format stream-json` protocol
/// (user messages in, streaming events out, permissions and interrupts as
/// control requests — verified against the live CLI), Codex speaks the
/// `codex app-server` JSON-RPC v2 protocol (thread/start, turn/start,
/// item deltas, approval server-requests — shapes from
/// `codex app-server generate-json-schema`). No file polling: the UI
/// renders the stream, and re-reads the transcript once per finished turn.

// MARK: - Transport

/// Owns one child process and its pipes. All I/O lands on a private
/// queue; the owner gets raw stdout lines and an exit callback there and
/// hops to the main actor itself.
final class AgentTransport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "houston.chat.transport")
    /// Queue-confined, like `buffer`/`stderrTail`: `write`/`writeRaw`
    /// read these on `queue` while `start`/`terminate` assign them from
    /// the caller — every access goes through `queue` or it's a race.
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var buffer = Data()
    private var stderrTail = Data()

    var onLine: (@Sendable (Data) -> Void)?
    var onExit: (@Sendable (Int32, String) -> Void)?

    var isRunning: Bool {
        queue.sync { process?.isRunning ?? false }
    }

    /// Resolved through a login shell once — the CLIs are npm globals that
    /// aren't on a GUI app's default PATH.
    nonisolated(unsafe) private static var binaryCache: [String: String] = [:]
    private static let cacheLock = NSLock()
    static func resolveBinary(_ name: String) -> String? {
        cacheLock.lock()
        if let hit = binaryCache[name] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // INTERACTIVE login shell (`-i`): a plain `-lc` login shell does
        // NOT source `.zshrc`, where user-installed CLIs put their PATH
        // (grok → ~/.grok/bin, added only there). System CLIs on the
        // default path resolved fine, hiding this. `-i` sources `.zshrc`.
        probe.arguments = ["-ilc", "command -v \(name)"]
        let out = Pipe()
        probe.standardOutput = out
        probe.standardError = Pipe()
        guard (try? probe.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        // A chatty `.zshrc` can print to stdout ahead of the answer, so
        // take the last line that's an absolute path to a real file
        // rather than trusting the whole output.
        let text = String(data: data, encoding: .utf8) ?? ""
        let path = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
        guard let path, !path.isEmpty else { return nil }
        cacheLock.lock()
        binaryCache[name] = path
        cacheLock.unlock()
        return path
    }

    /// The user's real shell PATH, resolved once through an interactive
    /// login zsh. Spawns must use THIS, not the app's inherited PATH: a
    /// GUI (or nohup) launch carries a minimal PATH, and codex is a node
    /// shim — `env: node: No such file or directory` killed every spawn
    /// when node lived behind `.zshrc` (nvm).
    nonisolated(unsafe) private static var cachedShellPATH: String?
    static func userShellPATH() -> String? {
        cacheLock.lock()
        if let hit = cachedShellPATH { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/zsh")
        probe.arguments = ["-ilc", "printf %s \"$PATH\""]
        let out = Pipe()
        probe.standardOutput = out
        probe.standardError = Pipe()
        guard (try? probe.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        // Last line, in case a chatty .zshrc printed above the answer.
        let path = (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n").map(String.init)
            .last { $0.contains("/") }
        guard let path, !path.isEmpty else { return nil }
        cacheLock.lock()
        cachedShellPATH = path
        cacheLock.unlock()
        return path
    }

    func start(
        binary: String, arguments: [String], cwd: String,
        extraEnvironment: [String: String] = [:]
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        // Same scrub as terminal panes: an inherited child-session marker
        // silently disables transcript saving, and the transcript IS the
        // chat.
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("CLAUDE_CODE_") {
            env.removeValue(forKey: key)
        }
        // Provider API keys ride the spawn env (codex reads them via
        // `env_key`) — never written to any config file.
        env.merge(extraEnvironment) { _, new in new }
        // The user's real shell PATH: node-shim CLIs (codex) die without
        // it when the app was launched with a minimal environment.
        if let shellPATH = Self.userShellPATH() {
            env["PATH"] = shellPATH
        }
        process.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.queue.async { self.consume(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.queue.async {
                self.stderrTail.append(data)
                if self.stderrTail.count > 4096 {
                    self.stderrTail = self.stderrTail.suffix(4096)
                }
            }
        }
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.queue.async {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                let tail = String(data: self.stderrTail, encoding: .utf8) ?? ""
                self.onExit?(proc.terminationStatus,
                             tail.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        try process.run()
        queue.sync {
            self.process = process
            self.stdinHandle = stdin.fileHandleForWriting
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { onLine?(line) }
        }
    }

    func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        queue.async { [weak self] in
            guard let self, let handle = self.stdinHandle else { return }
            try? handle.write(contentsOf: data + Data([0x0A]))
        }
    }

    /// Raw line write — for JSON-RPC responses whose id must be echoed
    /// byte-for-byte (it may be a number or a string).
    func writeRaw(_ line: String) {
        queue.async { [weak self] in
            guard let self, let handle = self.stdinHandle,
                  let data = (line + "\n").data(using: .utf8) else { return }
            try? handle.write(contentsOf: data)
        }
    }

    func terminate() {
        var detached: Process?
        queue.sync {
            detached = self.process
            let stdin = self.stdinHandle
            self.process = nil
            self.stdinHandle = nil
            try? stdin?.close()
        }
        let process = detached
        // Give a closing stdin a moment, then make sure.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process?.isRunning == true { process?.terminate() }
        }
    }
}

// MARK: - Session

/// One live conversation: the persistent process, the current turn's
/// streaming state, and the approval/interrupt controls. UI-facing state
/// is all `@Published` on the main actor.
@MainActor
final class ChatAgentSession: ObservableObject, Identifiable {
    struct ApprovalRequest: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        /// Claude: the tool input to echo back on allow (JSON).
        let claudeInputJSON: String?
        /// Codex: the raw JSON-RPC id to echo in the response.
        let codexIDRaw: String?
        /// Gemini (ACP): the request's raw JSON-RPC id, plus the option
        /// ids the agent offered for allow / deny.
        var geminiIDRaw: String? = nil
        var geminiAllowOption: String? = nil
        var geminiDenyOption: String? = nil
    }

    /// A send parked while a turn was running.
    struct QueuedSend: Identifiable {
        let id = UUID()
        let text: String
        let model: ChatModelChoice
    }

    let harness: ChatHarness
    let projectPath: String

    /// Claude session id / Codex thread id, once known.
    @Published private(set) var sessionID: String?
    @Published private(set) var running = false
    @Published private(set) var pendingUserText: String?
    /// Finished blocks of the running turn (text runs + tool chips).
    @Published private(set) var liveBlocks: [ChatMessage.Block] = []
    /// The currently-streaming text tail.
    @Published private(set) var streamText = ""
    /// Extended-thinking progress for the block in flight: the CLI's
    /// running token estimate (`system/thinking_tokens`), 0 the instant a
    /// thinking block opens, nil once a text or tool block lands. On an
    /// open-ended build prompt at high/xhigh, Opus 5.5 and Fable 5.1 think
    /// for MINUTES after the first tool result (measured 2026-09-24:
    /// 10k+ tokens, still going at two minutes) — the terminal shows a
    /// climbing counter, and without this the chat showed a bare
    /// "Working…" and read as frozen.
    @Published private(set) var thinkingTokens: Int?
    /// Exchanges superseded by a newer send before the transcript
    /// re-read absorbed them — rendered ahead of the pending message so
    /// back-to-back sends never make the earlier one vanish.
    @Published private(set) var carriedTurns: [ChatMessage] = []
    /// Messages the user sent while a turn was running — held (like the
    /// terminal's line editor) and sent one at a time as each turn ends.
    @Published private(set) var queued: [QueuedSend] = []
    @Published private(set) var approval: ApprovalRequest?
    @Published private(set) var lastError: String?
    /// Bumps when a turn finishes — the transcript view reloads on it.
    @Published private(set) var completedTurns = 0
    /// The most recent send's model — composers open on it instead of
    /// snapping back to the harness default (the pick must survive the
    /// empty state → draft → transcript view changes).
    @Published private(set) var lastModel: ChatModelChoice?

    private var transport: AgentTransport?
    /// The claude process is pinned to its launch model/effort; a change
    /// respawns with --resume.
    private var claudeModelKey: String?
    private var interrupting = false
    private var currentTurnID: String?
    private var controlCounter = 0

    // Codex JSON-RPC bookkeeping.
    private var rpcCounter = 0
    private var threadReady = false
    /// Provider the running thread was started with — `thread/start` is
    /// the only place `modelProvider` can be set (`turn/start` takes just
    /// the model), so a provider switch respawns and re-resumes, same as
    /// claude's model pin.
    private var codexProviderKey: String?
    private var queuedTurns: [(String, ChatModelChoice)] = []
    private var startRequestID: Int?

    // Gemini ACP bookkeeping. The agent is pinned to its launch model
    // (respawn on change, like claude); the prompt request id marks the
    // turn's end (its response carries the stopReason).
    private var acpModelKey: String?
    private var acpSessionReady = false
    private var acpNewSessionID: Int?
    private var acpPromptID: Int?
    private var acpQueuedPrompts: [String] = []
    /// Pi only: the model to select once the session is open. Pi's model
    /// isn't a spawn flag — it's set per session via
    /// `session/set_config_option`, and the session isn't "ready" (queued
    /// prompts held) until that request answers, or the first turn could
    /// race onto pi's default model.
    private var acpPendingModelArg: String?
    private var acpSetModelID: Int?
    /// The exchange being streamed — accumulated so the whole turn can be
    /// written to the Houston-owned transcript when it ends.
    private var acpTurnUser: String?
    private var acpTurnBlocks: [ChatMessage.Block] = []

    init(harness: ChatHarness, projectPath: String, resumeID: String?) {
        self.harness = harness
        self.projectPath = projectPath
        self.sessionID = resumeID
    }

    var hasLiveContent: Bool {
        pendingUserText != nil || !liveBlocks.isEmpty || !streamText.isEmpty
            || approval != nil || lastError != nil || !carriedTurns.isEmpty
            || !queued.isEmpty
    }

    /// Content a transcript re-read should absorb — the finished (or
    /// superseded) exchange still rendering from the live section. Unlike
    /// `hasLiveContent` this excludes queued sends and errors, which no
    /// re-read can absorb. Views trigger absorption off this LEVEL, never
    /// off the `completedTurns` edge alone: an edge that fires while the
    /// observer is unmounted is gone, a level is re-checked on mount.
    var hasUnabsorbedTurn: Bool {
        pendingUserText != nil || !liveBlocks.isEmpty || !streamText.isEmpty
            || !carriedTurns.isEmpty
    }

    /// The agent's state, made explicit so no view has to infer it:
    /// `working` = a turn is in flight; `settling` = the turn finished but
    /// the transcript re-read hasn't absorbed it yet; `idle` = fully
    /// caught up.
    enum Phase { case idle, working, settling }
    var phase: Phase {
        if running { return .working }
        return hasUnabsorbedTurn ? .settling : .idle
    }

    // MARK: Public controls

    /// Every send goes through the queue — one turn runs at a time, like
    /// the terminal's line editor. Idle with an empty queue means the
    /// message starts immediately; otherwise it's HELD and drains FIFO
    /// (so a fresh composer send can never jump ahead of messages already
    /// shown as queued). The session drains itself on each successful
    /// turn end — no view needs to be mounted.
    func send(text: String, model: ChatModelChoice) {
        lastModel = model
        lastUsed = Date()
        queued.append(QueuedSend(text: text, model: model))
        drainQueue()
    }

    /// When this session last did anything the user asked for — the warm
    /// TTL sweep reads it, so an untouched process is reclaimed while an
    /// active lane stays hot.
    private(set) var lastUsed = Date()

    /// Boot the agent process (and resume its session) WITHOUT sending,
    /// so the first send costs a keystroke instead of a CLI cold start +
    /// session load — the single biggest reason chat felt slower than a
    /// terminal pane. No-op when a live transport already exists; a model
    /// mismatch is left for the send to resolve (a warm wrong-model
    /// process still beats a cold right-model one for perceived latency).
    func warmUp(model: ChatModelChoice) {
        // Attention refreshes the TTL even when the process is already
        // warm — opening a chat IS using it.
        lastUsed = Date()
        guard !running, transport?.isRunning != true else { return }
        switch harness {
        case .claude:
            ensureClaudeTransport(model: model)
        case .codex:
            // A local-engine chat would boot the MLX server off a mere
            // row click — only cloud codex warms ahead of the send.
            guard model.provider == nil else { return }
            ensureCodexTransport(model: model)
        case .gemini, .grok, .pi:
            ensureACPTransport(model: model)
        }
    }

    /// Drop a held message before it runs (the ✕ on a queued bubble).
    func cancelQueued(_ id: UUID) {
        queued.removeAll { $0.id == id }
    }

    private func drainQueue() {
        guard !running, !queued.isEmpty else { return }
        let next = queued.removeFirst()
        begin(text: next.text, model: next.model)
    }

    private func begin(text: String, model: ChatModelChoice) {
        lastError = nil
        interrupting = false
        // A send while the previous exchange exists only in the live
        // section (mid-turn, or inside the transcript flush lag) must
        // not wipe it — the message visibly vanished until the next
        // reload. Carry it until a transcript re-read absorbs it.
        carryLiveTurn()
        pendingUserText = text
        liveBlocks = []
        streamText = ""
        running = true
        ChatSessionHub.shared.noteActivity()
        // The sidebar lists chats from the on-disk index, and its only
        // unthrottled refreshes used to live in the chat view — navigate
        // away and a new message didn't surface for up to 30s. A turn
        // starting is exactly when this chat's recency changes (and when
        // a brand-new chat's file is created), so re-index shortly after
        // the CLI's first transcript flush, no view required.
        let project = projectPath
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            ChatIndexStore.shared.refresh(project, force: true)
        }
        switch harness {
        case .claude:
            sendClaude(text: text, model: model)
        case .codex:
            sendCodex(text: text, model: model)
        case .gemini, .grok, .pi:
            sendACP(text: text, model: model)
        }
    }

    func interrupt() {
        guard running else { return }
        interrupting = true
        switch harness {
        case .claude:
            controlCounter += 1
            transport?.write([
                "type": "control_request",
                "request_id": "houston-\(controlCounter)",
                "request": ["subtype": "interrupt"],
            ])
        case .codex:
            guard let sessionID, let currentTurnID else { return }
            rpcCounter += 1
            transport?.write([
                "jsonrpc": "2.0", "id": rpcCounter, "method": "turn/interrupt",
                "params": ["threadId": sessionID, "turnId": currentTurnID],
            ])
        case .gemini, .grok, .pi:
            guard let sessionID else { return }
            // ACP cancel is a notification (no id); the in-flight
            // session/prompt then resolves with stopReason "cancelled".
            transport?.write([
                "jsonrpc": "2.0", "method": "session/cancel",
                "params": ["sessionId": sessionID],
            ])
        }
    }

    func respond(to request: ApprovalRequest, allow: Bool) {
        guard approval?.id == request.id else { return }
        approval = nil
        switch harness {
        case .claude:
            var inner: [String: Any] = allow
                ? ["behavior": "allow"]
                : ["behavior": "deny", "message": "User denied this in Houston"]
            if allow, let json = request.claudeInputJSON,
               let data = json.data(using: .utf8),
               let input = try? JSONSerialization.jsonObject(with: data) {
                inner["updatedInput"] = input
            }
            transport?.write([
                "type": "control_response",
                "response": [
                    "subtype": "success",
                    "request_id": request.id,
                    "response": inner,
                ],
            ])
        case .codex:
            guard let idRaw = request.codexIDRaw else { return }
            let decision = allow ? "accept" : "decline"
            transport?.writeRaw(
                #"{"jsonrpc":"2.0","id":\#(idRaw),"result":{"decision":"\#(decision)"}}"#
            )
        case .gemini, .grok, .pi:
            guard let idRaw = request.geminiIDRaw else { return }
            // ACP permission response: a "selected" outcome carrying the
            // chosen optionId, or "cancelled" for deny.
            if allow, let option = request.geminiAllowOption {
                transport?.writeRaw(
                    #"{"jsonrpc":"2.0","id":\#(idRaw),"result":{"outcome":{"outcome":"selected","optionId":"\#(option)"}}}"#
                )
            } else if !allow, let option = request.geminiDenyOption {
                transport?.writeRaw(
                    #"{"jsonrpc":"2.0","id":\#(idRaw),"result":{"outcome":{"outcome":"selected","optionId":"\#(option)"}}}"#
                )
            } else {
                transport?.writeRaw(
                    #"{"jsonrpc":"2.0","id":\#(idRaw),"result":{"outcome":{"outcome":"cancelled"}}}"#
                )
            }
        }
    }

    func dismissError() { lastError = nil }

    // MARK: - Context meter

    /// Context occupancy from the last usage-bearing event — the full
    /// prompt footprint (input + cache read/create + output), the same
    /// math the terminal status pipeline uses. Claude only: Codex's
    /// app-server publishes no cumulative usage, so codex chats show no
    /// meter rather than a guess.
    @Published private(set) var contextTokens: Int?
    private var contextModel: String?
    /// The window the CLI itself reported (result.modelUsage) — exact,
    /// beats the model-name allowlist guess whenever we have it.
    private var reportedWindow: Int?
    var contextWindow: Int {
        reportedWindow ?? ProcessDetect.contextWindow(for: contextModel)
    }

    /// Initial value for a resumed chat, read off the transcript tail by
    /// the hub — live events overwrite it and always win.
    func seedUsage(tokens: Int, model: String?) {
        guard contextTokens == nil, tokens > 0 else { return }
        contextTokens = tokens
        if contextModel == nil { contextModel = model }
    }

    private func captureUsage(_ usage: [String: Any]?, model: String?) {
        if let model { contextModel = model }
        guard let usage else { return }
        let total = ((usage["input_tokens"] as? Int) ?? 0)
            + ((usage["cache_read_input_tokens"] as? Int) ?? 0)
            + ((usage["cache_creation_input_tokens"] as? Int) ?? 0)
            + ((usage["output_tokens"] as? Int) ?? 0)
        if total > 0 { contextTokens = total }
    }

    /// The last error reads as "not signed in" — the CLIs phrase it many
    /// ways ("Invalid API key · Please run /login", "Not logged in, run
    /// codex login", 401s), so this is a hint match, not a protocol field.
    /// When it fires, the chat offers the terminal login flow instead of
    /// a dead-end error line.
    var needsLogin: Bool {
        guard let message = lastError?.lowercased() else { return false }
        let hints = [
            "login", "log in", "logged in", "logged out", "sign in",
            "api key", "unauthorized", "401", "authentication",
            "not authenticated", "credential", "oauth",
        ]
        return hints.contains { message.contains($0) }
    }

    /// Absorb the finished turn (the transcript re-read now shows it).
    func clearTurn() {
        guard !running else { return }
        pendingUserText = nil
        liveBlocks = []
        streamText = ""
        carriedTurns = []
        // Settling → idle is a phase change the sidebar badge reads.
        ChatSessionHub.shared.noteActivity()
    }

    /// Snapshot the current live exchange into `carriedTurns`.
    private func carryLiveTurn() {
        if let pending = pendingUserText {
            carriedTurns.append(ChatMessage(
                role: .user, blocks: ChatArchive.userBlocks(pending)
            ))
        }
        var blocks = liveBlocks
        if !streamText.isEmpty { blocks.append(.text(streamText)) }
        if !blocks.isEmpty {
            carriedTurns.append(ChatMessage(role: .assistant, blocks: blocks))
        }
    }

    /// Drop carried turns a fresh transcript parse now contains, so an
    /// exchange never renders twice while a later turn is still running
    /// (`clearTurn` can't run then — it's gated on idle).
    func dropCarried(absorbedBy parsed: [ChatMessage]) {
        guard !carriedTurns.isEmpty else { return }
        carriedTurns.removeAll { turn in
            guard let needle = Self.matchText(turn) else { return true }
            return parsed.contains { message in
                message.role == turn.role && message.blocks.contains { block in
                    if case let .text(text) = block { return text.contains(needle) }
                    return false
                }
            }
        }
    }

    private static func matchText(_ message: ChatMessage) -> String? {
        for block in message.blocks {
            if case let .text(text) = block, !text.isEmpty {
                return String(text.prefix(60))
            }
        }
        return nil
    }

    func shutdown() {
        transport?.terminate()
        transport = nil
        claudeModelKey = nil
        codexProviderKey = nil
        acpModelKey = nil
        acpSessionReady = false
        threadReady = false
        running = false
    }

    // MARK: Claude driver

    private func sendClaude(text: String, model: ChatModelChoice) {
        guard ensureClaudeTransport(model: model) else { return }
        transport?.write([
            "type": "user",
            "message": [
                "role": "user",
                "content": [["type": "text", "text": text]],
            ],
        ])
    }

    /// The claude process, spawned if absent (or pinned to a different
    /// model/effort/permission — it can't change those mid-flight, so a
    /// mismatch respawns with --resume). Shared by `sendClaude` and
    /// `warmUp`.
    @discardableResult
    private func ensureClaudeTransport(model: ChatModelChoice) -> Bool {
        let key = (model.arg ?? "") + "|" + (model.effort ?? "")
            + "|" + model.permission.rawValue
        if transport == nil || claudeModelKey != key || transport?.isRunning != true {
            transport?.terminate()
            guard let binary = AgentTransport.resolveBinary("claude") else {
                fail("claude CLI not found on PATH")
                return false
            }
            var args = [
                "-p", "--input-format", "stream-json",
                "--output-format", "stream-json",
                "--verbose", "--include-partial-messages",
                "--permission-prompt-tool", "stdio",
            ]
            if let id = sessionID { args += ["--resume", id] }
            if let arg = model.arg { args += ["--model", arg] }
            if let effort = model.effort { args += ["--effort", effort] }
            switch model.permission {
            case .ask: break
            case .edits: args += ["--permission-mode", "acceptEdits"]
            case .full: args += ["--permission-mode", "bypassPermissions"]
            }
            let transport = AgentTransport()
            wire(transport)
            do {
                try transport.start(binary: binary, arguments: args, cwd: projectPath)
            } catch {
                fail(error.localizedDescription)
                return false
            }
            self.transport = transport
            claudeModelKey = key
        }
        return true
    }

    private func handleClaude(_ o: [String: Any]) {
        switch o["type"] as? String {
        case "system":
            switch o["subtype"] as? String {
            case "init":
                if let id = o["session_id"] as? String { sessionID = id }
            case "thinking_tokens":
                // The CLI's own running estimate for the open thinking
                // block — the same number the terminal's spinner shows.
                if let n = o["estimated_tokens"] as? Int { thinkingTokens = n }
            default:
                break
            }
        case "stream_event":
            guard let event = o["event"] as? [String: Any] else { return }
            switch event["type"] as? String {
            case "content_block_start":
                // A thinking block opening shows "Thinking…" at once, before
                // the first token estimate; any other block ends the phase.
                let kind = (event["content_block"] as? [String: Any])?["type"] as? String
                thinkingTokens = kind == "thinking" ? (thinkingTokens ?? 0) : nil
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any],
                      delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String else { return }
                streamText += text
            default:
                break
            }
        case "assistant":
            guard let message = o["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            captureUsage(
                message["usage"] as? [String: Any],
                model: message["model"] as? String
            )
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty {
                        liveBlocks.append(.text(text))
                        streamText = ""
                    }
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    liveBlocks.append(.tool(
                        name: name,
                        detail: Self.toolDetail(block["input"] as? [String: Any])
                    ))
                default:
                    break
                }
            }
        case "control_request":
            guard let id = o["request_id"] as? String,
                  let request = o["request"] as? [String: Any] else { return }
            let subtype = request["subtype"] as? String
            if subtype == "can_use_tool" || subtype == "permission" {
                let tool = request["tool_name"] as? String ?? "tool"
                let input = request["input"] as? [String: Any]
                let inputJSON = input
                    .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                    .flatMap { String(data: $0, encoding: .utf8) }
                approval = ApprovalRequest(
                    id: id,
                    title: "Allow \(tool)?",
                    detail: Self.toolDetail(input),
                    claudeInputJSON: inputJSON,
                    codexIDRaw: nil
                )
            } else {
                // Unknown control traffic must not hang the CLI.
                transport?.write([
                    "type": "control_response",
                    "response": [
                        "subtype": "error", "request_id": id,
                        "error": "unsupported in Houston",
                    ],
                ])
            }
        case "control_cancel_request":
            if let id = o["request_id"] as? String, approval?.id == id {
                approval = nil
            }
        case "result":
            // Do NOT capture result.usage as context occupancy: it is
            // CUMULATIVE across every API call in the turn (verified
            // against the live CLI — a 3-call turn reported ~86k there
            // vs ~29k real footprint), so it inflated the meter after
            // every multi-tool turn and tripped rollover far too early.
            // The last assistant message's usage is the true footprint.
            // result.modelUsage does carry the model's exact context
            // window, though — take that over the allowlist guess.
            if let modelUsage = o["modelUsage"] as? [String: [String: Any]] {
                let entry = contextModel.flatMap { model in
                    modelUsage[model] ?? modelUsage.values.first {
                        $0["canonicalModel"] as? String == model
                    }
                }
                if let window = entry?["contextWindow"] as? Int, window > 0 {
                    reportedWindow = window
                }
            }
            let subtype = o["subtype"] as? String
            endTurn(error: (subtype == "success" || interrupting)
                ? nil : "The turn failed (\(subtype ?? "unknown")).")
        default:
            break
        }
    }

    // MARK: Codex driver

    private func sendCodex(text: String, model: ChatModelChoice) {
        // A local model needs its server answering before codex tries to
        // connect; the check is instant when it's already up.
        if model.provider == LocalModelStore.mlxProviderID {
            Task { [weak self] in
                let up = await LocalModelStore.shared.ensureMLXRunning()
                guard let self else { return }
                if up {
                    self.sendCodexNow(text: text, model: model)
                } else {
                    self.fail("MLX Core's server didn't start "
                        + "(port \(LocalModelStore.mlxPort)).")
                }
            }
        } else {
            sendCodexNow(text: text, model: model)
        }
    }

    private func sendCodexNow(text: String, model: ChatModelChoice) {
        guard ensureCodexTransport(model: model) else { return }
        if threadReady {
            startCodexTurn(text: text, model: model)
        } else {
            queuedTurns.append((text, model))
        }
    }

    /// The codex app-server, spawned + initialized + thread started (or
    /// resumed) if absent. Shared by `sendCodexNow` and `warmUp`.
    @discardableResult
    private func ensureCodexTransport(model: ChatModelChoice) -> Bool {
        if transport == nil || transport?.isRunning != true
            || codexProviderKey != model.provider {
            transport?.terminate()
            threadReady = false
            guard let binary = AgentTransport.resolveBinary("codex") else {
                fail("codex CLI not found on PATH")
                return false
            }
            var arguments = ["app-server"]
            var extraEnv: [String: String] = [:]
            if model.provider == LocalModelStore.mlxProviderID {
                arguments += [
                    "-c", "model_providers.mlx.name=MLX Core",
                    "-c", "model_providers.mlx.base_url=\(LocalModelStore.mlxBaseURL)",
                    // codex dropped the chat wire API; MLX Core serves
                    // /v1/responses natively, so "responses" is correct.
                    "-c", "model_providers.mlx.wire_api=responses",
                ]
            } else if let providerID = model.provider,
                      let provider = ChatProvider.by(id: providerID) {
                // A cloud provider (Grok, DeepSeek, …) on the same rail
                // as MLX: config overrides + the API key in the env.
                arguments += [
                    "-c", "model_providers.\(provider.id).name=\(provider.name)",
                    "-c", "model_providers.\(provider.id).base_url=\(provider.baseURL)",
                    "-c", "model_providers.\(provider.id).env_key=\(provider.envKey)",
                    "-c", "model_providers.\(provider.id).wire_api=responses",
                ]
                if let key = ProviderAuthStore.shared.key(for: provider.id) {
                    extraEnv[provider.envKey] = key
                } else {
                    fail("No \(provider.name) API key — sign in from the "
                        + "model menu first.")
                    return false
                }
            }
            let transport = AgentTransport()
            wire(transport)
            do {
                try transport.start(
                    binary: binary, arguments: arguments, cwd: projectPath,
                    extraEnvironment: extraEnv
                )
            } catch {
                fail(error.localizedDescription)
                return false
            }
            self.transport = transport
            codexProviderKey = model.provider
            rpcCounter += 1
            transport.write([
                "jsonrpc": "2.0", "id": rpcCounter, "method": "initialize",
                "params": ["clientInfo": [
                    "name": "houston", "title": "Houston", "version": "1.0",
                ]],
            ])
            transport.write(["jsonrpc": "2.0", "method": "initialized"])
            rpcCounter += 1
            startRequestID = rpcCounter
            var params: [String: Any] = ["cwd": projectPath]
            if let provider = model.provider {
                params["modelProvider"] = provider
                if let arg = model.arg { params["model"] = arg }
            }
            if let id = sessionID {
                params["threadId"] = id
                transport.write([
                    "jsonrpc": "2.0", "id": rpcCounter, "method": "thread/resume",
                    "params": params,
                ])
            } else {
                transport.write([
                    "jsonrpc": "2.0", "id": rpcCounter, "method": "thread/start",
                    "params": params,
                ])
            }
        }
        return true
    }

    private func startCodexTurn(text: String, model: ChatModelChoice) {
        guard let sessionID else { return }
        var params: [String: Any] = [
            "threadId": sessionID,
            "input": [["type": "text", "text": text]],
        ]
        if let arg = model.arg { params["model"] = arg }
        if let effort = model.effort { params["effort"] = effort }
        // Approval + sandbox ride every turn (they persist onto later
        // turns, but sending them each time keeps mid-chat switches live).
        switch model.permission {
        case .ask:
            params["approvalPolicy"] = "on-request"
        case .edits:
            params["approvalPolicy"] = "never"
            params["sandboxPolicy"] = ["type": "workspaceWrite"]
        case .full:
            params["approvalPolicy"] = "never"
            params["sandboxPolicy"] = ["type": "dangerFullAccess"]
        }
        rpcCounter += 1
        transport?.write([
            "jsonrpc": "2.0", "id": rpcCounter, "method": "turn/start",
            "params": params,
        ])
    }

    private func handleCodex(_ o: [String: Any], raw: Data) {
        let method = o["method"] as? String
        let hasID = o["id"] != nil
        if let method, hasID {
            handleCodexServerRequest(method: method, o: o, raw: raw)
        } else if let method {
            handleCodexNotification(method: method, o: o)
        } else if hasID {
            handleCodexResponse(o)
        }
    }

    private func handleCodexResponse(_ o: [String: Any]) {
        guard let id = o["id"] as? Int else { return }
        if let error = o["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "app-server error"
            if id == startRequestID {
                fail(message)
            } else {
                lastError = message
            }
            return
        }
        guard id == startRequestID,
              let result = o["result"] as? [String: Any] else { return }
        if let thread = result["thread"] as? [String: Any],
           let threadID = thread["id"] as? String {
            sessionID = threadID
        }
        threadReady = true
        let queued = queuedTurns
        queuedTurns = []
        for (text, model) in queued { startCodexTurn(text: text, model: model) }
    }

    private func handleCodexNotification(method: String, o: [String: Any]) {
        let params = o["params"] as? [String: Any] ?? [:]
        switch method {
        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String { streamText += delta }
        case "item/completed":
            guard let item = params["item"] as? [String: Any] else { return }
            switch item["type"] as? String {
            case "agentMessage":
                streamText = ""
                if let text = item["text"] as? String, !text.isEmpty {
                    liveBlocks.append(.text(text))
                }
            case "commandExecution":
                liveBlocks.append(.tool(
                    name: "Shell", detail: item["command"] as? String ?? ""
                ))
            case "fileChange":
                let changes = (item["changes"] as? [[String: Any]])?.count ?? 0
                liveBlocks.append(.tool(
                    name: "Edit",
                    detail: changes > 0 ? "\(changes) file(s)" : ""
                ))
            case "mcpToolCall":
                liveBlocks.append(.tool(
                    name: item["tool"] as? String ?? "MCP",
                    detail: item["server"] as? String ?? ""
                ))
            case "webSearch":
                liveBlocks.append(.tool(
                    name: "WebSearch", detail: item["query"] as? String ?? ""
                ))
            default:
                break
            }
        case "turn/started":
            if let turn = params["turn"] as? [String: Any] {
                currentTurnID = turn["id"] as? String
            }
        case "turn/completed":
            var failure: String?
            if let turn = params["turn"] as? [String: Any],
               let error = turn["error"] as? [String: Any] {
                failure = error["message"] as? String ?? "The turn failed."
            }
            endTurn(error: interrupting ? nil : failure)
        case "error":
            let message = (params["error"] as? [String: Any])?["message"] as? String
                ?? params["message"] as? String
            if running { endTurn(error: message ?? "app-server error") }
        default:
            break
        }
    }

    private func handleCodexServerRequest(
        method: String, o: [String: Any], raw: Data
    ) {
        // The JSON-RPC id must be echoed exactly (number or string) — cut
        // it out of the raw line instead of round-tripping types.
        let idRaw: String = {
            if let n = o["id"] as? Int { return String(n) }
            if let s = o["id"] as? String { return "\"\(s)\"" }
            return "null"
        }()
        let params = o["params"] as? [String: Any] ?? [:]
        switch method {
        case "item/commandExecution/requestApproval":
            approval = ApprovalRequest(
                id: idRaw,
                title: "Run command?",
                detail: params["command"] as? String
                    ?? (params["reason"] as? String ?? ""),
                claudeInputJSON: nil,
                codexIDRaw: idRaw
            )
        case "item/fileChange/requestApproval":
            approval = ApprovalRequest(
                id: idRaw,
                title: "Apply file changes?",
                detail: params["reason"] as? String ?? "",
                claudeInputJSON: nil,
                codexIDRaw: idRaw
            )
        default:
            transport?.writeRaw(
                #"{"jsonrpc":"2.0","id":\#(idRaw),"error":{"code":-32601,"message":"unsupported in Houston"}}"#
            )
        }
    }

    // MARK: Gemini driver (ACP — Zed's Agent Client Protocol)

    private func sendACP(text: String, model: ChatModelChoice) {
        guard ensureACPTransport(model: model) else { return }
        acpTurnUser = text
        acpTurnBlocks = []
        if acpSessionReady {
            startACPTurn(text: text)
        } else {
            acpQueuedPrompts.append(text)
        }
    }

    /// The `gemini --acp` process, spawned + initialized + session opened
    /// (new, or loaded when resuming a known id). Pinned to its launch
    /// model — a model change respawns, same as claude.
    @discardableResult
    private func ensureACPTransport(model: ChatModelChoice) -> Bool {
        let modelKey = model.arg ?? ""
        if transport == nil || transport?.isRunning != true
            || acpModelKey != modelKey {
            transport?.terminate()
            acpSessionReady = false
            acpSetModelID = nil
            // The ACP harnesses spawn a stdio agent; only the command and
            // its flags differ. Gemini: `gemini --acp -m <model>`. Grok
            // Build: `grok --model <model> agent stdio` (global flags lead
            // the subcommand). Pi: `pi-acp`, no model flag — the model is
            // set after session open (see `acpPendingModelArg`).
            let cli: String
            var arguments: [String]
            var extraEnv: [String: String] = [:]
            acpPendingModelArg = nil
            switch harness {
            case .grok:
                cli = "grok"
                arguments = []
                if let arg = model.arg { arguments += ["--model", arg] }
                arguments += ["agent", "stdio"]
            case .pi:
                cli = "pi-acp"
                arguments = []
                acpPendingModelArg = model.arg
                // Only the SELECTED model's provider key rides the spawn
                // (the pi id's prefix names it) — handing a third-party
                // CLI every stored key at once was over-sharing. Pi's own
                // credential store (~/.pi) covers everything else.
                // "oauth" is Houston's marker for CLI-held credentials,
                // not a key — never exported.
                let piPrefix = model.arg?.split(separator: "/").first
                    .map(String.init)
                let providerID: String? = switch piPrefix {
                case "xai": "xai"
                case "google": "gemini"
                case "deepseek": "deepseek"
                default: nil
                }
                if let providerID,
                   let provider = ChatProvider.by(id: providerID),
                   let key = ProviderAuthStore.shared.key(for: provider.id),
                   key != "oauth" {
                    extraEnv[provider.envKey] = key
                }
            default:
                cli = "gemini"
                arguments = ["--acp"]
                if let arg = model.arg { arguments += ["-m", arg] }
            }
            guard let binary = AgentTransport.resolveBinary(cli) else {
                switch harness {
                case .grok:
                    fail("Grok CLI not found — install it with "
                        + "`curl -fsSL https://x.ai/cli/install.sh | bash`.")
                case .pi:
                    fail("Pi not found — install it with `npm install -g "
                        + "@earendil-works/pi-coding-agent pi-acp`.")
                default:
                    fail("gemini CLI not found — install it with "
                        + "`brew install gemini-cli`.")
                }
                return false
            }
            let transport = AgentTransport()
            wire(transport)
            do {
                try transport.start(
                    binary: binary, arguments: arguments, cwd: projectPath,
                    extraEnvironment: extraEnv
                )
            } catch {
                fail(error.localizedDescription)
                return false
            }
            self.transport = transport
            acpModelKey = modelKey
            // ACP handshake: initialize, then open the session. The
            // session/new (or /load) response readies the turn queue.
            rpcCounter += 1
            transport.write([
                "jsonrpc": "2.0", "id": rpcCounter, "method": "initialize",
                "params": [
                    "protocolVersion": 1,
                    "clientCapabilities": [
                        "fs": ["readTextFile": false, "writeTextFile": false],
                    ],
                ],
            ])
            rpcCounter += 1
            acpNewSessionID = rpcCounter
            var params: [String: Any] = ["cwd": projectPath, "mcpServers": []]
            if let id = sessionID {
                params["sessionId"] = id
                transport.write([
                    "jsonrpc": "2.0", "id": rpcCounter, "method": "session/load",
                    "params": params,
                ])
            } else {
                transport.write([
                    "jsonrpc": "2.0", "id": rpcCounter, "method": "session/new",
                    "params": params,
                ])
            }
        }
        return true
    }

    private func markACPSessionReady() {
        acpSessionReady = true
        let queued = acpQueuedPrompts
        acpQueuedPrompts = []
        for text in queued { startACPTurn(text: text) }
    }

    private func startACPTurn(text: String) {
        guard let sessionID else { return }
        rpcCounter += 1
        acpPromptID = rpcCounter
        transport?.write([
            "jsonrpc": "2.0", "id": rpcCounter, "method": "session/prompt",
            "params": [
                "sessionId": sessionID,
                "prompt": [["type": "text", "text": text]],
            ],
        ])
    }

    private func handleACP(_ o: [String: Any]) {
        let method = o["method"] as? String
        let hasID = o["id"] != nil
        if let method, hasID {
            handleACPServerRequest(method: method, o: o)
        } else if let method {
            handleACPNotification(method: method, o: o)
        } else if hasID {
            handleACPResponse(o)
        }
    }

    private func handleACPResponse(_ o: [String: Any]) {
        guard let id = o["id"] as? Int else { return }
        if let error = o["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Agent error"
            if id == acpNewSessionID || id == acpSetModelID {
                fail(message)
            } else if running {
                endTurn(error: message)
            } else {
                lastError = message
            }
            return
        }
        let result = o["result"] as? [String: Any]
        if id == acpNewSessionID {
            if let newID = result?["sessionId"] as? String { sessionID = newID }
            // Pi: pin the chosen model before any prompt runs. The queue
            // stays held until set_config_option answers — a prompt sent
            // alongside could race onto pi's default model.
            if harness == .pi, let arg = acpPendingModelArg, let sessionID {
                rpcCounter += 1
                acpSetModelID = rpcCounter
                transport?.write([
                    "jsonrpc": "2.0", "id": rpcCounter,
                    "method": "session/set_config_option",
                    "params": [
                        "sessionId": sessionID,
                        "configId": "model",
                        "value": arg,
                    ],
                ])
                return
            }
            markACPSessionReady()
        } else if id == acpSetModelID {
            acpSetModelID = nil
            markACPSessionReady()
        } else if id == acpPromptID {
            // The prompt request resolves once the whole turn is done; its
            // stopReason distinguishes a clean finish from a refusal.
            let stop = result?["stopReason"] as? String
            let failure = (stop == "refusal") ? "The model declined to answer." : nil
            finishACPTurn(error: interrupting ? nil : failure)
        }
    }

    private func handleACPNotification(method: String, o: [String: Any]) {
        guard method == "session/update",
              let params = o["params"] as? [String: Any],
              let update = params["update"] as? [String: Any] else { return }
        switch update["sessionUpdate"] as? String {
        case "agent_message_chunk":
            if let text = acpChunkText(update["content"]) { streamText += text }
        case "tool_call":
            // Flush any streamed text into a block first so tool chips land
            // in order.
            flushACPStream()
            let title = update["title"] as? String
                ?? (update["kind"] as? String ?? "Tool")
            let block = ChatMessage.Block.tool(
                name: acpToolName(update["kind"] as? String),
                detail: title
            )
            liveBlocks.append(block)
            acpTurnBlocks.append(block)
        case "usage_update":
            // ACP publishes live context occupancy: `used` tokens of a
            // `size` window — a real meter, unlike codex.
            if let used = update["used"] as? Int, used > 0 {
                contextTokens = used
            }
            if let size = update["size"] as? Int, size > 0 {
                reportedWindow = size
            }
        default:
            // agent_thought_chunk, plan, available_commands_update, … —
            // not surfaced in the transcript.
            break
        }
    }

    private func handleACPServerRequest(method: String, o: [String: Any]) {
        let idRaw: String = {
            if let n = o["id"] as? Int { return String(n) }
            if let s = o["id"] as? String { return "\"\(s)\"" }
            return "null"
        }()
        let params = o["params"] as? [String: Any] ?? [:]
        switch method {
        case "session/request_permission":
            let options = params["options"] as? [[String: Any]] ?? []
            let toolCall = params["toolCall"] as? [String: Any]
            approval = ApprovalRequest(
                id: idRaw,
                title: toolCall?["title"] as? String ?? "Allow this action?",
                detail: acpToolName((toolCall?["kind"]) as? String),
                claudeInputJSON: nil,
                codexIDRaw: nil,
                geminiIDRaw: idRaw,
                geminiAllowOption: acpAllowOption(options),
                geminiDenyOption: acpDenyOption(options)
            )
        default:
            // Houston advertised no fs capability, so read/write requests
            // shouldn't arrive — refuse anything unexpected cleanly.
            transport?.writeRaw(
                #"{"jsonrpc":"2.0","id":\#(idRaw),"error":{"code":-32601,"message":"unsupported in Houston"}}"#
            )
        }
    }

    /// A completed ACP turn: flush the stream, persist the exchange to
    /// Houston's own transcript, then run the shared end-of-turn logic.
    private func finishACPTurn(error: String?) {
        flushACPStream()
        if error == nil, let user = acpTurnUser, let id = sessionID,
           !acpTurnBlocks.isEmpty {
            ChatArchive.appendACPTurn(
                projectPath: projectPath, id: id, harness: harness,
                user: user, assistant: acpTurnBlocks
            )
        }
        acpTurnUser = nil
        acpTurnBlocks = []
        endTurn(error: error)
    }

    private func flushACPStream() {
        guard !streamText.isEmpty else { return }
        let block = ChatMessage.Block.text(streamText)
        liveBlocks.append(block)
        acpTurnBlocks.append(block)
        streamText = ""
    }

    /// An ACP content chunk's text — `content` is a single ContentBlock
    /// (`{type:"text", text}`); non-text parts (images, audio) are skipped.
    private func acpChunkText(_ content: Any?) -> String? {
        guard let block = content as? [String: Any],
              block["type"] as? String == "text" else { return nil }
        return block["text"] as? String
    }

    /// ACP tool `kind` → a friendly chip name.
    private func acpToolName(_ kind: String?) -> String {
        switch kind {
        case "read": "Read"
        case "edit": "Edit"
        case "delete": "Delete"
        case "move": "Move"
        case "search": "Search"
        case "execute": "Shell"
        case "fetch": "Fetch"
        case "think": "Think"
        default: "Tool"
        }
    }

    /// Pick the option id that means "allow": prefer a one-shot approval,
    /// else the first non-reject/non-cancel option.
    private func acpAllowOption(_ options: [[String: Any]]) -> String? {
        let ids = options.compactMap { $0["optionId"] as? String }
        return ids.first { $0 == "proceed_once" }
            ?? ids.first { $0.hasPrefix("proceed") }
            ?? ids.first { !$0.contains("cancel") && !$0.contains("reject") }
    }

    private func acpDenyOption(_ options: [[String: Any]]) -> String? {
        let ids = options.compactMap { $0["optionId"] as? String }
        return ids.first { $0 == "cancel" }
            ?? ids.first { $0.contains("reject") || $0.contains("cancel") }
    }

    // MARK: Shared plumbing

    private func wire(_ transport: AgentTransport) {
        transport.onLine = { [weak self] line in
            guard let self,
                  let o = (try? JSONSerialization.jsonObject(with: line))
                    as? [String: Any] else { return }
            // Cross to the main actor with the parsed payload boxed; the
            // transport queue owns nothing UI-visible.
            let box = UncheckedBox(value: o)
            Task { @MainActor in
                switch self.harness {
                case .claude: self.handleClaude(box.value)
                case .codex: self.handleCodex(box.value, raw: line)
                case .gemini, .grok, .pi: self.handleACP(box.value)
                }
            }
        }
        transport.onExit = { [weak self] status, stderr in
            guard let self else { return }
            Task { @MainActor in
                guard self.transport != nil else { return }
                self.transport = nil
                self.claudeModelKey = nil
                self.codexProviderKey = nil
                self.acpModelKey = nil
                self.acpSessionReady = false
                self.threadReady = false
                if self.running {
                    let detail = stderr.isEmpty ? "exit \(status)" : stderr
                    self.endTurn(error: self.interrupting
                        ? nil : "The agent process died (\(detail)).")
                }
            }
        }
    }

    private func endTurn(error: String?) {
        running = false
        interrupting = false
        approval = nil
        thinkingTokens = nil
        currentTurnID = nil
        lastUsed = Date()
        if let error { lastError = error }
        completedTurns += 1
        ChatSessionHub.shared.noteActivity()
        // The transcript now holds the finished exchange — put it in the
        // sidebar immediately, even when no chat view is mounted.
        ChatIndexStore.shared.refresh(projectPath, force: true)
        // A finished OR stopped turn fires the next held message
        // (2026-09-21: Stop with a queue means "skip to what's waiting",
        // not "halt everything" — an empty queue still just halts). Only
        // an errored turn holds, so messages don't launch into the
        // failed state — or wipe the error the user hasn't seen yet.
        if error == nil {
            drainQueue()
        }
    }

    /// The queued bubble's ⬆ — run this held message NOW: it jumps to
    /// the front, and a running turn is interrupted (its end drains the
    /// queue, which now leads with this message).
    func sendQueuedNow(_ id: UUID) {
        guard let index = queued.firstIndex(where: { $0.id == id }) else { return }
        let item = queued.remove(at: index)
        queued.insert(item, at: 0)
        if running {
            interrupt()
        } else {
            drainQueue()
        }
    }

    private func fail(_ message: String) {
        running = false
        pendingUserText = nil
        lastError = message
    }

    private static func toolDetail(_ input: [String: Any]?) -> String {
        guard let input else { return "" }
        for key in ["description", "file_path", "command", "pattern", "query", "url"] {
            if let value = input[key] as? String, !value.isEmpty {
                return String(value.prefix(120))
            }
        }
        return ""
    }
}

/// Sends a non-Sendable JSON dictionary across the queue→MainActor hop;
/// ownership transfers whole, never shared.
private final class UncheckedBox: @unchecked Sendable {
    let value: [String: Any]
    init(value: [String: Any]) { self.value = value }
}

// MARK: - Hub

/// The set of live chat sessions: one per transcript file, plus at most
/// one "draft" (a new chat whose file isn't known yet) per project.
/// Sessions stay warm while their chat is open; everything dies with the
/// app.
@MainActor
final class ChatSessionHub: ObservableObject {
    static let shared = ChatSessionHub()

    @Published private(set) var sessions: [String: ChatAgentSession] = [:]
    @Published private(set) var drafts: [String: ChatAgentSession] = [:]

    /// Bumped on every session phase change (turn start/end/absorb) —
    /// the sidebar observes it so chat-row badges track working/idle
    /// without observing every session object individually.
    @Published private(set) var activityTick = 0
    func noteActivity() { activityTick += 1 }

    /// How long an untouched warm process survives. Sessions used to die
    /// the moment the chat browser closed, which made every return visit
    /// pay a CLI cold start + `--resume` session load — the whole reason
    /// chat felt slower than a terminal pane. Now warmth follows
    /// attention: recently used lanes stay hot, the sweep reclaims the
    /// rest.
    static let warmTTL: TimeInterval = 15 * 60
    /// Idle warm processes are ~100–300MB of node each — browsing chat
    /// rows must not accumulate a fleet. Beyond the cap, oldest idle dies.
    private static let maxIdleWarm = 4

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ChatSessionHub.shared.shutdownAll()
            }
        }
        Task { @MainActor [weak self] in
            while let self {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                self.ttlSweep()
            }
        }
    }

    /// Boot a chat's agent ahead of its first send (chat open, not send,
    /// is the trigger), then enforce the warm cap.
    func prewarm(_ ref: ChatSessionRef, project: String) {
        let session = session(for: ref, project: project)
        session.warmUp(
            model: session.lastModel ?? .fallback(for: ref.harness)
        )
        let idle = sessions
            .filter { $0.value.phase == .idle && $0.key != ref.filePath }
            .sorted { $0.value.lastUsed < $1.value.lastUsed }
        for (file, stale) in idle.dropLast(Self.maxIdleWarm - 1) {
            stale.shutdown()
            sessions.removeValue(forKey: file)
        }
    }

    /// Reclaim warm processes nothing has touched in `warmTTL` — except
    /// the chat on screen, which stays hot as long as it's being looked
    /// at. Mid-turn and unabsorbed sessions are never touched.
    private func ttlSweep() {
        let cutoff = Date().addingTimeInterval(-Self.warmTTL)
        for (file, session) in sessions
        where session.phase == .idle && session.lastUsed < cutoff
            && CapsuleStore.shared.activeChatFile != file {
            session.shutdown()
            sessions.removeValue(forKey: file)
        }
        for (project, session) in drafts
        where !session.running && !session.hasLiveContent
            && session.lastUsed < cutoff {
            session.shutdown()
            drafts.removeValue(forKey: project)
        }
    }

    func session(for ref: ChatSessionRef, project: String) -> ChatAgentSession {
        if let existing = sessions[ref.filePath] { return existing }
        let file = (ref.filePath as NSString).lastPathComponent
        let id: String = switch ref.harness {
        case .claude: (file as NSString).deletingPathExtension
        // rollout-<timestamp>-<uuid>.jsonl — the id is the last 36 chars.
        case .codex: String((file as NSString).deletingPathExtension.suffix(36))
        // Houston names the file <acpSessionId>.jsonl.
        case .gemini, .grok, .pi: (file as NSString).deletingPathExtension
        }
        let session = ChatAgentSession(
            harness: ref.harness, projectPath: project, resumeID: id
        )
        sessions[ref.filePath] = session
        seedContext(session, transcript: ref.filePath)
        return session
    }

    /// Seed a resumed Claude chat's context meter from its transcript
    /// tail, so the meter reads before the first new turn. Off-main —
    /// `readUsage` hits the filesystem (and can fall back to a full read).
    private func seedContext(_ session: ChatAgentSession, transcript path: String) {
        guard session.harness == .claude else { return }
        Task.detached(priority: .utility) {
            let summary = ProcessDetect.readUsage(jsonlPath: path)
            guard summary.contextTokens > 0 else { return }
            await MainActor.run {
                session.seedUsage(
                    tokens: summary.contextTokens, model: summary.model
                )
            }
        }
    }

    /// The new-chat session for a project — reused until it's promoted to
    /// a real file, replaced if the user switches harness.
    func draft(in project: String, harness: ChatHarness) -> ChatAgentSession {
        if let existing = drafts[project], existing.harness == harness {
            return existing
        }
        drafts[project]?.shutdown()
        let session = ChatAgentSession(
            harness: harness, projectPath: project, resumeID: nil
        )
        drafts[project] = session
        return session
    }

    /// A resumable session created directly on a known id whose file
    /// exists (cross-harness transplants).
    func adopt(file: String, harness: ChatHarness, project: String, id: String) -> ChatAgentSession {
        if let existing = sessions[file] { return existing }
        let session = ChatAgentSession(
            harness: harness, projectPath: project, resumeID: id
        )
        sessions[file] = session
        seedContext(session, transcript: file)
        return session
    }

    /// The draft grew a real transcript file — rekey it.
    func promoteDraft(in project: String, to file: String) {
        guard let draft = drafts.removeValue(forKey: project) else { return }
        if let displaced = sessions[file], displaced !== draft {
            displaced.shutdown()
        }
        sessions[file] = draft
    }

    func discardDraft(in project: String) {
        drafts.removeValue(forKey: project)?.shutdown()
    }

    /// The chat's file is going away — kill any live process on it.
    func forget(file: String) {
        sessions.removeValue(forKey: file)?.shutdown()
    }

    func shutdownAll() {
        for session in sessions.values { session.shutdown() }
        for session in drafts.values { session.shutdown() }
        sessions = [:]
        drafts = [:]
    }
}
