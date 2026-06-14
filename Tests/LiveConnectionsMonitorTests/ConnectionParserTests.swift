import Foundation
import Testing
@testable import LiveConnectionsMonitorCore

@Test func parsesEstablishedLsofTCPConnection() {
    let sample = """
    COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
    Safari     123 me     12u  IPv4 0xabc              0t0  TCP 192.168.1.10:52144->93.184.216.34:443 (ESTABLISHED)
    """
    let connections = ConnectionParser().parseLsof(sample, now: Date(timeIntervalSince1970: 1))
    #expect(connections.count == 1)
    #expect(connections[0].processName == "Safari")
    #expect(connections[0].pid == 123)
    #expect(connections[0].protocolKind == .tcp)
    #expect(connections[0].direction == .established)
    #expect(connections[0].local.address == "192.168.1.10")
    #expect(connections[0].local.port == "52144")
    #expect(connections[0].remote?.address == "93.184.216.34")
    #expect(connections[0].remote?.port == "443")
}

@Test func parsesListeningLsofTCPConnection() {
    let sample = """
    COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
    sshd       456 root    5u  IPv6 0xabc              0t0  TCP *:22 (LISTEN)
    """
    let connection = ConnectionParser().parseLsof(sample).first
    #expect(connection?.direction == .listening)
    #expect(connection?.remote == nil)
    #expect(connection?.local.port == "22")
}

@Test func parsesNetstatFallbackLine() {
    let sample = "tcp4       0      0  192.168.1.10.52144   93.184.216.34.443    ESTABLISHED"
    let connection = ConnectionParser().parseNetstat(sample).first
    #expect(connection?.protocolKind == .tcp)
    #expect(connection?.state == "ESTABLISHED")
}

@Test func validatorRefusesUnsafeAddressesAndWarnsForPrivateLAN() {
    let validator = IPAddressValidator()
    if case .refused = validator.validate("127.0.0.1") {} else {
        Issue.record("Expected loopback to be refused")
    }
    if case .refused = validator.validate("224.0.0.1") {} else {
        Issue.record("Expected multicast to be refused")
    }
    if case .warning = validator.validate("192.168.1.0/24") {} else {
        Issue.record("Expected private LAN range warning")
    }
    if case .valid = validator.validate("93.184.216.34") {} else {
        Issue.record("Expected public IPv4 to be valid")
    }
}

@Test func blocklistParserDeduplicatesAndSkipsInvalidLines() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString).appendingPathExtension("txt")
    try """
    # comment
    93.184.216.34
    93.184.216.34
    192.168.1.0/24
    not-an-ip
    ; another comment
    """.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    let parsed = try BlocklistImportService().parse(url: url)
    #expect(parsed.entries.map(\.value) == ["192.168.1.0/24", "93.184.216.34"])
    #expect(parsed.skipped == 1)
    #expect(parsed.warnings.count == 1)
}

@Test func geoSimulationMatchesIPv4CIDR() {
    let countries = [
        GeoBlockCountry(countryCode: "ZZ", countryName: "Testland", ipv4RangeCount: 1, ipv6RangeCount: 0, isEnabled: true, direction: .both, lastImportedAt: Date(), sourceName: "test", notes: "", expiresAt: nil)
    ]
    let ranges = [
        GeoBlockRange(id: 1, countryCode: "ZZ", countryName: "Testland", cidr: "93.184.216.0/24", ipVersion: .ipv4, sourceName: "test", importedAt: Date(), isEnabled: true, validationStatus: "valid")
    ]
    let connections = [
        NetworkConnection(processName: "Safari", pid: 12, protocolKind: .tcp, direction: .established, local: NetworkEndpoint(address: "192.168.1.2", port: "50000"), remote: NetworkEndpoint(address: "93.184.216.34", port: "443"), state: "ESTABLISHED", firstSeen: Date(), lastSeen: Date())
    ]
    let simulation = GeoBlockSimulationService().simulate(countries: countries, ranges: ranges, connections: connections, allowlist: [])
    #expect(simulation.affectedConnections.count == 1)
    #expect(simulation.generatedRuleCount == 2)
}

@Test func lookupServiceRefusesReservedAddresses() {
    let service = LookupService()
    if case .failure(.reservedAddress) = service.canLookup(ip: "192.168.1.1") {} else {
        Issue.record("Expected private IP lookup to be refused")
    }
    if case .success("93.184.216.34") = service.canLookup(ip: "93.184.216.34") {} else {
        Issue.record("Expected public IP lookup to be allowed")
    }
}
