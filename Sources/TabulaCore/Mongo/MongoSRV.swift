import dnssd
import Foundation

/// Resolves a `mongodb+srv` seed list with the system resolver and checks the result, as the MongoDB SRV
/// specification requires: every target must be in the seed host's parent domain. Without that check a spoofed
/// DNS answer could send the connection to any host holding a valid certificate for its own name.
enum MongoSRV {
    struct Target: Equatable, Sendable {
        var host: String
        var port: Int
    }

    /// The members behind `seed` (e.g. cluster0.abcde.mongodb.net), in DNS order.
    static func resolve(_ seed: String, timeout: Double) async throws -> [Target] {
        let host = normalized(seed)
        guard host.split(separator: ".").count >= Defaults.Mongo.srvMinimumLabels else {
            throw DatabaseError("“\(seed)” isn't a DNS seed list name; it needs at least \(Defaults.Mongo.srvMinimumLabels) parts, like cluster0.example.net.")
        }
        let targets = try await Task.detached { try lookup("_mongodb._tcp." + host, timeout: timeout) }.value
        guard !targets.isEmpty else { throw DatabaseError("DNS has no MongoDB servers for \(host).") }
        try validate(targets, seed: host)
        return targets
    }

    /// Every target must end with the seed's parent domain (the seed minus its first label).
    static func validate(_ targets: [Target], seed: String) throws {
        let parent = normalized(seed).split(separator: ".").dropFirst().joined(separator: ".")
        for target in targets {
            let name = normalized(target.host)
            guard name.hasSuffix("." + parent), name != parent else {
                throw DatabaseError("DNS for \(seed) points to \(target.host), outside \(parent). Tabula refuses it, since that "
                    + "could be a spoofed answer.")
            }
        }
    }

    private static func normalized(_ name: String) -> String {
        var name = name.trimmingCharacters(in: .whitespaces).lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        return name
    }

    // MARK: DNS

    /// Collects the answers the callback receives.
    private final class Answers {
        var targets: [Target] = []
        var error: DNSServiceErrorType = DNSServiceErrorType(kDNSServiceErr_NoError)
        var done = false
    }

    /// A blocking SRV query through the system resolver (honors the Mac's DNS settings and VPNs).
    private static func lookup(_ name: String, timeout: Double) throws -> [Target] {
        let answers = Answers()
        var reference: DNSServiceRef?
        let context = Unmanaged.passUnretained(answers).toOpaque()
        let status = DNSServiceQueryRecord(&reference, 0, 0, name, UInt16(kDNSServiceType_SRV), UInt16(kDNSServiceClass_IN), { _, flags, _, error, _, _, _, length, data, _, context in
            guard let context else { return }
            let answers = Unmanaged<Answers>.fromOpaque(context).takeUnretainedValue()
            if error != kDNSServiceErr_NoError {
                answers.error = error
                answers.done = true
                return
            }
            if let data, let target = MongoSRV.parse(UnsafeRawBufferPointer(start: data, count: Int(length))) {
                answers.targets.append(target)
            }
            if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 { answers.done = true }
        }, context)
        guard status == kDNSServiceErr_NoError, let reference else {
            throw DatabaseError("DNS lookup for \(name) couldn't start (error \(status)).")
        }
        defer { DNSServiceRefDeallocate(reference) }

        let socket = DNSServiceRefSockFD(reference)
        let deadline = Date().addingTimeInterval(timeout)
        while !answers.done {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw DatabaseError("DNS lookup for \(name) timed out.") }
            var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(remaining * 1000))
            guard ready >= 0 else { throw DatabaseError("DNS lookup for \(name) failed.") }
            if ready > 0 {
                let processed = DNSServiceProcessResult(reference)
                guard processed == kDNSServiceErr_NoError else { throw DatabaseError("DNS lookup for \(name) failed (error \(processed)).") }
            }
        }
        if answers.error == kDNSServiceErr_NoSuchRecord || answers.error == kDNSServiceErr_NoSuchName { return [] }
        guard answers.error == kDNSServiceErr_NoError else { throw DatabaseError("DNS lookup for \(name) failed (error \(answers.error)).") }
        return answers.targets
    }

    /// SRV data: priority (2), weight (2), port (2), then the target as length-prefixed labels.
    static func parse(_ data: UnsafeRawBufferPointer) -> Target? {
        let bytes = Array(data.bindMemory(to: UInt8.self))
        let header = 6
        guard bytes.count > header else { return nil }
        let port = Int(bytes[4]) << 8 | Int(bytes[5])
        var labels: [String] = []
        var index = header
        while index < bytes.count {
            let length = Int(bytes[index])
            index += 1
            if length == 0 { break }
            guard index + length <= bytes.count else { return nil }
            labels.append(String(decoding: bytes[index..<index + length], as: UTF8.self))
            index += length
        }
        guard !labels.isEmpty, port > 0 else { return nil }
        return Target(host: labels.joined(separator: "."), port: port)
    }
}
