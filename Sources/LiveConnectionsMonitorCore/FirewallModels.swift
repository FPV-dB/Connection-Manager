import Foundation

public enum FirewallDirection: String, CaseIterable, Identifiable, Sendable {
    case inbound
    case outbound
    case both

    public var id: String { rawValue }
}

public enum FirewallRuleSource: String, CaseIterable, Identifiable, Sendable {
    case manual
    case imported
    case rule
    case temporary
    case allowlist

    public var id: String { rawValue }
}

public enum FirewallRuleGroup: String, CaseIterable, Identifiable, Sendable {
    case manualBlocks = "Manual Blocks"
    case importedBlocklists = "Imported Blocklists"
    case temporaryBlocks = "Temporary Blocks"
    case trustedAllowlist = "Trusted Allowlist"

    public var id: String { rawValue }
}

public struct ManualBlockedIP: Identifiable, Hashable, Sendable {
    public let id: Int64
    public var address: String
    public var direction: FirewallDirection
    public var note: String
    public var source: FirewallRuleSource
    public var dateAdded: Date
    public var isEnabled: Bool
}

public struct Blocklist: Identifiable, Hashable, Sendable {
    public let id: Int64
    public var name: String
    public var sourceFilename: String
    public var importedAt: Date
    public var entryCount: Int
    public var isEnabled: Bool
    public var notes: String
    public var lastAppliedAt: Date?
}

public struct BlocklistEntry: Identifiable, Hashable, Sendable {
    public let id: Int64
    public var blocklistID: Int64
    public var value: String
    public var isEnabled: Bool
    public var warning: String?
}

public struct AllowlistEntry: Identifiable, Hashable, Sendable {
    public let id: Int64
    public var value: String
    public var note: String
    public var dateAdded: Date
    public var isEnabled: Bool
}

public struct BlockRule: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var group: FirewallRuleGroup
    public var value: String
    public var direction: FirewallDirection
    public var source: FirewallRuleSource
    public var note: String
    public var isEnabled: Bool
}

public enum IPVersion: String, CaseIterable, Identifiable, Sendable {
    case ipv4 = "IPv4"
    case ipv6 = "IPv6"

    public var id: String { rawValue }
}

public struct GeoBlockSource: Identifiable, Hashable, Sendable {
    public let id: Int64
    public var name: String
    public var sourceURL: String
    public var notes: String
    public var dateAdded: Date
}

public struct GeoBlockCountry: Identifiable, Hashable, Sendable {
    public var id: String { countryCode }
    public var countryCode: String
    public var countryName: String
    public var ipv4RangeCount: Int
    public var ipv6RangeCount: Int
    public var isEnabled: Bool
    public var direction: FirewallDirection
    public var lastImportedAt: Date?
    public var sourceName: String
    public var notes: String
    public var expiresAt: Date?

    public var ruleCountEstimate: Int {
        let rangeCount = ipv4RangeCount + ipv6RangeCount
        return direction == .both ? rangeCount * 2 : rangeCount
    }
}

public struct GeoBlockRange: Identifiable, Hashable, Sendable {
    public let id: Int64
    public var countryCode: String
    public var countryName: String
    public var cidr: String
    public var ipVersion: IPVersion
    public var sourceName: String
    public var importedAt: Date
    public var isEnabled: Bool
    public var validationStatus: String
}

public struct GeoBlockRule: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var countryCode: String
    public var countryName: String
    public var cidr: String
    public var direction: FirewallDirection
    public var isEnabled: Bool
    public var notes: String
}

public struct GeoBlockSimulation: Sendable {
    public var selectedCountries: [String] = []
    public var cidrRangeCount = 0
    public var generatedRuleCount = 0
    public var estimatedAnchorBytes = 0
    public var affectedConnections: [NetworkConnection] = []
    public var affectedProcesses: [(String, Int)] = []
    public var allowlistExemptions = 0
    public var warnings: [String] = []
}

public struct FirewallEventLog: Identifiable, Hashable, Sendable {
    public let id: Int64
    public var date: Date
    public var eventType: String
    public var message: String
    public var detail: String
    public var succeeded: Bool
}

public struct FirewallSettings: Hashable, Sendable {
    public var refreshInterval: RefreshInterval = .two
    public var autoApplyImportedBlocklists = false
    public var confirmBeforeApplying = true
    public var backupAnchorBeforeRewrite = true
    public var anchorPath = FirewallBlockService.anchorPath
    public var anchorName = FirewallBlockService.anchorName
    public var defaultLookupProviderID = "ipinfo"
    public var suppressLookupPrivacyWarning = false
    public var suppressTracerouteWarning = false
    public var launchAtLogin = false
    public var startupMode: StartupProtectionMode = .monitorOnly
    public var startupAcknowledged = false
    public var lastStartupAt: Date?
    public var lastStartupSynchronizationAt: Date?
    public var startupAnchorInstalled = false
    public var startupRulesLoaded = false
    public var blockKnownGoogleConnections = false
    public var googleRangesLastUpdatedAt: Date?
}

public enum StartupProtectionMode: String, CaseIterable, Identifiable, Sendable {
    case monitorOnly = "Monitor Only"
    case protectionAtBoot = "Protection at Boot"
    case strictStartupLock = "Strict Startup Lock"

    public var id: String { rawValue }

    public var detail: String {
        switch self {
        case .monitorOnly:
            return "No startup PF rules. App launches normally."
        case .protectionAtBoot:
            return "Existing app firewall rules remain active and synchronize after launch."
        case .strictStartupLock:
            return "Advanced: block non-essential traffic until Connection Manager starts."
        }
    }
}

public struct StartupProtectionStatus: Sendable, Hashable {
    public var pfEnabled = "Unknown"
    public var startupAnchorInstalled = false
    public var rulesLoaded = false
    public var lastSynchronization: Date?
}

public struct FirewallDashboardSnapshot: Sendable {
    public var activeConnections = 0
    public var blockedIPs = 0
    public var loadedBlocklists = 0
    public var blocksInLastHour = 0
    public var topRemoteIPs: [(String, Int)] = []
    public var topProcesses: [(String, Int)] = []
    public var pfStatus = "unknown"
    public var lastRuleReload: Date?
}

public struct BlocklistImportResult: Sendable {
    public var blocklist: Blocklist?
    public var importedEntries = 0
    public var skippedEntries = 0
    public var warnings: [String] = []
}
