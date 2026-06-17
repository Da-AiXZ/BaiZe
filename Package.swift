// swift-tools-version: 5.9
// NOTE: Actual iOS app build is driven by XcodeGen (project.yml). This BaizeKit target is for SPM dependency resolution and development reference only.
import PackageDescription

let package = Package(
    name: "Baize",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "BaizeKit", targets: ["BaizeKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/holzschu/ios_system", branch: "master"),
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess", from: "4.2.2"),
    ],
    targets: [
        .target(
            name: "BaizeKit",
            dependencies: [
                .product(name: "ios_system", package: "ios_system"),
                .product(name: "KeychainAccess", package: "KeychainAccess"),
            ],
            path: "Baize/Baize",
            exclude: ["App/BaizeApp.swift", "Info.plist", "Baize.entitlements"],
            resources: [
                .process("Resources/monaco-editor"),
            ]
        ),
    ]
)
