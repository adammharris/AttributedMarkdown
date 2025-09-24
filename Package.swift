// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AttributedMarkdown",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v15),
        .watchOS(.v8),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "AttributedMarkdown",
            targets: ["AttributedMarkdown"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.4.0")
    ],
    targets: [
        .target(
            name: "AttributedMarkdown",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown")
            ],
            path: "Sources/AttributedMarkdown"
        ),
        .testTarget(
            name: "AttributedMarkdownTests",
            dependencies: ["AttributedMarkdown"],
            path: "Tests/AttributedMarkdownTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
