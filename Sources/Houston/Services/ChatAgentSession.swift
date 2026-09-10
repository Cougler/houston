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
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var buffer = Data()
    private var stderrTail = Data()

    var onLine: (@Sendable (Data) -> Void)?
    var onExit: (@Sendable (Int32, String) -> Void)?

    var isRunning: Bool { process?.isRunning ?? false }

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
        probe.arguments = ["-lc", "command -v \(name)"]
        let out = Pipe()
        probe.standardOutput = out
        probe.standardError = Pipe()
        guard (try? probe.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        guard probe.terminationStatus == 0,
              let path = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        cacheLock.lock()
        binaryCache[name] = path
        cacheLock.unlock()
        return path
    }

    func start(binary: String, arguments: [String], cwd: String) throws {
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
        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting
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
        let process = process
        let stdin = stdinHandle
        self.process = nil
        self.stdinHandle = nil
        queue.async {
            try? stdin?.close()
        }
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

    init(harness: ChatHarness, projectPath: String, resumeID: String?) {
        self.harness = harness
        self.projectPath = projectPath
        self.sessionID = resumeID
    }

    var hasLiveContent: Bool {
        pendingUserText != nil || !liveBlocks.isEmpty || !streamText.isEmpty
            || approval != nil || lastError != nil
    }

    // MARK: Public controls

    func send(text: String, model: ChatModelChoice) {
        lastModel = model
        lastError = nil
        interrupting = false
        pendingUserText = text
        liveBlocks = []
        streamText = ""
        running = true
        switch harness {
        case .claude:
            sendClaude(text: text, model: model)
        case .codex:
            sendCodex(text: text, model: model)
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
        }
    }

    func dismissError() { lastError = nil }

    /// Absorb the finished turn (the transcript re-read now shows it).
    func clearTurn() {
        guard !running else { return }
        pendingUserText = nil
        liveBlocks = []
        streamText = ""
    }

    func shutdown() {
        transport?.terminate()
        transport = nil
        claudeModelKey = nil
        codexProviderKey = nil
        threadReady = false
        running = false
    }

    // MARK: Claude driver

    private func sendClaude(text: String, model: ChatModelChoice) {
        let key = (model.arg ?? "") + "|" + (model.effort ?? "")
            + "|" + model.permission.rawValue
        if transport == nil || claudeModelKey != key || transport?.isRunning != true {
            transport?.terminate()
            guard let binary = AgentTransport.resolveBinary("claude") else {
                fail("claude CLI not found on PATH")
                return
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
                return
            }
            self.transport = transport
            claudeModelKey = key
        }
        transport?.write([
            "type": "user",
            "message": [
                "role": "user",
                "content": [["type": "text", "text": text]],
            ],
        ])
    }

    private func handleClaude(_ o: [String: Any]) {
        switch o["type"] as? String {
        case "system":
            if o["subtype"] as? String == "init",
               let id = o["session_id"] as? String {
                sessionID = id
            }
        case "stream_event":
            guard let event = o["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return }
            streamText += text
        case "assistant":
            guard let message = o["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
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
        if transport == nil || transport?.isRunning != true
            || codexProviderKey != model.provider {
            transport?.terminate()
            threadReady = false
            guard let binary = AgentTransport.resolveBinary("codex") else {
                fail("codex CLI not found on PATH")
                return
            }
            var arguments = ["app-server"]
            if model.provider == LocalModelStore.mlxProviderID {
                arguments += [
                    "-c", "model_providers.mlx.name=MLX Core",
                    "-c", "model_providers.mlx.base_url=\(LocalModelStore.mlxBaseURL)",
                    // codex dropped the chat wire API; MLX Core serves
                    // /v1/responses natively, so "responses" is correct.
                    "-c", "model_providers.mlx.wire_api=responses",
                ]
            }
            let transport = AgentTransport()
            wire(transport)
            do {
                try transport.start(
                    binary: binary, arguments: arguments, cwd: projectPath
                )
            } catch {
                fail(error.localizedDescription)
                return
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
        if threadReady {
            startCodexTurn(text: text, model: model)
        } else {
            queuedTurns.append((text, model))
        }
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
        currentTurnID = nil
        if let error { lastError = error }
        completedTurns += 1
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

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ChatSessionHub.shared.shutdownAll()
            }
        }
    }

    func session(for ref: ChatSessionRef, project: String) -> ChatAgentSession {
        if let existing = sessions[ref.filePath] { return existing }
        let file = (ref.filePath as NSString).lastPathComponent
        let id: String = switch ref.harness {
        case .claude: (file as NSString).deletingPathExtension
        // rollout-<timestamp>-<uuid>.jsonl — the id is the last 36 chars.
        case .codex: String((file as NSString).deletingPathExtension.suffix(36))
        }
        let session = ChatAgentSession(
            harness: ref.harness, projectPath: project, resumeID: id
        )
        sessions[ref.filePath] = session
        return session
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

    /// Idle sessions are cheap but not free — drop the ones no chat is
    /// looking at, keeping any that are mid-turn.
    func releaseIdle(except keep: Set<String> = []) {
        for (file, session) in sessions
        where !keep.contains(file) && !session.running {
            session.shutdown()
            sessions.removeValue(forKey: file)
        }
        for (project, session) in drafts where !session.running && !session.hasLiveContent {
            session.shutdown()
            drafts.removeValue(forKey: project)
        }
    }

    func shutdownAll() {
        for session in sessions.values { session.shutdown() }
        for session in drafts.values { session.shutdown() }
        sessions = [:]
        drafts = [:]
    }
}
