// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StayAlive",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "StayAlive",
            path: "StayAlive",
            exclude: ["Info.plist", "Assets.xcassets"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications")
            ]
        )
    ]
)
