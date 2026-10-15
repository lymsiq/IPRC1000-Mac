// swift-tools-version: 6.0
import PackageDescription
import Foundation

let sbcLibraryPath = ProcessInfo.processInfo.environment["IPRC1000_SBC_LIBRARY_PATH"] ?? "Vendor/lib"

let package = Package(
    name: "IPRC1000Adapter",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "IPRC1000Adapter", targets: ["IPRC1000Adapter"])
    ],
    targets: [
        .target(
            name: "CRemoteSupport",
            linkerSettings: [
                .unsafeFlags(["-L\(sbcLibraryPath)"]),
                .linkedLibrary("sbc")
            ]
        ),
        .executableTarget(
            name: "IPRC1000Adapter",
            dependencies: ["CRemoteSupport"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("CoreAudio")
            ]
        )
    ]
)
