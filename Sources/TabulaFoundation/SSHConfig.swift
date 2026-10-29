import Foundation

/// An SSH server that database traffic goes through, for servers reachable only from it (a bastion).
/// Keys come from ssh-agent or an identity file; no SSH password or passphrase is ever stored.
public struct SSHConfig: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var user: String
    /// A private key file; nil uses ssh-agent and the default keys.
    public var identityFile: String?

    public init(host: String = "", port: Int = 22, user: String = "", identityFile: String? = nil) {
        self.host = host
        self.port = port
        self.user = user
        self.identityFile = identityFile
    }

    /// What's wrong with these settings, or nil when they can be used. Checked again before every connection, since
    /// saved files can be edited by hand.
    public var problem: String? {
        if host.isEmpty { return "Enter the SSH host." }
        if !Self.isSafeName(host) { return "The SSH host isn't valid." }
        if !(1...65535).contains(port) { return "The SSH port must be between 1 and 65535." }
        if user.isEmpty { return "Enter the SSH user." }
        if !Self.isSafeName(user) { return "The SSH user isn't valid." }
        if let identityFile {
            let path = (identityFile as NSString).expandingTildeInPath
            if path.isEmpty || path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                return "The SSH key path isn't valid."
            }
            if !FileManager.default.isReadableFile(atPath: path) { return "The SSH key file can't be read." }
        }
        return nil
    }

    /// Host names, IP addresses and user names, with nothing ssh could read as an option, a second host or part
    /// of a forward specification.
    package static func isSafeName(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, first != "-" else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return text.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }
}
