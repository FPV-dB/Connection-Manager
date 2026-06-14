import Foundation
import SwiftUI

@MainActor
public final class LiveConnectionsViewModel: ObservableObject {
    @Published public private(set) var connections: [NetworkConnection] = []
    @Published public private(set) var blockedIPs: [String] = []
    @Published public var searchText = ""
    @Published public var refreshInterval: RefreshInterval = .two {
        didSet { restartLoop() }
    }
    @Published public var selectedConnectionID: NetworkConnection.ID?
    @Published public var errorMessage: String?
    @Published public var isRefreshing = false
    @Published public private(set) var lastRefreshedAt: Date?
    @Published public var pendingBlockIP: String?
    @Published public var pendingGatewayOverrideIP: String?

    private let monitorService: ConnectionMonitorService
    private let firewallService: FirewallBlockService
    private var refreshTask: Task<Void, Never>?
    private var staleMisses: [NetworkConnection.ID: Int] = [:]
    private let staleGraceCycles = 3

    public init(monitorService: ConnectionMonitorService, firewallService: FirewallBlockService) {
        self.monitorService = monitorService
        self.firewallService = firewallService
    }

    deinit {
        refreshTask?.cancel()
    }

    public var filteredConnections: [NetworkConnection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return connections }
        return connections.filter { connection in
            [
                connection.processName,
                connection.pid.map(String.init) ?? "",
                connection.protocolKind.rawValue,
                connection.direction.rawValue,
                connection.local.address,
                connection.local.port,
                connection.remote?.address ?? "",
                connection.remote?.port ?? "",
                connection.state
            ].joined(separator: " ").lowercased().contains(query)
        }
    }

    public var selectedConnection: NetworkConnection? {
        guard let selectedConnectionID else { return nil }
        return connections.first { $0.id == selectedConnectionID }
    }

    public func start() {
        restartLoop()
        Task {
            blockedIPs = await firewallService.loadBlockedIPs()
            if connections.isEmpty {
                await refreshNow()
            }
        }
    }

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    public func refreshNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        do {
            let scanned = try await monitorService.scan()
            merge(scanned)
            lastRefreshedAt = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
        isRefreshing = false
    }

    public func requestBlockSelectedConnection() async {
        guard let connection = selectedConnection else {
            errorMessage = "Select a connection before blocking."
            return
        }
        guard let remoteIP = connection.remote?.address, !remoteIP.isEmpty else {
            errorMessage = "The selected connection has no remote IP."
            return
        }
        switch await firewallService.safety(for: remoteIP) {
        case .allowed:
            pendingBlockIP = remoteIP
        case let .needsGatewayOverride(gateway):
            pendingGatewayOverrideIP = gateway
        case let .blocked(message):
            errorMessage = message
        }
    }

    public func confirmBlock(ip: String) async {
        errorMessage = nil
        do {
            blockedIPs = try await firewallService.block(ip: ip, existing: Set(blockedIPs))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func unblock(ip: String) async {
        errorMessage = nil
        do {
            blockedIPs = try await firewallService.unblock(ip: ip, existing: Set(blockedIPs))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restartLoop() {
        refreshTask?.cancel()
        guard let seconds = refreshInterval.seconds else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                await self?.refreshNow()
            }
        }
    }

    private func merge(_ scanned: [NetworkConnection]) {
        let selectedID = selectedConnectionID
        let scannedByID = Dictionary(uniqueKeysWithValues: scanned.map { ($0.id, $0) })
        let scannedIDs = Set(scannedByID.keys)
        for id in scannedIDs {
            staleMisses[id] = 0
        }

        var merged: [NetworkConnection] = connections.compactMap { existing in
            if let next = scannedByID[existing.id] {
                return next
            }
            let misses = (staleMisses[existing.id] ?? 0) + 1
            staleMisses[existing.id] = misses
            return misses <= staleGraceCycles ? existing : nil
        }

        let existingIDs = Set(merged.map(\.id))
        let newRows = scanned.filter { !existingIDs.contains($0.id) }.sorted(by: stableSort)
        merged.append(contentsOf: newRows)
        merged.sort(by: stableSort)

        let liveIDs = Set(merged.map(\.id))
        staleMisses = staleMisses.filter { liveIDs.contains($0.key) }

        withTransaction(Transaction(animation: nil)) {
            connections = merged
            if let selectedID, liveIDs.contains(selectedID) {
                selectedConnectionID = selectedID
            } else if selectedID != nil {
                selectedConnectionID = nil
            }
        }
    }

    private func stableSort(_ lhs: NetworkConnection, _ rhs: NetworkConnection) -> Bool {
        if lhs.processName != rhs.processName {
            return lhs.processName.localizedCaseInsensitiveCompare(rhs.processName) == .orderedAscending
        }
        if (lhs.pid ?? 0) != (rhs.pid ?? 0) { return (lhs.pid ?? 0) < (rhs.pid ?? 0) }
        return lhs.id < rhs.id
    }
}
