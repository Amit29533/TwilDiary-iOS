// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TwilDiaryCore",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "TwilDiaryCore", targets: ["TwilDiaryCore"])],
    targets: [.target(name: "TwilDiaryCore", resources: [.process("Fixtures")]), .testTarget(name: "TwilDiaryCoreTests", dependencies: ["TwilDiaryCore"]) ]
)
