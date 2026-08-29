// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Perch",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Perch", targets: ["Perch"])
    ],
    targets: [
        .executableTarget(
            name: "Perch",
            path: "Sources/Perch"
        )
    ]
)
