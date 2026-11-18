// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "GmailPushBridge",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "GmailPushBridge", targets: ["GmailPushBridge"])
    ],
    targets: [
        .executableTarget(
            name: "GmailPushBridge",
            path: "Sources/GmailPushBridge"
        ),
        .testTarget(
            name: "GmailPushBridgeTests",
            dependencies: ["GmailPushBridge"],
            path: "Tests/GmailPushBridgeTests"
        )
    ]
)
