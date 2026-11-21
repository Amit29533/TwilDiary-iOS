// swift-tools-version:5.9
import PackageDescription

// mpv for JellySpace's second player: Streamyfin's build of MPVKit (mpv 0.41, FFmpeg 8.1, GPL),
// which adds vo_avfoundation: VideoToolbox frames handed straight to an AVSampleBufferDisplayLayer,
// as AVPlayer and AetherEngine show video, instead of drawing every frame through Vulkan on Metal.
// It keeps gpu-next too (used only for smooth motion, which needs a GPU renderer).
// Their own Package.swift points at an older build, so the release is pinned here by its checksum.
let package = Package(
    name: "MPVKitAV",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "MPVKitAV", targets: ["MPVKitAV"]),
    ],
    targets: [
        .target(
            name: "MPVKitAV",
            dependencies: ["MPVKit"],
            path: "Sources/MPVKitAV",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("VideoToolbox"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedLibrary("xml2"),
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
                .linkedLibrary("resolv"),
                .linkedLibrary("expat"),
            ]
        ),
        .binaryTarget(
            name: "MPVKit",
            url: "https://github.com/streamyfin/MPVKit/releases/download/0.41.0-av5/MPVKit.xcframework.zip",
            checksum: "80a79fbb34b1a3ae84744fe7bb9d365d2a006a5f617460933b7ce777251d3618"
        ),
    ]
)
