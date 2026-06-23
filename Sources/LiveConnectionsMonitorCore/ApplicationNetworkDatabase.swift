import Foundation
import SQLite3

public final class ApplicationNetworkDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "LiveConnectionsMonitor.ApplicationNetworkDatabase")

    public init(url: URL? = nil) throws {
        let databaseURL = try url ?? Self.defaultURL()
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            throw ApplicationDatabaseError.openFailed(errorText)
        }
        try queue.sync { try migrate() }
    }

    deinit { sqlite3_close(db) }

    public func rules() throws -> [String: AppRuleAction] {
        try queue.sync {
            let statement = try prepare("SELECT app_id, action FROM app_rules")
            defer { sqlite3_finalize(statement) }
            var result: [String: AppRuleAction] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = text(statement, 0), let raw = text(statement, 1), let action = AppRuleAction(rawValue: raw) else { continue }
                result[id] = action
            }
            return result
        }
    }

    public func setRule(_ action: AppRuleAction, for appID: String) throws {
        try queue.sync {
            try execute("INSERT OR REPLACE INTO app_rules (app_id, action, updated_at) VALUES (?, ?, ?)", [appID, action.rawValue, Date().timeIntervalSince1970])
        }
    }

    public func save(_ records: [AppConnectionRecord], historyLimit: Int) throws {
        guard !records.isEmpty else { return }
        try queue.sync {
            try execute("BEGIN IMMEDIATE")
            do {
                for record in records {
                    try execute("""
                        INSERT OR REPLACE INTO app_connection_history
                        (id, timestamp, app_id, pid, direction, protocol, local_address, local_port,
                         remote_address, remote_port, remote_hostname, country_code, state, bytes_sent,
                         bytes_received, duration, rule_action)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, [
                            record.id, record.timestamp.timeIntervalSince1970, record.appBundleIdentifier,
                            record.pid, record.direction.rawValue, record.protocolKind.rawValue,
                            record.localAddress, record.localPort, record.remoteAddress, record.remotePort,
                            record.remoteHostname, record.countryCode, record.state, record.bytesSent,
                            record.bytesReceived, record.duration, record.ruleAction.rawValue
                        ])
                }
                for appID in Set(records.map(\.appBundleIdentifier)) {
                    try execute("""
                        DELETE FROM app_connection_history WHERE app_id = ? AND id NOT IN
                        (SELECT id FROM app_connection_history WHERE app_id = ? ORDER BY timestamp DESC LIMIT ?)
                        """, [appID, appID, max(1, historyLimit)])
                }
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    public func recentConnections(for appID: String, limit: Int) throws -> [AppConnectionRecord] {
        try queue.sync {
            let statement = try prepare("""
                SELECT id, timestamp, app_id, pid, direction, protocol, local_address, local_port,
                       remote_address, remote_port, remote_hostname, country_code, state, bytes_sent,
                       bytes_received, duration, rule_action
                FROM app_connection_history WHERE app_id = ? ORDER BY timestamp DESC LIMIT ?
                """)
            defer { sqlite3_finalize(statement) }
            bind(appID, to: statement, at: 1)
            bind(max(1, limit), to: statement, at: 2)
            var result: [AppConnectionRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = text(statement, 0), let appID = text(statement, 2) else { continue }
                result.append(AppConnectionRecord(
                    id: id,
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    appBundleIdentifier: appID,
                    pid: Int(sqlite3_column_int64(statement, 3)),
                    direction: AppConnectionDirection(rawValue: text(statement, 4) ?? "") ?? .outbound,
                    protocolKind: NetworkProtocolKind(rawValue: text(statement, 5) ?? "") ?? .tcp,
                    localAddress: text(statement, 6) ?? "",
                    localPort: text(statement, 7) ?? "",
                    remoteAddress: text(statement, 8), remotePort: text(statement, 9),
                    remoteHostname: text(statement, 10), countryCode: text(statement, 11),
                    state: text(statement, 12) ?? "", bytesSent: uint(statement, 13),
                    bytesReceived: uint(statement, 14), duration: sqlite3_column_double(statement, 15),
                    ruleAction: AppRuleAction(rawValue: text(statement, 16) ?? "") ?? .observed
                ))
            }
            return result
        }
    }

    public func clearHistory(for appID: String) throws {
        try queue.sync { try execute("DELETE FROM app_connection_history WHERE app_id = ?", [appID]) }
    }

    private func migrate() throws {
        try execute("PRAGMA journal_mode = WAL")
        try execute("""
            CREATE TABLE IF NOT EXISTS app_connection_history (
                id TEXT PRIMARY KEY, timestamp REAL NOT NULL, app_id TEXT NOT NULL, pid INTEGER NOT NULL,
                direction TEXT NOT NULL, protocol TEXT NOT NULL, local_address TEXT NOT NULL,
                local_port TEXT NOT NULL, remote_address TEXT, remote_port TEXT, remote_hostname TEXT,
                country_code TEXT, state TEXT NOT NULL, bytes_sent INTEGER, bytes_received INTEGER,
                duration REAL NOT NULL, rule_action TEXT NOT NULL
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS idx_app_history_recent ON app_connection_history(app_id, timestamp DESC)")
        try execute("""
            CREATE TABLE IF NOT EXISTS app_rules (
                app_id TEXT PRIMARY KEY, action TEXT NOT NULL, updated_at REAL NOT NULL
            )
            """)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw ApplicationDatabaseError.queryFailed(errorText) }
        return statement
    }

    private func execute(_ sql: String, _ values: [Any?] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() { bind(value, to: statement, at: Int32(offset + 1)) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else {
            throw ApplicationDatabaseError.queryFailed(errorText)
        }
    }

    private func bind(_ value: Any?, to statement: OpaquePointer?, at index: Int32) {
        switch value {
        case let value as String: sqlite3_bind_text(statement, index, value, -1, applicationSQLiteTransient)
        case let value as Int: sqlite3_bind_int64(statement, index, Int64(value))
        case let value as UInt64: sqlite3_bind_int64(statement, index, Int64(clamping: value))
        case let value as Double: sqlite3_bind_double(statement, index, value)
        default: sqlite3_bind_null(statement, index)
        }
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return String(cString: sqlite3_column_text(statement, index))
    }

    private func uint(_ statement: OpaquePointer?, _ index: Int32) -> UInt64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return UInt64(max(0, sqlite3_column_int64(statement, index)))
    }

    private var errorText: String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error" }

    private static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("Live Connections Monitor", isDirectory: true).appendingPathComponent("applications.sqlite")
    }
}

private enum ApplicationDatabaseError: LocalizedError {
    case openFailed(String), queryFailed(String)
    var errorDescription: String? {
        switch self {
        case let .openFailed(message): "Could not open application history: \(message)"
        case let .queryFailed(message): "Application history query failed: \(message)"
        }
    }
}

private let applicationSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
