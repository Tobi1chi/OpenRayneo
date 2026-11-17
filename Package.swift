// swift-tools-version: 5.10
// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import PackageDescription
import Foundation

let voiceLibraryDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent(".build/local-voice/lib").path

let package = Package(
    name: "OpenRayneoBridge",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AssistantCore", targets: ["AssistantCore"]),
        .executable(name: "openrayneo-bridge", targets: ["OpenRayneoBridge"])
    ],
    dependencies: [.package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1")],
    targets: [
        .systemLibrary(name: "CSherpaOnnx"),
        .target(name: "AssistantCore"),
        .executableTarget(
            name: "OpenRayneoBridge",
            dependencies: ["AssistantCore", "CSherpaOnnx", .product(name: "WhisperKit", package: "argmax-oss-swift")],
            linkerSettings: [.linkedFramework("IOBluetooth"),
                .unsafeFlags(["-L", voiceLibraryDirectory, "-Xlinker", "-rpath", "-Xlinker", voiceLibraryDirectory,
                              "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
