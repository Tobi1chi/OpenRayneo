// swift-tools-version: 5.10
// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "OpenRayneoBridge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "openrayneo-bridge", targets: ["OpenRayneoBridge"])
    ],
    targets: [
        .executableTarget(
            name: "OpenRayneoBridge",
            linkerSettings: [.linkedFramework("IOBluetooth")]
        )
    ]
)
