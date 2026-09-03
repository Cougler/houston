import Foundation
import Network

/// Tier 3 of shareable dev URLs: public `https://<name>.gohouston.live`
/// links through Houston's relay VPS.
///
/// The tunnel model is deliberately mux-free, mirroring the relay's:
/// Houston parks a few idle outbound TLS connections per shared project
/// (authenticated by the user's Pro token in an HTTP `Upgrade:
/// houston-tunnel` handshake). Each incoming public request consumes one —
/// the relay writes the raw HTTP request down it, Houston splices it onto
/// a fresh connection to the local dev port, and opens a replacement.
/// WebSockets/HMR/SSE work for free because after the first request the
/// two sockets are just joined byte streams.
///
/// The relay decides everything else server-side: the stable space-themed
/// subdomain (returned in the handshake response), the splash page, and
/// the PIN gate (the current PIN rides on every handshake, so changing it
/// re-keys the relay's cookie and locks old viewers out).
@MainActor
final class RelayTunnelStore: ObservableObject {
    /// One tunnel manager for the whole app — a second instance would park
    /// its own duplicate relay connections. Shared by the window and the
    /// menubar popover.
    static let shared = RelayTunnelStore()

    enum ProjectState: Equatable {
        case connecting
        case online(url: String)
        case offline          // enabled, but no dev server running
    }

    /// Per project label. Absent = web share off for that project.
    @Published private(set) var states: [String: ProjectState] = [:]
    /// The relay rejected the token — surfaced in the UI, retried only
    /// after the token changes.
    @Published private(set) var tokenRejected = false
    /// Labels whose dev server shares its port with another project's
    /// (value = the other project). Tunnels splice by port, so two servers
    /// on one port are indistinguishable — sharing is refused for both
    /// until one moves (measured: localhost:3000 and *:3000 can coexist,
    /// and the nondis link served Hierarch's app).
    @Published private(set) var portConflicts: [String: String] = [:]

    nonisolated static let relayHost = "gohouston.live"

    private var settings = HoustonSettings.read()
    /// label → local dev port, from the dev-server snapshot.
    private var ports: [String: Int] = [:]
    /// Idle (parked) connection count per label.
    private var idle: [String: Int] = [:]
    /// Reconnect backoff per label, reset on any successful handshake.
    private var backoff: [String: TimeInterval] = [:]
    private var generation = 0

    // Each viewer request consumes one parked connection (the relay is
    // per-request, one tunnel conn per asset fetch), so headroom matters:
    // a Vite dev page bursts dozens of module fetches on first load, and
    // big chunks hold their connection for the whole transfer.
    private let targetIdle = 10

    var token: String { settings.relayToken }

    // MARK: - intents

    func reloadSettings() {
        let fresh = HoustonSettings.read()
        let tokenChanged = fresh.relayToken != settings.relayToken
        settings = fresh
        if tokenChanged { tokenRejected = false }
        reconcile(bounce: tokenChanged)
    }

    func setToken(_ tok: String) {
        settings.relayToken = tok.trimmingCharacters(in: .whitespacesAndNewlines)
        HoustonSettings.write(settings)
        tokenRejected = false
        reconcile(bounce: true)
    }

    func setEnabled(_ label: String, _ on: Bool) {
        if on {
            if !settings.relayEnabled.contains(label) { settings.relayEnabled.append(label) }
        } else {
            settings.relayEnabled.removeAll { $0 == label }
        }
        HoustonSettings.write(settings)
        reconcile(bounce: false)
    }

    func isEnabled(_ label: String) -> Bool { settings.relayEnabled.contains(label) }

    func pin(for label: String) -> String { settings.relayPins[label] ?? "" }

    /// Sets (or clears, with "") the 4-digit viewer code. Takes effect by
    /// bouncing the project's connections — the new PIN rides the next
    /// handshake, and the relay re-keys its gate cookie.
    func setPin(_ label: String, _ pin: String) {
        let clean = pin.filter(\.isNumber)
        guard clean.isEmpty || clean.count == 4 else { return }
        settings.relayPins[label] = clean
        HoustonSettings.write(settings)
        reconcile(bounce: true, only: label)
    }

    /// Dev-server snapshot tick (same one that feeds ShareProxyStore).
    /// Reconciles every tick, not just on route changes — the 2s cadence is
    /// what heals the pool after relay restarts, network blips, or any
    /// idle-count drift.
    func update(servers: [DevServer]) {
        var routes: [String: Int] = [:]
        var portOwner: [Int: String] = [:]
        var conflicts: [String: String] = [:]
        for server in servers {
            let label = ShareProxyStore.label(for: server.project ?? server.command)
            if routes[label] == nil { routes[label] = server.port }
            if let owner = portOwner[server.port], owner != label {
                conflicts[label] = owner
                conflicts[owner] = label
            } else {
                portOwner[server.port] = label
            }
        }
        ports = routes
        if conflicts != portConflicts { portConflicts = conflicts }
        reconcile(bounce: false)
    }

    // MARK: - pool reconciliation

    /// Brings reality (parked connections) to intent (enabled projects with
    /// a running server and a token). `bounce` abandons existing
    /// connections first — used when the token or a PIN changed, since
    /// both only ride the handshake.
    private func reconcile(bounce: Bool, only: String? = nil) {
        if bounce {
            generation += 1
            if let only {
                idle[only] = 0
                if states[only] != nil { states[only] = .connecting }
            } else {
                idle = [:]
                for k in states.keys { states[k] = .connecting }
            }
        }

        let wanted = Set(settings.relayEnabled)
        for label in states.keys where !wanted.contains(label) {
            states[label] = nil
            idle[label] = nil
        }
        guard !settings.relayToken.isEmpty, !tokenRejected else { return }

        for label in wanted {
            guard portConflicts[label] == nil else {
                // Contested port: never open a tunnel that might serve
                // the wrong project. The UI explains; existing parked
                // conns for the label die off on their own.
                if states[label] != .offline { states[label] = .offline }
                idle[label] = nil
                continue
            }
            guard let port = ports[label] else {
                if states[label] != .offline { states[label] = .offline }
                idle[label] = nil
                continue
            }
            if states[label] == nil || states[label] == .offline {
                states[label] = .connecting
            }
            let parked = idle[label] ?? 0
            for _ in parked..<targetIdle {
                spawn(label: label, port: port)
            }
        }
    }

    private func spawn(label: String, port: Int) {
        idle[label, default: 0] += 1
        let gen = generation
        RelayWire.open(
            token: settings.relayToken,
            project: label,
            pin: settings.relayPins[label] ?? "",
            localPort: port
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event, label: label, gen: gen)
            }
        }
    }

    private func handle(_ event: RelayWire.Event, label: String, gen: Int) {
        // Events from a pre-bounce generation only decrement nothing —
        // their idle slots were already zeroed.
        let current = gen == generation
        switch event {
        case let .registered(url):
            guard current else { return }
            backoff[label] = nil
            if isEnabled(label), states[label] != .online(url: url) {
                states[label] = .online(url: url)
            }
        case .consumed:
            // A viewer took this connection — replace it.
            guard current else { return }
            idle[label, default: 1] -= 1
            if isEnabled(label), let port = ports[label] {
                spawn(label: label, port: port)
            }
        case .closed:
            guard current else { return }
            idle[label, default: 1] -= 1
            guard isEnabled(label), ports[label] != nil,
                  !settings.relayToken.isEmpty, !tokenRejected else { return }
            let delay = backoff[label] ?? 2
            backoff[label] = min(delay * 2, 15)
            let expected = generation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, self.generation == expected,
                      self.isEnabled(label), let port = self.ports[label] else { return }
                if (self.idle[label] ?? 0) < self.targetIdle {
                    self.spawn(label: label, port: port)
                }
            }
        case .authFailed:
            idle[label] = 0
            tokenRejected = true
            for k in states.keys { states[k] = .connecting }
        }
    }
}

/// One-shot latch shared across a connection's callback closures.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// The per-connection plumbing, off the main actor — everything here runs
/// on per-connection dispatch queues (same shape as ProxyWire).
private enum RelayWire {

    enum Event {
        /// Handshake accepted; the relay reports this project's public URL.
        case registered(url: String)
        /// A viewer's request arrived and this connection is now spliced —
        /// it no longer counts as idle.
        case consumed
        /// Closed or failed while idle (relay restart, NAT timeout,
        /// network change).
        case closed
        /// The relay rejected the token (403) — don't reconnect.
        case authFailed
    }

    static func open(
        token: String, project: String, pin: String, localPort: Int,
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        let queue = DispatchQueue(label: "houston.relay.conn")
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let params = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
        guard let port = NWEndpoint.Port(rawValue: 443) else { return }
        let conn = NWConnection(
            host: NWEndpoint.Host(RelayTunnelStore.relayHost), port: port, using: params
        )

        // Terminal events (consumed/closed/authFailed) fire once per
        // connection; `registered` passes through untouched.
        let once = Once()
        let finish: @Sendable (Event) -> Void = { event in
            if case .registered = event { onEvent(event); return }
            guard once.first() else { return }
            onEvent(event)
        }

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                conn.stateUpdateHandler = { st in
                    if case .failed = st { finish(.closed); conn.cancel() }
                }
                handshake(
                    conn, token: token, project: project, pin: pin,
                    localPort: localPort, queue: queue, finish: finish
                )
            case .failed, .waiting:
                // .waiting is how connection-refused surfaces; Network
                // would retry forever, so treat it as down.
                conn.cancel()
                finish(.closed)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private static func handshake(
        _ conn: NWConnection, token: String, project: String, pin: String,
        localPort: Int, queue: DispatchQueue, finish: @escaping @Sendable (Event) -> Void
    ) {
        let request = "GET /api/tunnel HTTP/1.1\r\n"
            + "Host: \(RelayTunnelStore.relayHost)\r\n"
            + "Upgrade: houston-tunnel\r\n"
            + "Connection: Upgrade\r\n"
            + "Authorization: Bearer \(token)\r\n"
            + "X-Houston-Project: \(project)\r\n"
            + "X-Houston-Pin: \(pin)\r\n\r\n"
        conn.send(content: Data(request.utf8), completion: .contentProcessed { error in
            guard error == nil else { conn.cancel(); finish(.closed); return }
            readResponse(conn, buffered: Data(), localPort: localPort, queue: queue, finish: finish)
        })
    }

    private static func readResponse(
        _ conn: NWConnection, buffered: Data, localPort: Int,
        queue: DispatchQueue, finish: @escaping @Sendable (Event) -> Void
    ) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
            guard error == nil else { conn.cancel(); finish(.closed); return }
            var buf = buffered
            if let data { buf.append(data) }
            guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || buf.count > 64 * 1024 {
                    conn.cancel()
                    finish(.closed)
                } else {
                    readResponse(conn, buffered: buf, localPort: localPort, queue: queue, finish: finish)
                }
                return
            }
            let header = String(decoding: buf[..<headerEnd.lowerBound], as: UTF8.self)
            let leftover = Data(buf[headerEnd.upperBound...])
            let lines = header.split(separator: "\r\n")
            let status = lines.first ?? ""
            guard status.contains(" 101 ") else {
                conn.cancel()
                finish(status.contains(" 403 ") ? .authFailed : .closed)
                return
            }
            if let urlLine = lines.first(where: { $0.lowercased().hasPrefix("x-houston-url:") }) {
                let url = urlLine.dropFirst("x-houston-url:".count)
                    .trimmingCharacters(in: .whitespaces)
                finish(.registered(url: url))
            }
            park(conn, leftover: leftover, localPort: localPort, queue: queue, finish: finish)
        }
    }

    /// Idle state: wait for the relay to write a viewer's request bytes.
    private static func park(
        _ conn: NWConnection, leftover: Data, localPort: Int,
        queue: DispatchQueue, finish: @escaping @Sendable (Event) -> Void
    ) {
        if !leftover.isEmpty {
            // The relay pipelined a request right behind the 101.
            splice(conn, firstBytes: leftover, localPort: localPort, queue: queue, finish: finish)
            return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, complete, error in
            if let data, !data.isEmpty {
                splice(conn, firstBytes: data, localPort: localPort, queue: queue, finish: finish)
            } else if complete || error != nil {
                conn.cancel()
                finish(.closed)
            } else {
                park(conn, leftover: Data(), localPort: localPort, queue: queue, finish: finish)
            }
        }
    }

    /// A viewer arrived: join this tunnel connection to a fresh local
    /// connection and pump bytes both ways until either side closes.
    private static func splice(
        _ tunnel: NWConnection, firstBytes: Data, localPort: Int,
        queue: DispatchQueue, finish: @escaping @Sendable (Event) -> Void
    ) {
        finish(.consumed)
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(localPort)) else {
            tunnel.cancel()
            return
        }
        // `localhost`, not 127.0.0.1 — node dev servers routinely bind only
        // the IPv6 loopback (same trap as the health probe).
        let backend = NWConnection(host: "localhost", port: nwPort, using: .tcp)
        backend.stateUpdateHandler = { state in
            switch state {
            case .ready:
                backend.stateUpdateHandler = nil
                backend.send(content: firstBytes, completion: .contentProcessed { error in
                    guard error == nil else { tunnel.cancel(); backend.cancel(); return }
                    pump(from: tunnel, to: backend)
                    pump(from: backend, to: tunnel)
                })
            case .failed, .waiting:
                // Dev server died between the snapshot and this request —
                // drop the tunnel; the relay serves its offline page next
                // time round.
                backend.cancel()
                tunnel.cancel()
            default:
                break
            }
        }
        backend.start(queue: queue)
    }

    private static func pump(from a: NWConnection, to b: NWConnection) {
        a.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, complete, error in
            if complete {
                // End of stream: forward any final bytes AND the close as
                // one ordered final message (data, then FIN/close_notify).
                // Cancelling right after a plain send drops whatever the
                // framework hasn't flushed yet — that was measured as
                // responses arriving up to a few KB short, which truncated
                // JS modules and black-paged Vite apps.
                b.send(
                    content: (data?.isEmpty == false) ? data : nil,
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { _ in a.cancel() }
                )
                // b is cancelled by the opposite pump when its own read
                // side ends (the peer closes in response to our FIN).
            } else if let data, !data.isEmpty {
                b.send(content: data, completion: .contentProcessed { sendError in
                    guard sendError == nil else { a.cancel(); b.cancel(); return }
                    pump(from: a, to: b)
                })
            } else if error != nil {
                a.cancel()
                b.cancel()
            } else {
                pump(from: a, to: b)
            }
        }
    }
}
