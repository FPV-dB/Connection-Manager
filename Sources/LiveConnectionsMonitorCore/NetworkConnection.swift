import Foundation

public enum NetworkProtocolKind: String, CaseIterable, Identifiable, Sendable {
    case tcp = "TCP"
    case udp = "UDP"

    public var id: String { rawValue }
}

public enum ConnectionDirection: String, CaseIterable, Identifiable, Sendable {
    case incoming = "incoming"
    case outgoing = "outgoing"
    case listening = "listening"
    case established = "established"
    case unknown = "unknown"

    public var id: String { rawValue }
}

public struct NetworkEndpoint: Hashable, Sendable {
    public var address: String
    public var port: String

    public init(address: String, port: String) {
        self.address = address
        self.port = port
    }
}

public struct NetworkConnection: Identifiable, Hashable, Sendable {
    public var id: String { dedupeKey }
    public let processName: String
    public let pid: Int?
    public let protocolKind: NetworkProtocolKind
    public let direction: ConnectionDirection
    public let local: NetworkEndpoint
    public let remote: NetworkEndpoint?
    public let state: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var bytesIn: UInt64?
    public var bytesOut: UInt64?
    public var bytesInPerSecond: Double?
    public var bytesOutPerSecond: Double?

    public var dedupeKey: String {
        [
            protocolKind.rawValue,
            local.address,
            local.port,
            remote?.address ?? "",
            remote?.port ?? "",
            pid.map(String.init) ?? ""
        ].joined(separator: "|")
    }

    public init(
        processName: String,
        pid: Int?,
        protocolKind: NetworkProtocolKind,
        direction: ConnectionDirection,
        local: NetworkEndpoint,
        remote: NetworkEndpoint?,
        state: String,
        firstSeen: Date,
        lastSeen: Date,
        bytesIn: UInt64? = nil,
        bytesOut: UInt64? = nil,
        bytesInPerSecond: Double? = nil,
        bytesOutPerSecond: Double? = nil
    ) {
        self.processName = processName
        self.pid = pid
        self.protocolKind = protocolKind
        self.direction = direction
        self.local = local
        self.remote = remote
        self.state = state
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.bytesInPerSecond = bytesInPerSecond
        self.bytesOutPerSecond = bytesOutPerSecond
    }

    public var pidSortValue: Int { pid ?? -1 }
    public var protocolSortValue: String { protocolKind.rawValue }
    public var directionSortValue: String { direction.rawValue }
    public var localAddressSortValue: String { local.address }
    public var localPortSortValue: Int { Int(local.port) ?? -1 }
    public var remoteAddressSortValue: String { remote?.address ?? "" }
    public var remotePortSortValue: Int { Int(remote?.port ?? "") ?? -1 }
    public var bytesInSortValue: UInt64 { bytesIn ?? 0 }
    public var bytesOutSortValue: UInt64 { bytesOut ?? 0 }
    public var bytesInRateSortValue: Double { bytesInPerSecond ?? 0 }
    public var bytesOutRateSortValue: Double { bytesOutPerSecond ?? 0 }
}

public enum RefreshInterval: String, CaseIterable, Identifiable, Sendable {
    case manual = "Manual"
    case one = "1s"
    case two = "2s"
    case five = "5s"
    case ten = "10s"
    case thirty = "30s"

    public var id: String { rawValue }

    public var seconds: UInt64? {
        switch self {
        case .manual: nil
        case .one: 1
        case .two: 2
        case .five: 5
        case .ten: 10
        case .thirty: 30
        }
    }
}

public enum ConnectionSortField: String, CaseIterable, Identifiable, Sendable {
    case process = "Process"
    case pid = "PID"
    case proto = "Protocol"
    case direction = "Direction"
    case localAddress = "Local Address"
    case localPort = "Local Port"
    case remoteAddress = "Remote Address"
    case remotePort = "Remote Port"
    case state = "State"
    case bytesIn = "Bytes In"
    case bytesOut = "Bytes Out"
    case inboundRate = "In/s"
    case outboundRate = "Out/s"

    public var id: String { rawValue }
}
