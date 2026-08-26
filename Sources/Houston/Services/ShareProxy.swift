import Foundation
import Network

/// Tiers 1 and 2 of shareable dev URLs. A reverse proxy listens on port 80
/// (falling back to 14080 when 80 is taken) and routes each HTTP connection
/// by its Host header — `hierarch.localhost` → the detected dev port for the
/// project "hierarch". Browsers resolve `*.localhost` to loopback by standard
/// (RFC 6761), so tier 1 needs no DNS at all; tier 2 registers
/// `<project>.local` over mDNS (`MDNSAdvertiser`) so phones on the same
/// Wi-Fi reach the proxy, which forwards to the dev server's loopback —
/// meaning the dev server itself never has to bind beyond localhost.
///
/// The proxy reads only up to the end of the first request's headers, then
/// splices bytes both ways untouched — WebSockets, HMR, and SSE work for
/// free. Tier 3 (public share links through a relay) is not built yet; the
/// share UI reserves its slot.
@MainActor
final class ShareProxyStore: ObservableObject {
    /// The listener is up and accepting.
    @Published private(set) var running = false
    /// The port actually bound — 80, or the fallback when 80 was busy.
    @Published private(set) var port: Int?
    /// Mirror of `!settings.sharingDisabled`.
    @Published private(set) var enabled = !HoustonSettings.read().sharingDisabled

    nonisolated static let defaultPort = 80
    /// Outside DevServerDetect's 3000–9999 scan range on purpose — Houston's
    /// own proxy must never show up as somebody's dev server.
    nonisolated static let fallbackPort = 14080

    private let router = ProxyRouter()
    private var listener: NWListener?
    private let mdns = MDNSAdvertiser()
    private let queue = DispatchQueue(label: "houston.shareproxy.listen")

    func start() {
        guard enabled, listener == nil else { return }
        listen(on: Self.defaultPort)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
        port = nil
        mdns.update(labels: [])
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        var s = HoustonSettings.read()
        s.sharingDisabled = !on
        HoustonSettings.write(s)
        on ? start() : stop()
    }

    /// Rebuilds the Host-header routing table from the current dev-server
    /// snapshot. Servers are already sorted project-first / port-ascending,
    /// so a project running several listeners shares under its lowest port.
    func update(servers: [DevServer]) {
        var routes: [String: Int] = [:]
        for server in servers {
            let label = Self.label(for: server.project ?? server.command)
            if routes[label] == nil { routes[label] = server.port }
        }
        router.set(routes)
        if running { mdns.update(labels: Set(routes.keys)) }
    }

    // MARK: - URLs for the share UI

    /// `""` on port 80, `":14080"` on the fallback.
    var portSuffix: String {
        guard let port, port != Self.defaultPort else { return "" }
        return ":\(port)"
    }

    func localURL(forProjectNamed name: String) -> String {
        "http://\(Self.label(for: name)).localhost\(portSuffix)"
    }

    func lanURL(forProjectNamed name: String) -> String {
        "http://\(Self.label(for: name)).local\(portSuffix)"
    }

    /// Project name → DNS label: lowercase, runs of anything outside
    /// [a-z0-9] collapse to a single hyphen, no leading/trailing hyphens.
    nonisolated static func label(for name: String) -> String {
        var out = ""
        var pendingHyphen = false
        for ch in name.lowercased() where ch.isASCII {
            if ch.isLetter || ch.isNumber {
                if pendingHyphen, !out.isEmpty { out.append("-") }
                pendingHyphen = false
                out.append(ch)
            } else {
                pendingHyphen = true
            }
        }
        return out.isEmpty ? "app" : out
    }

    // MARK: - listener

    private func listen(on portNumber: Int) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(portNumber)) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params, on: nwPort) else {
            if portNumber == Self.defaultPort { listen(on: Self.fallbackPort) }
            return
        }
        self.listener = listener
        let router = self.router
        listener.newConnectionHandler = { conn in
            ProxyWire.handle(conn, router: router, advertisedPort: portNumber)
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.running = true
                    self.port = portNumber
                    self.mdns.update(labels: Set(self.router.all().keys))
                case .failed:
                    // Port 80 taken (or vanished) — retry once on the high
                    // fallback; a second failure leaves sharing off.
                    listener.cancel()
                    self.listener = nil
                    self.running = false
                    self.port = nil
                    if portNumber == Self.defaultPort {
                        self.listen(on: Self.fallbackPort)
                    }
                default:
                    break
                }
            }
        }
        listener.start(queue: queue)
    }
}

/// Host-label → dev-port table, read from connection queues while the main
/// actor rewrites it on every dev-server tick.
final class ProxyRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: Int] = [:]

    func set(_ new: [String: Int]) {
        lock.lock()
        routes = new
        lock.unlock()
    }

    func port(for label: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return routes[label]
    }

    func all() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return routes
    }
}

/// The per-connection plumbing, deliberately outside the @MainActor store —
/// everything here runs on per-connection dispatch queues.
private enum ProxyWire {

    static func handle(_ client: NWConnection, router: ProxyRouter, advertisedPort: Int) {
        let queue = DispatchQueue(label: "houston.shareproxy.conn")
        client.start(queue: queue)
        readHeader(client, buffered: Data(), router: router, advertisedPort: advertisedPort, queue: queue)
    }

    /// Accumulates until the first request's header block ends, then routes.
    private static func readHeader(
        _ client: NWConnection, buffered: Data, router: ProxyRouter,
        advertisedPort: Int, queue: DispatchQueue
    ) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { data, _, complete, error in
            guard error == nil else { client.cancel(); return }
            var buf = buffered
            if let data { buf.append(data) }
            if let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) {
                route(
                    client, request: buf, header: buf[..<headerEnd.upperBound],
                    router: router, advertisedPort: advertisedPort, queue: queue
                )
            } else if complete || buf.count > 128 * 1024 {
                client.cancel()
            } else {
                readHeader(client, buffered: buf, router: router, advertisedPort: advertisedPort, queue: queue)
            }
        }
    }

    private static func route(
        _ client: NWConnection, request: Data, header: Data.SubSequence,
        router: ProxyRouter, advertisedPort: Int, queue: DispatchQueue
    ) {
        let label = hostLabel(inHeader: String(decoding: header, as: UTF8.self))
        guard let label, let port = router.port(for: label),
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            respond(client, status: "404 Not Found",
                    html: listingPage(router: router, advertisedPort: advertisedPort, missing: label))
            return
        }

        // `localhost`, not 127.0.0.1 — node dev servers routinely bind only
        // the IPv6 loopback (same trap as the health probe).
        let backend = NWConnection(host: "localhost", port: nwPort, using: .tcp)
        backend.stateUpdateHandler = { state in
            switch state {
            case .ready:
                backend.stateUpdateHandler = nil
                backend.send(content: request, completion: .contentProcessed { sendError in
                    guard sendError == nil else { client.cancel(); backend.cancel(); return }
                    pump(from: client, to: backend)
                    pump(from: backend, to: client)
                })
            case .failed, .waiting:
                // .waiting is how connection-refused surfaces (and Network
                // would otherwise retry forever) — the server died between
                // the lsof scan and this request.
                backend.cancel()
                respond(client, status: "502 Bad Gateway",
                        html: offlinePage(label: label, port: port))
            default:
                break
            }
        }
        backend.start(queue: queue)
    }

    /// One direction of the splice. Bytes are forwarded untouched — that's
    /// what keeps WebSockets/HMR/SSE working with zero protocol knowledge.
    private static func pump(from a: NWConnection, to b: NWConnection) {
        a.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, complete, error in
            if let data, !data.isEmpty {
                b.send(content: data, completion: .contentProcessed { sendError in
                    guard sendError == nil else { a.cancel(); b.cancel(); return }
                    if complete { a.cancel(); b.cancel() } else { pump(from: a, to: b) }
                })
            } else if complete || error != nil {
                a.cancel()
                b.cancel()
            } else {
                pump(from: a, to: b)
            }
        }
    }

    /// The label routed by the request's Host header: `hierarch.localhost`
    /// and `hierarch.local` (any port suffix) both give "hierarch". A bare
    /// `localhost` / IP host returns nil — that lands on the listing page.
    private static func hostLabel(inHeader header: String) -> String? {
        for line in header.split(separator: "\r\n").dropFirst() {
            guard line.lowercased().hasPrefix("host:") else { continue }
            var host = line.dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased()
            if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
            for suffix in [".localhost", ".local"] where host.hasSuffix(suffix) {
                let label = String(host.dropLast(suffix.count))
                return label.isEmpty ? nil : label
            }
            return nil
        }
        return nil
    }

    // MARK: - fallback pages

    private static func respond(_ client: NWConnection, status: String, html: String) {
        let body = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        client.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            client.cancel()
        })
    }

    private static let pageStyle = """
        <style>body{font-family:-apple-system,sans-serif;max-width:34em;margin:15vh auto;\
        padding:0 1.5em;color:#333}@media(prefers-color-scheme:dark){body{background:#1e1e1e;\
        color:#e8e8e8}a{color:#9cf}}h1{font-size:1.3em}li{margin:.4em 0}</style>
        """

    private static func listingPage(router: ProxyRouter, advertisedPort: Int, missing: String?) -> String {
        let suffix = advertisedPort == ShareProxyStore.defaultPort ? "" : ":\(advertisedPort)"
        let items = router.all().sorted { $0.key < $1.key }.map { label, port in
            "<li><a href=\"http://\(label).localhost\(suffix)/\">\(label).localhost\(suffix)</a>"
                + " <small>&rarr; port \(port)</small></li>"
        }
        let title = missing.map { "No dev server named &ldquo;\($0)&rdquo; is running" }
            ?? "Houston dev servers"
        let list = items.isEmpty ? "<p>No dev servers are running right now.</p>"
            : "<ul>\(items.joined())</ul>"
        return "<!doctype html><title>Houston</title>\(pageStyle)<h1>\(title)</h1>\(list)"
    }

    private static func offlinePage(label: String, port: Int) -> String {
        "<!doctype html><title>Houston</title>\(pageStyle)"
            + "<h1>\(label) is not answering</h1>"
            + "<p>Houston routed this to port \(port), but nothing accepted the "
            + "connection &mdash; the dev server has probably just stopped.</p>"
    }
}
