import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public final class ApplicationNetworkViewModel: ObservableObject {
    @Published public private(set) var applications: [RunningAppNetworkSummary] = []
    @Published public private(set) var connectionHistory: [AppConnectionRecord] = []
    @Published public private(set) var samplesByApp: [String: [AppTrafficSample]] = [:]
    @Published public var selectedAppID: String? { didSet { loadSelectedHistory() } }
    @Published public var searchText = ""
    @Published public var connectionSearchText = ""
    @Published public var connectionFilter: AppConnectionFilter = .all {
        didSet { UserDefaults.standard.set(connectionFilter.rawValue, forKey: "applications.connectionFilter") }
    }
    @Published public var errorMessage: String?
    @Published public private(set) var lastUpdatedAt: Date?
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var rules: [String: AppRuleAction] = [:]

    @AppStorage("applications.showOnlyNetworkActivity") public var showOnlyNetworkActivity = false
    @AppStorage("applications.includeLoopback") public var includeLoopback = false
    @AppStorage("applications.historyLimit") public var historyLimit = 1_000
    @AppStorage("applications.updateInterval") private var updateIntervalRaw = AppMonitorInterval.one.rawValue

    public let capabilities: AppProviderCapabilities
    private let provider: any AppNetworkActivityProvider
    private let database: ApplicationNetworkDatabase
    private var refreshTask: Task<Void, Never>?

    public init(provider: any AppNetworkActivityProvider, database: ApplicationNetworkDatabase) {
        self.provider = provider
        self.database = database
        capabilities = provider.capabilities
        rules = (try? database.rules()) ?? [:]
        connectionFilter = AppConnectionFilter(rawValue: UserDefaults.standard.string(forKey: "applications.connectionFilter") ?? "") ?? .all
    }

    deinit { refreshTask?.cancel() }

    public var updateInterval: AppMonitorInterval {
        get { AppMonitorInterval(rawValue: updateIntervalRaw) ?? .one }
        set {
            updateIntervalRaw = newValue.rawValue
            restartLoop()
        }
    }

    public var visibleApplications: [RunningAppNetworkSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return applications.filter { app in
            let hasActivity = app.currentUploadBps > 0 || app.currentDownloadBps > 0 || app.activeConnectionCount > 0 || app.totalUploadedBytes > 0 || app.totalDownloadedBytes > 0
            guard !showOnlyNetworkActivity || hasActivity else { return false }
            return query.isEmpty || [app.appName, app.bundleIdentifier ?? "", String(app.pid)].joined(separator: " ").lowercased().contains(query)
        }
    }

    public var selectedApp: RunningAppNetworkSummary? {
        applications.first { $0.id == selectedAppID }
    }

    public var selectedSamples: [AppTrafficSample] {
        samplesByApp[selectedAppID ?? ""] ?? []
    }

    public var filteredConnections: [AppConnectionRecord] {
        let query = connectionSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return connectionHistory.filter { record in
            let filterMatches: Bool
            switch connectionFilter {
            case .all: filterMatches = true
            case .allowed: filterMatches = record.ruleAction == .allowed || record.ruleAction == .temporaryAllow
            case .blocked: filterMatches = record.ruleAction == .blocked || record.ruleAction == .manualBlock
            case .inbound: filterMatches = record.direction == .inbound
            case .outbound: filterMatches = record.direction == .outbound
            case .tcp: filterMatches = record.protocolKind == .tcp
            case .udp: filterMatches = record.protocolKind == .udp
            }
            guard filterMatches else { return false }
            return query.isEmpty || [record.localAddress, record.localPort, record.remoteAddress ?? "", record.remotePort ?? "", record.remoteHostname ?? "", record.countryCode ?? "", record.state].joined(separator: " ").lowercased().contains(query)
        }
    }

    public func start() {
        guard refreshTask == nil else { return }
        restartLoop()
        Task { await refreshNow() }
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
            let descriptors = Self.runningApplications()
            let snapshot = try await provider.snapshot(for: descriptors, includeLoopback: includeLoopback, rules: rules)
            merge(snapshot)
            lastUpdatedAt = Date()
            let database = database
            let records = snapshot.connections
            let limit = historyLimit
            try await Task.detached { try database.save(records, historyLimit: limit) }.value
            if selectedAppID != nil { await reloadSelectedHistory() }
        } catch {
            errorMessage = error.localizedDescription
        }
        isRefreshing = false
    }

    public func icon(for app: RunningAppNetworkSummary) -> NSImage {
        if let running = NSRunningApplication(processIdentifier: pid_t(app.pid)), let icon = running.icon { return icon }
        if let path = app.executablePath { return NSWorkspace.shared.icon(forFile: path) }
        return NSImage(systemSymbolName: "app", accessibilityDescription: "Application") ?? NSImage()
    }

    public func rule(for app: RunningAppNetworkSummary) -> AppRuleAction {
        rules[app.bundleIdentifier ?? app.id] ?? .observed
    }

    public func setRule(_ action: AppRuleAction, for app: RunningAppNetworkSummary) {
        let key = app.bundleIdentifier ?? app.id
        rules[key] = action
        let database = database
        Task {
            do { try await Task.detached { try database.setRule(action, for: key) }.value }
            catch { errorMessage = error.localizedDescription }
        }
    }

    public func quitSelectedApp() {
        guard let app = selectedApp, app.isRunning,
              let running = NSRunningApplication(processIdentifier: pid_t(app.pid)) else { return }
        if !running.terminate() { errorMessage = "macOS could not quit \(app.appName)." }
    }

    public func clearSelectedHistory() {
        guard let selectedAppID else { return }
        let database = database
        Task {
            do {
                try await Task.detached { try database.clearHistory(for: selectedAppID) }.value
                connectionHistory = []
            } catch { errorMessage = error.localizedDescription }
        }
    }

    public func exportSelectedHistory() {
        guard let app = selectedApp else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(app.appName.replacingOccurrences(of: " ", with: "_"))_connections.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Self.csv(for: filteredConnections).write(to: url, atomically: true, encoding: .utf8)
        } catch { errorMessage = "Could not export CSV: \(error.localizedDescription)" }
    }

    private func restartLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.updateInterval.rawValue))
                await self.refreshNow()
            }
        }
    }

    private func merge(_ snapshot: AppNetworkProviderSnapshot) {
        let now = Date()
        var previousByID: [String: RunningAppNetworkSummary] = [:]
        for app in applications { previousByID[app.id] = app }
        let liveSummaries = snapshot.summaries.map { incoming in
            guard let previous = previousByID[incoming.id], previous.pid == incoming.pid else { return incoming }
            var app = incoming
            app.lastSeen = incoming.lastSeen ?? previous.lastSeen
            app.totalUploadedBytes = max(incoming.totalUploadedBytes, previous.totalUploadedBytes)
            app.totalDownloadedBytes = max(incoming.totalDownloadedBytes, previous.totalDownloadedBytes)
            return app
        }
        let liveIDs = Set(liveSummaries.map(\.id))
        let stopped = applications.filter { !liveIDs.contains($0.id) }.map { old in
            var app = old
            app.isRunning = false
            app.currentUploadBps = 0
            app.currentDownloadBps = 0
            app.activeConnectionCount = 0
            return app
        }
        applications = (liveSummaries + stopped).sorted {
            if $0.isRunning != $1.isRunning { return $0.isRunning }
            return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
        for app in liveSummaries {
            var samples = samplesByApp[app.id] ?? []
            samples.append(AppTrafficSample(timestamp: now, appBundleIdentifier: app.id, uploadBps: app.currentUploadBps, downloadBps: app.currentDownloadBps, activeConnectionCount: app.activeConnectionCount))
            samplesByApp[app.id] = Array(samples.suffix(300))
        }
        if selectedAppID == nil { selectedAppID = applications.first?.id }
    }

    private func loadSelectedHistory() {
        Task { await reloadSelectedHistory() }
    }

    private func reloadSelectedHistory() async {
        guard let selectedAppID else { connectionHistory = []; return }
        let database = database
        let limit = historyLimit
        do { connectionHistory = try await Task.detached { try database.recentConnections(for: selectedAppID, limit: limit) }.value }
        catch { errorMessage = error.localizedDescription }
    }

    private static func runningApplications() -> [RunningAppDescriptor] {
        var seenIDs: Set<String> = []
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, !app.isTerminated else { return nil }
            let name = app.localizedName ?? app.executableURL?.deletingPathExtension().lastPathComponent ?? "Application"
            let descriptor = RunningAppDescriptor(appName: name, bundleIdentifier: app.bundleIdentifier, pid: Int(app.processIdentifier), executablePath: app.executableURL?.path)
            guard seenIDs.insert(descriptor.id).inserted else { return nil }
            return descriptor
        }
    }

    private static func csv(for records: [AppConnectionRecord]) -> String {
        let header = "Time,Direction,Protocol,Local Address,Local Port,Remote Address,Remote Port,Remote Hostname,Country,State,Bytes Sent,Bytes Received,Duration,Rule Matched"
        let formatter = ISO8601DateFormatter()
        return ([header] + records.map { record in
            [formatter.string(from: record.timestamp), record.direction.rawValue, record.protocolKind.rawValue,
             record.localAddress, record.localPort, record.remoteAddress ?? "", record.remotePort ?? "",
             record.remoteHostname ?? "", record.countryCode ?? "", record.state,
             record.bytesSent.map(String.init) ?? "", record.bytesReceived.map(String.init) ?? "",
             String(format: "%.1f", record.duration), record.ruleAction.label].map(csvEscape).joined(separator: ",")
        }).joined(separator: "\n") + "\n"
    }

    private static func csvEscape(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
