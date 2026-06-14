import Foundation

public struct FirewallRuleGenerator: Sendable {
    public init() {}

    public func rules(for blockRules: [BlockRule], allowlist: [AllowlistEntry], settings: FirewallSettings) -> String {
        let allowed = Set(allowlist.filter(\.isEnabled).map { $0.value })
        var lines = [
            "# Managed by Firewall Dashboard.",
            "# Dedicated PF anchor: \(settings.anchorName)",
            "# Do not place unrelated rules in this file.",
            ""
        ]
        for group in FirewallRuleGroup.allCases where group != .trustedAllowlist {
            let groupRules = blockRules.filter { $0.group == group && $0.isEnabled && !allowed.contains($0.value) }
            guard !groupRules.isEmpty else { continue }
            lines.append("# \(group.rawValue)")
            for rule in groupRules.sorted(by: { $0.value < $1.value }) {
                switch rule.direction {
                case .inbound:
                    lines.append("block drop in quick from \(rule.value)")
                case .outbound:
                    lines.append("block drop out quick to \(rule.value)")
                case .both:
                    lines.append("block drop in quick from \(rule.value)")
                    lines.append("block drop out quick to \(rule.value)")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
