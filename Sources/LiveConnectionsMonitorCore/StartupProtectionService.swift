import Foundation
import ServiceManagement

public struct LoginItemService: Sendable {
    public init() {}

    public func status() -> String {
        switch SMAppService.mainApp.status {
        case .enabled: return "Enabled"
        case .notRegistered: return "Disabled"
        case .requiresApproval: return "Requires Approval"
        case .notFound: return "Unavailable"
        @unknown default: return "Unknown"
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}

public actor StartupProtectionService {
    public static let startupAnchor = "com.apple/com.connectionmanager.startup"
    public static let rulesAnchor = "com.apple/com.connectionmanager.rules"
    public static let blocklistsAnchor = "com.apple/com.connectionmanager.blocklists"
    public static let startupAnchorPath = "/etc/pf.anchors/com.connectionmanager.startup"

    private let runner: CommandRunner

    public init(runner: CommandRunner = CommandRunner()) {
        self.runner = runner
    }

    public func status(settings: FirewallSettings) async -> StartupProtectionStatus {
        let pf = await pfStatus()
        let installed = FileManager.default.fileExists(atPath: Self.startupAnchorPath)
        return StartupProtectionStatus(
            pfEnabled: pf,
            startupAnchorInstalled: installed || settings.startupAnchorInstalled,
            rulesLoaded: settings.startupRulesLoaded,
            lastSynchronization: settings.lastStartupSynchronizationAt
        )
    }

    public func install(mode: StartupProtectionMode, rulePreview: String, backup: Bool) async throws {
        let rules = startupRules(mode: mode, rulePreview: rulePreview)
        let backupCommand = backup ? "if [ -f \"\(Self.startupAnchorPath)\" ]; then /bin/cp \"\(Self.startupAnchorPath)\" \"\(Self.startupAnchorPath).bak.$(/bin/date +%Y%m%d%H%M%S)\"; fi" : ":"
        let script = """
        set -e
        tmp="$(/usr/bin/mktemp)"
        /bin/cat > "$tmp" <<'EOF'
        \(rules)
        EOF
        \(backupCommand)
        /usr/bin/install -m 0644 "$tmp" "\(Self.startupAnchorPath)"
        /bin/rm -f "$tmp"
        /sbin/pfctl -a "\(Self.startupAnchor)" -f "\(Self.startupAnchorPath)"
        /sbin/pfctl -e >/dev/null 2>&1 || true
        """
        try await runner.runAppleScriptWithAdministratorPrivileges(shellScript: script)
    }

    public func rollback() async throws {
        let script = """
        set -e
        /bin/cat > "\(Self.startupAnchorPath)" <<'EOF'
        # Managed by Connection Manager.
        # Startup protection disabled.
        EOF
        /sbin/pfctl -a "\(Self.startupAnchor)" -f "\(Self.startupAnchorPath)"
        """
        try await runner.runAppleScriptWithAdministratorPrivileges(shellScript: script)
    }

    private func startupRules(mode: StartupProtectionMode, rulePreview: String) -> String {
        switch mode {
        case .monitorOnly:
            return """
            # Managed by Connection Manager.
            # Monitor Only: no startup PF rules.
            """
        case .protectionAtBoot:
            return """
            # Managed by Connection Manager.
            # Startup anchor: \(Self.startupAnchor)
            # Existing app rules are kept active until the UI synchronizes.
            \(rulePreview)
            """
        case .strictStartupLock:
            return """
            # Managed by Connection Manager.
            # Strict Startup Lock: advanced mode.
            # Allows essential local/DNS/DHCP traffic and blocks other traffic until rules are synchronized.
            pass quick on lo0 all
            pass out quick proto udp to port { 53 67 68 123 }
            pass in quick proto udp from port { 53 67 68 123 }
            block drop quick all
            """
        }
    }

    private func pfStatus() async -> String {
        guard let result = try? await runner.run("/sbin/pfctl", arguments: ["-s", "info"]) else { return "Unknown" }
        if result.output.localizedCaseInsensitiveContains("status: enabled") { return "Yes" }
        if result.output.localizedCaseInsensitiveContains("status: disabled") { return "No" }
        return "Unknown"
    }
}
