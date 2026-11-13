// swift-tools-version: 5.10
// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "OpenRayneoBridge",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OpenRayneoCore", targets: ["OpenRayneoCore"]),
        .executable(name: "openrayneo-bridge", targets: ["OpenRayneoBridge"])
    ],
    targets: [
        .target(
            name: "OpenRayneoCore",
            linkerSettings: [.linkedFramework("IOBluetooth")]
        ),
        .executableTarget(
            name: "OpenRayneoBridge",
            dependencies: ["OpenRayneoCore"]
        ),
        .testTarget(
            name: "OpenRayneoCoreTests",
            dependencies: ["OpenRayneoCore"]
        )
    ]
)
