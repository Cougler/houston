import Foundation

/// Identifies the running top-level `claude` CLI processes and resolves each
/// one's active JSONL transcript to compute live context size + percentage.
enum ProcessDetect {

    private static let defaultContextWindow = 200_000
    private static let opus1mContextWindow = 1_000_000
    private static let sessionMatchToleranceMs: Int64 = 30_000
    /// Transcripts grow to tens of MB and are re-read on every poll, but usage
    /// lives in the last assistant message — so read only this much of the
    /// tail, falling back to the whole file in the rare miss.
    private static let usageTailBytes = 262_144

    private static let homeDir: String = NSHomeDirectory()
    private static var projectsRoot: String { homeDir + "/.claude/projects" }
    private static var sessionsRoot: String { homeDir + "/.claude/sessions" }

    // MARK: - public

    /// All top-level (non-child) claude sessions, sorted hottest first.
    static func snapshot() -> [ActiveSession] {
        let procs = ProcScan.table(withStartTimes: true)
        let claudes = topLevelClaudes(in: procs)

        var sessions: [ActiveSession] = []
        sessions.reserveCapacity(claudes.count)

        for p in claudes {
            let sessionFile = readSessionFile(pid: p.pid)
            guard let cwd = sessionFile?.cwd ?? ProcScan.cwd(ofPid: p.pid) else { continue }
            let startMs = p.lstart.flatMap(ProcScan.startMs(fromLstart:))
            let jsonl = findJsonl(sessionFile: sessionFile, cwd: cwd, startMs: startMs)
            let summary = jsonl.map { readUsage(jsonlPath: $0) } ?? UsageSummary()
            let contextSize = summary.input + summary.cacheRead + summary.cacheCreate
                + summary.output

            sessions.append(
                ActiveSession(
                    id: p.pid,
                    cwd: cwd,
                    contextSize: contextSize,
                    contextWindow: contextWindow(for: summary.model),
                    lastActivityMs: summary.timestampMs
                        ?? jsonl.flatMap { fileMtimeMs(path: $0) },
                    isHoustonOwned: ProcScan.isDescendant(
                        p.pid, of: ProcessInfo.processInfo.processIdentifier, in: procs
                    )
                )
            )
        }

        return sessions.sorted { a, b in
            (a.lastActivityMs ?? 0) > (b.lastActivityMs ?? 0)
        }
    }

    // MARK: - claude processes

    private static func isClaudeCmd(_ cmd: String) -> Bool {
        let exe = cmd.split(separator: " ").first.map(String.init) ?? cmd
        return (exe as NSString).lastPathComponent == "claude"
    }

    private static func topLevelClaudes(in procs: [Int32: ProcScan.Proc]) -> [ProcScan.Proc] {
        procs.values.filter { p in
            guard isClaudeCmd(p.command) else { return false }
            guard let parent = procs[p.ppid] else { return true }
            return !isClaudeCmd(parent.command)
        }
    }

    // MARK: - session files

    private struct SessionFile {
        let sessionId: String
        let cwd: String
    }

    private static func readSessionFile(pid: Int32) -> SessionFile? {
        let path = "\(sessionsRoot)/\(pid).json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = obj["sessionId"] as? String,
              let cwd = obj["cwd"] as? String else {
            return nil
        }
        return SessionFile(sessionId: sessionId, cwd: cwd)
    }

    // MARK: - JSONL matching

    private struct JsonlCandidate {
        let path: String
        let sessionId: String
        let mtimeMs: Int64
        let birthMs: Int64?
    }

    private static func findJsonl(
        sessionFile: SessionFile?,
        cwd: String,
        startMs: Int64?
    ) -> String? {
        let dirName = cwd.replacingOccurrences(of: "/", with: "-")
        let dirPath = "\(projectsRoot)/\(dirName)"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dirPath) else { return nil }

        var candidates: [JsonlCandidate] = []
        for entry in entries where entry.hasSuffix(".jsonl") {
            let full = (dirPath as NSString).appendingPathComponent(entry)
            guard let mtime = fileMtimeMs(path: full) else { continue }
            candidates.append(
                JsonlCandidate(
                    path: full,
                    sessionId: (entry as NSString).deletingPathExtension,
                    mtimeMs: mtime,
                    birthMs: fileBirthMs(path: full)
                )
            )
        }
        guard let latest = candidates.max(by: { $0.mtimeMs < $1.mtimeMs }) else { return nil }

        // Preferred: latest-mtime JSONL that's been touched during this PID's lifetime.
        if let startMs, latest.mtimeMs >= startMs { return latest.path }

        // Fallback: session-file's sessionId points at a known JSONL.
        if let sessionFile,
           let match = candidates.first(where: { $0.sessionId == sessionFile.sessionId }) {
            return match.path
        }

        // Last resort: birth-time correlation with the PID's start.
        guard let startMs else { return nil }
        var bestPath: String?
        var bestDelta: Int64 = .max
        for c in candidates {
            guard let birth = c.birthMs else { continue }
            let delta = abs(birth - startMs)
            if delta < bestDelta {
                bestDelta = delta
                bestPath = c.path
            }
        }
        return bestDelta <= sessionMatchToleranceMs ? bestPath : nil
    }

    // MARK: - usage parsing

    private struct UsageSummary {
        var input: Int = 0
        var cacheRead: Int = 0
        var cacheCreate: Int = 0
        var output: Int = 0
        var model: String? = nil
        var timestampMs: Int64? = nil
    }

    private static func readUsage(jsonlPath: String) -> UsageSummary {
        guard let tail = tail(ofFile: jsonlPath, maxBytes: usageTailBytes) else {
            return UsageSummary()
        }
        var lines = tail.data.split(separator: UInt8(ascii: "\n"))
        // A mid-file start lands inside a line; the fragment can't parse.
        if !tail.isWholeFile, !lines.isEmpty { lines.removeFirst() }
        if let found = latestUsage(in: lines) { return found }

        // Tail carried no usage (giant trailing tool result, etc.) — pay for
        // the full read rather than report 0 context.
        if !tail.isWholeFile,
           let all = try? Data(contentsOf: URL(fileURLWithPath: jsonlPath)) {
            return latestUsage(in: all.split(separator: UInt8(ascii: "\n"))) ?? UsageSummary()
        }
        return UsageSummary()
    }

    /// Scans bottom-up — usage almost always lives in the last assistant
    /// message, so this usually parses one line and stops.
    private static func latestUsage(in lines: [Data]) -> UsageSummary? {
        for line in lines.reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else {
                continue
            }
            var s = UsageSummary()
            s.input = (usage["input_tokens"] as? Int) ?? 0
            s.cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
            s.cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0
            s.output = (usage["output_tokens"] as? Int) ?? 0
            s.model = message["model"] as? String
            if let ts = obj["timestamp"] as? String {
                s.timestampMs = parseISO8601(ts)
            }
            return s
        }
        return nil
    }

    private static func tail(
        ofFile path: String,
        maxBytes: Int
    ) -> (data: Data, isWholeFile: Bool)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let isWholeFile = size <= UInt64(maxBytes)
        do {
            try handle.seek(toOffset: isWholeFile ? 0 : size - UInt64(maxBytes))
            guard let data = try handle.readToEnd() else { return nil }
            return (data, isWholeFile)
        } catch {
            return nil
        }
    }

    // ISO8601DateFormatter is documented thread-safe but (unlike DateFormatter)
    // not marked Sendable in the SDK; `unsafe` only silences that check.
    private nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()
    private nonisolated(unsafe) static let isoPlain: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()

    private static func parseISO8601(_ s: String) -> Int64? {
        guard let d = isoFractional.date(from: s) ?? isoPlain.date(from: s) else { return nil }
        return Int64(d.timeIntervalSince1970 * 1000)
    }

    // MARK: - context window

    /// The current model families all ship a 1M context window; the 200k models
    /// are the older generations plus Haiku. The transcript only records the
    /// bare model id (e.g. "claude-opus-5") — the harness's "[1m]" suffix is NOT
    /// persisted in the JSONL or the session file, so we can't key off it.
    ///
    /// This is deliberately an allowlist of the *small*-window models with 1M as
    /// the default, so a newly released model reads correctly without a code
    /// change. The 200k set is effectively closed: everything current except
    /// Haiku is 1M.
    private static let smallWindowPatterns = [
        "haiku",                    // Haiku 4.5 and earlier — 200k
        "opus-4-[0-5]", "opus-3",   // Opus 4.5 and earlier
        "sonnet-4-[0-5]", "sonnet-3",
        "claude-2",
    ]

    private static func contextWindow(for model: String?) -> Int {
        guard let model else { return defaultContextWindow }
        for p in smallWindowPatterns {
            if model.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil {
                return defaultContextWindow
            }
        }
        return opus1mContextWindow
    }

    // MARK: - file attributes

    private static func fileMtimeMs(path: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let m = attrs[FileAttributeKey.modificationDate] as? Date else { return nil }
        return Int64(m.timeIntervalSince1970 * 1000)
    }

    private static func fileBirthMs(path: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let b = attrs[FileAttributeKey.creationDate] as? Date else { return nil }
        return Int64(b.timeIntervalSince1970 * 1000)
    }
}
