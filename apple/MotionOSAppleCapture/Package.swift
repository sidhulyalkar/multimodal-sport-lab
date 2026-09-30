// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MotionOSAppleCapture",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(name: "MotionOSAppleCapture", targets: ["MotionOSAppleCapture"])
    ],
    targets: [
        .target(name: "MotionOSAppleCapture"),
        .testTarget(
            name: "MotionOSAppleCaptureTests",
            dependencies: ["MotionOSAppleCapture"],
            resources: [.copy("Fixtures")]
        )
    ]
)
