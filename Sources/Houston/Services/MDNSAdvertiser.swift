import Foundation
import dnssd

/// Registers `<project>.local` hostnames over mDNS so phones and other
/// machines on the Wi-Fi resolve them to this Mac — tier 2 of shareable dev
/// URLs. This is *hostname* registration (an A record via
/// `DNSServiceRegisterRecord`), not service advertisement: `NWListener`'s
/// Bonjour support only publishes `_http._tcp` service entries, which don't
/// make a typed-in hostname resolve. Equivalent to `dns-sd -P` without the
/// child process to babysit.
@MainActor
final class MDNSAdvertiser {

    private var service: DNSServiceRef?
    private var source: DispatchSourceRead?
    private var records: [String: DNSRecordRef] = [:]
    /// The IPv4 the records currently point at (network byte order); when
    /// the Mac hops networks the records are dropped and re-registered.
    private var currentAddr: in_addr_t?

    /// dns_sd.h values — the anonymous C enums import awkwardly.
    private static let flagUnique: DNSServiceFlags = 0x20  // kDNSServiceFlagsUnique
    private static let typeA: UInt16 = 1                   // kDNSServiceType_A
    private static let classIN: UInt16 = 1                 // kDNSServiceClass_IN

    /// Reconciles the advertised set: registers new labels, removes stale
    /// ones, re-registers everything when the primary IP changed. An empty
    /// set tears the daemon connection down entirely.
    func update(labels: Set<String>) {
        guard !labels.isEmpty else { teardown(); return }
        guard let addr = Self.primaryIPv4() else { teardown(); return }

        if addr.s_addr != currentAddr { teardown() }
        currentAddr = addr.s_addr

        if service == nil { connect() }
        guard let service else { return }

        for (label, record) in records where !labels.contains(label) {
            DNSServiceRemoveRecord(service, record, 0)
            records[label] = nil
        }
        for label in labels where records[label] == nil {
            var record: DNSRecordRef?
            var rdata = addr
            let err = withUnsafeBytes(of: &rdata) { raw in
                DNSServiceRegisterRecord(
                    service, &record, Self.flagUnique,
                    0,  // kDNSServiceInterfaceIndexAny
                    "\(label).local.", Self.typeA, Self.classIN,
                    UInt16(raw.count), raw.baseAddress,
                    120,  // TTL seconds
                    { _, _, _, _, _ in }, nil
                )
            }
            if err == kDNSServiceErr_NoError, let record {
                records[label] = record
            }
        }
    }

    private func connect() {
        var ref: DNSServiceRef?
        guard DNSServiceCreateConnection(&ref) == kDNSServiceErr_NoError, let ref else { return }
        service = ref
        // Registration confirmations/conflicts arrive on the daemon socket;
        // they must be drained or the connection wedges.
        let src = DispatchSource.makeReadSource(
            fileDescriptor: DNSServiceRefSockFD(ref), queue: .main
        )
        src.setEventHandler { [weak self] in
            guard let self, let service = self.service else { return }
            if DNSServiceProcessResult(service) != kDNSServiceErr_NoError {
                self.teardown()
            }
        }
        src.resume()
        source = src
    }

    private func teardown() {
        source?.cancel()
        source = nil
        if let service { DNSServiceRefDeallocate(service) }
        service = nil
        records = [:]
        currentAddr = nil
    }

    /// The Wi-Fi/Ethernet IPv4 to advertise: en0 when it's up, else the
    /// first running non-loopback interface.
    private static func primaryIPv4() -> in_addr? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }

        var fallback: in_addr?
        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let sa = entry.pointee.ifa_addr,
                  sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0 else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr
            }
            if String(cString: entry.pointee.ifa_name) == "en0" { return addr }
            if fallback == nil { fallback = addr }
        }
        return fallback
    }
}
