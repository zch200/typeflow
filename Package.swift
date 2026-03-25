// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TypeFlow",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TypeFlow", targets: ["TypeFlow"])
    ],
    targets: [
        .executableTarget(
            name: "TypeFlow",
            path: "Sources/TypeFlow",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "App/Info.plist"
                ])
            ]
        )
    ]
)
