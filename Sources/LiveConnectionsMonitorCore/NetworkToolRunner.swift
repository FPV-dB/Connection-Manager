import Foundation

public enum NetworkToolKind: Sendable {
    case traceroute
    case ping
}

public enum NetworkToolError: LocalizedError {
    case reservedAddress
    case launchFailed(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .reservedAddress:
            return "This address is local/reserved and is not suitable for this network tool."
        case let .launchFailed(message):
            return message
        case let .unavailable(tool):
            return "\(tool) is not available on this Mac."
        }
    }
}

public final class NetworkToolRunner: @unchecked Sendable {
    private var process: Process?
    private let validator = IPAddressValidator()

    public init() {}

    public var isRunning: Bool {
        process?.isRunning == true
    }

    public func stop() {
        process?.terminate()
        process = nil
    }

    public func run(kind: NetworkToolKind, ip: String, output: @escaping @Sendable (String) -> Void) async throws {
        switch validator.validate(ip) {
        case .valid:
            break
        case .warning, .refused:
            throw NetworkToolError.reservedAddress
        }

        let command = command(for: kind, ip: ip)
        guard FileManager.default.isExecutableFile(atPath: command.path) else {
            throw NetworkToolError.unavailable(command.path)
        }

        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: command.path)
                process.arguments = command.arguments

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                self.process = process

                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    output(text)
                }

                do {
                    try process.run()
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    self.process = nil
                    throw NetworkToolError.launchFailed(error.localizedDescription)
                }

                let timeout = Task {
                    try? await Task.sleep(for: .seconds(kind == .ping ? 12 : 45))
                    if process.isRunning {
                        process.terminate()
                    }
                }

                process.waitUntilExit()
                timeout.cancel()
                pipe.fileHandleForReading.readabilityHandler = nil
                self.process = nil
            }.value
        } onCancel: {
            self.stop()
        }
    }

    private func command(for kind: NetworkToolKind, ip: String) -> (path: String, arguments: [String]) {
        switch kind {
        case .ping:
            return ("/sbin/ping", ["-c", "4", ip])
        case .traceroute:
            if ip.contains(":") {
                if FileManager.default.isExecutableFile(atPath: "/usr/sbin/traceroute6") {
                    return ("/usr/sbin/traceroute6", [ip])
                }
                return ("/usr/sbin/traceroute", ["-6", ip])
            }
            return ("/usr/sbin/traceroute", [ip])
        }
    }
}
