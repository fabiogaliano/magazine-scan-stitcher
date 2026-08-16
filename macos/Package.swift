// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MagazineScan",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MagazineScan", targets: ["MagazineScanApp"])
    ],
    targets: [
        .executableTarget(
            name: "MagazineScanApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ImageIO"),
                .linkedFramework("ImageCaptureCore"),
                .linkedFramework("Quartz")
            ]
        )
    ]
)
