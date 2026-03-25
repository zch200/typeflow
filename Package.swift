// swift-tools-version: 6.0
import PackageDescription

let whisperBuild = "Libraries/whisper.cpp/build"

let package = Package(
    name: "TypeFlow",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TypeFlow", targets: ["TypeFlow"])
    ],
    targets: [
        .target(
            name: "CWhisper",
            path: "Sources/CWhisper",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags([
                    "-ILibraries/whisper.cpp/include",
                    "-ILibraries/whisper.cpp/ggml/include",
                ])
            ]
        ),
        .executableTarget(
            name: "TypeFlow",
            dependencies: ["CWhisper"],
            path: "Sources/TypeFlow",
            swiftSettings: [
                .unsafeFlags([
                    "-Xcc", "-ILibraries/whisper.cpp/include",
                    "-Xcc", "-ILibraries/whisper.cpp/ggml/include",
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "App/Info.plist",
                    "-L\(whisperBuild)/src",
                    "-L\(whisperBuild)/ggml/src",
                    "-L\(whisperBuild)/ggml/src/ggml-metal",
                    "-L\(whisperBuild)/ggml/src/ggml-blas",
                    "-lwhisper",
                    "-lggml",
                    "-lggml-base",
                    "-lggml-cpu",
                    "-lggml-metal",
                    "-lggml-blas",
                    "-lc++",
                ]),
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        )
    ]
)
