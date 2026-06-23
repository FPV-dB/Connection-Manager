import AppKit
import Charts
import SwiftUI

public struct ApplicationsNetworkView: View {
    @ObservedObject private var viewModel: ApplicationNetworkViewModel
    @State private var confirmingQuit = false

    public init(viewModel: ApplicationNetworkViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        HSplitView {
            appList
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 430)
            Group {
                if let app = viewModel.selectedApp {
                    detail(for: app)
                } else {
                    ContentUnavailableView("Select an application", systemImage: "app.badge", description: Text("Choose a running or recently closed app to inspect its network activity."))
                }
            }
            .frame(minWidth: 700)
        }
        .onAppear { viewModel.start() }
        .alert("Quit \(viewModel.selectedApp?.appName ?? "application")?", isPresented: $confirmingQuit) {
            Button("Cancel", role: .cancel) {}
            Button("Quit App", role: .destructive) { viewModel.quitSelectedApp() }
        } message: {
            Text("Unsaved work in this application may be lost.")
        }
        .overlay(alignment: .bottom) {
            if let error = viewModel.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
            }
        }
    }

    private var appList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search applications", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    Toggle("Network activity only", isOn: $viewModel.showOnlyNetworkActivity)
                    Toggle("Include loopback", isOn: $viewModel.includeLoopback)
                    Divider()
                    Picker("Update interval", selection: Binding(get: { viewModel.updateInterval }, set: { viewModel.updateInterval = $0 })) {
                        ForEach(AppMonitorInterval.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("History per app", selection: $viewModel.historyLimit) {
                        ForEach([100, 500, 1_000, 5_000], id: \.self) { Text($0.formatted()).tag($0) }
                    }
                } label: { Image(systemName: "slider.horizontal.3") }
                Button { Task { await viewModel.refreshNow() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.isRefreshing)
            }
            .padding(10)
            Divider()
            List(viewModel.visibleApplications, selection: $viewModel.selectedAppID) { app in
                appRow(app).tag(app.id)
            }
            .listStyle(.sidebar)
            HStack {
                Text("\(viewModel.visibleApplications.count) apps")
                Spacer()
                Text(viewModel.lastUpdatedAt?.formatted(date: .omitted, time: .standard) ?? "Not checked")
            }
            .font(.caption).foregroundStyle(.secondary).padding(8)
        }
    }

    private func appRow(_ app: RunningAppNetworkSummary) -> some View {
        HStack(spacing: 9) {
            Image(nsImage: viewModel.icon(for: app)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(app.appName).lineLimit(1)
                    if !app.isRunning { Text("Not running").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Text("\(app.activeConnectionCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(app.bundleIdentifier ?? "PID \(app.pid)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    Label(rate(app.currentDownloadBps), systemImage: "arrow.down")
                    Label(rate(app.currentUploadBps), systemImage: "arrow.up")
                    Spacer()
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private func detail(for app: RunningAppNetworkSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                detailHeader(app)
                metrics(app)
                policy(app)
                charts
                recentConnections
            }
            .padding(16)
        }
    }

    private func detailHeader(_ app: RunningAppNetworkSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: viewModel.icon(for: app)).resizable().frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 3) {
                HStack { Text(app.appName).font(.title2.weight(.semibold)); statusPill(app.isRunning ? "Running" : "Not running", active: app.isRunning) }
                Text(app.bundleIdentifier ?? "No bundle identifier").font(.callout).foregroundStyle(.secondary)
                Text(app.executablePath ?? "Executable path unavailable").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Text("PID \(app.pid)  •  Team ID: \(app.teamIdentifier ?? "Unavailable")").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Quit App", role: .destructive) { confirmingQuit = true }.disabled(!app.isRunning)
        }
    }

    private func metrics(_ app: RunningAppNetworkSummary) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
            metric("Download", rate(app.currentDownloadBps), "arrow.down")
            metric("Upload", rate(app.currentUploadBps), "arrow.up")
            metric("Downloaded", bytes(app.totalDownloadedBytes), "internaldrive")
            metric("Uploaded", bytes(app.totalUploadedBytes), "externaldrive")
            metric("Active connections", "\(app.activeConnectionCount)", "network")
            metric("Last activity", app.lastSeen?.formatted(date: .abbreviated, time: .standard) ?? "None observed", "clock")
        }
    }

    private func policy(_ app: RunningAppNetworkSummary) -> some View {
        GroupBox("Application Policy") {
            HStack {
                Picker("Rule", selection: Binding(get: { viewModel.rule(for: app) }, set: { viewModel.setRule($0, for: app) })) {
                    Text("Observe").tag(AppRuleAction.observed)
                    Text("Allow").tag(AppRuleAction.allowed)
                    Text("Block").tag(AppRuleAction.manualBlock)
                }
                .pickerStyle(.segmented).frame(width: 300)
                Spacer()
                if !viewModel.capabilities.enforcesPerAppRules {
                    Label("Saved policy; enforcement requires the future Network Extension provider", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(6)
        }
    }

    private var charts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last \(min(300, viewModel.selectedSamples.count)) seconds").font(.headline)
            HStack(spacing: 12) {
                trafficChart(title: "Download", keyPath: \.downloadBps, color: .blue)
                trafficChart(title: "Upload", keyPath: \.uploadBps, color: .orange)
                connectionChart
            }
        }
    }

    private func trafficChart(title: String, keyPath: KeyPath<AppTrafficSample, Double>, color: Color) -> some View {
        GroupBox(title) {
            Chart(viewModel.selectedSamples) { sample in
                AreaMark(x: .value("Time", sample.timestamp), y: .value("Bytes/s", sample[keyPath: keyPath])).foregroundStyle(color.opacity(0.18))
                LineMark(x: .value("Time", sample.timestamp), y: .value("Bytes/s", sample[keyPath: keyPath])).foregroundStyle(color)
            }
            .chartXAxis(.hidden).frame(height: 105).padding(4)
        }
    }

    private var connectionChart: some View {
        GroupBox("Connections") {
            Chart(viewModel.selectedSamples) { sample in
                LineMark(x: .value("Time", sample.timestamp), y: .value("Connections", sample.activeConnectionCount)).foregroundStyle(.green)
            }
            .chartXAxis(.hidden).frame(height: 105).padding(4)
        }
    }

    private var recentConnections: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent Connections").font(.headline)
                TextField("Search connections", text: $viewModel.connectionSearchText).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Picker("Filter", selection: $viewModel.connectionFilter) {
                    ForEach(AppConnectionFilter.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 140)
                Spacer()
                Button("Clear History", role: .destructive) { viewModel.clearSelectedHistory() }
                Button("Export CSV") { viewModel.exportSelectedHistory() }.disabled(viewModel.filteredConnections.isEmpty)
            }
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    connectionGrid(header: true)
                    Divider()
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.filteredConnections) { record in
                            connectionGrid(record: record)
                            Divider()
                        }
                    }
                }
            }
            .frame(minHeight: 240, maxHeight: 420)
            .background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 6))
            if !viewModel.capabilities.suppliesPerFlowBytes {
                Text("Per-flow byte counts, reverse DNS, GeoIP, and definitive inbound/outbound attribution will populate when a richer Network Extension provider is connected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func connectionGrid(header: Bool = false, record: AppConnectionRecord? = nil) -> some View {
        Grid(horizontalSpacing: 10) {
            GridRow {
                gridCell(header ? "Time" : record?.timestamp.formatted(date: .omitted, time: .standard) ?? "", 85, header)
                gridCell(header ? "Direction" : record?.direction.rawValue.capitalized ?? "", 75, header)
                gridCell(header ? "Protocol" : record?.protocolKind.rawValue ?? "", 60, header)
                gridCell(header ? "Local address" : record?.localAddress ?? "", 155, header)
                gridCell(header ? "Port" : record?.localPort ?? "", 55, header)
                gridCell(header ? "Remote address" : record?.remoteAddress ?? "-", 155, header)
                gridCell(header ? "Port" : record?.remotePort ?? "-", 55, header)
                gridCell(header ? "Hostname" : record?.remoteHostname ?? "-", 150, header)
                gridCell(header ? "Country" : record?.countryCode ?? "-", 65, header)
                gridCell(header ? "State" : record?.state ?? "", 90, header)
                gridCell(header ? "Sent" : record?.bytesSent.map(bytes) ?? "-", 80, header)
                gridCell(header ? "Received" : record?.bytesReceived.map(bytes) ?? "-", 80, header)
                gridCell(header ? "Duration" : record.map { String(format: "%.1fs", $0.duration) } ?? "", 70, header)
                gridCell(header ? "Rule matched" : record?.ruleAction.label ?? "", 105, header)
            }
        }.padding(.horizontal, 8).padding(.vertical, header ? 7 : 5)
    }

    private func gridCell(_ value: String, _ width: CGFloat, _ header: Bool) -> some View {
        Text(value).font(header ? .caption.weight(.semibold) : .caption.monospaced()).lineLimit(1).frame(width: width, alignment: .leading)
    }

    private func metric(_ title: String, _ value: String, _ symbol: String) -> some View {
        GroupBox { VStack(alignment: .leading, spacing: 5) { Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary); Text(value).font(.headline.monospacedDigit()).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading).padding(3) }
    }

    private func statusPill(_ text: String, active: Bool) -> some View {
        Text(text).font(.caption.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 2).background(active ? Color.green.opacity(0.16) : Color.secondary.opacity(0.14)).clipShape(Capsule())
    }

    private func rate(_ value: Double) -> String { "\(ByteCountFormatter.string(fromByteCount: Int64(max(0, value).rounded()), countStyle: .binary))/s" }
    private func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .binary) }
}
