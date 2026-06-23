import Foundation
import Testing
@testable import LiveConnectionsMonitorCore

private let googleRules = [
    BlockRule(group: .importedBlocklists, value: "192.178.0.0/15", direction: .both, source: .imported, note: "goog.json", isEnabled: true),
    BlockRule(group: .importedBlocklists, value: "142.250.0.0/15", direction: .both, source: .imported, note: "goog.json", isEnabled: true),
    BlockRule(group: .importedBlocklists, value: "74.125.0.0/16", direction: .both, source: .imported, note: "goog.json", isEnabled: true)
]

@Test(arguments: [
    ("mail.google.com", "192.178.188.18", "192.178.0.0/15"),
    ("maps.google.com", "192.178.187.100", "192.178.0.0/15"),
    ("fonts.googleapis.com", "192.178.188.95", "192.178.0.0/15"),
    ("youtube.com", "192.178.187.136", "192.178.0.0/15"),
    ("i.ytimg.com", "142.250.124.119", "142.250.0.0/15"),
    ("accounts.google.com", "74.125.68.84", "74.125.0.0/16")
])
func capturedGoogleResolutionIsBlocked(hostname: String, address: String, expectedRule: String) {
    let result = FirewallRuleEvaluator().evaluate(address: address, blockRules: googleRules, allowlist: [])
    #expect(result.decision == .blocked, "\(hostname) should be blocked")
    #expect(result.matchingRule == expectedRule)
    #expect(result.evaluations.last?.matched == true)
    #expect(result.evaluations.last?.reason == "Address is inside CIDR \(expectedRule).")
}

@Test func allowlistCIDRTakesPrecedenceOverBroaderBlockCIDR() {
    let allowlist = [AllowlistEntry(id: 1, value: "192.178.188.0/24", note: "trusted", dateAdded: Date(), isEnabled: true)]
    let result = FirewallRuleEvaluator().evaluate(address: "192.178.188.18", blockRules: googleRules, allowlist: allowlist)
    #expect(result.decision == .allowed)
    #expect(result.matchingRule == "192.178.188.0/24")
    #expect(result.evaluations.count == 1)
}

@Test func generatedAllowlistPassesBeforeBroaderBlockCIDR() {
    let allowlist = [AllowlistEntry(id: 1, value: "192.178.188.18", note: "trusted", dateAdded: Date(), isEnabled: true)]
    let rules = FirewallRuleGenerator().rules(for: googleRules, allowlist: allowlist, settings: FirewallSettings())
    let passRange = try! #require(rules.range(of: "pass out quick to 192.178.188.18"))
    let blockRange = try! #require(rules.range(of: "block drop out quick to 192.178.0.0/15"))
    #expect(passRange.lowerBound < blockRange.lowerBound)
}

@Test func evaluatorLogsFailedAndSuccessfulRuleReasons() {
    let result = FirewallRuleEvaluator().evaluate(address: "142.250.124.119", blockRules: googleRules, allowlist: [])
    #expect(result.evaluations[0].matched == false)
    #expect(result.evaluations[0].reason == "Address is outside CIDR 192.178.0.0/15.")
    #expect(result.evaluations[1].matched == true)
    #expect(result.evaluations[1].reason == "Address is inside CIDR 142.250.0.0/15.")
}

@Test func defaultAnchorIsReachableFromMacOSPFConfiguration() {
    #expect(FirewallBlockService.anchorName.hasPrefix("com.apple/"))
    #expect(FirewallSettings().anchorName == FirewallBlockService.anchorName)
    #expect(StartupProtectionService.startupAnchor.hasPrefix("com.apple/"))
    #expect(StartupProtectionService.rulesAnchor.hasPrefix("com.apple/"))
    #expect(StartupProtectionService.blocklistsAnchor.hasPrefix("com.apple/"))
}

@Test func legacySavedAnchorNameMigratesToReachableAnchor() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let database = try FirewallDatabase(url: url)
    var settings = FirewallSettings()
    settings.anchorName = FirewallBlockService.legacyAnchorName
    try database.save(settings: settings)
    #expect(try database.settings().anchorName == FirewallBlockService.anchorName)
}
