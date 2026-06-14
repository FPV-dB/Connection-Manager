import Foundation

public struct ConnectionParser: Sendable {
    public init() {}

    public func parseLsof(_ output: String, now: Date = Date()) -> [NetworkConnection] {
        output.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            parseLsofLine(String(line), now: now)
        }
    }

    public func parseNetstat(_ output: String, now: Date = Date()) -> [NetworkConnection] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            parseNetstatLine(String(line), now: now)
        }
    }

    private func parseLsofLine(_ line: String, now: Date) -> NetworkConnection? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 8 else { return nil }
        let command = parts[0]
        let pid = Int(parts[1])
        guard let protocolIndex = parts.firstIndex(where: { $0 == "TCP" || $0 == "UDP" }) else { return nil }
        let name = parts[protocolIndex...].joined(separator: " ")
        return parseName(name, processName: command, pid: pid, now: now)
    }

    private func parseNetstatLine(_ line: String, now: Date) -> NetworkConnection? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let proto = parts.first?.lowercased(), proto.hasPrefix("tcp") || proto.hasPrefix("udp") else { return nil }
        guard parts.count >= 5 else { return nil }
        let protocolKind: NetworkProtocolKind = proto.hasPrefix("tcp") ? .tcp : .udp
        let local = parseEndpoint(parts[3])
        let remote = parseEndpoint(parts[4])
        let state = parts.dropFirst(5).first ?? (protocolKind == .udp ? "UDP" : "")
        return NetworkConnection(
            processName: "unknown",
            pid: nil,
            protocolKind: protocolKind,
            direction: direction(protocolKind: protocolKind, state: state, remote: remote),
            local: local,
            remote: isEmptyRemote(remote) ? nil : remote,
            state: state,
            firstSeen: now,
            lastSeen: now
        )
    }

    private func parseName(_ name: String, processName: String, pid: Int?, now: Date) -> NetworkConnection? {
        let protocolKind: NetworkProtocolKind
        if name.hasPrefix("TCP ") {
            protocolKind = .tcp
        } else if name.hasPrefix("UDP ") {
            protocolKind = .udp
        } else {
            return nil
        }

        let withoutProtocol = String(name.dropFirst(4))
        let state = stateText(in: withoutProtocol) ?? (protocolKind == .udp ? "UDP" : "")
        let endpointText = withoutProtocol.replacingOccurrences(of: "\\s+\\([^)]*\\)$", with: "", options: .regularExpression)
        let pair = endpointText.components(separatedBy: "->")
        let local = parseEndpoint(pair.first ?? "")
        let remote = pair.dropFirst().first.map(parseEndpoint)

        return NetworkConnection(
            processName: processName,
            pid: pid,
            protocolKind: protocolKind,
            direction: direction(protocolKind: protocolKind, state: state, remote: remote),
            local: local,
            remote: remote.flatMap { isEmptyRemote($0) ? nil : $0 },
            state: state,
            firstSeen: now,
            lastSeen: now
        )
    }

    private func stateText(in text: String) -> String? {
        guard let open = text.lastIndex(of: "("), let close = text.lastIndex(of: ")"), open < close else { return nil }
        return String(text[text.index(after: open)..<close])
    }

    private func parseEndpoint(_ text: String) -> NetworkEndpoint {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "*" || value == "*.*" {
            return NetworkEndpoint(address: "*", port: "")
        }
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else {
                return NetworkEndpoint(address: value, port: "")
            }
            let address = String(value[value.index(after: value.startIndex)..<close])
            let rest = value[value.index(after: close)...]
            let port = rest.hasPrefix(":") ? String(rest.dropFirst()) : ""
            return NetworkEndpoint(address: address, port: port)
        }
        guard let colon = value.lastIndex(of: ":") else {
            return NetworkEndpoint(address: value, port: "")
        }
        return NetworkEndpoint(
            address: String(value[..<colon]),
            port: String(value[value.index(after: colon)...])
        )
    }

    private func direction(protocolKind: NetworkProtocolKind, state: String, remote: NetworkEndpoint?) -> ConnectionDirection {
        let upper = state.uppercased()
        if upper.contains("LISTEN") { return .listening }
        if upper.contains("ESTABLISHED") { return .established }
        if protocolKind == .udp, remote == nil { return .listening }
        return remote == nil ? .unknown : .established
    }

    private func isEmptyRemote(_ endpoint: NetworkEndpoint) -> Bool {
        endpoint.address.isEmpty || endpoint.address == "*" || endpoint.address == "*.*"
    }
}
