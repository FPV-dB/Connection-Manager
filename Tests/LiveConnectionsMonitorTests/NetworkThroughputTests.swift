import Foundation
import Testing
@testable import LiveConnectionsMonitorCore

@Test func throughputUsesCounterDeltasAndElapsedTime() {
    var calculator = NetworkThroughputCalculator()
    let start = Date(timeIntervalSince1970: 1_000)

    #expect(calculator.sample(
        counters: NetworkByteCounters(received: 10_000, sent: 2_000),
        at: start
    ) == .zero)

    let reading = calculator.sample(
        counters: NetworkByteCounters(received: 14_000, sent: 3_000),
        at: start.addingTimeInterval(2)
    )
    #expect(reading.downloadBytesPerSecond == 2_000)
    #expect(reading.uploadBytesPerSecond == 500)
}

@Test func throughputHandlesInterfaceCounterReset() {
    var calculator = NetworkThroughputCalculator()
    let start = Date(timeIntervalSince1970: 2_000)
    _ = calculator.sample(counters: NetworkByteCounters(received: 100, sent: 100), at: start)

    let reading = calculator.sample(
        counters: NetworkByteCounters(received: 10, sent: 10),
        at: start.addingTimeInterval(1)
    )
    #expect(reading == .zero)
}

@Test func throughputFormatterSwitchesUnits() {
    #expect(ThroughputFormatter.string(bytesPerSecond: 999, unit: .bytes) == "999 B/s")
    #expect(ThroughputFormatter.string(bytesPerSecond: 12_400, unit: .bytes) == "12.4 KB/s")
    #expect(ThroughputFormatter.string(bytesPerSecond: 12_400_000, unit: .bytes) == "12.4 MB/s")
    #expect(ThroughputFormatter.string(bytesPerSecond: 1_800_000_000, unit: .bytes) == "1.8 GB/s")
    #expect(ThroughputFormatter.string(bytesPerSecond: 1_000_000, unit: .bits) == "8.0 Mb/s")
    #expect(ThroughputFormatter.string(bytesPerSecond: 12_400_000, unit: .bytes, compact: true) == "12.4M")
}
