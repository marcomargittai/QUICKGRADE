// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QUICKGRADE",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "QuickGrade", targets: ["QuickGradeApp"])
    ],
    targets: [
        .target(name: "QuickGradeCore", path: "Sources/QuickGradeCore"),
        .executableTarget(
            name: "QuickGradeApp",
            dependencies: ["QuickGradeCore"],
            path: "Sources/QuickGradeApp"
        ),
        .testTarget(
            name: "QuickGradeTests",
            dependencies: ["QuickGradeCore"],
            path: "Tests/QuickGradeTests"
        )
    ]
)
