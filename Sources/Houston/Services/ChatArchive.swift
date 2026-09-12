import Foundation

/// Which CLI harness wrote a session transcript.
enum ChatHarness: String {
    case claude = "Claude"
    case codex = "Codex"
}

/// One session file on disk, indexed for the chat browser's list.
struct ChatSessionRef: Identifiable, Equatable {
    let harness: ChatHarness
    let filePath: String
    let title: String
    let modified: Date
    var id: String { filePath }
}

/// One rendered message: a run of same-role content.
struct ChatMessage: Identifiable {
    enum Role { case user, assistant }
    enum Block: Identifiable {
        case text(String)
        /// Fenced code with the fence's language hint, when it had one.
        case code(String, lang: String?)
        /// A tool invocation, compressed to a chip: name + one-line detail.
        case tool(name: String, detail: String)
        /// A capsule attachment marker — rendered as a capsule chip
        /// (short title; click opens the capsule view on `file`).
        case capsule(title: String, file: String)
        /// A quoted fragment from a sealed chat — the full quote rides
        /// along for the model (and transplants), but only the short
        /// title renders, as a chip.
        case fragment(title: String, text: String)

        var id: String {
            switch self {
            case let .text(s): "t:\(s.hashValue)"
            case let .code(s, _): "c:\(s.hashValue)"
            case let .tool(name, detail): "x:\(name):\(detail.hashValue)"
            case let .capsule(_, file): "cap:\(file.hashValue)"
            case let .fragment(title, _): "frag:\(title.hashValue)"
            }
        }
    }
    /// Stable across re-parses: the parser numbers messages in order, so
    /// a transcript reload updates rows in place instead of tearing down
    /// and rebuilding every message view (visible as a flicker).
    let id: String
    let role: Role
    var blocks: [Block]

    init(id: String = UUID().uuidString, role: Role, blocks: [Block]) {
        self.id = id
        self.role = role
        self.blocks = blocks
    }
}

/// Reads the session archives both harnesses keep on disk —
/// `~/.claude/projects/<munged-cwd>/*.jsonl` and
/// `~/.codex/sessions/**/rollout-*.jsonl` — and turns them into clean chat
/// transcripts. Pure file reading; call off the main thread.
enum ChatArchive {

    // MARK: - Session index

    static func sessions(for projectPath: String) -> [ChatSessionRef] {
        var out = claudeSessions(for: projectPath) + codexSessions(for: projectPath)
        out.sort { $0.modified > $1.modified }
        return out
    }

    private static var home: String { NSHomeDirectory() }

    /// Claude's per-project directory name: every non-alphanumeric character
    /// of the cwd becomes "-".
    static func claudeProjectDir(for projectPath: String) -> String {
        let munged = String(projectPath.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return home + "/.claude/projects/" + munged
    }

    private static func claudeSessions(for projectPath: String) -> [ChatSessionRef] {
        let dir = claudeProjectDir(for: projectPath)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var refs: [ChatSessionRef] = []
        for name in names where name.hasSuffix(".jsonl") {
            let path = dir + "/" + name
            let attributes = (try? fm.attributesOfItem(atPath: path)) ?? [:]
            let mtime = attributes[.modificationDate] as? Date ?? .distantPast
            let size = (attributes[.size] as? Int) ?? 0
            let title: String?
            if let cached = claudeTitleCache.get(
                path, mtime: mtime.timeIntervalSince1970, size: size
            ) {
                title = cached
            } else {
                title = claudeTitle(path: path)
                claudeTitleCache.set(
                    path, mtime: mtime.timeIntervalSince1970, size: size, title: title
                )
            }
            guard let title else { continue }
            refs.append(ChatSessionRef(
                harness: .claude, filePath: path, title: title, modified: mtime
            ))
        }
        return refs
    }

    /// The list title: the session's summary line when Claude wrote one,
    /// else the first *substantive* user message — slash commands and
    /// bash-mode inputs only ever title a chat when nothing better exists
    /// in it. nil = no user turn at all (warmup files).
    private static func claudeTitle(path: String) -> String? {
        var substantive: String?
        var commandOnly: String?
        var summary: String?
        // The budget must survive pasted screenshots: images ride base64
        // inside the early message lines and a small cap dies inside them
        // before the first real sentence (a session titled "/clear" was
        // this). Summary lines sit at the head when present, so the scan
        // stops at the first substantive message instead of reading on.
        scanLines(path: path, maxBytes: 8_000_000) { obj in
            if summary == nil, obj["type"] as? String == "summary",
               let s = obj["summary"] as? String, !s.isEmpty {
                summary = s
            }
            if substantive == nil, let text = claudeUserText(obj) {
                if isCommandLike(text) {
                    if commandOnly == nil { commandOnly = text }
                } else {
                    substantive = text
                }
            }
            return substantive == nil
        }
        guard substantive != nil || commandOnly != nil else { return nil }
        return summary ?? (substantive ?? commandOnly).map { condense($0) }
    }

    /// A message that is a command invocation, not conversation — useless
    /// as a chat name ("/clear", "$ npm run dev").
    private static func isCommandLike(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("/") && !t.contains("\n") { return true }
        if t.hasPrefix("$ ") { return true }
        return false
    }

    /// Codex writes every session into one global tree with the cwd only
    /// inside the first line — index it once and keep the answers.
    private struct CodexHead: Codable {
        let cwd: String?
        /// Houston's own cross-harness transplants — never listed, the
        /// original chat already is.
        let houstonExport: Bool
        var mtime: Double = 0
        var size: Int = 0
    }
    /// Persisted to disk keyed by (mtime, size): without it every launch
    /// re-read the head of every rollout file — tens of thousands — and
    /// chats took seconds to appear.
    private final class CwdCache: @unchecked Sendable {
        private var values: [String: CodexHead] = [:]
        private var dirty = false
        private let lock = NSLock()

        private static var fileURL: URL {
            let dir = ("~/Library/Application Support/Houston" as String).expandingTildePath
            return URL(fileURLWithPath: dir).appendingPathComponent("codex-heads.json")
        }

        init() {
            if let data = try? Data(contentsOf: Self.fileURL),
               let stored = try? JSONDecoder().decode([String: CodexHead].self, from: data) {
                values = stored
            }
        }

        func get(_ key: String, mtime: Double, size: Int) -> CodexHead? {
            lock.lock(); defer { lock.unlock() }
            guard let hit = values[key], hit.mtime == mtime, hit.size == size else {
                return nil
            }
            return hit
        }

        func set(_ key: String, _ value: CodexHead) {
            lock.lock(); defer { lock.unlock() }
            values[key] = value
            dirty = true
        }

        func saveIfDirty() {
            lock.lock()
            guard dirty else { lock.unlock(); return }
            dirty = false
            let snapshot = values
            lock.unlock()
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(
                at: Self.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
    private static let codexCwdCache = CwdCache()

    /// Heuristic titles (both harnesses) re-derived only when the file
    /// changes — the scan can read megabytes past pasted images, too
    /// heavy to repeat per refresh.
    private final class TitleCache: @unchecked Sendable {
        private var values: [String: (mtime: Double, size: Int, title: String?)] = [:]
        private let lock = NSLock()
        func get(_ key: String, mtime: Double, size: Int) -> String?? {
            lock.lock(); defer { lock.unlock() }
            guard let hit = values[key], hit.mtime == mtime, hit.size == size else {
                return nil
            }
            return .some(hit.title)
        }
        func set(_ key: String, mtime: Double, size: Int, title: String?) {
            lock.lock(); defer { lock.unlock() }
            values[key] = (mtime, size, title)
        }
    }
    private static let claudeTitleCache = TitleCache()

    private static func codexSessions(for projectPath: String) -> [ChatSessionRef] {
        let root = home + "/.codex/sessions"
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: root) else { return [] }
        var refs: [ChatSessionRef] = []
        for case let rel as String in walker {
            guard rel.hasSuffix(".jsonl"),
                  (rel as NSString).lastPathComponent.hasPrefix("rollout-") else { continue }
            let path = root + "/" + rel
            let attributes = (try? fm.attributesOfItem(atPath: path)) ?? [:]
            let mtime = attributes[.modificationDate] as? Date ?? .distantPast
            let size = (attributes[.size] as? Int) ?? 0
            let head = codexHead(
                path: path, mtime: mtime.timeIntervalSince1970, size: size
            )
            guard head.cwd == projectPath, !head.houstonExport else { continue }
            let title: String?
            if let cached = claudeTitleCache.get(
                path, mtime: mtime.timeIntervalSince1970, size: size
            ) {
                title = cached
            } else {
                title = codexTitle(path: path)
                claudeTitleCache.set(
                    path, mtime: mtime.timeIntervalSince1970, size: size, title: title
                )
            }
            guard let title else { continue }
            refs.append(ChatSessionRef(
                harness: .codex, filePath: path, title: title, modified: mtime
            ))
        }
        codexCwdCache.saveIfDirty()
        return refs
    }

    /// The cwd (and Houston's export marker) sit in the first few hundred
    /// bytes of the meta line, before the (huge) base instructions — a
    /// bounded regex read keeps indexing tens of thousands of rollout
    /// files tolerable.
    private static func codexHead(path: String, mtime: Double, size: Int) -> CodexHead {
        if let cached = codexCwdCache.get(path, mtime: mtime, size: size) {
            return cached
        }
        var cwd: String?
        var houston = false
        if let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 4096),
               let head = String(data: data, encoding: .utf8) ?? String(
                   data: data, encoding: .isoLatin1
               ) {
                if let range = head.range(
                    of: #""cwd":"([^"\\]|\\.)*""#, options: .regularExpression
                ) {
                    let raw = head[range].dropFirst(7).dropLast()
                    cwd = raw.replacingOccurrences(of: "\\/", with: "/")
                }
                houston = head.contains(#""originator":"Houston""#)
            }
        }
        let result = CodexHead(
            cwd: cwd, houstonExport: houston, mtime: mtime, size: size
        )
        codexCwdCache.set(path, result)
        return result
    }

    /// Joined text of a Codex message payload's content blocks
    /// (`input_text` / `output_text`).
    private static func codexContentText(_ payload: [String: Any]) -> String? {
        guard let content = payload["content"] as? [[String: Any]] else { return nil }
        let parts = content.compactMap { $0["text"] as? String }
        let joined = parts.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    /// nil for ChatGPT Desktop's *imports* of other agents' sessions (it
    /// converts foreign transcripts into rollouts, re-encoding their tool
    /// calls as `[external_agent_tool_call: …]` text) — the original
    /// already appears in the Claude listing, so the copy would be a dupe.
    private static func codexTitle(path: String) -> String? {
        var substantive: String?
        var commandOnly: String?
        var imported = false
        var assistantChecked = 0
        scanLines(path: path, maxBytes: 512_000) { obj in
            guard let payload = obj["payload"] as? [String: Any] else { return true }
            var userText: String?
            if obj["type"] as? String == "event_msg",
               payload["type"] as? String == "user_message",
               let message = payload["message"] as? String {
                userText = cleanUserText(message)
            } else if obj["type"] as? String == "response_item",
                      payload["type"] as? String == "message",
                      let text = codexContentText(payload) {
                switch payload["role"] as? String {
                case "user":
                    userText = cleanUserText(text)
                case "assistant":
                    if text.contains("[external_agent_tool_call")
                        || text.hasPrefix("[external_agent_tool_result") {
                        imported = true
                        return false
                    }
                    assistantChecked += 1
                default:
                    break
                }
            }
            if let userText {
                if isCommandLike(userText) {
                    if commandOnly == nil { commandOnly = userText }
                } else if substantive == nil {
                    substantive = userText
                }
            }
            // Keep scanning past the title until enough assistant turns
            // have been cleared of import markers.
            return substantive == nil || assistantChecked < 6
        }
        if imported { return nil }
        return (substantive ?? commandOnly).map { condense($0) }
    }

    // MARK: - Title snippet

    /// The opening exchange, compact — fuel for the on-device title model.
    static func titleSnippet(_ ref: ChatSessionRef) -> String? {
        var user: String?
        var assistant: String?
        // Same budget rationale as `claudeTitle`: pasted images are base64
        // in the early lines and must not eat the whole scan.
        scanLines(path: ref.filePath, maxBytes: 8_000_000) { obj in
            switch ref.harness {
            case .claude:
                if user == nil, let t = claudeUserText(obj), !isCommandLike(t) {
                    user = t
                }
                if assistant == nil, obj["type"] as? String == "assistant",
                   let message = obj["message"] as? [String: Any] {
                    for block in contentBlocks(message)
                    where block["type"] as? String == "text" {
                        if let t = block["text"] as? String, !t.isEmpty {
                            assistant = t
                            break
                        }
                    }
                }
            case .codex:
                guard let payload = obj["payload"] as? [String: Any],
                      obj["type"] as? String == "response_item",
                      payload["type"] as? String == "message",
                      let text = codexContentText(payload) else { break }
                switch payload["role"] as? String {
                case "user":
                    if user == nil, let clean = cleanUserText(text),
                       !isCommandLike(clean) {
                        user = clean
                    }
                case "assistant":
                    if assistant == nil, !text.hasPrefix("[external_agent_tool") {
                        assistant = text
                    }
                default:
                    break
                }
            }
            return user == nil || assistant == nil
        }
        guard user != nil || assistant != nil else { return nil }
        var parts: [String] = []
        if let user { parts.append("User: " + String(user.prefix(1500))) }
        if let assistant { parts.append("Assistant: " + String(assistant.prefix(600))) }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Transcripts

    /// Parsed transcripts keyed by (mtime, size), small LRU — reopening a
    /// chat renders instantly instead of flashing a spinner, and the
    /// once-per-turn re-read only pays for parsing when the file actually
    /// changed.
    private final class TranscriptCache: @unchecked Sendable {
        private var values: [String: (mtime: Double, size: Int, messages: [ChatMessage])] = [:]
        private var order: [String] = []
        private let lock = NSLock()

        func get(_ key: String, mtime: Double, size: Int) -> [ChatMessage]? {
            lock.lock(); defer { lock.unlock() }
            guard let hit = values[key], hit.mtime == mtime, hit.size == size else {
                return nil
            }
            return hit.messages
        }

        func set(_ key: String, mtime: Double, size: Int, messages: [ChatMessage]) {
            lock.lock(); defer { lock.unlock() }
            values[key] = (mtime, size, messages)
            order.removeAll { $0 == key }
            order.append(key)
            while order.count > 8 {
                values.removeValue(forKey: order.removeFirst())
            }
        }
    }
    private static let transcriptCache = TranscriptCache()

    private static func fileStat(_ path: String) -> (mtime: Double, size: Int) {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        return (
            (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            (attributes[.size] as? Int) ?? 0
        )
    }

    static func transcript(_ ref: ChatSessionRef) -> [ChatMessage] {
        let stat = fileStat(ref.filePath)
        if let hit = transcriptCache.get(ref.filePath, mtime: stat.mtime, size: stat.size) {
            return hit
        }
        let parsed = switch ref.harness {
        case .claude: claudeTranscript(path: ref.filePath)
        case .codex: codexTranscript(path: ref.filePath)
        }
        transcriptCache.set(
            ref.filePath, mtime: stat.mtime, size: stat.size, messages: parsed
        )
        return parsed
    }

    /// The cached parse if the file hasn't changed since — one stat plus a
    /// dictionary hit, cheap enough for the main thread. nil means the
    /// caller must do a real (off-main) `transcript` read.
    static func cachedTranscript(_ ref: ChatSessionRef) -> [ChatMessage]? {
        let stat = fileStat(ref.filePath)
        return transcriptCache.get(ref.filePath, mtime: stat.mtime, size: stat.size)
    }

    private static func claudeTranscript(path: String) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        scanLines(path: path, maxBytes: .max) { obj in
            // Sidechains are subagent traffic; meta lines are harness
            // bookkeeping — neither is part of the conversation.
            if obj["isSidechain"] as? Bool == true { return true }
            if obj["isMeta"] as? Bool == true { return true }
            guard let type = obj["type"] as? String,
                  let message = obj["message"] as? [String: Any] else { return true }
            switch type {
            case "user":
                if let text = claudeUserText(obj) {
                    if text.hasPrefix(handoffPrefix) {
                        append(.user, blocks: [.text(handoffNote)], into: &messages)
                    } else {
                        append(.user, blocks: userBlocks(text), into: &messages)
                    }
                }
            case "assistant":
                var blocks: [ChatMessage.Block] = []
                for block in contentBlocks(message) {
                    switch block["type"] as? String {
                    case "text":
                        if let text = block["text"] as? String,
                           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            blocks += splitMarkdown(text)
                        }
                    case "tool_use":
                        let name = block["name"] as? String ?? "tool"
                        blocks.append(.tool(
                            name: name,
                            detail: toolDetail(input: block["input"] as? [String: Any])
                        ))
                    default:
                        break // thinking et al.
                    }
                }
                if !blocks.isEmpty { append(.assistant, blocks: blocks, into: &messages) }
            default:
                break
            }
            return true
        }
        return messages
    }

    private static func codexTranscript(path: String) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        scanLines(path: path, maxBytes: .max) { obj in
            guard obj["type"] as? String == "response_item",
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "message",
                  let text = codexContentText(payload) else { return true }
            switch payload["role"] as? String {
            case "user":
                if let clean = cleanUserText(text) {
                    if clean.hasPrefix(handoffPrefix) {
                        append(.user, blocks: [.text(handoffNote)], into: &messages)
                    } else {
                        append(.user, blocks: userBlocks(clean), into: &messages)
                    }
                } else if text.contains("<INSTRUCTIONS>") {
                    // Codex's injected project context — a giant blob
                    // nobody rereads; stand a one-liner in for it.
                    append(.user, blocks: [.text(
                        "Brought Codex up to speed on the project."
                    )], into: &messages)
                }
            case "assistant":
                // Codex Desktop encodes tool traffic as marked-up text.
                if let chip = codexToolChip(text) {
                    append(.assistant, blocks: [chip], into: &messages)
                } else if !text.hasPrefix("[external_agent_tool_result]") {
                    append(.assistant, blocks: splitMarkdown(text), into: &messages)
                }
            default:
                break
            }
            return true
        }
        return messages
    }

    /// `[external_agent_tool_call: Bash]\ndescription: …` → a tool chip.
    private static func codexToolChip(_ text: String) -> ChatMessage.Block? {
        guard text.hasPrefix("[external_agent_tool_call:") else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let name = lines.first.map {
            $0.dropFirst("[external_agent_tool_call:".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ]"))
        } ?? "tool"
        var detail = ""
        if lines.count > 1, !lines[1].hasPrefix("[/") {
            detail = String(lines[1])
            for prefix in ["description: ", "file: ", "command: "]
            where detail.hasPrefix(prefix) {
                detail = String(detail.dropFirst(prefix.count))
            }
        }
        return .tool(name: String(name), detail: condense(detail))
    }

    // MARK: - Cross-harness transplants

    /// Neither CLI can read the other's store, but both provably resume
    /// session files written by someone else (verified for `claude
    /// --resume` with a synthetic file; ChatGPT Desktop's import proves
    /// the codex side). So "continue this chat with the other model"
    /// transpiles the transcript into a fresh native session for the
    /// target CLI and returns its id for a real resume — full history,
    /// original file untouched.
    static func exportToClaude(_ messages: [ChatMessage], projectPath: String) -> String? {
        guard !messages.isEmpty else { return nil }
        let sid = UUID().uuidString.lowercased()
        let dir = claudeProjectDir(for: projectPath)
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        let stamp = isoNow()
        var lines: [String] = []
        var parent: Any = NSNull()
        for message in messages {
            let text = flatten(message)
            guard !text.isEmpty else { continue }
            let user = message.role == .user
            let uuid = UUID().uuidString.lowercased()
            let obj: [String: Any] = [
                "type": user ? "user" : "assistant",
                "message": [
                    "role": user ? "user" : "assistant",
                    // Claude writes user turns as bare strings and
                    // assistant turns as content blocks; mirror that.
                    "content": user ? text : [["type": "text", "text": text]],
                ] as [String: Any],
                "uuid": uuid, "parentUuid": parent, "sessionId": sid,
                "timestamp": stamp, "cwd": projectPath, "version": "2.1.0",
                "isSidechain": false, "userType": "external", "gitBranch": "",
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  let line = String(data: data, encoding: .utf8) else { continue }
            lines.append(line)
            parent = uuid
        }
        guard !lines.isEmpty else { return nil }
        let body = lines.joined(separator: "\n") + "\n"
        guard (try? body.write(
            toFile: dir + "/" + sid + ".jsonl", atomically: true, encoding: .utf8
        )) != nil else { return nil }
        return sid
    }

    /// `originator: "Houston"` hides the file from the chat index (used
    /// for cross-harness transplants, whose original stays listed); pass
    /// anything else to create a file that IS listed (duplicates).
    static func exportToCodex(
        _ messages: [ChatMessage], projectPath: String, originator: String = "Houston"
    ) -> String? {
        guard !messages.isEmpty else { return nil }
        let sid = UUID().uuidString.lowercased()
        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let dir = String(
            format: "%@/.codex/sessions/%04d/%02d/%02d",
            home, parts.year ?? 2026, parts.month ?? 1, parts.day ?? 1
        )
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        let stamp = isoNow()
        let meta: [String: Any] = [
            "timestamp": stamp,
            "type": "session_meta",
            "payload": [
                "session_id": sid, "id": sid, "timestamp": stamp,
                "cwd": projectPath, "originator": originator,
                "cli_version": "", "source": "houston",
                "model_provider": "openai",
            ] as [String: Any],
        ]
        var lines: [Any] = [meta]
        for message in messages {
            let text = flatten(message)
            guard !text.isEmpty else { continue }
            let user = message.role == .user
            lines.append([
                "timestamp": stamp,
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": user ? "user" : "assistant",
                    "content": [[
                        "type": user ? "input_text" : "output_text",
                        "text": text,
                    ]],
                ] as [String: Any],
            ] as [String: Any])
        }
        let encoded = lines.compactMap { obj -> String? in
            guard let data = try? JSONSerialization.data(withJSONObject: obj)
            else { return nil }
            return String(data: data, encoding: .utf8)
        }
        guard encoded.count == lines.count else { return nil }
        let file = "rollout-" + fileStamp(now) + "-" + sid + ".jsonl"
        let body = encoded.joined(separator: "\n") + "\n"
        guard (try? body.write(
            toFile: dir + "/" + file, atomically: true, encoding: .utf8
        )) != nil else { return nil }
        return sid
    }

    /// The rollout file a codex export just wrote, found by its id.
    static func codexRolloutPath(id: String) -> String? {
        let root = home + "/.codex/sessions"
        guard let walker = FileManager.default.enumerator(atPath: root) else { return nil }
        for case let rel as String in walker where rel.hasSuffix("-\(id).jsonl") {
            return root + "/" + rel
        }
        return nil
    }

    /// Character budget under which a transplant copies the chat whole —
    /// roughly 10k tokens; beyond it the head is compressed into a
    /// mission-log-style handoff so the target model doesn't pay for (or
    /// overflow on) the full history.
    static let fullTransplantMax = 40_000
    /// The verbatim tail kept alongside a handoff brief — the in-flight
    /// exchange the next message actually engages with.
    private static let transplantTailBudget = 12_000

    static func flatSize(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + flatten($1).count }
    }

    /// Splits a long transcript for transplanting: the recent tail stays
    /// verbatim, the head comes back as chunk strings sized for the
    /// on-device summarizer (only the most recent ~35k chars of head —
    /// mission-log philosophy: distant history lives in the repo).
    static func splitForHandoff(
        _ messages: [ChatMessage]
    ) -> (headChunks: [String], tail: [ChatMessage]) {
        var tail: [ChatMessage] = []
        var budget = transplantTailBudget
        var index = messages.count - 1
        while index >= 0, budget > 0 {
            let size = flatten(messages[index]).count
            tail.insert(messages[index], at: 0)
            budget -= size
            index -= 1
        }
        var chunks: [String] = []
        var current = ""
        for message in messages[0...max(index, 0)] where index >= 0 {
            let role = message.role == .user ? "User" : "Assistant"
            current += role + ": " + flatten(message) + "\n\n"
            if current.count > 2_800 {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return (Array(chunks.suffix(12)), tail)
    }

    /// The transplant's opening message: the brief, framed so the target
    /// model treats it as authoritative context. The prefix is the render
    /// marker — transcripts collapse the whole brief to `handoffNote`, so
    /// the chat view shows a one-liner while the model keeps the detail.
    static let handoffPrefix = "[Handoff] This conversation continues"
    static let handoffNote = "Brought the model up to speed on the earlier conversation."
    static func handoffMessage(brief: String, from harness: ChatHarness) -> ChatMessage {
        ChatMessage(role: .user, blocks: [.text(
            handoffPrefix + " from a session run under "
            + harness.rawValue + ". Brief of the earlier work:\n\n" + brief
            + "\n\nPick up from this handoff and the recent messages that follow."
        )])
    }

    /// A message's blocks as one plain-text body for the target harness.
    /// Capsule chips round-trip as their marker line, so a transplanted
    /// chat re-renders (and re-references) them intact.
    static func flatten(_ message: ChatMessage) -> String {
        message.blocks.compactMap { block -> String? in
            switch block {
            case let .text(text): text
            case let .code(code, lang): "```" + (lang ?? "") + "\n" + code + "\n```"
            case let .tool(name, detail):
                detail.isEmpty ? "[\(name)]" : "[\(name): \(detail)]"
            case let .capsule(title, file):
                "[Capsule \"\(title)\" @ \(file)] An earlier chat from this "
                    + "project, attached as context — read or grep its "
                    + "transcript for specifics when needed."
            case let .fragment(title, text):
                "[Fragment \"\(title)\"]\n" + text + "\n[/Fragment]"
            }
        }.joined(separator: "\n\n")
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    // MARK: - Shared parsing helpers

    /// Runs `handle` per parsed JSONL line until it returns false or the
    /// byte budget runs out.
    private static func scanLines(
        path: String, maxBytes: Int, handle: ([String: Any]) -> Bool
    ) {
        guard let stream = InputStream(fileAtPath: path) else { return }
        stream.open()
        defer { stream.close() }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 262_144)
        var consumed = 0
        while stream.hasBytesAvailable, consumed < maxBytes {
            let n = stream.read(&chunk, maxLength: chunk.count)
            guard n > 0 else { break }
            consumed += n
            buffer.append(chunk, count: n)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.isEmpty,
                      let obj = (try? JSONSerialization.jsonObject(with: line))
                        as? [String: Any] else { continue }
                if !handle(obj) { return }
            }
        }
        if !buffer.isEmpty,
           let obj = (try? JSONSerialization.jsonObject(with: buffer)) as? [String: Any] {
            _ = handle(obj)
        }
    }

    private static func contentBlocks(_ message: [String: Any]) -> [[String: Any]] {
        if let blocks = message["content"] as? [[String: Any]] { return blocks }
        if let text = message["content"] as? String { return [["type": "text", "text": text]] }
        return []
    }

    /// The user's actual words from a Claude transcript line — nil for tool
    /// results, hook noise, and command bookkeeping.
    private static func claudeUserText(_ obj: [String: Any]) -> String? {
        guard obj["type"] as? String == "user",
              obj["isSidechain"] as? Bool != true,
              obj["isMeta"] as? Bool != true,
              let message = obj["message"] as? [String: Any] else { return nil }
        var parts: [String] = []
        for block in contentBlocks(message) where block["type"] as? String == "text" {
            if let text = block["text"] as? String { parts.append(text) }
        }
        guard !parts.isEmpty else { return nil }
        return cleanUserText(parts.joined(separator: "\n"))
    }

    /// Strips harness wrappers out of user text: system reminders and
    /// command bookkeeping become either nothing or the bare "/command".
    private static func cleanUserText(_ raw: String) -> String? {
        var text = raw
        for tag in ["system-reminder", "environment_context", "user_instructions",
                    "local-command-stdout", "command-message", "command-args",
                    "local-command-caveat", "bash-stdout", "bash-stderr",
                    // Background-task completions are injected as
                    // user-role messages — harness plumbing, not the user.
                    "task-notification",
                    // Codex injects its project context (AGENTS.md, plugin
                    // roster) into the first recorded user turn.
                    "INSTRUCTIONS", "recommended_plugins"] {
            text = stripTag(tag, from: text)
        }
        // Interrupt bookkeeping ("[Request interrupted by user]" and
        // variants) is likewise injected, never typed.
        text = text.replacingOccurrences(
            of: #"(?m)^\[Request interrupted[^\]]*\]$"#,
            with: "",
            options: .regularExpression
        )
        // Codex titles its injected AGENTS.md blob with a heading OUTSIDE
        // the <INSTRUCTIONS> tags — stripping the tags orphans it.
        text = text.replacingOccurrences(
            of: #"(?m)^#{0,6}\s*AGENTS\.md instructions for [^\n]*$"#,
            with: "",
            options: .regularExpression
        )
        // Bash-mode input renders as a shell line — and reads as one to
        // `isCommandLike`, so it never names a chat.
        text = text.replacingOccurrences(
            of: #"<bash-input>([\s\S]*?)</bash-input>"#,
            with: "\\$ $1",
            options: .regularExpression
        )
        if let range = text.range(
            of: #"<command-name>([^<]*)</command-name>"#, options: .regularExpression
        ) {
            let name = text[range]
                .replacingOccurrences(of: "<command-name>", with: "")
                .replacingOccurrences(of: "</command-name>", with: "")
            text = text.replacingCharacters(in: range, with: name)
        }
        if text.hasPrefix("Caveat: The messages below were generated") { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stripTag(_ tag: String, from text: String) -> String {
        text.replacingOccurrences(
            of: "<\(tag)>[\\s\\S]*?</\(tag)>",
            with: "",
            options: .regularExpression
        )
    }

    /// A one-line summary of a tool call's input for the chip.
    private static func toolDetail(input: [String: Any]?) -> String {
        guard let input else { return "" }
        for key in ["description", "file_path", "command", "pattern", "query",
                    "prompt", "url", "path"] {
            if let value = input[key] as? String, !value.isEmpty {
                return condense(value)
            }
        }
        return ""
    }

    /// First line, whitespace-collapsed, capped for list rows and chips.
    static func condense(_ text: String) -> String {
        let line = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? text
        let flat = line.trimmingCharacters(in: .whitespaces)
        return flat.count > 160 ? String(flat.prefix(160)) + "…" : flat
    }

    /// Matches a capsule attachment's marker line — see
    /// `ChatCapsule.referenceText` for the writer.
    private static let capsuleMarker = try? NSRegularExpression(
        pattern: #"^\[Capsule "([^"]*)" @ ([^\]]+)\]"#
    )

    /// Matches a quoted fragment's opening marker — see
    /// `CapsuleMessageRow.referenceText` for the writer. The body runs
    /// until the `[/Fragment]` line; only the label renders.
    private static let fragmentMarker = try? NSRegularExpression(
        pattern: #"^\[Fragment "([^"]*)""#
    )

    /// A user message's blocks, with capsule attachment markers pulled
    /// out as chips and quoted fragments collapsed to chips (the chip
    /// leads; the marker's body is for the model, not the reader).
    static func userBlocks(_ text: String) -> [ChatMessage.Block] {
        let hasCapsule = text.contains("[Capsule \"")
        let hasFragment = text.contains("[Fragment \"")
        guard hasCapsule || hasFragment else {
            return splitMarkdown(text)
        }
        var chips: [ChatMessage.Block] = []
        var rest: [String] = []
        var fragmentTitle: String?
        var fragmentBody: [String] = []
        for line in text.components(separatedBy: "\n") {
            if let title = fragmentTitle {
                if line.trimmingCharacters(in: .whitespaces) == "[/Fragment]" {
                    chips.append(.fragment(
                        title: title,
                        text: fragmentBody.joined(separator: "\n")
                    ))
                    fragmentTitle = nil
                    fragmentBody = []
                } else {
                    fragmentBody.append(line)
                }
                continue
            }
            let range = NSRange(line.startIndex..., in: line)
            if let capsuleMarker,
               let match = capsuleMarker.firstMatch(in: line, range: range),
               let titleRange = Range(match.range(at: 1), in: line),
               let fileRange = Range(match.range(at: 2), in: line) {
                chips.append(.capsule(
                    title: String(line[titleRange]),
                    file: String(line[fileRange])
                ))
            } else if let fragmentMarker,
                      let match = fragmentMarker.firstMatch(in: line, range: range),
                      let titleRange = Range(match.range(at: 1), in: line) {
                fragmentTitle = String(line[titleRange])
            } else {
                rest.append(line)
            }
        }
        // An unterminated fragment (shouldn't happen) still chips.
        if let title = fragmentTitle {
            chips.append(.fragment(
                title: title, text: fragmentBody.joined(separator: "\n")
            ))
        }
        return chips + splitMarkdown(rest.joined(separator: "\n"))
    }

    /// Splits fenced code out of markdown so the view can render it as a
    /// monospace card instead of mangled inline text.
    private static func splitMarkdown(_ text: String) -> [ChatMessage.Block] {
        var blocks: [ChatMessage.Block] = []
        var inCode = false
        var fenceLang: String?
        var current: [String] = []
        func flush() {
            let joined = current.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                blocks.append(inCode ? .code(joined, lang: fenceLang) : .text(joined))
            }
            current = []
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                inCode.toggle()
                let hint = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                fenceLang = inCode && !hint.isEmpty ? hint : nil
            } else {
                current.append(line)
            }
        }
        flush()
        return blocks
    }

    /// Consecutive same-role lines merge into one message so a multi-part
    /// assistant turn reads as a single reply.
    private static func append(
        _ role: ChatMessage.Role,
        blocks: [ChatMessage.Block],
        into messages: inout [ChatMessage]
    ) {
        guard !blocks.isEmpty else { return }
        if let last = messages.indices.last, messages[last].role == role {
            messages[last].blocks += blocks
        } else {
            // Ordinal ids: transcripts only ever grow at the tail, so an
            // existing message keeps its id across reloads.
            messages.append(ChatMessage(
                id: "m\(messages.count)", role: role, blocks: blocks
            ))
        }
    }
}

/// Pinned/archived flags per chat file, persisted to
/// `Application Support/Houston/chat-meta.json`. Renames live in
/// `ChatTitler`'s title overlay, not here.
@MainActor
final class ChatMetaStore: ObservableObject {
    static let shared = ChatMetaStore()

    @Published private(set) var pinned: Set<String> = []
    @Published private(set) var archived: Set<String> = []
    /// Chats forked off another chat: file → the file it branched from.
    /// Drives the branch glyph in the sidebar.
    @Published private(set) var branches: [String: String] = [:]

    private struct Blob: Codable {
        var pinned: [String] = []
        var archived: [String] = []
        var branches: [String: String]?
    }

    private static var fileURL: URL {
        let dir = ("~/Library/Application Support/Houston" as String).expandingTildePath
        return URL(fileURLWithPath: dir).appendingPathComponent("chat-meta.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let blob = try? JSONDecoder().decode(Blob.self, from: data) {
            pinned = Set(blob.pinned)
            archived = Set(blob.archived)
            branches = blob.branches ?? [:]
        }
    }

    private func save() {
        let blob = Blob(
            pinned: Array(pinned), archived: Array(archived),
            branches: branches
        )
        guard let data = try? JSONEncoder().encode(blob) else { return }
        try? FileManager.default.createDirectory(
            at: Self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    func togglePin(_ file: String) {
        if pinned.contains(file) { pinned.remove(file) } else { pinned.insert(file) }
        save()
    }

    func toggleArchive(_ file: String) {
        if archived.contains(file) {
            archived.remove(file)
        } else {
            archived.insert(file)
            pinned.remove(file)
        }
        save()
    }

    func markBranch(_ file: String, of parent: String) {
        branches[file] = parent
        save()
    }

    /// A deleted chat's flags go with it.
    func forget(_ file: String) {
        guard pinned.contains(file) || archived.contains(file)
            || branches[file] != nil else { return }
        pinned.remove(file)
        archived.remove(file)
        branches.removeValue(forKey: file)
        save()
    }

    /// Sidebar order: pinned first, archived gone.
    func arrangeSidebar(_ refs: [ChatSessionRef]) -> [ChatSessionRef] {
        let visible = refs.filter { !archived.contains($0.filePath) }
        return visible.filter { pinned.contains($0.filePath) }
            + visible.filter { !pinned.contains($0.filePath) }
    }

    /// Browser order: pinned first, archived last (dimmed there, and the
    /// only place they can be unarchived from).
    func arrangeBrowser(_ refs: [ChatSessionRef]) -> [ChatSessionRef] {
        refs.filter { pinned.contains($0.filePath) }
            + refs.filter { !pinned.contains($0.filePath) && !archived.contains($0.filePath) }
            + refs.filter { archived.contains($0.filePath) && !pinned.contains($0.filePath) }
    }
}

/// Per-project chat index for the sidebar: sessions load off-main and are
/// cached, so the entries builder can read them synchronously.
@MainActor
final class ChatIndexStore: ObservableObject {
    static let shared = ChatIndexStore()

    @Published private(set) var chats: [String: [ChatSessionRef]] = [:]
    private var inFlight: Set<String> = []
    private var loadedAt: [String: Date] = [:]

    /// One serial pass over every project — the sidebar shows chats under
    /// all headers, and a sequential walk avoids a thundering herd on the
    /// first (uncached) Codex index.
    func refreshAll(_ paths: [String]) {
        Task.detached(priority: .utility) {
            for path in paths {
                let skip = await MainActor.run { () -> Bool in
                    let store = ChatIndexStore.shared
                    if store.inFlight.contains(path) { return true }
                    if let at = store.loadedAt[path],
                       Date().timeIntervalSince(at) < 30 { return true }
                    store.inFlight.insert(path)
                    return false
                }
                if skip { continue }
                let refs = ChatArchive.sessions(for: path)
                await MainActor.run {
                    let store = ChatIndexStore.shared
                    store.inFlight.remove(path)
                    store.loadedAt[path] = Date()
                    if store.chats[path] != refs { store.chats[path] = refs }
                    // The sidebar shows the first few — name the weak ones.
                    for ref in refs.prefix(8) { ChatTitler.shared.ensure(ref) }
                }
            }
        }
    }

    /// Indexing reads thousands of rollout heads on first run — refreshes
    /// are throttled per project unless forced.
    func refresh(_ projectPath: String, force: Bool = false) {
        guard !inFlight.contains(projectPath) else { return }
        if !force, let at = loadedAt[projectPath],
           Date().timeIntervalSince(at) < 30 { return }
        inFlight.insert(projectPath)
        Task.detached(priority: .utility) {
            let refs = ChatArchive.sessions(for: projectPath)
            await MainActor.run {
                let store = ChatIndexStore.shared
                store.inFlight.remove(projectPath)
                store.loadedAt[projectPath] = Date()
                if store.chats[projectPath] != refs {
                    store.chats[projectPath] = refs
                }
                for ref in refs.prefix(8) { ChatTitler.shared.ensure(ref) }
            }
        }
    }
}
