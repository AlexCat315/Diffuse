// swift-tools-version: 6.1
import PackageDescription

// Desktop-only terminal component. It lives outside the GuavaUI package so
// iOS, Android and browser builds never load the libghostty-vt artifact,
// which `guava-dev native-bootstrap` stages into GuavaUI/vendor.
let package = Package(
    name: "GuavaUITerminal",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GuavaUITerminal", targets: ["GuavaUITerminal"]),
        .executable(name: "TerminalDemo", targets: ["TerminalDemo"]),
    ],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        // Ghostty's VT emulator as a static C library. Only Engine/ imports it;
        // its types never appear in GuavaUITerminal's public API.
        .binaryTarget(name: "GhosttyVt", path: "../vendor/GhosttyVt.artifactbundle"),
        .target(name: "GuavaUITerminal", dependencies: [
            "GhosttyVt",
            .product(name: "GuavaUICompose", package: "GuavaUI"),
            .product(name: "GuavaUIRuntime", package: "GuavaUI"),
        ]),
        .executableTarget(name: "TerminalDemo", dependencies: [
            "GuavaUITerminal",
            .product(name: "GuavaUI", package: "GuavaUI"),
        ]),
        .testTarget(name: "GuavaUITerminalTests", dependencies: [
            "GuavaUITerminal",
            .product(name: "GuavaUICompose", package: "GuavaUI"),
            .product(name: "GuavaUIRuntime", package: "GuavaUI"),
        ]),
    ]
)
