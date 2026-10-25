// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TwilDiaryCore",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "TwilDiaryCore", targets: ["TwilDiaryCore"]),
        .library(name: "TwilDiaryTestSupport", targets: ["TwilDiaryTestSupport"])
    ],
    targets: [
        .target(name: "TwilDiaryCore", linkerSettings: [.linkedFramework("AppIntents", .when(platforms: [.iOS]))]),
        .target(name: "TwilDiaryTestSupport", dependencies: ["TwilDiaryCore"], resources: [.process("Fixtures")]),
        .testTarget(name: "TwilDiaryCoreTests", dependencies: ["TwilDiaryCore", "TwilDiaryTestSupport"], resources: [.process("Fixtures")])
    ]
)
