// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PSTE",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PSTE",
            path: "Sources/PSTE"
        )
    ]
)
