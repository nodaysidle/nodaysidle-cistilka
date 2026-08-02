// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Cistilka",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // In-process SFTP (NIOSSH). If resolution/build fails on a machine, keep
        // Scanner/SFTPClientProtocol.swift + FakeSFTPClient and wire Citadel later.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.11.0"),
    ],
    targets: [
        .executableTarget(
            name: "Cistilka",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Citadel", package: "Citadel"),
            ],
            path: "Sources/Cistilka",
            // Info.plist is packaging metadata, not a SwiftPM resource bundle entry.
            exclude: ["Resources/Info.plist"],
            resources: [.process("Resources")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CistilkaTests",
            dependencies: ["Cistilka"],
            path: "Tests/CistilkaTests"
        ),
    ]
)
