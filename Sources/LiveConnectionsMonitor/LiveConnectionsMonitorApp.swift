import AppKit
import LiveConnectionsMonitorCore
import SwiftUI

@main
struct LiveConnectionsMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel: FirewallDashboardViewModel

    init() {
        let database: FirewallDatabase
        do {
            database = try FirewallDatabase()
        } catch {
            fatalError("Unable to open firewall dashboard database: \(error.localizedDescription)")
        }
        let firewallService = FirewallBlockService()
        let liveViewModel = LiveConnectionsViewModel(
            monitorService: ConnectionMonitorService(),
            firewallService: firewallService
        )
        _viewModel = StateObject(wrappedValue: FirewallDashboardViewModel(
            database: database,
            liveConnectionsViewModel: liveViewModel,
            firewallService: firewallService
        ))
    }

    var body: some Scene {
        WindowGroup("Firewall Dashboard") {
            FirewallDashboardView(viewModel: viewModel)
                .frame(minWidth: 1180, minHeight: 720)
                .background(WindowCloseHider())
        }
        .windowStyle(.titleBar)
        .commands {
            CommandMenu("Connections") {
                Button("Show Connections") {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
                }
                .keyboardShortcut("0", modifiers: [.command])

                Button("Refresh Now") {
                    viewModel.reload()
                    Task { await viewModel.liveConnectionsViewModel.refreshNow() }
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }

        MenuBarExtra("Connections", systemImage: "network") {
            Button("Show Connections") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
            }
            Button("Refresh Now") {
                viewModel.reload()
                Task { await viewModel.liveConnectionsViewModel.refreshNow() }
            }
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct WindowCloseHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.delegate = context.coordinator
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.delegate = context.coordinator
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            sender.orderOut(nil)
            return false
        }
    }
}
