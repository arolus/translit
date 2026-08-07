// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Translit",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "translit"),
    ]
)
