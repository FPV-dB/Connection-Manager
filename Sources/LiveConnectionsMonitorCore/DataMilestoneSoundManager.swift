import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

public enum DataMilestoneDirection: String, CaseIterable, Identifiable, Sendable {
    case download
    case upload
    case combined

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .download: "Download only"
        case .upload: "Upload only"
        case .combined: "Upload + Download combined"
        }
    }
}

public enum DataMilestoneUnit: String, CaseIterable, Identifiable, Sendable {
    case kb
    case mb
    case gb
    case tb

    public var id: String { rawValue }
    public var label: String { rawValue.uppercased() }

    public var multiplier: UInt64 {
        switch self {
        case .kb: 1_024
        case .mb: 1_024 * 1_024
        case .gb: 1_024 * 1_024 * 1_024
        case .tb: 1_024 * 1_024 * 1_024 * 1_024
        }
    }

    public static func bytes(value: Double, unit: DataMilestoneUnit) -> UInt64 {
        UInt64(max(1, (value * Double(unit.multiplier)).rounded()))
    }
}

public enum DataMilestoneSoundSelection: String, CaseIterable, Identifiable, Sendable {
    case builtInTick
    case builtInBeep
    case systemSound
    case customFile

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .builtInTick: "Built-in tick"
        case .builtInBeep: "Built-in beep"
        case .systemSound: "macOS system sound"
        case .customFile: "Custom audio file"
        }
    }
}

public struct DataMilestoneSettings: Equatable, Sendable {
    public var enabled: Bool
    public var direction: DataMilestoneDirection
    public var thresholdBytes: UInt64
    public var selectedSound: DataMilestoneSoundSelection
    public var volume: Double
    public var cooldownSeconds: Double

    public init(
        enabled: Bool = false,
        direction: DataMilestoneDirection = .download,
        thresholdBytes: UInt64 = DataMilestoneUnit.bytes(value: 1, unit: .gb),
        selectedSound: DataMilestoneSoundSelection = .builtInTick,
        volume: Double = 0.75,
        cooldownSeconds: Double = 1
    ) {
        self.enabled = enabled
        self.direction = direction
        self.thresholdBytes = max(1, thresholdBytes)
        self.selectedSound = selectedSound
        self.volume = min(1, max(0, volume))
        self.cooldownSeconds = max(0, cooldownSeconds)
    }
}

public struct DataMilestoneState: Equatable, Sendable {
    public var accumulatedBytes: UInt64
    public var nextMilestoneBytes: UInt64
    public var lastSoundTime: Date?

    public init(accumulatedBytes: UInt64 = 0, nextMilestoneBytes: UInt64 = DataMilestoneUnit.bytes(value: 1, unit: .gb), lastSoundTime: Date? = nil) {
        self.accumulatedBytes = accumulatedBytes
        self.nextMilestoneBytes = max(1, nextMilestoneBytes)
        self.lastSoundTime = lastSoundTime
    }
}

public struct DataMilestoneDecision: Equatable, Sendable {
    public let shouldPlaySound: Bool
    public let crossedMilestone: Bool
    public let bytesAdded: UInt64
}

public enum DataMilestonePlanner {
    public static func resolve(
        settings: DataMilestoneSettings,
        state: inout DataMilestoneState,
        downloadBytes: UInt64,
        uploadBytes: UInt64,
        at date: Date
    ) -> DataMilestoneDecision {
        guard settings.enabled else {
            return DataMilestoneDecision(shouldPlaySound: false, crossedMilestone: false, bytesAdded: 0)
        }

        let bytesAdded: UInt64 = switch settings.direction {
        case .download: downloadBytes
        case .upload: uploadBytes
        case .combined: downloadBytes &+ uploadBytes
        }

        guard bytesAdded > 0 else {
            return DataMilestoneDecision(shouldPlaySound: false, crossedMilestone: false, bytesAdded: 0)
        }

        let threshold = max(1, settings.thresholdBytes)
        if state.nextMilestoneBytes == 0 || state.nextMilestoneBytes <= state.accumulatedBytes {
            state.nextMilestoneBytes = nextMilestone(after: state.accumulatedBytes, threshold: threshold)
        }

        state.accumulatedBytes = state.accumulatedBytes &+ bytesAdded
        guard state.accumulatedBytes >= state.nextMilestoneBytes else {
            return DataMilestoneDecision(shouldPlaySound: false, crossedMilestone: false, bytesAdded: bytesAdded)
        }

        state.nextMilestoneBytes = nextMilestone(after: state.accumulatedBytes, threshold: threshold)

        let canPlay: Bool
        if let lastSoundTime = state.lastSoundTime {
            canPlay = date.timeIntervalSince(lastSoundTime) >= settings.cooldownSeconds
        } else {
            canPlay = true
        }

        if canPlay {
            state.lastSoundTime = date
        }

        return DataMilestoneDecision(shouldPlaySound: canPlay, crossedMilestone: true, bytesAdded: bytesAdded)
    }

    public static func nextMilestone(after accumulatedBytes: UInt64, threshold: UInt64) -> UInt64 {
        let threshold = max(1, threshold)
        return ((accumulatedBytes / threshold) + 1) * threshold
    }
}

public protocol DataMilestoneSoundPlaying: AnyObject {
    func play(selection: DataMilestoneSoundSelection, systemSoundName: String, customSoundURL: URL?, volume: Double)
}

public final class NSSoundDataMilestonePlayer: DataMilestoneSoundPlaying {
    public init() {}

    public func play(selection: DataMilestoneSoundSelection, systemSoundName: String, customSoundURL: URL?, volume: Double) {
        DispatchQueue.main.async {
            let sound: NSSound?
            switch selection {
            case .builtInTick:
                sound = NSSound(named: NSSound.Name("Tink")) ?? NSSound(named: NSSound.Name("Pop"))
            case .builtInBeep:
                sound = NSSound(named: NSSound.Name("Ping")) ?? NSSound(named: NSSound.Name("Glass"))
            case .systemSound:
                sound = NSSound(named: NSSound.Name(systemSoundName))
            case .customFile:
                if let customSoundURL {
                    sound = NSSound(contentsOf: customSoundURL, byReference: true)
                } else {
                    sound = NSSound(named: NSSound.Name("Tink"))
                }
            }
            sound?.volume = Float(min(1, max(0, volume)))
            sound?.play()
        }
    }
}

@MainActor
public final class DataMilestoneSoundManager: ObservableObject {
    public enum DefaultsKey {
        public static let enabled = "dataMilestone.enabled"
        public static let direction = "dataMilestone.direction"
        public static let thresholdValue = "dataMilestone.thresholdValue"
        public static let thresholdUnit = "dataMilestone.thresholdUnit"
        public static let selectedSound = "dataMilestone.selectedSound"
        public static let systemSoundName = "dataMilestone.systemSoundName"
        public static let customSoundBookmark = "dataMilestone.customSoundBookmark"
        public static let volume = "dataMilestone.volume"
        public static let cooldownSeconds = "dataMilestone.cooldownSeconds"
        public static let accumulatedBytes = "dataMilestone.accumulatedBytes"
        public static let nextMilestoneBytes = "dataMilestone.nextMilestoneBytes"
        public static let lastSoundTime = "dataMilestone.lastSoundTime"
    }

    public static let systemSoundNames = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"
    ]

    @Published public var enabled: Bool { didSet { persistSettings() } }
    @Published public var direction: DataMilestoneDirection { didSet { persistSettings() } }
    @Published public var thresholdValue: Double { didSet { persistSettings(); normalizeNextMilestone() } }
    @Published public var thresholdUnit: DataMilestoneUnit { didSet { persistSettings(); normalizeNextMilestone() } }
    @Published public var selectedSound: DataMilestoneSoundSelection { didSet { persistSettings() } }
    @Published public var systemSoundName: String { didSet { persistSettings() } }
    @Published public var volume: Double { didSet { persistSettings() } }
    @Published public var cooldownSeconds: Double { didSet { persistSettings() } }
    @Published public private(set) var accumulatedBytes: UInt64 { didSet { persistProgress() } }
    @Published public private(set) var nextMilestoneBytes: UInt64 { didSet { persistProgress() } }
    @Published public private(set) var lastSoundTime: Date? { didSet { persistProgress() } }
    @Published public private(set) var customSoundURL: URL?
    @Published public private(set) var warningMessage: String?

    private let defaults: UserDefaults
    private let player: DataMilestoneSoundPlaying
    private var customSoundBookmark: Data?

    public init(defaults: UserDefaults = .standard, player: DataMilestoneSoundPlaying = NSSoundDataMilestonePlayer()) {
        self.defaults = defaults
        self.player = player
        enabled = defaults.object(forKey: DefaultsKey.enabled) as? Bool ?? false
        direction = DataMilestoneDirection(rawValue: defaults.string(forKey: DefaultsKey.direction) ?? "") ?? .download
        thresholdValue = defaults.object(forKey: DefaultsKey.thresholdValue) as? Double ?? 1
        thresholdUnit = DataMilestoneUnit(rawValue: defaults.string(forKey: DefaultsKey.thresholdUnit) ?? "") ?? .gb
        selectedSound = DataMilestoneSoundSelection(rawValue: defaults.string(forKey: DefaultsKey.selectedSound) ?? "") ?? .builtInTick
        systemSoundName = defaults.string(forKey: DefaultsKey.systemSoundName) ?? "Ping"
        volume = defaults.object(forKey: DefaultsKey.volume) as? Double ?? 0.75
        cooldownSeconds = defaults.object(forKey: DefaultsKey.cooldownSeconds) as? Double ?? 1
        let savedAccumulatedBytes = UInt64(defaults.object(forKey: DefaultsKey.accumulatedBytes) as? Int64 ?? 0)
        accumulatedBytes = savedAccumulatedBytes
        let savedNext = UInt64(defaults.object(forKey: DefaultsKey.nextMilestoneBytes) as? Int64 ?? 0)
        let savedThresholdBytes = Self.thresholdBytes(value: defaults.object(forKey: DefaultsKey.thresholdValue) as? Double ?? 1, unit: DataMilestoneUnit(rawValue: defaults.string(forKey: DefaultsKey.thresholdUnit) ?? "") ?? .gb)
        nextMilestoneBytes = savedNext > 0 ? savedNext : DataMilestonePlanner.nextMilestone(after: savedAccumulatedBytes, threshold: savedThresholdBytes)
        lastSoundTime = defaults.object(forKey: DefaultsKey.lastSoundTime) as? Date
        customSoundBookmark = defaults.data(forKey: DefaultsKey.customSoundBookmark)
        customSoundURL = Self.resolve(bookmark: customSoundBookmark)
    }

    public var thresholdBytes: UInt64 {
        Self.thresholdBytes(value: thresholdValue, unit: thresholdUnit)
    }

    public var remainingBytes: UInt64 {
        nextMilestoneBytes > accumulatedBytes ? nextMilestoneBytes - accumulatedBytes : 0
    }

    public var currentIntervalBytes: UInt64 {
        thresholdBytes - min(remainingBytes, thresholdBytes)
    }

    public var progressDescription: String {
        "\(Self.formatBytes(currentIntervalBytes)) / \(Self.formatBytes(thresholdBytes)) until next tick"
    }

    public var settings: DataMilestoneSettings {
        DataMilestoneSettings(
            enabled: enabled,
            direction: direction,
            thresholdBytes: thresholdBytes,
            selectedSound: selectedSound,
            volume: volume,
            cooldownSeconds: cooldownSeconds
        )
    }

    public func record(downloadBytes: UInt64, uploadBytes: UInt64, at date: Date = Date()) {
        var state = DataMilestoneState(
            accumulatedBytes: accumulatedBytes,
            nextMilestoneBytes: nextMilestoneBytes,
            lastSoundTime: lastSoundTime
        )
        let decision = DataMilestonePlanner.resolve(
            settings: settings,
            state: &state,
            downloadBytes: downloadBytes,
            uploadBytes: uploadBytes,
            at: date
        )
        accumulatedBytes = state.accumulatedBytes
        nextMilestoneBytes = state.nextMilestoneBytes
        lastSoundTime = state.lastSoundTime

        if decision.shouldPlaySound {
            playSelectedSound()
        }
    }

    public func resetCounter() {
        accumulatedBytes = 0
        nextMilestoneBytes = thresholdBytes
        lastSoundTime = nil
    }

    public func testSound() {
        playSelectedSound()
    }

    public func chooseCustomSound() {
        let panel = NSOpenPanel()
        panel.title = "Choose Milestone Sound"
        panel.allowedContentTypes = [.audio]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveCustomSound(url: url)
    }

    public func saveCustomSound(url: URL) {
        guard NSSound(contentsOf: url, byReference: true) != nil else {
            warningMessage = "That file could not be opened as an audio file."
            return
        }

        do {
            customSoundBookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(customSoundBookmark, forKey: DefaultsKey.customSoundBookmark)
            customSoundURL = url
            selectedSound = .customFile
            warningMessage = nil
        } catch {
            warningMessage = "The custom sound could not be saved: \(error.localizedDescription)"
        }
    }

    public static func thresholdBytes(value: Double, unit: DataMilestoneUnit) -> UInt64 {
        DataMilestoneUnit.bytes(value: value, unit: unit)
    }

    public static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .binary)
    }

    private func playSelectedSound() {
        var resolvedCustomURL: URL?
        var didStartAccessing = false
        if selectedSound == .customFile {
            resolvedCustomURL = customSoundURL ?? Self.resolve(bookmark: customSoundBookmark)
            if let resolvedCustomURL {
                didStartAccessing = resolvedCustomURL.startAccessingSecurityScopedResource()
            } else {
                warningMessage = "Custom sound is missing. Falling back to the built-in tick."
            }
        }

        let selection = (selectedSound == .customFile && resolvedCustomURL == nil) ? DataMilestoneSoundSelection.builtInTick : selectedSound
        player.play(selection: selection, systemSoundName: systemSoundName, customSoundURL: resolvedCustomURL, volume: volume)

        if didStartAccessing {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                resolvedCustomURL?.stopAccessingSecurityScopedResource()
            }
        }
    }

    private func persistSettings() {
        defaults.set(enabled, forKey: DefaultsKey.enabled)
        defaults.set(direction.rawValue, forKey: DefaultsKey.direction)
        defaults.set(thresholdValue, forKey: DefaultsKey.thresholdValue)
        defaults.set(thresholdUnit.rawValue, forKey: DefaultsKey.thresholdUnit)
        defaults.set(selectedSound.rawValue, forKey: DefaultsKey.selectedSound)
        defaults.set(systemSoundName, forKey: DefaultsKey.systemSoundName)
        defaults.set(volume, forKey: DefaultsKey.volume)
        defaults.set(cooldownSeconds, forKey: DefaultsKey.cooldownSeconds)
    }

    private func persistProgress() {
        defaults.set(Int64(clamping: accumulatedBytes), forKey: DefaultsKey.accumulatedBytes)
        defaults.set(Int64(clamping: nextMilestoneBytes), forKey: DefaultsKey.nextMilestoneBytes)
        defaults.set(lastSoundTime, forKey: DefaultsKey.lastSoundTime)
    }

    private func normalizeNextMilestone() {
        nextMilestoneBytes = DataMilestonePlanner.nextMilestone(after: accumulatedBytes, threshold: thresholdBytes)
    }

    private static func resolve(bookmark: Data?) -> URL? {
        guard let bookmark else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
