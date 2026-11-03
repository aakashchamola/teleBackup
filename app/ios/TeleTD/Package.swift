// swift-tools-version:5.9
import PackageDescription

// The Telegram account on iPhone: TDLib behind the core's `TdGateway`. Kept apart from TeleCore so the core's tests stay fast.
// The TDLib build is a community build of the official sources (Swiftgram); SwiftPM checks the download against a fixed SHA-256.
let package = Package(
    name: "TeleTD",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "TeleTD", targets: ["TeleTD"])],
    dependencies: [
        .package(path: "../TeleCore"),
        .package(path: "../ThirdParty/TDLibFramework"),
    ],
    targets: [
        .target(name: "TeleTD", dependencies: ["TeleCore", .product(name: "TDLibFramework", package: "TDLibFramework")]),
        .testTarget(name: "TeleTDTests", dependencies: ["TeleTD", "TeleCore"]),
    ]
)
