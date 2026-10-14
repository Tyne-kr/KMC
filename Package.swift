// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "G309MouseTool",
    platforms: [
        // Matches LSMinimumSystemVersion in build-app.sh (13.5)
        .macOS("13.5")
    ],
    targets: [
        .target(
            name: "CSPI",
            path: "Sources/CSPI",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "G309MouseTool",
            dependencies: ["CSPI"],
            path: "Sources/G309MouseTool",
            exclude: ["Resources"],  // AppIcon.icns is bundled by build-app.sh, not SPM
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "KMCTests",
            dependencies: ["G309MouseTool"],
            path: "Tests/KMCTests"
        )
    ]
)
