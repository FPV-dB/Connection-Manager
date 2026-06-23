import Foundation
import SQLite3

public final class FirewallDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "LiveConnectionsMonitor.FirewallDatabase")

    public init(url: URL? = nil) throws {
        let databaseURL = try url ?? Self.defaultURL()
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            throw DatabaseError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    public func blocklists() throws -> [Blocklist] {
        try queue.sync {
            try rows("""
                SELECT blocklist_id, name, source_filename, imported_at, entry_count, is_enabled, notes, last_applied_at
                FROM blocklists
                ORDER BY imported_at DESC
                """).map(mapBlocklist)
        }
    }

    public func entries(blocklistID: Int64? = nil) throws -> [BlocklistEntry] {
        try queue.sync {
            let sql = blocklistID == nil
                ? "SELECT entry_id, blocklist_id, value, is_enabled, warning FROM blocklist_entries ORDER BY value"
                : "SELECT entry_id, blocklist_id, value, is_enabled, warning FROM blocklist_entries WHERE blocklist_id = ? ORDER BY value"
            return try rows(sql, parameters: blocklistID.map { [.int($0)] } ?? []).map(mapEntry)
        }
    }

    public func manualBlocks() throws -> [ManualBlockedIP] {
        try queue.sync {
            try rows("""
                SELECT block_id, address, direction, note, source, date_added, is_enabled
                FROM manual_blocks
                ORDER BY date_added DESC
                """).map(mapManualBlock)
        }
    }

    public func allowlist() throws -> [AllowlistEntry] {
        try queue.sync {
            try rows("""
                SELECT allow_id, value, note, date_added, is_enabled
                FROM allowlist
                ORDER BY value
                """).map(mapAllowlist)
        }
    }

    public func geoCountries() throws -> [GeoBlockCountry] {
        try queue.sync {
            try rows("""
                SELECT country_code, country_name, ipv4_count, ipv6_count, is_enabled, direction,
                       last_imported_at, source_name, notes, expires_at
                FROM geo_block_countries
                ORDER BY country_name COLLATE NOCASE
                """).map(mapGeoCountry)
        }
    }

    public func geoRanges(countryCode: String? = nil) throws -> [GeoBlockRange] {
        try queue.sync {
            let sql = countryCode == nil
                ? "SELECT range_id, country_code, country_name, cidr, ip_version, source_name, imported_at, is_enabled, validation_status FROM geo_block_ranges ORDER BY country_code, cidr"
                : "SELECT range_id, country_code, country_name, cidr, ip_version, source_name, imported_at, is_enabled, validation_status FROM geo_block_ranges WHERE country_code = ? ORDER BY cidr"
            return try rows(sql, parameters: countryCode.map { [.text($0.uppercased())] } ?? []).map(mapGeoRange)
        }
    }

    public func events(limit: Int = 200) throws -> [FirewallEventLog] {
        try queue.sync {
            try rows("""
                SELECT event_id, event_date, event_type, message, detail, succeeded
                FROM firewall_events
                ORDER BY event_date DESC, event_id DESC
                LIMIT ?
                """, parameters: [.int(Int64(limit))]).map(mapEvent)
        }
    }

    public func settings() throws -> FirewallSettings {
        try queue.sync {
            var settings = FirewallSettings()
            for row in try rows("SELECT key, value FROM settings") {
                let key = row["key"]?.string ?? ""
                let value = row["value"]?.string ?? ""
                switch key {
                case "autoApplyImportedBlocklists": settings.autoApplyImportedBlocklists = value == "1"
                case "confirmBeforeApplying": settings.confirmBeforeApplying = value != "0"
                case "backupAnchorBeforeRewrite": settings.backupAnchorBeforeRewrite = value != "0"
                case "anchorPath":
                    if !value.isEmpty {
                        settings.anchorPath = value == FirewallBlockService.legacyAnchorPath
                            ? FirewallBlockService.anchorPath
                            : value
                    }
                case "anchorName":
                    if !value.isEmpty {
                        settings.anchorName = value == FirewallBlockService.legacyAnchorName
                            ? FirewallBlockService.anchorName
                            : value
                    }
                case "refreshInterval": settings.refreshInterval = RefreshInterval(rawValue: value) ?? .two
                case "defaultLookupProviderID": if !value.isEmpty { settings.defaultLookupProviderID = value }
                case "suppressLookupPrivacyWarning": settings.suppressLookupPrivacyWarning = value == "1"
                case "suppressTracerouteWarning": settings.suppressTracerouteWarning = value == "1"
                case "launchAtLogin": settings.launchAtLogin = value == "1"
                case "startupMode": settings.startupMode = StartupProtectionMode(rawValue: value) ?? .monitorOnly
                case "startupAcknowledged": settings.startupAcknowledged = value == "1"
                case "lastStartupAt": settings.lastStartupAt = Double(value).map(Date.init(timeIntervalSince1970:))
                case "lastStartupSynchronizationAt": settings.lastStartupSynchronizationAt = Double(value).map(Date.init(timeIntervalSince1970:))
                case "startupAnchorInstalled": settings.startupAnchorInstalled = value == "1"
                case "startupRulesLoaded": settings.startupRulesLoaded = value == "1"
                case "blockKnownGoogleConnections": settings.blockKnownGoogleConnections = value == "1"
                case "googleRangesLastUpdatedAt": settings.googleRangesLastUpdatedAt = Double(value).map(Date.init(timeIntervalSince1970:))
                default: break
                }
            }
            return settings
        }
    }

    public func save(settings: FirewallSettings) throws {
        try queue.sync {
            for (key, value) in [
                ("autoApplyImportedBlocklists", settings.autoApplyImportedBlocklists ? "1" : "0"),
                ("confirmBeforeApplying", settings.confirmBeforeApplying ? "1" : "0"),
                ("backupAnchorBeforeRewrite", settings.backupAnchorBeforeRewrite ? "1" : "0"),
                ("anchorPath", settings.anchorPath),
                ("anchorName", settings.anchorName),
                ("refreshInterval", settings.refreshInterval.rawValue),
                ("defaultLookupProviderID", settings.defaultLookupProviderID),
                ("suppressLookupPrivacyWarning", settings.suppressLookupPrivacyWarning ? "1" : "0"),
                ("suppressTracerouteWarning", settings.suppressTracerouteWarning ? "1" : "0"),
                ("launchAtLogin", settings.launchAtLogin ? "1" : "0"),
                ("startupMode", settings.startupMode.rawValue),
                ("startupAcknowledged", settings.startupAcknowledged ? "1" : "0"),
                ("lastStartupAt", settings.lastStartupAt.map { String($0.timeIntervalSince1970) } ?? ""),
                ("lastStartupSynchronizationAt", settings.lastStartupSynchronizationAt.map { String($0.timeIntervalSince1970) } ?? ""),
                ("startupAnchorInstalled", settings.startupAnchorInstalled ? "1" : "0"),
                ("startupRulesLoaded", settings.startupRulesLoaded ? "1" : "0"),
                ("blockKnownGoogleConnections", settings.blockKnownGoogleConnections ? "1" : "0"),
                ("googleRangesLastUpdatedAt", settings.googleRangesLastUpdatedAt.map { String($0.timeIntervalSince1970) } ?? "")
            ] {
                try execute("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)", [.text(key), .text(value)])
            }
        }
    }

    public func recordStartup(at date: Date = Date()) throws {
        var current = try settings()
        current.lastStartupAt = date
        try save(settings: current)
    }

    public func insertManualBlock(address: String, direction: FirewallDirection, note: String, source: FirewallRuleSource = .manual) throws {
        try queue.sync {
            try execute("""
                INSERT OR REPLACE INTO manual_blocks (address, direction, note, source, date_added, is_enabled)
                VALUES (?, ?, ?, ?, ?, 1)
                """, [.text(address), .text(direction.rawValue), .text(note), .text(source.rawValue), .double(Date().timeIntervalSince1970)])
        }
    }

    public func deleteManualBlock(id: Int64) throws {
        try queue.sync {
            try execute("DELETE FROM manual_blocks WHERE block_id = ?", [.int(id)])
        }
    }

    public func setManualBlockEnabled(id: Int64, enabled: Bool) throws {
        try queue.sync {
            try execute("UPDATE manual_blocks SET is_enabled = ? WHERE block_id = ?", [.int(enabled ? 1 : 0), .int(id)])
        }
    }

    public func insertAllowlist(value: String, note: String) throws {
        try queue.sync {
            try execute("""
                INSERT OR REPLACE INTO allowlist (value, note, date_added, is_enabled)
                VALUES (?, ?, ?, 1)
                """, [.text(value), .text(note), .double(Date().timeIntervalSince1970)])
        }
    }

    public func deleteAllowlist(id: Int64) throws {
        try queue.sync {
            try execute("DELETE FROM allowlist WHERE allow_id = ?", [.int(id)])
        }
    }

    public func setBlocklistEnabled(id: Int64, enabled: Bool) throws {
        try queue.sync {
            try execute("UPDATE blocklists SET is_enabled = ? WHERE blocklist_id = ?", [.int(enabled ? 1 : 0), .int(id)])
            try insertEventLocked(type: "Blocklist \(enabled ? "enabled" : "disabled")", message: "Updated blocklist \(id)", detail: "", succeeded: true)
        }
    }

    public func replaceManagedBlocklist(name: String, sourceFilename: String, notes: String, entries: [String], enabled: Bool) throws {
        try queue.sync {
            try execute("BEGIN IMMEDIATE")
            do {
                let existingID = try rows(
                    "SELECT blocklist_id FROM blocklists WHERE name = ? ORDER BY blocklist_id LIMIT 1",
                    parameters: [.text(name)]
                ).first?["blocklist_id"]?.int
                let blocklistID: Int64
                if let existingID {
                    blocklistID = existingID
                    try execute("DELETE FROM blocklist_entries WHERE blocklist_id = ?", [.int(blocklistID)])
                    try execute("""
                        UPDATE blocklists
                        SET source_filename = ?, imported_at = ?, entry_count = ?, is_enabled = ?, notes = ?
                        WHERE blocklist_id = ?
                        """, [
                            .text(sourceFilename), .double(Date().timeIntervalSince1970), .int(Int64(entries.count)),
                            .int(enabled ? 1 : 0), .text(notes), .int(blocklistID)
                        ])
                } else {
                    try execute("""
                        INSERT INTO blocklists (name, source_filename, imported_at, entry_count, is_enabled, notes, last_applied_at)
                        VALUES (?, ?, ?, ?, ?, ?, NULL)
                        """, [
                            .text(name), .text(sourceFilename), .double(Date().timeIntervalSince1970),
                            .int(Int64(entries.count)), .int(enabled ? 1 : 0), .text(notes)
                        ])
                    blocklistID = sqlite3_last_insert_rowid(db)
                }
                for entry in entries {
                    try execute("""
                        INSERT OR IGNORE INTO blocklist_entries (blocklist_id, value, is_enabled, warning)
                        VALUES (?, ?, 1, NULL)
                        """, [.int(blocklistID), .text(entry)])
                }
                try insertEventLocked(type: "Managed blocklist refreshed", message: name, detail: "\(entries.count) ranges", succeeded: true)
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    public func setManagedBlocklistEnabled(name: String, enabled: Bool) throws {
        try queue.sync {
            try execute("UPDATE blocklists SET is_enabled = ? WHERE name = ?", [.int(enabled ? 1 : 0), .text(name)])
        }
    }

    public func setGeoCountryEnabled(code: String, enabled: Bool) throws {
        try queue.sync {
            try execute("UPDATE geo_block_countries SET is_enabled = ? WHERE country_code = ?", [.int(enabled ? 1 : 0), .text(code.uppercased())])
        }
    }

    public func setGeoCountryDirection(code: String, direction: FirewallDirection) throws {
        try queue.sync {
            try execute("UPDATE geo_block_countries SET direction = ? WHERE country_code = ?", [.text(direction.rawValue), .text(code.uppercased())])
        }
    }

    public func setGeoCountryNotes(code: String, notes: String) throws {
        try queue.sync {
            try execute("UPDATE geo_block_countries SET notes = ? WHERE country_code = ?", [.text(notes), .text(code.uppercased())])
        }
    }

    public func importGeoRanges(countryCode: String, countryName: String, sourceName: String, notes: String, ranges: [(cidr: String, version: IPVersion, status: String)], skipped: Int) throws {
        try queue.sync {
            let code = countryCode.uppercased()
            let now = Date().timeIntervalSince1970
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("DELETE FROM geo_block_ranges WHERE country_code = ? AND source_name = ?", [.text(code), .text(sourceName)])
                for range in ranges {
                    try execute("""
                        INSERT OR IGNORE INTO geo_block_ranges (country_code, country_name, cidr, ip_version, source_name, imported_at, is_enabled, validation_status)
                        VALUES (?, ?, ?, ?, ?, ?, 1, ?)
                        """, [.text(code), .text(countryName), .text(range.cidr), .text(range.version.rawValue), .text(sourceName), .double(now), .text(range.status)])
                }
                let counts = try rows("""
                    SELECT
                        SUM(CASE WHEN ip_version = 'IPv4' THEN 1 ELSE 0 END) AS ipv4_count,
                        SUM(CASE WHEN ip_version = 'IPv6' THEN 1 ELSE 0 END) AS ipv6_count
                    FROM geo_block_ranges
                    WHERE country_code = ? AND is_enabled = 1
                    """, parameters: [.text(code)]).first ?? [:]
                try execute("""
                    INSERT INTO geo_block_countries (country_code, country_name, ipv4_count, ipv6_count, is_enabled, direction, last_imported_at, source_name, notes, expires_at)
                    VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, NULL)
                    ON CONFLICT(country_code) DO UPDATE SET
                        country_name = excluded.country_name,
                        ipv4_count = excluded.ipv4_count,
                        ipv6_count = excluded.ipv6_count,
                        last_imported_at = excluded.last_imported_at,
                        source_name = excluded.source_name,
                        notes = CASE WHEN geo_block_countries.notes = '' THEN excluded.notes ELSE geo_block_countries.notes END
                    """, [
                    .text(code),
                    .text(countryName),
                    .int(counts["ipv4_count"]?.int ?? 0),
                    .int(counts["ipv6_count"]?.int ?? 0),
                    .text(FirewallDirection.both.rawValue),
                    .double(now),
                    .text(sourceName),
                    .text(notes)
                ])
                try insertEventLocked(type: "Country blocklist imported", message: "\(code) \(countryName)", detail: "\(ranges.count) ranges, \(skipped) skipped", succeeded: true)
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    public func importBlocklist(name: String, sourceFilename: String, notes: String, entries: [(value: String, warning: String?)], skipped: Int) throws -> Blocklist {
        try queue.sync {
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("""
                    INSERT INTO blocklists (name, source_filename, imported_at, entry_count, is_enabled, notes, last_applied_at)
                    VALUES (?, ?, ?, ?, 1, ?, NULL)
                    """, [.text(name), .text(sourceFilename), .double(Date().timeIntervalSince1970), .int(Int64(entries.count)), .text(notes)])
                let blocklistID = sqlite3_last_insert_rowid(db)
                for entry in entries {
                    try execute("""
                        INSERT OR IGNORE INTO blocklist_entries (blocklist_id, value, is_enabled, warning)
                        VALUES (?, ?, 1, ?)
                        """, [.int(blocklistID), .text(entry.value), entry.warning.map(DBValue.text) ?? .null])
                }
                try insertEventLocked(type: "Blocklist imported", message: "\(name): \(entries.count) entries", detail: "Skipped \(skipped) invalid lines", succeeded: true)
                try execute("COMMIT")
                return try mapBlocklist(rows("SELECT blocklist_id, name, source_filename, imported_at, entry_count, is_enabled, notes, last_applied_at FROM blocklists WHERE blocklist_id = ?", parameters: [.int(blocklistID)]).first ?? [:])
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    public func insertEvent(type: String, message: String, detail: String = "", succeeded: Bool = true) throws {
        try queue.sync {
            try insertEventLocked(type: type, message: message, detail: detail, succeeded: succeeded)
        }
    }

    private func migrate() throws {
        try queue.sync {
            try execute("PRAGMA journal_mode = WAL")
            try execute("""
                CREATE TABLE IF NOT EXISTS blocklists (
                    blocklist_id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    source_filename TEXT NOT NULL,
                    imported_at REAL NOT NULL,
                    entry_count INTEGER NOT NULL,
                    is_enabled INTEGER NOT NULL DEFAULT 1,
                    notes TEXT NOT NULL DEFAULT '',
                    last_applied_at REAL
                )
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS blocklist_entries (
                    entry_id INTEGER PRIMARY KEY AUTOINCREMENT,
                    blocklist_id INTEGER NOT NULL,
                    value TEXT NOT NULL,
                    is_enabled INTEGER NOT NULL DEFAULT 1,
                    warning TEXT,
                    UNIQUE(blocklist_id, value)
                )
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS manual_blocks (
                    block_id INTEGER PRIMARY KEY AUTOINCREMENT,
                    address TEXT NOT NULL UNIQUE,
                    direction TEXT NOT NULL,
                    note TEXT NOT NULL DEFAULT '',
                    source TEXT NOT NULL,
                    date_added REAL NOT NULL,
                    is_enabled INTEGER NOT NULL DEFAULT 1
                )
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS allowlist (
                    allow_id INTEGER PRIMARY KEY AUTOINCREMENT,
                    value TEXT NOT NULL UNIQUE,
                    note TEXT NOT NULL DEFAULT '',
                    date_added REAL NOT NULL,
                    is_enabled INTEGER NOT NULL DEFAULT 1
                )
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS firewall_events (
                    event_id INTEGER PRIMARY KEY AUTOINCREMENT,
                    event_date REAL NOT NULL,
                    event_type TEXT NOT NULL,
                    message TEXT NOT NULL,
                    detail TEXT NOT NULL,
                    succeeded INTEGER NOT NULL
                )
                """)
            try execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try execute("""
                CREATE TABLE IF NOT EXISTS geo_block_countries (
                    country_code TEXT PRIMARY KEY,
                    country_name TEXT NOT NULL,
                    ipv4_count INTEGER NOT NULL DEFAULT 0,
                    ipv6_count INTEGER NOT NULL DEFAULT 0,
                    is_enabled INTEGER NOT NULL DEFAULT 0,
                    direction TEXT NOT NULL DEFAULT 'both',
                    last_imported_at REAL,
                    source_name TEXT NOT NULL DEFAULT '',
                    notes TEXT NOT NULL DEFAULT '',
                    expires_at REAL
                )
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS geo_block_ranges (
                    range_id INTEGER PRIMARY KEY AUTOINCREMENT,
                    country_code TEXT NOT NULL,
                    country_name TEXT NOT NULL,
                    cidr TEXT NOT NULL,
                    ip_version TEXT NOT NULL,
                    source_name TEXT NOT NULL,
                    imported_at REAL NOT NULL,
                    is_enabled INTEGER NOT NULL DEFAULT 1,
                    validation_status TEXT NOT NULL,
                    UNIQUE(country_code, cidr, source_name)
                )
                """)
            try execute("CREATE INDEX IF NOT EXISTS idx_geo_block_ranges_country ON geo_block_ranges(country_code, is_enabled)")
            try execute("CREATE INDEX IF NOT EXISTS idx_geo_block_ranges_cidr ON geo_block_ranges(cidr)")
        }
    }

    private func insertEventLocked(type: String, message: String, detail: String, succeeded: Bool) throws {
        try execute("""
            INSERT INTO firewall_events (event_date, event_type, message, detail, succeeded)
            VALUES (?, ?, ?, ?, ?)
            """, [.double(Date().timeIntervalSince1970), .text(type), .text(message), .text(detail), .int(succeeded ? 1 : 0)])
    }

    private func rows(_ sql: String, parameters: [DBValue] = []) throws -> [[String: DBValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        try bind(parameters, to: statement)
        var output: [[String: DBValue]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: DBValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                row[name] = value(statement: statement, index: index)
            }
            output.append(row)
        }
        return output
    }

    private func execute(_ sql: String, _ parameters: [DBValue] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        try bind(parameters, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bind(_ parameters: [DBValue], to statement: OpaquePointer?) throws {
        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            switch parameter {
            case let .text(value): sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            case let .int(value): sqlite3_bind_int64(statement, index, value)
            case let .double(value): sqlite3_bind_double(statement, index, value)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
    }

    private func value(statement: OpaquePointer?, index: Int32) -> DBValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: .int(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: .double(sqlite3_column_double(statement, index))
        case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(statement, index)))
        default: .null
        }
    }

    private func mapBlocklist(_ row: [String: DBValue]) throws -> Blocklist {
        Blocklist(
            id: row["blocklist_id"]?.int ?? 0,
            name: row["name"]?.string ?? "",
            sourceFilename: row["source_filename"]?.string ?? "",
            importedAt: Date(timeIntervalSince1970: row["imported_at"]?.double ?? 0),
            entryCount: Int(row["entry_count"]?.int ?? 0),
            isEnabled: (row["is_enabled"]?.int ?? 0) == 1,
            notes: row["notes"]?.string ?? "",
            lastAppliedAt: row["last_applied_at"]?.optionalDouble.map(Date.init(timeIntervalSince1970:))
        )
    }

    private func mapEntry(_ row: [String: DBValue]) -> BlocklistEntry {
        BlocklistEntry(id: row["entry_id"]?.int ?? 0, blocklistID: row["blocklist_id"]?.int ?? 0, value: row["value"]?.string ?? "", isEnabled: (row["is_enabled"]?.int ?? 0) == 1, warning: row["warning"]?.optionalString)
    }

    private func mapManualBlock(_ row: [String: DBValue]) -> ManualBlockedIP {
        ManualBlockedIP(id: row["block_id"]?.int ?? 0, address: row["address"]?.string ?? "", direction: FirewallDirection(rawValue: row["direction"]?.string ?? "") ?? .both, note: row["note"]?.string ?? "", source: FirewallRuleSource(rawValue: row["source"]?.string ?? "") ?? .manual, dateAdded: Date(timeIntervalSince1970: row["date_added"]?.double ?? 0), isEnabled: (row["is_enabled"]?.int ?? 0) == 1)
    }

    private func mapAllowlist(_ row: [String: DBValue]) -> AllowlistEntry {
        AllowlistEntry(id: row["allow_id"]?.int ?? 0, value: row["value"]?.string ?? "", note: row["note"]?.string ?? "", dateAdded: Date(timeIntervalSince1970: row["date_added"]?.double ?? 0), isEnabled: (row["is_enabled"]?.int ?? 0) == 1)
    }

    private func mapEvent(_ row: [String: DBValue]) -> FirewallEventLog {
        FirewallEventLog(id: row["event_id"]?.int ?? 0, date: Date(timeIntervalSince1970: row["event_date"]?.double ?? 0), eventType: row["event_type"]?.string ?? "", message: row["message"]?.string ?? "", detail: row["detail"]?.string ?? "", succeeded: (row["succeeded"]?.int ?? 0) == 1)
    }

    private func mapGeoCountry(_ row: [String: DBValue]) -> GeoBlockCountry {
        GeoBlockCountry(
            countryCode: row["country_code"]?.string ?? "",
            countryName: row["country_name"]?.string ?? "",
            ipv4RangeCount: Int(row["ipv4_count"]?.int ?? 0),
            ipv6RangeCount: Int(row["ipv6_count"]?.int ?? 0),
            isEnabled: (row["is_enabled"]?.int ?? 0) == 1,
            direction: FirewallDirection(rawValue: row["direction"]?.string ?? "") ?? .both,
            lastImportedAt: row["last_imported_at"]?.optionalDouble.map(Date.init(timeIntervalSince1970:)),
            sourceName: row["source_name"]?.string ?? "",
            notes: row["notes"]?.string ?? "",
            expiresAt: row["expires_at"]?.optionalDouble.map(Date.init(timeIntervalSince1970:))
        )
    }

    private func mapGeoRange(_ row: [String: DBValue]) -> GeoBlockRange {
        GeoBlockRange(
            id: row["range_id"]?.int ?? 0,
            countryCode: row["country_code"]?.string ?? "",
            countryName: row["country_name"]?.string ?? "",
            cidr: row["cidr"]?.string ?? "",
            ipVersion: IPVersion(rawValue: row["ip_version"]?.string ?? "") ?? .ipv4,
            sourceName: row["source_name"]?.string ?? "",
            importedAt: Date(timeIntervalSince1970: row["imported_at"]?.double ?? 0),
            isEnabled: (row["is_enabled"]?.int ?? 0) == 1,
            validationStatus: row["validation_status"]?.string ?? ""
        )
    }

    private static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("Live Connections Monitor", isDirectory: true).appendingPathComponent("firewall.sqlite")
    }
}

private enum DatabaseError: LocalizedError {
    case openFailed(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case let .openFailed(message): "Could not open firewall database: \(message)"
        case let .queryFailed(message): "Firewall database query failed: \(message)"
        }
    }
}

private enum DBValue {
    case text(String)
    case int(Int64)
    case double(Double)
    case null

    var string: String {
        switch self {
        case let .text(value): value
        case let .int(value): String(value)
        case let .double(value): String(value)
        case .null: ""
        }
    }

    var optionalString: String? {
        if case .null = self { return nil }
        return string
    }

    var int: Int64 {
        switch self {
        case let .int(value): value
        case let .double(value): Int64(value)
        case let .text(value): Int64(value) ?? 0
        case .null: 0
        }
    }

    var double: Double {
        switch self {
        case let .double(value): value
        case let .int(value): Double(value)
        case let .text(value): Double(value) ?? 0
        case .null: 0
        }
    }

    var optionalDouble: Double? {
        if case .null = self { return nil }
        return double
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
