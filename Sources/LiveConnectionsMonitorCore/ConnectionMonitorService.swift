import Foundation

public actor ConnectionMonitorService {
    private let runner: CommandRunner
    private let parser: ConnectionParser
    private var seen: [String: NetworkConnection] = [:]
    private var previousUsage: [Int: ProcessNetworkUsage] = [:]

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

        let usage = await usageSnapshot(now: now)
        var updated: [String: NetworkConnection] = [:]
        for connection in parsed {
            var next = connection
            if let previous = seen[connection.dedupeKey] {
                next.firstSeen = previous.firstSeen
            }
            next.lastSeen = now
            if let pid = next.pid, let currentUsage = usage[pid] {
                next.bytesIn = currentUsage.bytesIn
                next.bytesOut = currentUsage.bytesOut
                if let previous = previousUsage[pid] {
                    let elapsed = max(currentUsage.date.timeIntervalSince(previous.date), 0.001)
                    next.bytesInPerSecond = Double(currentUsage.bytesIn.saturatingSubtract(previous.bytesIn)) / elapsed
                    next.bytesOutPerSecond = Double(currentUsage.bytesOut.saturatingSubtract(previous.bytesOut)) / elapsed
                }
            }
            updated[next.dedupeKey] = next
        }
        seen = updated
        previousUsage = usage
        return updated.values.sorted {
            if $0.processName != $1.processName { return $0.processName.localizedCaseInsensitiveCompare($1.processName) == .orderedAscending }
            return ($0.pid ?? 0) < ($1.pid ?? 0)
        }
    }

    private func usageSnapshot(now: Date) async -> [Int: ProcessNetworkUsage] {
        guard let result = try? await runner.run("/usr/bin/nettop", arguments: ["-P", "-L", "1", "-J", "bytes_in,bytes_out"]),
              result.exitCode == 0 else {
            return [:]
        }
        return parseNettop(result.output, now: now)
    }

    private func parseNettop(_ output: String, now: Date) -> [Int: ProcessNetworkUsage] {
        var usage: [Int: ProcessNetworkUsage] = [:]
        for line in output.split(whereSeparator: \.isNewline).map(String.init).dropFirst() {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, let processPID = parts.first else { continue }
            guard let dot = processPID.lastIndex(of: "."),
                  let pid = Int(processPID[processPID.index(after: dot)...]),
                  let bytesIn = UInt64(parts[1]),
                  let bytesOut = UInt64(parts[2]) else {
                continue
            }
            usage[pid] = ProcessNetworkUsage(bytesIn: bytesIn, bytesOut: bytesOut, date: now)
        }
        return usage
    }
}

private struct ProcessNetworkUsage: Sendable {
    let bytesIn: UInt64
    let bytesOut: UInt64
    let date: Date
}

private extension UInt64 {
    func saturatingSubtract(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}
