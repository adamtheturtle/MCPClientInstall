// swift-tools-version: 6.2
import PackageDescription

/// Safe, non-destructive editing of MCP desktop-client configuration files.
///
/// Uses Foundation plus swift-toml's C++ parser. The package supports Apple
/// platforms and Linux; Apple declarations do not restrict SwiftPM's Linux availability.
let package = Package(
    name: "MCPClientInstall",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "MCPClientInstall", targets: ["MCPClientInstall"])
    ],
    dependencies: [
        .package(url: "https://github.com/mattt/swift-toml.git", from: "2.0.0")
    ],
    targets: [
        .target(
            name: "MCPClientInstall",
            dependencies: [
                .product(name: "TOML", package: "swift-toml")
            ],
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
