// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Houston",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Prebuilt libghostty XCFramework + Swift terminal views. Pins the
        // upstream Ghostty commit in its own Ghostty.ref, so a package bump
        // can't silently move to a different Ghostty build. MIT, macOS 13+.
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.3.2"),
    ],
    targets: [
        .executableTarget(
            name: "Houston",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "GhosttyTheme", package: "libghostty-spm"),
            ],
            path: "Sources/Houston",
            resources: [
                .copy("Resources/icons"),
            ]
        )
    ]
)
