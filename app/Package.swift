// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DimitriStudio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DimitriStudio",
            path: "Sources/DimitriStudio",
            // The Mol* structure viewer page (Mol* 5.12.0 bundle, MIT), copied
            // as a folder so its files keep their relative paths.
            resources: [.copy("Resources/Viewer")]
        )
    ]
)
