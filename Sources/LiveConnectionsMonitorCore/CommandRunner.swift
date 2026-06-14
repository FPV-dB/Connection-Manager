import Foundation

public struct CommandResult: Sendable {
    public let output: String
    public let errorOutput: String
    public let exitCode: Int32
}

public enum CommandRunnerError: LocalizedError {
    case launchFailed(String)
    case failed(path: String, code: Int32, output: String)

    public var errorDescription: String? {
        switch self {
        case let .launchFailed(message):
            return message
        case let .failed(path, code, output):
            return "\(path) failed with exit code \(code): \(output)"
        }
    }
}

public struct CommandRunner: Sendable {
    public init() {}

    public func run(_ path: String, arguments: [String]) async throws -> CommandResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                throw CommandRunnerError.launchFailed("Unable to launch \(path): \(error.localizedDescription)")
            }

            process.waitUntilExit()
            let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return CommandResult(output: output, errorOutput: errorOutput, exitCode: process.terminationStatus)
        }.value
    }

    public func runAppleScriptWithAdministratorPrivileges(shellScript: String) async throws {
        let escaped = shellScript.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let result = try await run("/usr/bin/osascript", arguments: [
            "-e",
            "do shell script \"\(escaped)\" with administrator privileges"
        ])
        guard result.exitCode == 0 else {
            throw CommandRunnerError.failed(
                path: "/usr/bin/osascript",
                code: result.exitCode,
                output: result.errorOutput.isEmpty ? result.output : result.errorOutput
            )
        }
    }
}
