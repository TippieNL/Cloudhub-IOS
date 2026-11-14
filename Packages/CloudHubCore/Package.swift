// swift-tools-version:5.9
//
// Everything in the app that does not need a screen: the API client, the
// models, the upload queue and the rules the screens follow. Kept as a package
// so it builds and tests with `swift test` on any machine -- macOS or Linux --
// without a simulator.
import PackageDescription

let package = Package(
    name: "CloudHubCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "CloudHubCore", targets: ["CloudHubCore"]),
    ],
    targets: [
        .target(name: "CloudHubCore"),
        .testTarget(name: "CloudHubCoreTests", dependencies: ["CloudHubCore"]),
    ]
)
