// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoolMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CoolMac", targets: ["CoolMacApp"]),
        .executable(name: "CoolMacHelper", targets: ["CoolMacHelper"]),
        .executable(name: "coolmacctl", targets: ["CoolMacCLI"]),
    ],
    targets: [
        .target(name: "CSMC", publicHeadersPath: "include", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "CIPC", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fblocks"])], linkerSettings: [.linkedFramework("Security"), .linkedFramework("CoreFoundation")]),
        .target(name: "CoolMacCore"),
        .target(name: "CoolMacUpdates"),
        .target(name: "CoolMacHardware", dependencies: ["CSMC", "CoolMacCore"], linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "CoolMacClient", dependencies: ["CIPC", "CoolMacCore"]),
        .executableTarget(name: "CoolMacApp", dependencies: ["CoolMacCore", "CoolMacHardware", "CoolMacClient", "CoolMacUpdates"], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ServiceManagement")]),
        .executableTarget(name: "CoolMacHelper", dependencies: ["CoolMacCore", "CoolMacHardware", "CIPC"], linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("SystemConfiguration")]),
        .executableTarget(name: "CoolMacCLI", dependencies: ["CoolMacCore", "CoolMacHardware", "CoolMacClient"]),
        .executableTarget(name: "CoolMacRelease", dependencies: ["CoolMacUpdates"], linkerSettings: [.linkedFramework("Security")]),
        .executableTarget(name: "CoolMacInstallTool", dependencies: ["CoolMacCore", "CoolMacUpdates"], linkerSettings: [.linkedFramework("Security")]),
        .testTarget(name: "CoolMacCoreTests", dependencies: ["CoolMacCore"]),
        .testTarget(name: "CoolMacUpdatesTests", dependencies: ["CoolMacUpdates"]),
        .testTarget(name: "CoolMacHardwareTests", dependencies: ["CoolMacHardware", "CSMC"]),
    ]
)
