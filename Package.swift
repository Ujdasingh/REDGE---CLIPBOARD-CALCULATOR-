// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Redge",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Redge",
            path: "Sources/Redge"
        )
    ]
)
