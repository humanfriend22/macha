// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "macha",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        // Stable 2.x line: long-lived MQTTClient API. (3.0 is a release candidate with a different API.)
        .package(url: "https://github.com/swift-server-community/mqtt-nio.git", from: "2.13.0"),
        // Direct dependency for ByteBuffer / TimeAmount (NIOCore), which mqtt-nio's API uses.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .executableTarget(
            name: "macha",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "MQTTNIO", package: "mqtt-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            swiftSettings: [
                // IOBluetooth callbacks and the shared state here are not Swift 6 strict-concurrency
                // clean yet. Remove this line once it all works and fix the warnings.
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                // Embed Resources/Info.plist so macOS has a Bluetooth usage string to show.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ]),
            ]
        ),
    ]
)
