import SwiftUI

public struct LiveConnectionsView: View {
    @ObservedObject private var viewModel: LiveConnectionsViewModel

    public init(viewModel: LiveConnectionsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                connectionTable
                Divider()
                BlockedIPsView(blockedIPs: viewModel.blockedIPs) { ip in
                    Task { await viewModel.unblock(ip: ip) }
                }
                .frame(width: 260)
            }
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.08))
            }
        }
        .navigationTitle("Connections")
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .alert("Block Remote IP?", isPresented: Binding(
            get: { viewModel.pendingBlockIP != nil },
            set: { if !$0 { viewModel.pendingBlockIP = nil } }
        )) {
            Button("Cancel", role: .cancel) { viewModel.pendingBlockIP = nil }
            Button("Block", role: .destructive) {
                if let ip = viewModel.pendingBlockIP {
                    Task { await viewModel.confirmBlock(ip: ip) }
                }
                viewModel.pendingBlockIP = nil
            }
        } message: {
            Text("Block all traffic to and from \(viewModel.pendingBlockIP ?? "this host")? This may disrupt active network activity for that host.")
        }
        .alert("Default Gateway", isPresented: Binding(
            get: { viewModel.pendingGatewayOverrideIP != nil },
            set: { if !$0 { viewModel.pendingGatewayOverrideIP = nil } }
        )) {
            Button("Cancel", role: .cancel) { viewModel.pendingGatewayOverrideIP = nil }
            Button("Block Gateway Anyway", role: .destructive) {
                if let ip = viewModel.pendingGatewayOverrideIP {
                    Task { await viewModel.confirmBlock(ip: ip) }
                }
                viewModel.pendingGatewayOverrideIP = nil
            }
        } message: {
            Text("\(viewModel.pendingGatewayOverrideIP ?? "This IP") appears to be your default gateway. Blocking it can disconnect this Mac from the network.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Label("Connections", systemImage: "network")
                .font(.headline)
            TextField("Search process, IP, port, protocol", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 260)
            Picker("Interval", selection: $viewModel.refreshInterval) {
                ForEach(RefreshInterval.allCases) { interval in
                    Text(interval.rawValue).tag(interval)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 360)
            Button {
                Task { await viewModel.refreshNow() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Button {
                Task { await viewModel.requestBlockSelectedConnection() }
            } label: {
                Label("Block Remote IP", systemImage: "hand.raised.fill")
            }
            .disabled(viewModel.selectedConnection?.remote?.address == nil)
            Spacer()
            if viewModel.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
            Text("Last refreshed: \(viewModel.lastRefreshedAt.map(Self.timeFormatter.string(from:)) ?? "-")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(12)
    }

    private var connectionTable: some View {
        Table(viewModel.filteredConnections, selection: $viewModel.selectedConnectionID) {
            TableColumn("Process") { connection in
                connectionCell(connection) {
                    Text(connection.processName)
                        .lineLimit(1)
                }
            }
            TableColumn("PID") { connection in
                connectionCell(connection) {
                    Text(connection.pid.map(String.init) ?? "-")
                        .monospacedDigit()
                }
            }
            TableColumn("Protocol") { connection in
                connectionCell(connection) {
                    Text(connection.protocolKind.rawValue)
                }
            }
            TableColumn("Direction") { connection in
                connectionCell(connection) {
                    Text(connection.direction.rawValue)
                }
            }
            TableColumn("Local") { connection in
                connectionCell(connection) {
                    endpointText(connection.local)
                }
            }
            TableColumn("Remote") { connection in
                connectionCell(connection) {
                    if let remote = connection.remote {
                        endpointText(remote)
                    } else {
                        Text("-")
                    }
                }
            }
            TableColumn("State") { connection in
                connectionCell(connection) {
                    Text(connection.state.isEmpty ? "-" : connection.state)
                }
            }
            TableColumn("First Seen") { connection in
                connectionCell(connection) {
                    Text(Self.timeFormatter.string(from: connection.firstSeen))
                        .monospacedDigit()
                }
            }
            TableColumn("Last Seen") { connection in
                connectionCell(connection) {
                    Text(Self.timeFormatter.string(from: connection.lastSeen))
                        .monospacedDigit()
                }
            }
        }
        .transaction { $0.animation = nil }
    }

    private func connectionCell<Content: View>(
        _ connection: NetworkConnection,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu {
                if let remoteIP = connection.remote?.address, !remoteIP.isEmpty {
                    if viewModel.blockedIPs.contains(remoteIP) {
                        Button {
                            Task { await viewModel.unblock(ip: remoteIP) }
                        } label: {
                            Label("Unblock \(remoteIP)", systemImage: "lock.open")
                        }
                    } else {
                        Button {
                            Task { await viewModel.requestBlock(connection: connection) }
                        } label: {
                            Label("Block \(remoteIP)", systemImage: "hand.raised.fill")
                        }
                    }
                } else {
                    Button("No Remote IP") {}
                        .disabled(true)
                }
            }
    }

    private func endpointText(_ endpoint: NetworkEndpoint) -> some View {
        Text(endpoint.port.isEmpty ? endpoint.address : "\(endpoint.address):\(endpoint.port)")
            .font(.system(.body, design: .monospaced))
            .lineLimit(1)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()
}

public struct BlockedIPsView: View {
    let blockedIPs: [String]
    let unblock: (String) -> Void

    public init(blockedIPs: [String], unblock: @escaping (String) -> Void) {
        self.blockedIPs = blockedIPs
        self.unblock = unblock
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Blocked IPs", systemImage: "shield")
                .font(.headline)
            if blockedIPs.isEmpty {
                Text("No PF blocks managed by this app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                List(blockedIPs, id: \.self) { ip in
                    HStack {
                        Text(ip)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Button {
                            unblock(ip)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Unblock \(ip)")
                    }
                }
            }
            Spacer()
            Text("PF anchor: \(FirewallBlockService.anchorName)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }
}
