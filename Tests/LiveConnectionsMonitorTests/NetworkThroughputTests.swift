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

@Test func throughputFormatterSupportsFixedRateUnits() {
    #expect(ThroughputRateUnit.allCases.map(\.label).contains("MB/sec"))
    #expect(ThroughputRateUnit.allCases.map(\.label).contains("Gb/sec"))
    #expect(ThroughputFormatter.string(bytesPerSecond: 12_400_000, unit: .kilobytes) == "12400 KB/s")
    #expect(ThroughputFormatter.string(bytesPerSecond: 12_400_000, unit: .megabytes) == "12.4 MB/s")
    #expect(ThroughputFormatter.string(bytesPerSecond: 12_400_000, unit: .gigabytes) == "0.0 GB/s")
    #expect(ThroughputFormatter.string(bytesPerSecond: 1_000_000, unit: .megabits) == "8.0 Mb/s")
}

@Test func menuBarThroughputUsesThreeDigitsAndPromotesUnits() {
    #expect(ThroughputFormatter.menuBarString(bytesPerSecond: 0, unit: .bytes, compact: true) == "000B")
    #expect(ThroughputFormatter.menuBarString(bytesPerSecond: 7, unit: .bytes, compact: true) == "007B")
    #expect(ThroughputFormatter.menuBarString(bytesPerSecond: 42_000, unit: .bytes, compact: true) == "042K")
    #expect(ThroughputFormatter.menuBarString(bytesPerSecond: 999_600, unit: .bytes, compact: true) == "001M")
    #expect(ThroughputFormatter.menuBarString(bytesPerSecond: 12_400_000, unit: .bytes, compact: false) == "012 MB/s")
    #expect(ThroughputFormatter.menuBarString(bytesPerSecond: 1_000_000, unit: .bits, compact: false) == "008 Mb/s")
}

@Test func menuBarThroughputSupportsFixedRateUnits() {
    #expect(ThroughputFormatter.menuBarString(bytesPerSecond: 12_400_000, unit: .kilobytes, compact: true) == "999K")
    #expect(ThroughputFormatter.menuBarString(bytesPerSecond: 12_400_000, unit: .megabytes, compact: false) == "012 MB/s")
    #expect(ThroughputFormatter.menuBarString(bytesPerSecond: 1_000_000, unit: .megabits, compact: false) == "008 Mb/s")
}

@Test func dataMilestoneThresholdConversionUsesBinaryUnits() {
    #expect(DataMilestoneUnit.bytes(value: 1, unit: .kb) == 1_024)
    #expect(DataMilestoneUnit.bytes(value: 1, unit: .mb) == 1_048_576)
    #expect(DataMilestoneUnit.bytes(value: 1, unit: .gb) == 1_073_741_824)
    #expect(DataMilestoneUnit.bytes(value: 0.5, unit: .gb) == 536_870_912)
}

@Test func dataMilestoneTracksDownloadOnly() {
    let settings = DataMilestoneSettings(enabled: true, direction: .download, thresholdBytes: 1_000)
    var state = DataMilestoneState(accumulatedBytes: 0, nextMilestoneBytes: 1_000)
    let decision = DataMilestonePlanner.resolve(
        settings: settings,
        state: &state,
        downloadBytes: 400,
        uploadBytes: 900,
        at: Date(timeIntervalSince1970: 1)
    )

    #expect(decision.shouldPlaySound == false)
    #expect(state.accumulatedBytes == 400)
    #expect(state.nextMilestoneBytes == 1_000)
}

@Test func dataMilestoneTracksUploadOnly() {
    let settings = DataMilestoneSettings(enabled: true, direction: .upload, thresholdBytes: 1_000)
    var state = DataMilestoneState(accumulatedBytes: 0, nextMilestoneBytes: 1_000)
    let decision = DataMilestonePlanner.resolve(
        settings: settings,
        state: &state,
        downloadBytes: 900,
        uploadBytes: 400,
        at: Date(timeIntervalSince1970: 1)
    )

    #expect(decision.shouldPlaySound == false)
    #expect(state.accumulatedBytes == 400)
}

@Test func dataMilestoneTracksCombinedTraffic() {
    let settings = DataMilestoneSettings(enabled: true, direction: .combined, thresholdBytes: 1_000)
    var state = DataMilestoneState(accumulatedBytes: 0, nextMilestoneBytes: 1_000)
    let decision = DataMilestonePlanner.resolve(
        settings: settings,
        state: &state,
        downloadBytes: 600,
        uploadBytes: 500,
        at: Date(timeIntervalSince1970: 1)
    )

    #expect(decision.shouldPlaySound == true)
    #expect(decision.crossedMilestone == true)
    #expect(state.accumulatedBytes == 1_100)
    #expect(state.nextMilestoneBytes == 2_000)
}

@Test func dataMilestoneCrossesOneMilestone() {
    let settings = DataMilestoneSettings(enabled: true, direction: .download, thresholdBytes: 1_000)
    var state = DataMilestoneState(accumulatedBytes: 900, nextMilestoneBytes: 1_000)
    let decision = DataMilestonePlanner.resolve(
        settings: settings,
        state: &state,
        downloadBytes: 100,
        uploadBytes: 0,
        at: Date(timeIntervalSince1970: 1)
    )

    #expect(decision.shouldPlaySound == true)
    #expect(state.accumulatedBytes == 1_000)
    #expect(state.nextMilestoneBytes == 2_000)
}

@Test func dataMilestoneJumpAcrossMultipleMilestonesPlaysOnceAndAdvances() {
    let settings = DataMilestoneSettings(enabled: true, direction: .download, thresholdBytes: 1_000)
    var state = DataMilestoneState(accumulatedBytes: 900, nextMilestoneBytes: 1_000)
    let decision = DataMilestonePlanner.resolve(
        settings: settings,
        state: &state,
        downloadBytes: 3_600,
        uploadBytes: 0,
        at: Date(timeIntervalSince1970: 1)
    )

    #expect(decision.shouldPlaySound == true)
    #expect(state.accumulatedBytes == 4_500)
    #expect(state.nextMilestoneBytes == 5_000)
}

@MainActor
@Test func dataMilestoneResetClearsProgress() {
    let defaults = UserDefaults(suiteName: "DataMilestoneReset-\(UUID().uuidString)")!
    let manager = DataMilestoneSoundManager(defaults: defaults, player: MockMilestonePlayer())
    manager.enabled = true
    manager.thresholdValue = 1
    manager.thresholdUnit = .mb
    manager.record(downloadBytes: 2_000, uploadBytes: 0, at: Date(timeIntervalSince1970: 1))

    manager.resetCounter()

    #expect(manager.accumulatedBytes == 0)
    #expect(manager.nextMilestoneBytes == manager.thresholdBytes)
    #expect(manager.lastSoundTime == nil)
}

@Test func dataMilestoneDisabledStateDoesNotAccumulateOrPlay() {
    let settings = DataMilestoneSettings(enabled: false, direction: .combined, thresholdBytes: 1_000)
    var state = DataMilestoneState(accumulatedBytes: 900, nextMilestoneBytes: 1_000)
    let decision = DataMilestonePlanner.resolve(
        settings: settings,
        state: &state,
        downloadBytes: 10_000,
        uploadBytes: 10_000,
        at: Date(timeIntervalSince1970: 1)
    )

    #expect(decision.shouldPlaySound == false)
    #expect(decision.crossedMilestone == false)
    #expect(state.accumulatedBytes == 900)
    #expect(state.nextMilestoneBytes == 1_000)
}

@Test func dataMilestoneCooldownStillAdvancesWithoutPlaying() {
    let settings = DataMilestoneSettings(enabled: true, direction: .download, thresholdBytes: 1_000, cooldownSeconds: 10)
    var state = DataMilestoneState(
        accumulatedBytes: 900,
        nextMilestoneBytes: 1_000,
        lastSoundTime: Date(timeIntervalSince1970: 5)
    )
    let decision = DataMilestonePlanner.resolve(
        settings: settings,
        state: &state,
        downloadBytes: 200,
        uploadBytes: 0,
        at: Date(timeIntervalSince1970: 8)
    )

    #expect(decision.shouldPlaySound == false)
    #expect(decision.crossedMilestone == true)
    #expect(state.accumulatedBytes == 1_100)
    #expect(state.nextMilestoneBytes == 2_000)
    #expect(state.lastSoundTime == Date(timeIntervalSince1970: 5))
}

private final class MockMilestonePlayer: DataMilestoneSoundPlaying {
    private(set) var playCount = 0

    func play(selection: DataMilestoneSoundSelection, systemSoundName: String, customSoundURL: URL?, volume: Double) {
        playCount += 1
    }
}
