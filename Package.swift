// swift-tools-version: 6.2
import PackageDescription

/// Safe, non-destructive editing of MCP desktop-client configuration files.
///
/// Foundation-only and dependency-free. The package supports macOS and Linux;
/// Apple platform declarations do not restrict SwiftPM's Linux availability.
let package = Package(
    name: "MCPClientInstall",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MCPClientInstall", targets: ["MCPClientInstall"])
    ],
    targets: [
        .target(
            name: "MCPClientInstall",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "MCPClientInstallTests",
            dependencies: ["MCPClientInstall"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
