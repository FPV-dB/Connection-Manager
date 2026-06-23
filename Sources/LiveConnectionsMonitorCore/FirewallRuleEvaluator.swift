import Darwin
import Foundation

public enum FirewallDecision: String, Sendable {
    case allowed
    case blocked
}

public struct FirewallRuleEvaluation: Equatable, Sendable {
    public let rule: String
    public let source: FirewallRuleSource
    public let matched: Bool
    public let reason: String
}

public struct FirewallEvaluation: Equatable, Sendable {
    public let address: String
    public let evaluations: [FirewallRuleEvaluation]
    public let decision: FirewallDecision
    public let matchingRule: String?
}

public struct FirewallRuleEvaluator: Sendable {
    public init() {}

    public func evaluate(address rawAddress: String, blockRules: [BlockRule], allowlist: [AllowlistEntry]) -> FirewallEvaluation {
        let address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        var evaluations: [FirewallRuleEvaluation] = []

        for entry in allowlist where entry.isEnabled {
            let result = match(address: address, rule: entry.value)
            evaluations.append(FirewallRuleEvaluation(
                rule: entry.value,
                source: .allowlist,
                matched: result.matched,
                reason: result.reason
            ))
            if result.matched {
                return FirewallEvaluation(address: address, evaluations: evaluations, decision: .allowed, matchingRule: entry.value)
            }
        }

        for rule in blockRules where rule.isEnabled {
            let result = match(address: address, rule: rule.value)
            evaluations.append(FirewallRuleEvaluation(
                rule: rule.value,
                source: rule.source,
                matched: result.matched,
                reason: result.reason
            ))
            if result.matched {
                return FirewallEvaluation(address: address, evaluations: evaluations, decision: .blocked, matchingRule: rule.value)
            }
        }

        return FirewallEvaluation(address: address, evaluations: evaluations, decision: .allowed, matchingRule: nil)
    }

    private func match(address: String, rule rawRule: String) -> (matched: Bool, reason: String) {
        let rule = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate = ParsedAddress(address) else {
            return (false, "Connection address is not a valid IPv4 or IPv6 address.")
        }
        guard let network = ParsedNetwork(rule) else {
            return (false, "Rule is not a valid IP address or CIDR range.")
        }
        guard candidate.family == network.address.family else {
            return (false, "IP version differs from the rule.")
        }

        let matched = candidate.bytes.indices.allSatisfy { index in
            let bitsBeforeByte = index * 8
            let remaining = network.prefixLength - bitsBeforeByte
            if remaining <= 0 { return true }
            let significantBits = min(8, remaining)
            let mask = UInt8(truncatingIfNeeded: 0xff << (8 - significantBits))
            return candidate.bytes[index] & mask == network.address.bytes[index] & mask
        }
        if matched {
            return (true, rule.contains("/") ? "Address is inside CIDR \(rule)." : "Address exactly equals \(rule).")
        }
        return (false, rule.contains("/") ? "Address is outside CIDR \(rule)." : "Address differs from \(rule).")
    }
}

private struct ParsedNetwork {
    let address: ParsedAddress
    let prefixLength: Int

    init?(_ value: String) {
        let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let address = ParsedAddress(String(parts[0])) else { return nil }
        let maximum = address.family == AF_INET ? 32 : 128
        let prefix = parts.count == 2 ? Int(parts[1]) : maximum
        guard let prefix, (0...maximum).contains(prefix) else { return nil }
        self.address = address
        self.prefixLength = prefix
    }
}

private struct ParsedAddress {
    let family: Int32
    let bytes: [UInt8]

    init?(_ value: String) {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, value, &ipv4) == 1 {
            self.family = AF_INET
            self.bytes = withUnsafeBytes(of: ipv4.s_addr) { Array($0) }
            return
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, value, &ipv6) == 1 {
            self.family = AF_INET6
            self.bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            return
        }
        return nil
    }
}
