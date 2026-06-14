import Foundation

public struct BlocklistImportService: Sendable {
    private let validator: IPAddressValidator

    public init(validator: IPAddressValidator = IPAddressValidator()) {
        self.validator = validator
    }

    public func parse(url: URL) throws -> (entries: [(value: String, warning: String?)], skipped: Int, warnings: [String]) {
        let text = try String(contentsOf: url, encoding: .utf8)
        var entries: [String: String] = [:]
        var skipped = 0
        var warnings: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline).map(String.init) {
            guard let candidate = candidate(from: rawLine) else { continue }
            let value = validator.normalize(candidate)
            switch validator.validate(value) {
            case .valid:
                entries[value] = ""
            case let .warning(message):
                entries[value] = message
                warnings.append("\(value): \(message)")
            case .refused:
                skipped += 1
            }
        }
        return (entries.keys.sorted().map { ($0, entries[$0].flatMap { $0.isEmpty ? nil : $0 }) }, skipped, warnings)
    }

    public func importFile(url: URL, database: FirewallDatabase, notes: String = "") throws -> BlocklistImportResult {
        let parsed = try parse(url: url)
        let blocklist = try database.importBlocklist(
            name: url.deletingPathExtension().lastPathComponent,
            sourceFilename: url.lastPathComponent,
            notes: notes,
            entries: parsed.entries,
            skipped: parsed.skipped
        )
        return BlocklistImportResult(blocklist: blocklist, importedEntries: parsed.entries.count, skippedEntries: parsed.skipped, warnings: parsed.warnings)
    }

    private func candidate(from rawLine: String) -> String? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";") else { return nil }
        let firstColumn = trimmed.split(separator: ",", maxSplits: 1).first.map(String.init) ?? trimmed
        let withoutInlineComment = firstColumn
            .split(separator: "#", maxSplits: 1).first.map(String.init) ?? firstColumn
        let candidate = withoutInlineComment
            .split(separator: ";", maxSplits: 1).first.map(String.init) ?? withoutInlineComment
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct FirewallEventLogService: Sendable {
    private let database: FirewallDatabase

    public init(database: FirewallDatabase) {
        self.database = database
    }

    public func log(type: String, message: String, detail: String = "", succeeded: Bool = true) {
        try? database.insertEvent(type: type, message: message, detail: detail, succeeded: succeeded)
    }
}

public struct GatewayDetectionService: Sendable {
    private let runner: CommandRunner

    public init(runner: CommandRunner = CommandRunner()) {
        self.runner = runner
    }

    public func defaultGateway() async -> String? {
        guard let result = try? await runner.run("/sbin/route", arguments: ["-n", "get", "default"]), result.exitCode == 0 else {
            return nil
        }
        for line in result.output.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("gateway:") {
                return trimmed.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
