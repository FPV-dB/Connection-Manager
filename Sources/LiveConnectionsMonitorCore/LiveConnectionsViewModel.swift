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
    @Published public var sortField: ConnectionSortField = .process {
        didSet {
            if oldValue != sortField {
                resortConnections()
            }
        }
    }
    @Published public var sortAscending = true {
        didSet {
            if oldValue != sortAscending {
                resortConnections()
            }
        }
    }
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
        let filtered: [NetworkConnection]
        if query.isEmpty {
            filtered = connections
        } else {
            filtered = connections.filter { connection in
            [
                connection.processName,
                connection.pid.map(String.init) ?? "",
                connection.protocolKind.rawValue,
                connection.direction.rawValue,
                connection.local.address,
                connection.local.port,
                connection.remote?.address ?? "",
                connection.remote?.port ?? "",
                connection.state,
                connection.bytesIn.map(String.init) ?? "",
                connection.bytesOut.map(String.init) ?? ""
            ].joined(separator: " ").lowercased().contains(query)
            }
        }
        return filtered.sorted(by: sort)
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
        let newRows = scanned.filter { !existingIDs.contains($0.id) }.sorted(by: sort)
        merged.append(contentsOf: newRows)
        merged.sort(by: sort)

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

    private func resortConnections() {
        let selectedID = selectedConnectionID
        withTransaction(Transaction(animation: nil)) {
            connections.sort(by: sort)
            selectedConnectionID = selectedID
        }
    }

    private func sort(_ lhs: NetworkConnection, _ rhs: NetworkConnection) -> Bool {
        let ascending: Bool
        switch sortField {
        case .process: ascending = lhs.processName.localizedCaseInsensitiveCompare(rhs.processName) == .orderedAscending
        case .pid: ascending = lhs.pidSortValue < rhs.pidSortValue
        case .proto: ascending = lhs.protocolSortValue < rhs.protocolSortValue
        case .direction: ascending = lhs.directionSortValue < rhs.directionSortValue
        case .localAddress: ascending = lhs.localAddressSortValue < rhs.localAddressSortValue
        case .localPort: ascending = lhs.localPortSortValue < rhs.localPortSortValue
        case .remoteAddress: ascending = lhs.remoteAddressSortValue < rhs.remoteAddressSortValue
        case .remotePort: ascending = lhs.remotePortSortValue < rhs.remotePortSortValue
        case .state: ascending = lhs.state < rhs.state
        case .bytesIn: ascending = lhs.bytesInSortValue < rhs.bytesInSortValue
        case .bytesOut: ascending = lhs.bytesOutSortValue < rhs.bytesOutSortValue
        case .inboundRate: ascending = lhs.bytesInRateSortValue < rhs.bytesInRateSortValue
        case .outboundRate: ascending = lhs.bytesOutRateSortValue < rhs.bytesOutRateSortValue
        }
        if valueEqual(lhs, rhs) { return lhs.id < rhs.id }
        return sortAscending ? ascending : !ascending
    }

    private func valueEqual(_ lhs: NetworkConnection, _ rhs: NetworkConnection) -> Bool {
        switch sortField {
        case .process: lhs.processName == rhs.processName
        case .pid: lhs.pidSortValue == rhs.pidSortValue
        case .proto: lhs.protocolSortValue == rhs.protocolSortValue
        case .direction: lhs.directionSortValue == rhs.directionSortValue
        case .localAddress: lhs.localAddressSortValue == rhs.localAddressSortValue
        case .localPort: lhs.localPortSortValue == rhs.localPortSortValue
        case .remoteAddress: lhs.remoteAddressSortValue == rhs.remoteAddressSortValue
        case .remotePort: lhs.remotePortSortValue == rhs.remotePortSortValue
        case .state: lhs.state == rhs.state
        case .bytesIn: lhs.bytesInSortValue == rhs.bytesInSortValue
        case .bytesOut: lhs.bytesOutSortValue == rhs.bytesOutSortValue
        case .inboundRate: lhs.bytesInRateSortValue == rhs.bytesInRateSortValue
        case .outboundRate: lhs.bytesOutRateSortValue == rhs.bytesOutRateSortValue
        }
    }
}
