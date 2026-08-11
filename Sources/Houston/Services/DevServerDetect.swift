import Foundation

/// Mirrors electron/dev-servers.js. Lists every LISTEN socket in the 3000-9999
/// range that isn't a known macOS system service, then enriches each row with
/// the owning process's cwd and (if it lives under projectsDir) a project name.
enum DevServerDetect {

    private static let minPort = 3000
    private static let maxPort = 9999

    /// macOS background services that happen to bind dev-range ports
    /// (AirPlay Receiver on 5000/7000, Continuity, etc.).
    private static let systemCommands: Set<String> = [
        "ControlCenter",
        "mDNSResponder",
        "rapportd",
        "sharingd",
        "AirPlayXPCH",
        "remoted",
        "identityservicesd",
    ]

    private struct ListenRow {
        let command: String
        let pid: Int32
        let port: Int
    }

    // MARK: - public

    static func snapshot(projectsDirs: [String]) -> [DevServer] {
        let rows = listenSockets()
        var seen = Set<String>()
        var cwdCache: [Int32: String?] = [:]
        var servers: [DevServer] = []

        for r in rows {
            let key = "\(r.pid):\(r.port)"
            if seen.contains(key) { continue }
            seen.insert(key)

            let cwd: String?
            if let cached = cwdCache[r.pid] {
                cwd = cached
            } else {
                let resolved = ProcScan.cwd(ofPid: r.pid)
                cwdCache[r.pid] = resolved
                cwd = resolved
            }

            servers.append(
                DevServer(
                    pid: r.pid,
                    port: r.port,
                    command: r.command,
                    cwd: cwd,
                    project: projectFromCwd(cwd, appsDirs: projectsDirs),
                    url: "http://localhost:\(r.port)"
                )
            )
        }

        // Project-matched first, then by port asc; ties by pid for stability.
        servers.sort { a, b in
            let ap = a.project == nil ? 1 : 0
            let bp = b.project == nil ? 1 : 0
            if ap != bp { return ap < bp }
            if a.port != b.port { return a.port < b.port }
            return a.pid < b.pid
        }
        return servers
    }

    // MARK: - lsof parsing

    private static func listenSockets() -> [ListenRow] {
        guard let out = ProcScan.run(
            "/usr/sbin/lsof",
            ["-iTCP", "-sTCP:LISTEN", "-P", "-n", "+c", "0"]
        ) else { return [] }

        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return [] }

        var rows: [ListenRow] = []
        for raw in lines.dropFirst() {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            // COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME ... (LISTEN)
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if parts.count < 9 { continue }
            let command = parts[0]
            guard let pid = Int32(parts[1]) else { continue }

            // NAME starts at index 8 — but the row may have a trailing "(LISTEN)".
            // Find the first token from idx 8 onward ending in ":<digits>".
            var port: Int?
            for i in 8..<parts.count {
                if let r = parts[i].range(of: ":([0-9]+)$", options: .regularExpression),
                   let p = Int(parts[i][r].dropFirst()) {
                    port = p
                    break
                }
            }
            guard let port else { continue }
            if port < minPort || port > maxPort { continue }
            if systemCommands.contains(command) { continue }

            rows.append(ListenRow(command: command, pid: pid, port: port))
        }
        return rows
    }

    /// The project name is the first path component under whichever
    /// configured folder contains `cwd`.
    private static func projectFromCwd(_ cwd: String?, appsDirs: [String]) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        for appsDir in appsDirs {
            let prefix = appsDir + "/"
            guard cwd.hasPrefix(prefix) else { continue }
            let rel = String(cwd.dropFirst(prefix.count))
            if let first = rel.split(separator: "/").first, !first.isEmpty {
                return String(first)
            }
        }
        return nil
    }
}
