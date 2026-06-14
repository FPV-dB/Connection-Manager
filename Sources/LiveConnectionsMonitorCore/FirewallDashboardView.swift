import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct FirewallDashboardView: View {
    @ObservedObject private var viewModel: FirewallDashboardViewModel
    @State private var showingImporter = false
    @State private var showingCountryImporter = false
    @State private var manualValue = ""
    @State private var allowValue = ""
    @State private var countryCode = ""
    @State private var countryName = ""
    @State private var countrySource = ""
    @State private var countryNotes = ""
    @State private var dontShowLookupWarningAgain = false
    @State private var dontShowTracerouteWarningAgain = false

    public init(viewModel: FirewallDashboardViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $viewModel.selectedSection) {
                ForEach(FirewallSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .navigationTitle("Firewall")
        } detail: {
            Group {
                switch viewModel.selectedSection ?? .dashboard {
                case .dashboard:
                    dashboard
                case .liveConnections:
                    FirewallLiveConnectionsPage(viewModel: viewModel)
                case .blockedIPs:
                    blockedIPs
                case .blocklists:
                    blocklists
                case .countryBlocking:
                    countryBlocking
                case .rules:
                    RulesPreviewView(rulePreview: viewModel.rulePreview) {
                        Task { await viewModel.applyRulesIfAllowed() }
                    }
                case .logs:
                    logs
                case .settings:
                    FirewallSettingsView(settings: $viewModel.settings) {
                        viewModel.saveSettings()
                    }
                }
            }
            .navigationTitle(viewModel.selectedSection?.rawValue ?? "Dashboard")
            .toolbar {
                Button {
                    viewModel.reload()
                    Task { await viewModel.liveConnectionsViewModel.refreshNow() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .onAppear {
            viewModel.liveConnectionsViewModel.start()
            viewModel.reload()
        }
        .alert("Apply PF Rules?", isPresented: $viewModel.pendingApplyConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Apply", role: .destructive) {
                Task { await viewModel.applyRules() }
            }
        } message: {
            Text("This writes and reloads only the app-managed PF anchor. Administrator permission will be requested.")
        }
        .sheet(isPresented: $viewModel.showLookupPrivacyWarning) {
            VStack(alignment: .leading, spacing: 14) {
                Label("Third-party lookup", systemImage: "globe")
                    .font(.title3.weight(.semibold))
                Text("GeoIP/reputation lookup opens a third-party website and sends the selected IP address to that service. Only use this for IPs you intend to investigate.")
                Text("GeoIP results are approximate and can be wrong due to VPNs, CDNs, proxies, cloud hosting, and mobile networks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Don't show again", isOn: $dontShowLookupWarningAgain)
                HStack {
                    Spacer()
                    Button("Cancel") {
                        dontShowLookupWarningAgain = false
                        viewModel.cancelPendingLookup()
                    }
                    Button("Open Lookup") {
                        viewModel.openPendingLookup(dontShowAgain: dontShowLookupWarningAgain)
                        dontShowLookupWarningAgain = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(width: 460)
        }
        .sheet(isPresented: $viewModel.showTracerouteWarning) {
            VStack(alignment: .leading, spacing: 14) {
                Label("Traceroute", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.title3.weight(.semibold))
                Text("Traceroute sends network probes toward the selected host. It may be logged by intermediate networks and may be blocked or misleading.")
                Toggle("Don't show again", isOn: $dontShowTracerouteWarningAgain)
                HStack {
                    Spacer()
                    Button("Cancel") {
                        dontShowTracerouteWarningAgain = false
                        viewModel.showTracerouteWarning = false
                    }
                    Button("Run Traceroute") {
                        viewModel.confirmTraceroute(dontShowAgain: dontShowTracerouteWarningAgain)
                        dontShowTracerouteWarningAgain = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(width: 460)
        }
        .overlay(alignment: .bottom) {
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
            }
        }
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    summaryCard("Active connections", "\(viewModel.snapshot.activeConnections)", "network")
                    summaryCard("Blocked IPs", "\(viewModel.snapshot.blockedIPs)", "shield")
                    summaryCard("Loaded blocklists", "\(viewModel.snapshot.loadedBlocklists)", "list.bullet.rectangle")
                    summaryCard("Blocks last hour", "\(viewModel.snapshot.blocksInLastHour)", "clock")
                    summaryCard("PF status", viewModel.snapshot.pfStatus, "switch.2")
                    summaryCard("Last reload", viewModel.snapshot.lastRuleReload.map(Self.dateFormatter.string(from:)) ?? "-", "arrow.triangle.2.circlepath")
                }
                HStack(alignment: .top, spacing: 12) {
                    topList("Top remote IPs", rows: viewModel.snapshot.topRemoteIPs)
                    topList("Top processes", rows: viewModel.snapshot.topProcesses)
                }
            }
            .padding(18)
        }
    }

    private var blockedIPs: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("IP or CIDR", text: $manualValue)
                    .textFieldStyle(.roundedBorder)
                Button("Add Manual Block") {
                    viewModel.addManualBlock(manualValue)
                    manualValue = ""
                }
                .disabled(manualValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Table(viewModel.manualBlocks) {
                TableColumn("IP") { Text($0.address).font(.system(.body, design: .monospaced)) }
                TableColumn("Direction") { Text($0.direction.rawValue) }
                TableColumn("Source") { Text($0.source.rawValue) }
                TableColumn("Note") { Text($0.note) }
                TableColumn("Added") { Text(Self.dateFormatter.string(from: $0.dateAdded)) }
                TableColumn("Enabled") { block in
                    Toggle("", isOn: Binding(get: { block.isEnabled }, set: { viewModel.setManualBlockEnabled(id: block.id, enabled: $0) }))
                }
                TableColumn("Delete") { block in
                    Button("Unblock") { viewModel.deleteManualBlock(id: block.id) }
                }
            }
            Divider()
            HStack {
                TextField("Trusted allowlist IP/CIDR", text: $allowValue)
                    .textFieldStyle(.roundedBorder)
                Button("Add Allowlist") {
                    viewModel.addAllowlist(allowValue)
                    allowValue = ""
                }
            }
            Table(viewModel.allowlist) {
                TableColumn("Allowlisted") { Text($0.value).font(.system(.body, design: .monospaced)) }
                TableColumn("Note") { Text($0.note) }
                TableColumn("Delete") { entry in Button("Remove") { viewModel.deleteAllowlist(id: entry.id) } }
            }
            .frame(height: 150)
        }
        .padding(14)
    }

    private var blocklists: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    showingImporter = true
                } label: {
                    Label("Import Blocklist", systemImage: "square.and.arrow.down")
                }
                if !viewModel.importWarnings.isEmpty {
                    Text("\(viewModel.importWarnings.count) private/reserved warnings")
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            Table(viewModel.blocklists) {
                TableColumn("Name") { Text($0.name) }
                TableColumn("File") { Text($0.sourceFilename) }
                TableColumn("Entries") { Text("\($0.entryCount)").monospacedDigit() }
                TableColumn("Imported") { Text(Self.dateFormatter.string(from: $0.importedAt)) }
                TableColumn("Enabled") { list in
                    Toggle("", isOn: Binding(get: { list.isEnabled }, set: { viewModel.setBlocklistEnabled(id: list.id, enabled: $0) }))
                }
                TableColumn("Last Applied") { Text($0.lastAppliedAt.map(Self.dateFormatter.string(from:)) ?? "-") }
            }
            if !viewModel.importWarnings.isEmpty {
                Text(viewModel.importWarnings.prefix(6).joined(separator: "\n"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.plainText, .commaSeparatedText, UTType(filenameExtension: "ip") ?? .plainText, UTType(filenameExtension: "list") ?? .plainText]) { result in
            if case let .success(url) = result {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                viewModel.importBlocklist(url: url)
            }
        }
    }

    private var countryBlocking: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Country-level blocking is opt-in", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("Country-level blocking is broad and may block legitimate services, cloud platforms, CDNs, VPN endpoints, software updates, and ordinary users. Import only data you are licensed or allowed to use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                TextField("Code, e.g. AU", text: $countryCode)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                TextField("Country name", text: $countryName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                TextField("Source", text: $countrySource)
                    .textFieldStyle(.roundedBorder)
                TextField("Notes/reason", text: $countryNotes)
                    .textFieldStyle(.roundedBorder)
                Button("Import Country List") { showingCountryImporter = true }
                    .disabled(countryCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let progress = viewModel.countryImportProgress {
                Text(progress).font(.caption).foregroundStyle(.secondary)
            }
            Table(viewModel.geoCountries) {
                TableColumn("Country") { Text($0.countryName) }
                TableColumn("Code") { Text($0.countryCode).font(.system(.body, design: .monospaced)) }
                TableColumn("IPv4") { Text("\($0.ipv4RangeCount)").monospacedDigit() }
                TableColumn("IPv6") { Text("\($0.ipv6RangeCount)").monospacedDigit() }
                TableColumn("Enabled") { country in
                    Toggle("", isOn: Binding(
                        get: { country.isEnabled },
                        set: { viewModel.setGeoCountryEnabled(code: country.countryCode, enabled: $0) }
                    ))
                }
                TableColumn("Direction") { country in
                    Picker("", selection: Binding(
                        get: { country.direction },
                        set: { viewModel.setGeoCountryDirection(code: country.countryCode, direction: $0) }
                    )) {
                        ForEach(FirewallDirection.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                TableColumn("Last imported") { Text($0.lastImportedAt.map(Self.dateFormatter.string(from:)) ?? "-") }
                TableColumn("Source") { Text($0.sourceName) }
                TableColumn("Rule estimate") { Text("\($0.ruleCountEstimate)").monospacedDigit() }
                TableColumn("Notes") { country in
                    TextField("Notes", text: Binding(
                        get: { country.notes },
                        set: { viewModel.setGeoCountryNotes(code: country.countryCode, notes: $0) }
                    ))
                }
            }
            HStack {
                Button("Simulate Impact") { viewModel.simulateGeoImpact() }
                Button("Preview Rules") {
                    viewModel.simulateGeoImpact()
                    viewModel.selectedSection = .rules
                }
                Button("Apply Rules") {
                    viewModel.simulateGeoImpact()
                    Task { await viewModel.applyRulesIfAllowed() }
                }
                Spacer()
                Text("Estimated geo rules: \(viewModel.geoCountries.filter(\.isEnabled).reduce(0) { $0 + $1.ruleCountEstimate })")
                    .font(.caption)
                    .monospacedDigit()
            }
            geoSimulationSummary
        }
        .padding(14)
        .fileImporter(isPresented: $showingCountryImporter, allowedContentTypes: [.plainText, .commaSeparatedText, UTType(filenameExtension: "zone") ?? .plainText, UTType(filenameExtension: "cidr") ?? .plainText, UTType(filenameExtension: "list") ?? .plainText]) { result in
            if case let .success(url) = result {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                viewModel.importCountryList(
                    url: url,
                    countryCode: countryCode,
                    countryName: countryName.isEmpty ? countryCode.uppercased() : countryName,
                    sourceName: countrySource.isEmpty ? url.lastPathComponent : countrySource,
                    notes: countryNotes
                )
            }
        }
    }

    private var geoSimulationSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Simulation").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
                summaryCard("Countries", "\(viewModel.geoSimulation.selectedCountries.count)", "globe")
                summaryCard("CIDR ranges", "\(viewModel.geoSimulation.cidrRangeCount)", "number")
                summaryCard("PF rules", "\(viewModel.geoSimulation.generatedRuleCount)", "curlybraces")
                summaryCard("Anchor size", "\(viewModel.geoSimulation.estimatedAnchorBytes) bytes", "doc")
                summaryCard("Affected connections", "\(viewModel.geoSimulation.affectedConnections.count)", "bolt.horizontal")
                summaryCard("Allowlist exemptions", "\(viewModel.geoSimulation.allowlistExemptions)", "checkmark.shield")
            }
            if !viewModel.geoSimulation.affectedProcesses.isEmpty {
                Text("Affected processes: \(viewModel.geoSimulation.affectedProcesses.map { "\($0.0) (\($0.1))" }.joined(separator: ", "))")
                    .font(.caption)
            }
            ForEach(viewModel.geoSimulation.warnings, id: \.self) { warning in
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var logs: some View {
        Table(viewModel.events) {
            TableColumn("Time") { Text(Self.dateFormatter.string(from: $0.date)) }
            TableColumn("Event") { Text($0.eventType) }
            TableColumn("Message") { Text($0.message) }
            TableColumn("Detail") { Text($0.detail) }
            TableColumn("Result") { Text($0.succeeded ? "ok" : "failed").foregroundStyle($0.succeeded ? .green : .red) }
        }
        .padding(14)
    }

    private func summaryCard(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func topList(_ title: String, rows: [(String, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(rows, id: \.0) { row in
                HStack {
                    Text(row.0).font(.system(.body, design: .monospaced)).lineLimit(1)
                    Spacer()
                    Text("\(row.1)").monospacedDigit()
                }
            }
            if rows.isEmpty {
                Text("No data yet").foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
}

public struct FirewallLiveConnectionsPage: View {
    @ObservedObject var viewModel: FirewallDashboardViewModel

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            HSplitView {
                connectionTable
                detailsPanel
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
            }
        }
    }

    private var toolbar: some View {
        HStack {
            TextField("Search process, IP, port, protocol", text: Binding(
                get: { viewModel.liveConnectionsViewModel.searchText },
                set: { viewModel.liveConnectionsViewModel.searchText = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            Picker("Interval", selection: Binding(
                get: { viewModel.liveConnectionsViewModel.refreshInterval },
                set: { viewModel.liveConnectionsViewModel.refreshInterval = $0 }
            )) {
                ForEach(RefreshInterval.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 360)
            Button("Geo Lookup") { viewModel.requestLookup() }
                .disabled(!canLookupSelected)
            Menu("Lookup With...") {
                providerButtons()
            }
            .disabled(!canLookupSelected)
            Button("Copy IP") { viewModel.copySelectedRemoteIP() }
                .disabled(viewModel.liveConnectionsViewModel.selectedConnection?.remote?.address == nil)
            Button("Block IP") { blockSelected() }
                .disabled(viewModel.liveConnectionsViewModel.selectedConnection?.remote?.address == nil)
            Button("Refresh") { Task { await viewModel.liveConnectionsViewModel.refreshNow() } }
            Text("Last refreshed: \(viewModel.liveConnectionsViewModel.lastRefreshedAt.map(Self.timeFormatter.string(from:)) ?? "-")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(12)
    }

    private var connectionTable: some View {
        Table(viewModel.liveConnectionsViewModel.filteredConnections, selection: Binding(
            get: { viewModel.liveConnectionsViewModel.selectedConnectionID },
            set: { viewModel.liveConnectionsViewModel.selectedConnectionID = $0 }
        )) {
            TableColumn("Process") { connection in
                Text(connection.processName).lineLimit(1).frame(width: 150, alignment: .leading)
                    .contextMenu { contextMenu(for: connection) }
            }
            .width(150)
            TableColumn("PID") { Text($0.pid.map(String.init) ?? "-").monospacedDigit().frame(width: 64, alignment: .trailing) }
                .width(64)
            TableColumn("Protocol") { Text($0.protocolKind.rawValue).frame(width: 72, alignment: .leading) }
                .width(72)
            TableColumn("Direction") { Text($0.direction.rawValue).frame(width: 92, alignment: .leading) }
                .width(92)
            TableColumn("Local Address") { Text($0.local.address).font(.system(.body, design: .monospaced)).lineLimit(1).frame(width: 160, alignment: .leading) }
                .width(160)
            TableColumn("Local Port") { Text($0.local.port).monospacedDigit().frame(width: 76, alignment: .trailing) }
                .width(76)
            TableColumn("Remote Address") { connection in
                Text(connection.remote?.address ?? "-").font(.system(.body, design: .monospaced)).lineLimit(1).frame(width: 170, alignment: .leading)
                    .contextMenu { contextMenu(for: connection) }
            }
            .width(170)
            TableColumn("Remote Port") { Text($0.remote?.port ?? "-").monospacedDigit().frame(width: 84, alignment: .trailing) }
                .width(84)
            TableColumn("State") { Text($0.state.isEmpty ? "-" : $0.state).lineLimit(1).frame(width: 120, alignment: .leading) }
                .width(120)
            TableColumn("Block Status") { connection in
                Text(status(for: connection))
                    .foregroundStyle(status(for: connection) == "blocked" ? .red : .secondary)
                    .frame(width: 92, alignment: .leading)
            }
            .width(92)
        }
        .transaction { $0.animation = nil }
    }

    private var detailsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Connection Details", systemImage: "info.circle")
                .font(.headline)
            if let connection = viewModel.liveConnectionsViewModel.selectedConnection {
                detail("Remote IP", connection.remote?.address ?? "-")
                detail("Remote port", connection.remote?.port ?? "-")
                detail("Process", connection.processName)
                detail("PID", connection.pid.map(String.init) ?? "-")
                detail("Protocol", connection.protocolKind.rawValue)
                detail("State", connection.state.isEmpty ? "-" : connection.state)
                detail("First seen", Self.dateTimeFormatter.string(from: connection.firstSeen))
                detail("Last seen", Self.dateTimeFormatter.string(from: connection.lastSeen))
                Divider()
                HStack {
                    Button("Geo Lookup") { viewModel.requestLookup() }
                        .disabled(!canLookupSelected)
                    Button("Reputation Lookup") { viewModel.requestLookup(providerID: "talos") }
                        .disabled(!canLookupSelected)
                }
                HStack {
                    Button("Open in Browser") { viewModel.requestLookup() }
                        .disabled(!canLookupSelected)
                    Button("Block IP") { blockSelected() }
                        .disabled(connection.remote?.address == nil)
                }
                Button("Copy IP") { viewModel.copySelectedRemoteIP() }
                    .disabled(connection.remote?.address == nil)
                Text("GeoIP and reputation results are approximate and can be wrong due to VPNs, CDNs, proxies, cloud hosting, and mobile networks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Add note", text: $viewModel.selectedConnectionNote, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Divider()
                advancedTools
            } else {
                Text("Select a live connection to inspect lookup and block actions.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.quaternary.opacity(0.25))
    }

    private var advancedTools: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Advanced Network Tools", systemImage: "wrench.and.screwdriver")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                Button("Web Geo Lookup") { viewModel.requestLookup() }
                    .disabled(!canLookupSelected)
                Button("Web Reputation Lookup") { viewModel.requestLookup(providerID: "talos") }
                    .disabled(!canLookupSelected)
                Button("Traceroute") { viewModel.requestTraceroute() }
                    .disabled(!canLookupSelected || viewModel.isNetworkToolRunning)
                Button("Ping") { viewModel.runNetworkTool(.ping) }
                    .disabled(!canLookupSelected || viewModel.isNetworkToolRunning)
                Button("Copy IP") { viewModel.copySelectedRemoteIP() }
                    .disabled(viewModel.liveConnectionsViewModel.selectedConnection?.remote?.address == nil)
            }
            if viewModel.isNetworkToolRunning {
                ProgressView()
                    .controlSize(.small)
            }
            TextEditor(text: Binding(
                get: { viewModel.networkToolOutput },
                set: { viewModel.networkToolOutput = $0 }
            ))
            .font(.system(.caption, design: .monospaced))
            .frame(minHeight: 140)
            .border(.separator)
            HStack {
                Button("Stop") { viewModel.stopNetworkTool() }
                    .disabled(!viewModel.isNetworkToolRunning)
                Button("Copy Output") { viewModel.copyNetworkToolOutput() }
                    .disabled(viewModel.networkToolOutput.isEmpty)
                Button("Save Output") { viewModel.saveNetworkToolOutput() }
                    .disabled(viewModel.networkToolOutput.isEmpty)
            }
        }
    }

    private func status(for connection: NetworkConnection) -> String {
        guard let remote = connection.remote?.address else { return "-" }
        let manual = viewModel.manualBlocks.contains { $0.isEnabled && $0.address == remote }
        let imported = viewModel.blocklistEntries.contains { $0.isEnabled && $0.value == remote }
        let allowed = viewModel.allowlist.contains { $0.isEnabled && $0.value == remote }
        if allowed { return "allowlisted" }
        if manual || imported { return "blocked" }
        return "open"
    }

    @ViewBuilder
    private func providerButtons() -> some View {
        ForEach(LookupProvider.presets) { provider in
            Button("\(provider.name) (\(provider.category.rawValue))") {
                viewModel.requestLookup(providerID: provider.id)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for connection: NetworkConnection) -> some View {
        Button("Geo Lookup") {
            viewModel.liveConnectionsViewModel.selectedConnectionID = connection.id
            viewModel.requestLookup()
        }
        Menu("Lookup with...") {
            ForEach(LookupProvider.presets) { provider in
                Button(provider.name) {
                    viewModel.liveConnectionsViewModel.selectedConnectionID = connection.id
                    viewModel.requestLookup(providerID: provider.id)
                }
            }
        }
        Button("Copy remote IP") {
            viewModel.liveConnectionsViewModel.selectedConnectionID = connection.id
            viewModel.copySelectedRemoteIP()
        }
        Button("Block remote IP") {
            viewModel.liveConnectionsViewModel.selectedConnectionID = connection.id
            blockSelected()
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
    }

    private func blockSelected() {
        if let ip = viewModel.liveConnectionsViewModel.selectedConnection?.remote?.address {
            viewModel.addManualBlock(ip, note: viewModel.selectedConnectionNote.isEmpty ? "Blocked from live connection" : viewModel.selectedConnectionNote)
        }
    }

    private var canLookupSelected: Bool {
        guard let ip = viewModel.liveConnectionsViewModel.selectedConnection?.remote?.address else { return false }
        if case .success = LookupService().canLookup(ip: ip) {
            return true
        }
        return false
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
}

public struct RulesPreviewView: View {
    let rulePreview: String
    let apply: () -> Void

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Generated PF Rules", systemImage: "curlybraces.square")
                    .font(.headline)
                Spacer()
                Button("Apply Anchor") { apply() }
            }
            TextEditor(text: .constant(rulePreview))
                .font(.system(.body, design: .monospaced))
                .border(.separator)
        }
        .padding(14)
    }
}

public struct FirewallSettingsView: View {
    @Binding var settings: FirewallSettings
    let save: () -> Void

    public var body: some View {
        Form {
            Picker("Refresh interval", selection: $settings.refreshInterval) {
                ForEach(RefreshInterval.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Auto-apply imported blocklists", isOn: $settings.autoApplyImportedBlocklists)
            Toggle("Confirm before applying firewall changes", isOn: $settings.confirmBeforeApplying)
            Toggle("Backup previous app anchor file before rewriting", isOn: $settings.backupAnchorBeforeRewrite)
            TextField("PF anchor path", text: $settings.anchorPath)
            TextField("App anchor name", text: $settings.anchorName)
            Picker("Default lookup provider", selection: $settings.defaultLookupProviderID) {
                ForEach(LookupProvider.presets) { provider in
                    Text("\(provider.name) - \(provider.category.rawValue)").tag(provider.id)
                }
            }
            Toggle("Do not show GeoIP/reputation lookup privacy warning again", isOn: $settings.suppressLookupPrivacyWarning)
            Toggle("Do not show traceroute warning again", isOn: $settings.suppressTracerouteWarning)
            Button("Save Settings", action: save)
        }
        .padding(18)
    }
}
