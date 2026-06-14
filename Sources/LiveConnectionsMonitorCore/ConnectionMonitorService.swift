import Foundation

public actor ConnectionMonitorService {
    private let runner: CommandRunner
    private let parser: ConnectionParser
    private var seen: [String: NetworkConnection] = [:]

    public init(runner: CommandRunner = CommandRunner(), parser: ConnectionParser = ConnectionParser()) {
        self.runner = runner
        self.parser = parser
    }

    public func scan() async throws -> [NetworkConnection] {
        let now = Date()
        let parsed: [NetworkConnection]
        let lsof = try await runner.run("/usr/sbin/lsof", arguments: ["-i", "-n", "-P"])
        if lsof.exitCode == 0 {
            parsed = parser.parseLsof(lsof.output, now: now)
        } else {
            let netstat = try await runner.run("/usr/sbin/netstat", arguments: ["-anv"])
            guard netstat.exitCode == 0 else {
                let output = [lsof.errorOutput, netstat.errorOutput].filter { !$0.isEmpty }.joined(separator: "\n")
                throw CommandRunnerError.failed(path: "lsof/netstat", code: netstat.exitCode, output: output)
            }
            parsed = parser.parseNetstat(netstat.output, now: now)
        }

        var updated: [String: NetworkConnection] = [:]
        for connection in parsed {
            var next = connection
            if let previous = seen[connection.dedupeKey] {
                next.firstSeen = previous.firstSeen
            }
            next.lastSeen = now
            updated[next.dedupeKey] = next
        }
        seen = updated
        return updated.values.sorted {
            if $0.processName != $1.processName { return $0.processName.localizedCaseInsensitiveCompare($1.processName) == .orderedAscending }
            return ($0.pid ?? 0) < ($1.pid ?? 0)
        }
    }
}
