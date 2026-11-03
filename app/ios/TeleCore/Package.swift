// swift-tools-version:5.9
import PackageDescription

// The iPhone core: pure Swift, no UIKit. `swift test` runs on the Mac; the Runner app links it through TeleCore.podspec.
let package = Package(
    name: "TeleCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "TeleCore", targets: ["TeleCore"])],
    targets: [
        .target(name: "TeleCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "TeleCoreTests", dependencies: ["TeleCore"]),
    ]
)
