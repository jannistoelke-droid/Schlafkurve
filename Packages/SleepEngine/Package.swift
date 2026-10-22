// swift-tools-version: 6.0
// SleepEngine – the platform-independent analysis core of Schlafkurve.
// SleepEngineCore is pure Swift + Foundation (no Accelerate/AVFoundation), so it builds and
// tests on iOS, macOS, Linux (CI) and Windows (Swift for Windows).
import PackageDescription

let package = Package(
    name: "SleepEngine",
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "SleepEngineCore", targets: ["SleepEngineCore"]),
        .executable(name: "sleepreplay", targets: ["sleepreplay"]),
    ],
    targets: [
        .target(name: "SleepEngineCore"),
        .executableTarget(name: "sleepreplay", dependencies: ["SleepEngineCore"]),
        .testTarget(name: "SleepEngineCoreTests", dependencies: ["SleepEngineCore"]),
    ],
    swiftLanguageModes: [.v5]
)
