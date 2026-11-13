// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import OpenRayneoCore

if let commandIndex = CommandLine.arguments.firstIndex(where: { $0 == "--pair" || $0 == "--pairing-status" || $0 == "--unpair" }) {
    guard CommandLine.arguments.indices.contains(commandIndex + 1) else {
        fputs("Usage: openrayneo-bridge --unpair|--pair|--pairing-status AA-BB-CC-DD-EE-FF\n", stderr)
        exit(1)
    }
    let address = CommandLine.arguments[commandIndex + 1]
    if CommandLine.arguments[commandIndex] == "--unpair" { exit(runUnpairingCommand(address: address)) }
    exit(runPairingCommand(address: address, statusOnly: CommandLine.arguments[commandIndex] == "--pairing-status"))
}

if !CommandLine.arguments.contains("--headless"),
   Bundle.main.bundlePath.hasSuffix(".app") || CommandLine.arguments.contains("--gui") {
    MainActor.assumeIsolated { runDesktopApplication() }
}

guard let address = BridgeController.resolveRayneoAddress() else {
    fputs("Pair one RayNeo iO with this Mac, or set RAYNEO_ADDRESS if several are paired.\n", stderr)
    exit(1)
}
let token = ProcessInfo.processInfo.environment["OPENRAYNEO_API_TOKEN"] ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
let port = UInt16(ProcessInfo.processInfo.environment["OPENRAYNEO_PORT"] ?? "8765") ?? 8765
let controller = BridgeController(address: address)
let server = LocalHTTPServer(port: port, token: token, controller: controller)
print("API token: \(token)")
do {
    try server.run()
} catch {
    fputs("OpenRayneo Bridge failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
