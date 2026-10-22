// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SysBar",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SysBar",
            path: "Sources/SysBar",
            resources: [
                .process("Resources/en.lproj"),
                // Keep the authoring catalog available to parity tests without
                // compiling a second copy of the checked-in runtime tables.
                .copy("Resources/Localizable.xcstrings")
            ],
            swiftSettings: [
                .unsafeFlags(["-Osize"], .when(configuration: .release))
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-dead_strip", "-Xlinker", "-dead_strip_dylibs"],
                             .when(configuration: .release))
            ]
        ),
        .testTarget(
            name: "SysBarTests",
            dependencies: ["SysBar"]
        )
    ]
)
