// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "InstantSpaceSwitcher",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "InstantSpaceSwitcher", targets: ["InstantSpaceSwitcher"]),
        .executable(name: "cubicle", targets: ["CubicleCLI"]),
        // Libraries the Xcode project (project.yml) links into the app and the embedded CLI.
        .library(name: "ISS", targets: ["ISS"]),
        .library(name: "CubicleIPC", targets: ["CubicleIPC"])
    ],
    targets: [
        .target(
            name: "ISS",
            dependencies: [],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit")
            ]
        ),
        .target(name: "CubicleIPC"),
        .executableTarget(
            name: "InstantSpaceSwitcher",
            dependencies: ["ISS", "CubicleIPC"]
        ),
        .executableTarget(
            name: "CubicleCLI",
            dependencies: ["CubicleIPC"]
        ),
        .testTarget(
            name: "ISSTests",
            dependencies: ["ISS", "InstantSpaceSwitcher", "CubicleIPC"]
        )
    ]
)
