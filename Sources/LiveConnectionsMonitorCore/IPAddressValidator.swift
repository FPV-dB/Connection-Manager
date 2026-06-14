import Foundation

public enum IPValidationSeverity: Sendable {
    case valid
    case warning(String)
    case refused(String)
}

public struct IPAddressValidator: Sendable {
    public init() {}

    public func validate(_ rawValue: String) -> IPValidationSeverity {
        let value = normalize(rawValue)
        guard !value.isEmpty else { return .refused("Empty address") }
        let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
        let address = parts[0]
        if parts.count == 2, Int(parts[1]) == nil {
            return .refused("Invalid CIDR prefix")
        }
        if isIPv4(address) {
            return validateIPv4(address, cidr: parts.count == 2 ? Int(parts[1]) : nil)
        }
        if isLikelyIPv6(address) {
            return validateIPv6(address, cidr: parts.count == 2 ? Int(parts[1]) : nil)
        }
        return .refused("Invalid IP or CIDR")
    }

    public func normalize(_ rawValue: String) -> String {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func isPrivateOrReserved(_ rawValue: String) -> Bool {
        if case .warning = validate(rawValue) { return true }
        return false
    }

    private func validateIPv4(_ address: String, cidr: Int?) -> IPValidationSeverity {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return .refused("Invalid IPv4 address")
        }
        if let cidr, !(0...32).contains(cidr) { return .refused("Invalid IPv4 CIDR prefix") }
        if octets[0] == 127 { return .refused("Loopback addresses cannot be blocked") }
        if octets == [0, 0, 0, 0] { return .refused("Unspecified addresses cannot be blocked") }
        if octets == [255, 255, 255, 255] { return .refused("Broadcast addresses cannot be blocked") }
        if (224...239).contains(octets[0]) { return .refused("Multicast addresses cannot be blocked") }
        if octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 192 && octets[1] == 168) {
            return .warning("Private LAN range")
        }
        return .valid
    }

    private func validateIPv6(_ address: String, cidr: Int?) -> IPValidationSeverity {
        if let cidr, !(0...128).contains(cidr) { return .refused("Invalid IPv6 CIDR prefix") }
        let lower = address.lowercased()
        if lower == "::1" { return .refused("Loopback addresses cannot be blocked") }
        if lower == "::" { return .refused("Unspecified addresses cannot be blocked") }
        if lower.hasPrefix("ff") { return .refused("Multicast addresses cannot be blocked") }
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return .warning("Private LAN range") }
        return .valid
    }

    private func isIPv4(_ value: String) -> Bool {
        value.split(separator: ".").count == 4
    }

    private func isLikelyIPv6(_ value: String) -> Bool {
        value.contains(":")
    }
}
