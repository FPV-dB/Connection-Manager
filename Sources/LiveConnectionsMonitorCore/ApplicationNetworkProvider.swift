import Foundation
import Security

public actor ProcessCounterAppNetworkProvider: AppNetworkActivityProvider {
    public nonisolated let capabilities = AppProviderCapabilities.processCounters

    private let connectionMonitor: ConnectionMonitorService
    private var recordIDs: [String: String] = [:]

    public init(connectionMonitor: ConnectionMonitorService) {
        self.connectionMonitor = connectionMonitor
    }

    public func snapshot(
        for apps: [RunningAppDescriptor],
        includeLoopback: Bool,
        rules: [String: AppRuleAction]
    ) async throws -> AppNetworkProviderSnapshot {
        let now = Date()
        let scanned = try await connectionMonitor.scan()
        let appsByPID = Dictionary(uniqueKeysWithValues: apps.map { ($0.pid, $0) })
        let visibleConnections = scanned.filter { connection in
            guard let pid = connection.pid, appsByPID[pid] != nil else { return false }
            return includeLoopback || !Self.isLoopback(connection)
        }

        let grouped = Dictionary(grouping: visibleConnections, by: { $0.pid ?? -1 })
        var summaries: [RunningAppNetworkSummary] = []
        var records: [AppConnectionRecord] = []

        for app in apps {
            let key = app.bundleIdentifier ?? app.id
            let connections = grouped[app.pid] ?? []
            let downloaded = connections.compactMap(\.bytesIn).max() ?? 0
            let uploaded = connections.compactMap(\.bytesOut).max() ?? 0
            let action = rules[key] ?? .observed
            let lastActivity = connections.isEmpty ? nil : now

            summaries.append(RunningAppNetworkSummary(
                id: key,
                appName: app.appName,
                bundleIdentifier: app.bundleIdentifier,
                pid: app.pid,
                executablePath: app.executablePath,
                teamIdentifier: Self.teamIdentifier(at: app.executablePath),
                currentUploadBps: connections.compactMap(\.bytesOutPerSecond).max() ?? 0,
                currentDownloadBps: connections.compactMap(\.bytesInPerSecond).max() ?? 0,
                totalUploadedBytes: uploaded,
                totalDownloadedBytes: downloaded,
                activeConnectionCount: connections.count,
                lastSeen: lastActivity,
                isRunning: true
            ))

            for connection in connections {
                let recordKey = key + "|" + connection.dedupeKey
                let recordID = recordIDs[recordKey] ?? UUID().uuidString
                recordIDs[recordKey] = recordID
                records.append(AppConnectionRecord(
                    id: recordID,
                    timestamp: connection.lastSeen,
                    appBundleIdentifier: key,
                    pid: app.pid,
                    direction: connection.direction == .listening || connection.direction == .incoming ? .inbound : .outbound,
                    protocolKind: connection.protocolKind,
                    localAddress: connection.local.address,
                    localPort: connection.local.port,
                    remoteAddress: connection.remote?.address,
                    remotePort: connection.remote?.port,
                    remoteHostname: nil,
                    countryCode: nil,
                    state: connection.state,
                    bytesSent: capabilities.suppliesPerFlowBytes ? connection.bytesOut : nil,
                    bytesReceived: capabilities.suppliesPerFlowBytes ? connection.bytesIn : nil,
                    duration: max(0, connection.lastSeen.timeIntervalSince(connection.firstSeen)),
                    ruleAction: action
                ))
            }
        }
        return AppNetworkProviderSnapshot(summaries: summaries, connections: records)
    }

    private static func isLoopback(_ connection: NetworkConnection) -> Bool {
        let addresses = [connection.local.address, connection.remote?.address].compactMap { $0 }
        return addresses.contains { $0 == "::1" || $0.hasPrefix("127.") }
    }

    private static func teamIdentifier(at executablePath: String?) -> String? {
        guard let executablePath else { return nil }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: executablePath) as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any]
        else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
