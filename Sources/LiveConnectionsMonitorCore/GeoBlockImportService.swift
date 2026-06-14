import Foundation

public struct GeoBlockImportResult: Sendable {
    public var importedRanges: Int
    public var skippedRanges: Int
    public var warnings: [String]
}

public struct GeoBlockImportService: Sendable {
    private let validator = IPAddressValidator()

    public init() {}

    public func importFile(url: URL, countryCode: String, countryName: String, sourceName: String, notes: String, database: FirewallDatabase) async throws -> GeoBlockImportResult {
        try await Task.detached(priority: .utility) {
            let text = try String(contentsOf: url, encoding: .utf8)
            var deduped: [String: (cidr: String, version: IPVersion, status: String)] = [:]
            var skipped = 0
            var warnings: [String] = [
                "Country-level blocking is broad and can break websites, CDNs, APIs, game servers, software updates, cloud services, VPNs, and legitimate users."
            ]

            for rawLine in text.split(whereSeparator: \.isNewline).map(String.init) {
                guard let candidate = candidate(from: rawLine) else { continue }
                switch validator.validate(candidate) {
                case .valid:
                    deduped[candidate] = (candidate, candidate.contains(":") ? .ipv6 : .ipv4, "valid")
                case let .warning(message):
                    warnings.append("\(candidate): \(message)")
                    deduped[candidate] = (candidate, candidate.contains(":") ? .ipv6 : .ipv4, message)
                case .refused:
                    skipped += 1
                }
            }

            try database.importGeoRanges(
                countryCode: countryCode,
                countryName: countryName,
                sourceName: sourceName.isEmpty ? url.lastPathComponent : sourceName,
                notes: notes,
                ranges: deduped.values.sorted { $0.cidr < $1.cidr },
                skipped: skipped
            )
            return GeoBlockImportResult(importedRanges: deduped.count, skippedRanges: skipped, warnings: warnings)
        }.value
    }

    private func candidate(from rawLine: String) -> String? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";") else { return nil }
        let firstColumn = trimmed.split(separator: ",", maxSplits: 1).first.map(String.init) ?? trimmed
        let withoutComment = firstColumn
            .split(separator: "#", maxSplits: 1).first.map(String.init) ?? firstColumn
        let candidate = withoutComment
            .split(separator: ";", maxSplits: 1).first.map(String.init) ?? withoutComment
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct GeoBlockSimulationService: Sendable {
    public init() {}

    public func simulate(countries: [GeoBlockCountry], ranges: [GeoBlockRange], connections: [NetworkConnection], allowlist: [AllowlistEntry]) -> GeoBlockSimulation {
        let enabledCodes = Set(countries.map(\.countryCode))
        let allowlisted = Set(allowlist.filter(\.isEnabled).map(\.value))
        let activeRanges = ranges.filter { enabledCodes.contains($0.countryCode) && $0.isEnabled && !allowlisted.contains($0.cidr) }
        let affected = connections.filter { connection in
            guard let remote = connection.remote?.address, !allowlisted.contains(remote) else { return false }
            return activeRanges.contains { contains(ip: remote, inCIDR: $0.cidr) }
        }
        let processCounts = Dictionary(grouping: affected.map(\.processName), by: { $0 }).mapValues(\.count)
        let ruleCount = countries.reduce(0) { total, country in
            let count = activeRanges.filter { $0.countryCode == country.countryCode }.count
            return total + (country.direction == .both ? count * 2 : count)
        }
        let previewBytes = activeRanges.reduce(0) { $0 + $1.cidr.count + 32 } * (countries.contains { $0.direction == .both } ? 2 : 1)
        return GeoBlockSimulation(
            selectedCountries: countries.map { "\($0.countryCode) \($0.countryName)" },
            cidrRangeCount: activeRanges.count,
            generatedRuleCount: ruleCount,
            estimatedAnchorBytes: previewBytes,
            affectedConnections: affected,
            affectedProcesses: processCounts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) },
            allowlistExemptions: allowlisted.count,
            warnings: [
                "Country-level blocking is broad and may block legitimate services, cloud platforms, CDNs, VPN endpoints, software updates, and ordinary users.",
                "Rules are opt-in and generated only from enabled validated CIDR ranges."
            ]
        )
    }

    private func contains(ip: String, inCIDR cidr: String) -> Bool {
        guard !ip.contains(":"), !cidr.contains(":") else { return false }
        let parts = cidr.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let prefix = Int(parts[1]), let ipValue = ipv4(ip), let networkValue = ipv4(parts[0]) else {
            return ip == cidr
        }
        let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix)
        return (ipValue & mask) == (networkValue & mask)
    }

    private func ipv4(_ value: String) -> UInt32? {
        let parts = value.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 <= 255 }) else { return nil }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }
}
