// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "LiveConnectionsMonitor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LiveConnectionsMonitor", targets: ["LiveConnectionsMonitor"])
    ],
    targets: [
        .target(
            name: "LiveConnectionsMonitorCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "LiveConnectionsMonitor",
            dependencies: ["LiveConnectionsMonitorCore"]
        ),
        .testTarget(
            name: "LiveConnectionsMonitorTests",
            dependencies: ["LiveConnectionsMonitorCore"]
        )
    ],
    swiftLanguageModes: [.v6]
)
