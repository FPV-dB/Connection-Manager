import Foundation

public enum AppRuleAction: String, CaseIterable, Identifiable, Codable, Sendable {
    case allowed
    case blocked
    case temporaryAllow
    case manualBlock
    case observed

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .allowed: "Allowed"
        case .blocked: "Blocked"
        case .temporaryAllow: "Temporary Allow"
        case .manualBlock: "Manual Block"
        case .observed: "Observed"
        }
    }
}

public enum AppConnectionDirection: String, CaseIterable, Identifiable, Codable, Sendable {
    case inbound
    case outbound
    public var id: String { rawValue }
}

public struct RunningAppDescriptor: Identifiable, Hashable, Sendable {
    public var id: String { bundleIdentifier ?? executablePath ?? "pid:\(pid)" }
    public let appName: String
    public let bundleIdentifier: String?
    public let pid: Int
    public let executablePath: String?

    public init(appName: String, bundleIdentifier: String?, pid: Int, executablePath: String?) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.pid = pid
        self.executablePath = executablePath
    }
}

public struct RunningAppNetworkSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public var appName: String
    public var bundleIdentifier: String?
    public var pid: Int
    public var executablePath: String?
    public var teamIdentifier: String?
    public var currentUploadBps: Double
    public var currentDownloadBps: Double
    public var totalUploadedBytes: UInt64
    public var totalDownloadedBytes: UInt64
    public var activeConnectionCount: Int
    public var lastSeen: Date?
    public var isRunning: Bool
}

public struct AppConnectionRecord: Identifiable, Hashable, Sendable {
    public let id: String
    public let timestamp: Date
    public let appBundleIdentifier: String
    public let pid: Int
    public let direction: AppConnectionDirection
    public let protocolKind: NetworkProtocolKind
    public let localAddress: String
    public let localPort: String
    public let remoteAddress: String?
    public let remotePort: String?
    public let remoteHostname: String?
    public let countryCode: String?
    public let state: String
    public let bytesSent: UInt64?
    public let bytesReceived: UInt64?
    public let duration: TimeInterval
    public let ruleAction: AppRuleAction
}

public struct AppTrafficSample: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let appBundleIdentifier: String
    public let uploadBps: Double
    public let downloadBps: Double
    public let activeConnectionCount: Int
}

public struct AppProviderCapabilities: Sendable {
    public let enforcesPerAppRules: Bool
    public let resolvesHostnames: Bool
    public let suppliesGeoIP: Bool
    public let suppliesPerFlowBytes: Bool

    public static let processCounters = AppProviderCapabilities(
        enforcesPerAppRules: false,
        resolvesHostnames: false,
        suppliesGeoIP: false,
        suppliesPerFlowBytes: false
    )
}

public struct AppNetworkProviderSnapshot: Sendable {
    public let summaries: [RunningAppNetworkSummary]
    public let connections: [AppConnectionRecord]
}

public protocol AppNetworkActivityProvider: Sendable {
    var capabilities: AppProviderCapabilities { get }
    func snapshot(for apps: [RunningAppDescriptor], includeLoopback: Bool, rules: [String: AppRuleAction]) async throws -> AppNetworkProviderSnapshot
}

public enum AppConnectionFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case allowed = "Allowed"
    case blocked = "Blocked"
    case inbound = "Inbound"
    case outbound = "Outbound"
    case tcp = "TCP"
    case udp = "UDP"
    public var id: String { rawValue }
}

public enum AppMonitorInterval: Int, CaseIterable, Identifiable, Sendable {
    case one = 1
    case two = 2
    case five = 5
    public var id: Int { rawValue }
    public var label: String { "\(rawValue)s" }
}
