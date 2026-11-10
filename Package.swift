// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ooid",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "Ooid",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            resources: [
                .copy("Shaders.metal"),
                .copy("AppIcon.png"),
                .copy("wallpaper.icon"),
            ],
            swiftSettings: [
                .unsafeFlags(["-O", "-whole-module-optimization"], .when(configuration: .release)),
            ],
            // Where dyld finds Sparkle.framework: inside the .app, then next to the `swift run` binary.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path",
                ]),
            ]
        )
    ]
)
