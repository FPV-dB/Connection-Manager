import Combine
import Darwin
import Foundation

public struct NetworkByteCounters: Equatable, Sendable {
    public let received: UInt64
    public let sent: UInt64

    public init(received: UInt64, sent: UInt64) {
        self.received = received
        self.sent = sent
    }
}

public struct NetworkThroughputReading: Equatable, Sendable {
    public let downloadBytesPerSecond: Double
    public let uploadBytesPerSecond: Double

    public static let zero = NetworkThroughputReading(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0)

    public init(downloadBytesPerSecond: Double, uploadBytesPerSecond: Double) {
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
    }
}

public struct NetworkThroughputHistoryPoint: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let reading: NetworkThroughputReading
}

public struct NetworkThroughputCalculator: Sendable {
    private var previousCounters: NetworkByteCounters?
    private var previousDate: Date?

    public init() {}

    public mutating func sample(counters: NetworkByteCounters, at date: Date) -> NetworkThroughputReading {
        defer {
            previousCounters = counters
            previousDate = date
        }

        guard let previousCounters, let previousDate else { return .zero }
        let elapsed = date.timeIntervalSince(previousDate)
        guard elapsed > 0,
              counters.received >= previousCounters.received,
              counters.sent >= previousCounters.sent
        else { return .zero }

        return NetworkThroughputReading(
            downloadBytesPerSecond: Double(counters.received - previousCounters.received) / elapsed,
            uploadBytesPerSecond: Double(counters.sent - previousCounters.sent) / elapsed
        )
    }
}

public enum ThroughputRateUnit: String, CaseIterable, Identifiable, Sendable {
    case bytes
    case bits

    public var id: String { rawValue }
    public var label: String { self == .bytes ? "Bytes/sec" : "Bits/sec" }
}

public enum ThroughputUpdateInterval: Int, CaseIterable, Identifiable, Sendable {
    case one = 1
    case two = 2
    case five = 5

    public var id: Int { rawValue }
    public var label: String { "\(rawValue) second\(rawValue == 1 ? "" : "s")" }
}

public enum ThroughputDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case compact
    case detailed

    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

public enum ThroughputFormatter {
    public static func string(
        bytesPerSecond: Double,
        unit: ThroughputRateUnit,
        compact: Bool = false
    ) -> String {
        let value = max(0, bytesPerSecond) * (unit == .bits ? 8 : 1)
        let units = unit == .bits
            ? ["b/s", "Kb/s", "Mb/s", "Gb/s"]
            : ["B/s", "KB/s", "MB/s", "GB/s"]

        var scaled = value
        var unitIndex = 0
        while scaled >= 1_000, unitIndex < units.count - 1 {
            scaled /= 1_000
            unitIndex += 1
        }

        let number: String
        if unitIndex == 0 && scaled < 10 {
            number = String(format: "%.0f", scaled)
        } else if scaled < 100 {
            number = String(format: "%.1f", scaled)
        } else {
            number = String(format: "%.0f", scaled)
        }

        if compact {
            let suffixes = unit == .bits ? ["b", "K", "M", "G"] : ["B", "K", "M", "G"]
            return number + suffixes[unitIndex]
        }
        return number + " " + units[unitIndex]
    }
}

public protocol NetworkCounterReading: Sendable {
    func readCounters() -> NetworkByteCounters
}

public struct SystemNetworkCounterReader: NetworkCounterReading {
    public init() {}

    public func readCounters() -> NetworkByteCounters {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else {
            return NetworkByteCounters(received: 0, sent: 0)
        }
        defer { freeifaddrs(firstAddress) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var address: UnsafeMutablePointer<ifaddrs>? = firstAddress

        while let current = address {
            let interface = current.pointee
            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0

            if isUp,
               !isLoopback,
               interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
               let rawData = interface.ifa_data {
                let data = rawData.assumingMemoryBound(to: if_data.self).pointee
                received &+= UInt64(data.ifi_ibytes)
                sent &+= UInt64(data.ifi_obytes)
            }
            address = interface.ifa_next
        }

        return NetworkByteCounters(received: received, sent: sent)
    }
}

@MainActor
public final class NetworkThroughputMonitor: ObservableObject {
    public enum DefaultsKey {
        public static let displayEnabled = "throughput.displayEnabled"
        public static let rateUnit = "throughput.rateUnit"
        public static let updateInterval = "throughput.updateInterval"
        public static let displayMode = "throughput.displayMode"
    }

    @Published public private(set) var current = NetworkThroughputReading.zero
    @Published public private(set) var peakDownloadBytesPerSecond = 0.0
    @Published public private(set) var peakUploadBytesPerSecond = 0.0
    @Published public private(set) var history: [NetworkThroughputHistoryPoint] = []

    @Published public var displayEnabled: Bool {
        didSet { defaults.set(displayEnabled, forKey: DefaultsKey.displayEnabled) }
    }
    @Published public var rateUnit: ThroughputRateUnit {
        didSet { defaults.set(rateUnit.rawValue, forKey: DefaultsKey.rateUnit) }
    }
    @Published public var updateInterval: ThroughputUpdateInterval {
        didSet {
            defaults.set(updateInterval.rawValue, forKey: DefaultsKey.updateInterval)
            restartSampling()
        }
    }
    @Published public var displayMode: ThroughputDisplayMode {
        didSet { defaults.set(displayMode.rawValue, forKey: DefaultsKey.displayMode) }
    }

    private let defaults: UserDefaults
    private let counterReader: any NetworkCounterReading
    private var calculator = NetworkThroughputCalculator()
    private var samplingTask: Task<Void, Never>?

    public init(
        defaults: UserDefaults = .standard,
        counterReader: any NetworkCounterReading = SystemNetworkCounterReader()
    ) {
        self.defaults = defaults
        self.counterReader = counterReader
        displayEnabled = defaults.object(forKey: DefaultsKey.displayEnabled) as? Bool ?? true
        rateUnit = ThroughputRateUnit(rawValue: defaults.string(forKey: DefaultsKey.rateUnit) ?? "") ?? .bytes
        updateInterval = ThroughputUpdateInterval(rawValue: defaults.integer(forKey: DefaultsKey.updateInterval)) ?? .one
        displayMode = ThroughputDisplayMode(rawValue: defaults.string(forKey: DefaultsKey.displayMode) ?? "") ?? .detailed
        restartSampling()
    }

    deinit {
        samplingTask?.cancel()
    }

    private func restartSampling() {
        samplingTask?.cancel()
        calculator = NetworkThroughputCalculator()
        sample()
        let nanoseconds = UInt64(updateInterval.rawValue) * 1_000_000_000
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                self?.sample()
            }
        }
    }

    private func sample(at date: Date = Date()) {
        let reading = calculator.sample(counters: counterReader.readCounters(), at: date)
        current = reading
        peakDownloadBytesPerSecond = max(peakDownloadBytesPerSecond, reading.downloadBytesPerSecond)
        peakUploadBytesPerSecond = max(peakUploadBytesPerSecond, reading.uploadBytesPerSecond)
        history.append(NetworkThroughputHistoryPoint(timestamp: date, reading: reading))
        history.removeAll { date.timeIntervalSince($0.timestamp) > 60 }
    }
}
