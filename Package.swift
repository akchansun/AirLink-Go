// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HuChuan",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HuChuanCore", targets: ["HuChuanCore"]),
        .executable(name: "HuChuan", targets: ["HuChuan"]),
    ],
    targets: [
        .target(
            name: "HuChuanCore",
            path: "Sources/HuChuanCore",
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedFramework("CryptoKit"),
            ]
        ),
        .executableTarget(
            name: "HuChuan",
            dependencies: ["HuChuanCore"],
            path: "Sources/HuChuan",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Network"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
