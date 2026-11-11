// swift-tools-version: 5.9
import PackageDescription

// NotionBar builds two ways:
//   • ./build.sh            → build/NotionBar.app (works with just the Command Line Tools)
//   • NotionBar.xcodeproj   → open in Xcode and press Run
// This manifest drives the first one. Resources are copied into the .app by build.sh,
// so SwiftPM is told to leave that folder alone.
let package = Package(
    name: "NotionBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotionBar",
            path: "Sources/NotionBar",
            exclude: ["Resources"]
        )
    ]
)
