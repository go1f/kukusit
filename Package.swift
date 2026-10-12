// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PostureDiagnostics",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PostureDiagnostics", targets: ["PostureDiagnostics"]),
        .executable(name: "PostureCoreChecks", targets: ["PostureCoreChecks"])
    ],
    targets: [
        .target(name: "PostureCore"),
        .executableTarget(name: "KukusitUpdateInstaller", dependencies: ["PostureCore"]),
        .executableTarget(name: "PostureDiagnostics", dependencies: ["PostureCore"]),
        // Dependency-free native checks also run with Command Line Tools alone.
        .executableTarget(name: "PostureCoreChecks", dependencies: ["PostureCore"], path: "Tests/PostureCoreTests")
    ]
)
