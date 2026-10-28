// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Markable",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.4.0"),
        .package(path: "Vendor/swift-mermaid")
    ],
    targets: [
        .executableTarget(
            name: "Markable",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "Mermaid", package: "swift-mermaid")
            ],
            path: "Sources",
            resources: [.copy("Resources/KaTeX"), .copy("Resources/Help")]
        ),
        .testTarget(
            name: "MarkableTests",
            dependencies: ["Markable"],
            path: "Tests",
            exclude: ["UI/UsabilityTestPlan.md"]
        )
    ]
)
