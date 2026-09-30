// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Switchboard",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Switchboard", targets: ["Switchboard"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "SwitchboardCore"),
        .executableTarget(name: "Switchboard", dependencies: ["SwitchboardCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "SwitchboardCoreTests", dependencies: ["SwitchboardCore"])
    ]
)
