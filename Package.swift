// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Thuner",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Pure logic (state machine, level gate, track identity). No Apple media frameworks, so it's easy to test.
        .target(name: "ThunerCore"),
        // The menu bar app: Core Audio / AVAudioEngine capture, ShazamKit matching, Tuneshine, LAN coordination.
        .executableTarget(
            name: "Thuner",
            dependencies: ["ThunerCore", .product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework is copied into Contents/Frameworks by Scripts/build-app.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "ThunerCoreTests", dependencies: ["ThunerCore"]),
    ],
    swiftLanguageModes: [.v5]
)
