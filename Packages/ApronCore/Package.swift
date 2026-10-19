// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ApronCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ApronCore", targets: ["ApronCore"]), .executable(name: "apron-probe", targets: ["ApronProbe"])],
    targets: [
        .target(name: "ApronCore"),
        .executableTarget(name: "ApronProbe", dependencies: ["ApronCore"]),
        .testTarget(name: "ApronCoreTests", dependencies: ["ApronCore"], resources: [.copy("Fixtures")])
    ]
)
