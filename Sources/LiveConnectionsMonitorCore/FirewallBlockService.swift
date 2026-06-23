import Foundation

public enum BlockSafety: Equatable, Sendable {
    case allowed
    case needsGatewayOverride(String)
    case blocked(String)
}

public actor FirewallBlockService {
    // /etc/pf.conf invokes com.apple/*, so this child anchor participates in filtering
    // without rewriting the system PF configuration.
    public static let anchorName = "com.apple/com.connectionmanager.blocked"
    public static let legacyAnchorName = ["com", "radio" + "ecology", "blocked"].joined(separator: ".")
    public static let legacyAnchorPath = "/etc/pf.anchors/" + legacyAnchorName
    public static let anchorPath = "/etc/pf.anchors/com.connectionmanager.blocked"

    private let runner: CommandRunner

    public init(runner: CommandRunner = CommandRunner()) {
        self.runner = runner
    }

    public func loadBlockedIPs() async -> [String] {
        guard let result = try? await runner.run("/bin/cat", arguments: [Self.anchorPath]), result.exitCode == 0 else {
            return []
        }
        return parseBlockedIPs(fromAnchorText: result.output)
    }

    public func safety(for ip: String) async -> BlockSafety {
        let cleaned = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return .blocked("No remote IP is available for this connection.") }
        if ["127.0.0.1", "::1", "localhost", "0.0.0.0"].contains(cleaned.lowercased()) {
            return .blocked("Loopback and wildcard addresses cannot be blocked.")
        }
        if cleaned == "255.255.255.255" || cleaned.hasSuffix(".255") {
            return .blocked("Broadcast addresses cannot be blocked.")
        }
        if isMulticast(cleaned) {
            return .blocked("Multicast addresses cannot be blocked.")
        }
        if let gateway = await defaultGateway(), gateway == cleaned {
            return .needsGatewayOverride(gateway)
        }
        return .allowed
    }

    public func block(ip: String, existing: Set<String>) async throws -> [String] {
        var next = existing
        next.insert(ip)
        try await apply(blockedIPs: next)
        return Array(next).sorted()
    }

    public func unblock(ip: String, existing: Set<String>) async throws -> [String] {
        var next = existing
        next.remove(ip)
        try await apply(blockedIPs: next)
        return Array(next).sorted()
    }

    public func apply(blockedIPs: Set<String>) async throws {
        let rules = anchorText(for: blockedIPs)
        try await apply(anchorText: rules, settings: FirewallSettings())
    }

    public func apply(anchorText rules: String, settings: FirewallSettings) async throws {
        let backupCommand = settings.backupAnchorBeforeRewrite
            ? "if [ -f \"\(settings.anchorPath)\" ]; then /bin/cp \"\(settings.anchorPath)\" \"\(settings.anchorPath).bak.$(/bin/date +%Y%m%d%H%M%S)\"; fi"
            : ":"
        let script = """
        set -e
        tmp="$(/usr/bin/mktemp)"
        /bin/cat > "$tmp" <<'EOF'
        \(rules)
        EOF
        \(backupCommand)
        /usr/bin/install -m 0644 "$tmp" "\(settings.anchorPath)"
        /bin/rm -f "$tmp"
        /sbin/pfctl -a "\(settings.anchorName)" -f "\(settings.anchorPath)"
        /sbin/pfctl -e >/dev/null 2>&1 || true
        """
        try await runner.runAppleScriptWithAdministratorPrivileges(shellScript: script)
    }

    private func anchorText(for blockedIPs: Set<String>) -> String {
        var lines = [
            "# Managed by Live Connections Monitor.",
            "# Dedicated PF anchor: \(Self.anchorName)",
            "# Do not place unrelated rules in this file."
        ]
        for ip in blockedIPs.sorted() {
            lines.append("block drop out quick to \(ip)")
            lines.append("block drop in quick from \(ip)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func parseBlockedIPs(fromAnchorText text: String) -> [String] {
        var ips = Set<String>()
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            let parts = line.split(separator: " ").map(String.init)
            if let toIndex = parts.firstIndex(of: "to"), parts.indices.contains(parts.index(after: toIndex)) {
                ips.insert(parts[parts.index(after: toIndex)])
            }
            if let fromIndex = parts.firstIndex(of: "from"), parts.indices.contains(parts.index(after: fromIndex)) {
                ips.insert(parts[parts.index(after: fromIndex)])
            }
        }
        return Array(ips).sorted()
    }

    private func defaultGateway() async -> String? {
        guard let result = try? await runner.run("/sbin/route", arguments: ["-n", "get", "default"]), result.exitCode == 0 else {
            return nil
        }
        for line in result.output.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("gateway:") {
                return trimmed.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func isMulticast(_ ip: String) -> Bool {
        if ip.lowercased().hasPrefix("ff") { return true }
        let octets = ip.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, let first = octets.first else { return false }
        return (224...239).contains(first)
    }
}
