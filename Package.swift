// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "G309MouseTool",
    platforms: [
        .macOS(.v13)
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
            exclude: ["Info.plist", "G309MouseTool.entitlements"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
