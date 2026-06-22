import SwiftUI

public struct ThroughputMenuBarLabel: View {
    @ObservedObject private var monitor: NetworkThroughputMonitor

    public init(monitor: NetworkThroughputMonitor) {
        self.monitor = monitor
    }

    public var body: some View {
        if monitor.displayEnabled {
            if monitor.displayMode == .compact {
                Text("D:\(compactDownload) U:\(compactUpload)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .fixedSize()
            } else {
                Text("\(Image(systemName: "arrow.down")) \(download)  \(Image(systemName: "arrow.up")) \(upload)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .fixedSize()
            }
        } else {
            Image(systemName: "network")
        }
    }

    private var download: String {
        ThroughputFormatter.string(bytesPerSecond: monitor.current.downloadBytesPerSecond, unit: monitor.rateUnit)
    }

    private var upload: String {
        ThroughputFormatter.string(bytesPerSecond: monitor.current.uploadBytesPerSecond, unit: monitor.rateUnit)
    }

    private var compactDownload: String {
        ThroughputFormatter.string(bytesPerSecond: monitor.current.downloadBytesPerSecond, unit: monitor.rateUnit, compact: true)
    }

    private var compactUpload: String {
        ThroughputFormatter.string(bytesPerSecond: monitor.current.uploadBytesPerSecond, unit: monitor.rateUnit, compact: true)
    }
}

public struct NetworkThroughputPopover: View {
    @ObservedObject private var monitor: NetworkThroughputMonitor
    private let showConnections: () -> Void
    private let refreshConnections: () -> Void
    private let quit: () -> Void

    public init(
        monitor: NetworkThroughputMonitor,
        showConnections: @escaping () -> Void,
        refreshConnections: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        self.monitor = monitor
        self.showConnections = showConnections
        self.refreshConnections = refreshConnections
        self.quit = quit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Network Throughput", systemImage: "network")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
                Text("Live")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                metricRow("Download", systemImage: "arrow.down", value: currentDownload, color: .blue)
                metricRow("Upload", systemImage: "arrow.up", value: currentUpload, color: .green)
                Divider().gridCellColumns(3)
                metricRow("Peak download", systemImage: "arrow.down.to.line", value: peakDownload, color: .blue)
                metricRow("Peak upload", systemImage: "arrow.up.to.line", value: peakUpload, color: .green)
            }

            ThroughputGraph(history: monitor.history)
                .frame(height: 82)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
                .overlay(alignment: .topLeading) {
                    Text("Last 60 seconds")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(6)
                }

            HStack {
                Button("Show Connections", action: showConnections)
                    .buttonStyle(.borderedProminent)
                Button {
                    refreshConnections()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("Refresh connections")
                Spacer()
                Button("Quit", action: quit)
            }
        }
        .padding(14)
        .frame(width: 350)
    }

    private func metricRow(_ title: String, systemImage: String, value: String, color: Color) -> some View {
        GridRow {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 16)
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced).weight(.medium))
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var currentDownload: String {
        ThroughputFormatter.string(bytesPerSecond: monitor.current.downloadBytesPerSecond, unit: monitor.rateUnit)
    }

    private var currentUpload: String {
        ThroughputFormatter.string(bytesPerSecond: monitor.current.uploadBytesPerSecond, unit: monitor.rateUnit)
    }

    private var peakDownload: String {
        ThroughputFormatter.string(bytesPerSecond: monitor.peakDownloadBytesPerSecond, unit: monitor.rateUnit)
    }

    private var peakUpload: String {
        ThroughputFormatter.string(bytesPerSecond: monitor.peakUploadBytesPerSecond, unit: monitor.rateUnit)
    }
}

private struct ThroughputGraph: View {
    let history: [NetworkThroughputHistoryPoint]

    var body: some View {
        Canvas { context, size in
            guard history.count > 1 else { return }
            let maximum = max(
                history.map { $0.reading.downloadBytesPerSecond }.max() ?? 0,
                history.map { $0.reading.uploadBytesPerSecond }.max() ?? 0,
                1
            )
            draw(\.reading.downloadBytesPerSecond, color: .blue, maximum: maximum, context: &context, size: size)
            draw(\.reading.uploadBytesPerSecond, color: .green, maximum: maximum, context: &context, size: size)
        }
        .padding(.horizontal, 5)
        .padding(.top, 18)
        .padding(.bottom, 5)
    }

    private func draw(
        _ keyPath: KeyPath<NetworkThroughputHistoryPoint, Double>,
        color: Color,
        maximum: Double,
        context: inout GraphicsContext,
        size: CGSize
    ) {
        var path = Path()
        for (index, point) in history.enumerated() {
            let x = size.width * CGFloat(index) / CGFloat(max(1, history.count - 1))
            let ratio = min(1, max(0, point[keyPath: keyPath] / maximum))
            let y = size.height * (1 - CGFloat(ratio))
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        context.stroke(path, with: .color(color), lineWidth: 1.5)
    }
}
