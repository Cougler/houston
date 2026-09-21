import Foundation

/// Low-level process inspection shared by `ProcessDetect`, `AgentDetect` and
/// `DevServerDetect` — one implementation of the `ps` snapshot, the pid→cwd
/// lookup, and the parent-chain walk instead of three.
///
/// Everything here shells out and blocks; call it off the main thread.
enum ProcScan {

    struct Proc {
        let pid: Int32
        let ppid: Int32
        /// Raw `lstart` tokens, e.g. "Tue May 11 14:47:32 2026". Kept as a
        /// string so only the handful of rows that need a timestamp pay for
        /// date parsing — see `startMs(fromLstart:)`.
        let lstart: String?
        let command: String
    }

    /// `ps -axo pid=,ppid=[,lstart=],command=` → keyed by pid.
    static func table(withStartTimes: Bool) -> [Int32: Proc] {
        let columns = withStartTimes
            ? "pid=,ppid=,lstart=,command="
            : "pid=,ppid=,command="
        guard let out = run("/bin/ps", ["-axo", columns]) else { return [:] }

        // lstart is exactly 5 whitespace-separated tokens, so the line splits
        // positionally — no regex needed.
        let commandIndex = withStartTimes ? 7 : 2
        var map: [Int32: Proc] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(
                separator: " ", maxSplits: commandIndex, omittingEmptySubsequences: true
            )
            guard parts.count == commandIndex + 1,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]) else { continue }
            map[pid] = Proc(
                pid: pid,
                ppid: ppid,
                lstart: withStartTimes ? parts[2...6].joined(separator: " ") : nil,
                command: String(parts[commandIndex])
            )
        }
        return map
    }

    // Built once — it used to be allocated per `ps` line, every poll.
    private static let lstartFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        fmt.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return fmt
    }()

    static func startMs(fromLstart lstart: String) -> Int64? {
        guard let d = lstartFormatter.date(from: lstart) else { return nil }
        return Int64(d.timeIntervalSince1970 * 1000)
    }

    /// Walks the parent chain looking for `ancestor`. A pane's tree is
    /// `Houston → login → bash → agent`, so ancestry can't be decided from the
    /// immediate parent. Bounded so a cycle in a malformed snapshot can't spin.
    static func isDescendant(_ pid: Int32, of ancestor: Int32, in procs: [Int32: Proc]) -> Bool {
        var current = pid
        for _ in 0..<32 {
            guard let proc = procs[current] else { return false }
            if proc.ppid == ancestor { return true }
            if proc.ppid <= 1 { return false }
            current = proc.ppid
        }
        return false
    }

    static func cwd(ofPid pid: Int32) -> String? {
        cwds(ofPids: [pid])[pid]
    }

    /// One `lsof` spawn for the whole batch — the agent scan used to fork
    /// it once per candidate pid, every 2s tick. `-p` takes a
    /// comma-separated list; `-Fpn` interleaves `p<pid>` and `n<path>`
    /// records so each cwd attributes to its pid.
    static func cwds(ofPids pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        guard let out = run(
            "/usr/sbin/lsof", ["-a", "-p", list, "-d", "cwd", "-Fpn"]
        ) else { return [:] }
        var result: [Int32: String] = [:]
        var current: Int32?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p") {
                current = Int32(line.dropFirst())
            } else if line.hasPrefix("n"), let pid = current {
                result[pid] = String(line.dropFirst())
            }
        }
        return result
    }

    /// Runs a tool and captures stdout. Synchronous.
    static func run(_ executable: String, _ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
