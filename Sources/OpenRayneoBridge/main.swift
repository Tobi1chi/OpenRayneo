// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IOBluetooth

func resolveRayneoAddress() -> String? {
    if let configured = ProcessInfo.processInfo.environment["RAYNEO_ADDRESS"], !configured.isEmpty {
        return configured
    }
    let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
    let matches = devices.filter { ($0.nameOrAddress ?? "").localizedCaseInsensitiveContains("RayNeo iO") }
    return matches.count == 1 ? matches[0].addressString : nil
}

if let index = CommandLine.arguments.firstIndex(of: "--decode-official-audio") {
    guard CommandLine.arguments.indices.contains(index + 2) else {
        fputs("Usage: openrayneo-bridge --decode-official-audio SOURCE-AUDIO OUTPUT-DIRECTORY\n", stderr); exit(1)
    }
    let source = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    let directory = URL(fileURLWithPath: CommandLine.arguments[index + 2], isDirectory: true)
    Task { @MainActor in
        do {
            let audio = try await OfficialCloudAudioImport.prepare(source: source, directory: directory) { _ in }
            let result: [String: Any] = ["audioPath": audio.audioURL.path, "duration": audio.duration,
                "channelCount": audio.channelCount, "containerDuration": audio.containerDuration as Any? ?? NSNull(), "cloudRequests": false]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)); exit(0)
        } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }
    RunLoop.main.run(); exit(0)
}

if CommandLine.arguments.contains("--official-upload-status") {
    MainActor.assumeIsolated {
        let model = OfficialRecordingUploadModel.shared
        model.background.accountChanged()
        let cloud = OfficialCloudAudioModel.shared
        let jobs: [[String: Any]] = model.records.values.sorted { $0.taskID < $1.taskID }.map {
            ["entryID": $0.entryID.uuidString, "taskID": $0.taskID, "phase": $0.phase,
             "paused": $0.paused == true, "automaticallyResume": $0.automaticallyResume == true,
             "transcriptionState": $0.transcriptionState, "pendingUpload": $0.needsUpload,
             "pendingResult": $0.needsResult]
        }
        let output: [String: Any] = ["configured": model.configured, "jobs": jobs,
            "automaticQueueEnabled": model.configured && model.background.policy.resumeQueued,
            "automaticNewNativeEnabled": model.configured && model.background.policy.newNativeRecordings,
            "cloudAudioConfigured": cloud.configured, "downloadRecords": cloud.records.count,
            "automaticCloudSyncEnabled": cloud.configured && cloud.automaticallyDownload,
            "runtimeStarted": false, "networkRequests": false]
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
    }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--prepare-official-audio") {
    guard CommandLine.arguments.indices.contains(index + 2), let entryID = UUID(uuidString: CommandLine.arguments[index + 1]) else {
        fputs("Usage: openrayneo-bridge --prepare-official-audio LIBRARY-ENTRY-UUID OUTPUT-DIRECTORY\n", stderr)
        exit(1)
    }
    let destination = URL(fileURLWithPath: CommandLine.arguments[index + 2], isDirectory: true)
    Task { @MainActor in
        do {
            let indexURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OpenRayneo/RecordingLibrary/index.json")
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any]
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let entries = try decoder.decode([RecordingLibraryEntry].self,
                from: JSONSerialization.data(withJSONObject: root?["entries"] ?? []))
            guard let entry = entries.first(where: { $0.id == entryID }) else {
                throw OfficialMemoryFailure(message: "录音库中没有这个条目 ID。")
            }
            let audio = try await OfficialRecordingUploadAudio.prepare(entry: entry, destinationDirectory: destination) { _ in }
            let output: [String: Any] = ["entryID": entryID.uuidString, "filePath": audio.fileURL.path,
                "durationMilliseconds": audio.durationMilliseconds, "channelCount": audio.channelCount, "uploaded": false]
            let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self)); exit(0)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
        }
    }
    RunLoop.main.run(); exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--official-device-identity") {
    guard CommandLine.arguments.indices.contains(index + 1),
          let mac = OfficialCloudDeviceRepository.Record.normalizedMAC(CommandLine.arguments[index + 1]) else {
        fputs("Usage: openrayneo-bridge --official-device-identity AA-BB-CC-DD-EE-FF\n", stderr)
        exit(1)
    }
    let identity = OfficialCloudDeviceRepository.Record.nativeID(normalizedMAC: mac)
    let result = ["macAddr": mac, "localDeviceID": identity, "cloudMFISerialNumber": identity]
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]) {
        print(String(decoding: data, as: UTF8.self))
        exit(0)
    }
    exit(1)
}

if let index = CommandLine.arguments.firstIndex(of: "--official-email-agreements") {
    guard CommandLine.arguments.indices.contains(index + 1) else {
        fputs("Usage: openrayneo-bridge --official-email-agreements COUNTRY-CODE\n", stderr); exit(1)
    }
    let country = CommandLine.arguments[index + 1]
    Task {
        do {
            let agreements = try await OfficialEmailLoginService().agreements(country: country)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(agreements), as: UTF8.self)); exit(0)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
        }
    }
    RunLoop.main.run(); exit(0)
}

if CommandLine.arguments.contains("--official-agreements") {
    Task {
        do {
            let agreements = try await OfficialPhoneLoginService().agreements()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(agreements)
            print(String(decoding: data, as: UTF8.self))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
    RunLoop.main.run()
    exit(0)
}

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

private let localServicesOnly = CommandLine.arguments.contains("--local-services-only")
private let address = localServicesOnly ? nil : resolveRayneoAddress()
if !localServicesOnly, address == nil {
    fputs("Pair one RayNeo iO with this Mac, set RAYNEO_ADDRESS, or use --local-services-only for Agent records without glasses.\n", stderr); exit(1)
}
let token = ProcessInfo.processInfo.environment["OPENRAYNEO_API_TOKEN"] ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
let port = UInt16(ProcessInfo.processInfo.environment["OPENRAYNEO_PORT"] ?? "8765") ?? 8765
private let controller = address.map { BridgeController(address: $0) }
private let server = LocalHTTPServer(port: port, token: token, controller: controller)
print("API token: \(token)")
do {
    try server.run()
} catch {
    fputs("OpenRayneo Bridge failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
