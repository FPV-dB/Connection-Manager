import AppKit
import Foundation

@MainActor
public final class FirewallDashboardViewModel: ObservableObject {
    @Published public var selectedSection: FirewallSection? = .dashboard
    @Published public private(set) var snapshot = FirewallDashboardSnapshot()
    @Published public private(set) var blocklists: [Blocklist] = []
    @Published public private(set) var blocklistEntries: [BlocklistEntry] = []
    @Published public private(set) var manualBlocks: [ManualBlockedIP] = []
    @Published public private(set) var allowlist: [AllowlistEntry] = []
    @Published public private(set) var geoCountries: [GeoBlockCountry] = []
    @Published public private(set) var geoRanges: [GeoBlockRange] = []
    @Published public var geoSimulation = GeoBlockSimulation()
    @Published public var countryImportProgress: String?
    @Published public private(set) var events: [FirewallEventLog] = []
    @Published public var settings = FirewallSettings()
    @Published public var rulePreview = ""
    @Published public var errorMessage: String?
    @Published public var importWarnings: [String] = []
    @Published public var pendingApplyConfirmation = false
    @Published public var pendingLookupProviderID: String?
    @Published public var pendingLookupIP: String?
    @Published public var showLookupPrivacyWarning = false
    @Published public var showTracerouteWarning = false
    @Published public var selectedConnectionNote = ""
    @Published public var networkToolOutput = ""
    @Published public var isNetworkToolRunning = false

    public let liveConnectionsViewModel: LiveConnectionsViewModel
    private let database: FirewallDatabase
    private let importer = BlocklistImportService()
    private let generator = FirewallRuleGenerator()
    private let firewallService: FirewallBlockService
    private let lookupService = LookupService()
    private let networkToolRunner = NetworkToolRunner()

    public init(database: FirewallDatabase, liveConnectionsViewModel: LiveConnectionsViewModel, firewallService: FirewallBlockService) {
        self.database = database
        self.liveConnectionsViewModel = liveConnectionsViewModel
        self.firewallService = firewallService
        reload()
    }

    public func reload() {
        do {
            settings = try database.settings()
            blocklists = try database.blocklists()
            blocklistEntries = try database.entries()
            manualBlocks = try database.manualBlocks()
            allowlist = try database.allowlist()
            geoCountries = try database.geoCountries()
            geoRanges = try database.geoRanges()
            events = try database.events()
            liveConnectionsViewModel.refreshInterval = settings.refreshInterval
            rebuildPreview()
            rebuildSnapshot()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func importBlocklist(url: URL) {
        do {
            let result = try importer.importFile(url: url, database: database)
            importWarnings = result.warnings
            try database.insertEvent(type: "Blocklist imported", message: url.lastPathComponent, detail: "\(result.importedEntries) imported, \(result.skippedEntries) skipped", succeeded: true)
            reload()
            if settings.autoApplyImportedBlocklists {
                Task { await applyRulesIfAllowed() }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func addManualBlock(_ value: String, note: String = "Manual block", direction: FirewallDirection = .both) {
        do {
            try database.insertManualBlock(address: value, direction: direction, note: note)
            try database.insertEvent(type: "Connection blocked manually", message: value, detail: note, succeeded: true)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func deleteManualBlock(id: Int64) {
        do {
            try database.deleteManualBlock(id: id)
            try database.insertEvent(type: "Rule removed", message: "Manual block removed", detail: "id \(id)", succeeded: true)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func setManualBlockEnabled(id: Int64, enabled: Bool) {
        do {
            try database.setManualBlockEnabled(id: id, enabled: enabled)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func setBlocklistEnabled(id: Int64, enabled: Bool) {
        do {
            try database.setBlocklistEnabled(id: id, enabled: enabled)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func addAllowlist(_ value: String, note: String = "Trusted") {
        do {
            try database.insertAllowlist(value: value, note: note)
            try database.insertEvent(type: "Allowlist updated", message: value, detail: note, succeeded: true)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func deleteAllowlist(id: Int64) {
        do {
            try database.deleteAllowlist(id: id)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func saveSettings() {
        do {
            try database.save(settings: settings)
            liveConnectionsViewModel.refreshInterval = settings.refreshInterval
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func requestLookup(providerID: String? = nil) {
        let provider = providerID ?? settings.defaultLookupProviderID
        switch lookupService.canLookup(ip: liveConnectionsViewModel.selectedConnection?.remote?.address) {
        case let .success(ip):
            pendingLookupIP = ip
            pendingLookupProviderID = provider
            if settings.suppressLookupPrivacyWarning {
                openPendingLookup()
            } else {
                showLookupPrivacyWarning = true
            }
        case let .failure(error):
            errorMessage = error.localizedDescription
        }
    }

    public func openPendingLookup(dontShowAgain: Bool = false) {
        guard let ip = pendingLookupIP, let providerID = pendingLookupProviderID else { return }
        do {
            if dontShowAgain {
                settings.suppressLookupPrivacyWarning = true
                try database.save(settings: settings)
            }
            try lookupService.open(ip: ip, providerID: providerID)
        } catch {
            errorMessage = error.localizedDescription
        }
        pendingLookupIP = nil
        pendingLookupProviderID = nil
        showLookupPrivacyWarning = false
    }

    public func cancelPendingLookup() {
        pendingLookupIP = nil
        pendingLookupProviderID = nil
        showLookupPrivacyWarning = false
    }

    public func copySelectedRemoteIP() {
        guard let ip = liveConnectionsViewModel.selectedConnection?.remote?.address else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ip, forType: .string)
    }

    public func requestTraceroute() {
        switch lookupService.canLookup(ip: liveConnectionsViewModel.selectedConnection?.remote?.address) {
        case .success:
            if settings.suppressTracerouteWarning {
                runNetworkTool(.traceroute)
            } else {
                showTracerouteWarning = true
            }
        case let .failure(error):
            errorMessage = error.localizedDescription
        }
    }

    public func confirmTraceroute(dontShowAgain: Bool = false) {
        if dontShowAgain {
            settings.suppressTracerouteWarning = true
            try? database.save(settings: settings)
        }
        showTracerouteWarning = false
        runNetworkTool(.traceroute)
    }

    public func runNetworkTool(_ kind: NetworkToolKind) {
        guard let ip = liveConnectionsViewModel.selectedConnection?.remote?.address else {
            errorMessage = "No remote IP is available for the selected connection."
            return
        }
        guard !isNetworkToolRunning else { return }
        networkToolOutput = ""
        isNetworkToolRunning = true
        Task {
            do {
                try await networkToolRunner.run(kind: kind, ip: ip) { [weak self] text in
                    Task { @MainActor in
                        self?.networkToolOutput += text
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
            await MainActor.run {
                self.isNetworkToolRunning = false
            }
        }
    }

    public func stopNetworkTool() {
        networkToolRunner.stop()
        isNetworkToolRunning = false
    }

    public func copyNetworkToolOutput() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(networkToolOutput, forType: .string)
    }

    public func saveNetworkToolOutput() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "network-tool-output.txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try networkToolOutput.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func importCountryList(url: URL, countryCode: String, countryName: String, sourceName: String, notes: String = "") {
        countryImportProgress = "Importing \(countryCode.uppercased())..."
        Task {
            do {
                let result = try await GeoBlockImportService().importFile(
                    url: url,
                    countryCode: countryCode,
                    countryName: countryName,
                    sourceName: sourceName,
                    notes: notes,
                    database: database
                )
                await MainActor.run {
                    countryImportProgress = nil
                    importWarnings = result.warnings
                    reload()
                }
            } catch {
                await MainActor.run {
                    countryImportProgress = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    public func setGeoCountryEnabled(code: String, enabled: Bool) {
        do {
            try database.setGeoCountryEnabled(code: code, enabled: enabled)
            try database.insertEvent(type: enabled ? "Country block enabled" : "Country block disabled", message: code.uppercased(), detail: "", succeeded: true)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func setGeoCountryDirection(code: String, direction: FirewallDirection) {
        do {
            try database.setGeoCountryDirection(code: code, direction: direction)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func setGeoCountryNotes(code: String, notes: String) {
        do {
            try database.setGeoCountryNotes(code: code, notes: notes)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func simulateGeoImpact() {
        let simulator = GeoBlockSimulationService()
        geoSimulation = simulator.simulate(
            countries: geoCountries.filter(\.isEnabled),
            ranges: geoRanges.filter(\.isEnabled),
            connections: liveConnectionsViewModel.connections,
            allowlist: allowlist
        )
    }

    public func applyRulesIfAllowed() async {
        if settings.confirmBeforeApplying {
            pendingApplyConfirmation = true
            return
        }
        await applyRules()
    }

    public func applyRules() async {
        do {
            try database.insertEvent(type: "PF reload attempted", message: "Applying app anchor", detail: settings.anchorPath, succeeded: true)
            try await firewallService.apply(anchorText: rulePreview, settings: settings)
            try database.insertEvent(type: "PF reload succeeded", message: "Applied app anchor", detail: settings.anchorName, succeeded: true)
            reload()
        } catch {
            try? database.insertEvent(type: "PF reload failed", message: "Could not apply app anchor", detail: error.localizedDescription, succeeded: false)
            errorMessage = error.localizedDescription
            reload()
        }
    }

    private func rebuildPreview() {
        rulePreview = generator.rules(for: currentRules(), allowlist: allowlist, settings: settings)
    }

    private func currentRules() -> [BlockRule] {
        let manual = manualBlocks.map {
            BlockRule(group: .manualBlocks, value: $0.address, direction: $0.direction, source: $0.source, note: $0.note, isEnabled: $0.isEnabled)
        }
        let importedBlocklists = Set(blocklists.filter(\.isEnabled).map(\.id))
        let imported = blocklistEntries.filter { importedBlocklists.contains($0.blocklistID) && $0.isEnabled }.map {
            BlockRule(group: .importedBlocklists, value: $0.value, direction: .both, source: .imported, note: $0.warning ?? "", isEnabled: $0.isEnabled)
        }
        let enabledCountries = Dictionary(uniqueKeysWithValues: geoCountries.filter(\.isEnabled).map { ($0.countryCode, $0) })
        let geo = geoRanges.compactMap { range -> BlockRule? in
            guard range.isEnabled, let country = enabledCountries[range.countryCode] else { return nil }
            return BlockRule(group: .importedBlocklists, value: range.cidr, direction: country.direction, source: .imported, note: "Geo block \(country.countryCode): \(country.notes)", isEnabled: true)
        }
        return manual + imported + geo
    }

    private func rebuildSnapshot() {
        let connections = liveConnectionsViewModel.connections
        let remoteCounts = Dictionary(grouping: connections.compactMap(\.remote?.address), by: { $0 }).mapValues(\.count)
        let processCounts = Dictionary(grouping: connections.map(\.processName), by: { $0 }).mapValues(\.count)
        let hourAgo = Date().addingTimeInterval(-3600)
        snapshot = FirewallDashboardSnapshot(
            activeConnections: connections.count,
            blockedIPs: manualBlocks.filter(\.isEnabled).count + blocklistEntries.filter(\.isEnabled).count,
            loadedBlocklists: blocklists.count,
            blocksInLastHour: events.filter { $0.date >= hourAgo && $0.eventType.localizedCaseInsensitiveContains("block") }.count,
            topRemoteIPs: remoteCounts.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) },
            topProcesses: processCounts.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) },
            pfStatus: "unknown",
            lastRuleReload: events.first { $0.eventType == "PF reload succeeded" }?.date
        )
    }
}

public enum FirewallSection: String, CaseIterable, Identifiable, Sendable {
    case dashboard = "Dashboard"
    case liveConnections = "Live Connections"
    case blockedIPs = "Blocked IPs"
    case blocklists = "Blocklists"
    case countryBlocking = "Country Blocking"
    case rules = "Rules"
    case logs = "Logs"
    case settings = "Settings"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .liveConnections: "network"
        case .blockedIPs: "shield"
        case .blocklists: "list.bullet.rectangle"
        case .countryBlocking: "globe"
        case .rules: "curlybraces.square"
        case .logs: "doc.text.magnifyingglass"
        case .settings: "gearshape"
        }
    }
}
