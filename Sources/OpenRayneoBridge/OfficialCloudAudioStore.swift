// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct OfficialCloudAudioRecord: Codable, Identifiable {
    var id = UUID()
    let taskID: String
    var title: String
    var taskType: String?
    var createdAtMilliseconds: Int64?
    var bucketName: String?
    var objectKey: String?
    var compressedPath: String?
    var audioPath: String?
    var duration: Double?
    var channelCount: Int?
    var state = "queued"
    var lastError: String?

    var hasLocalSource: Bool {
        guard let compressedPath else { return false }
        let size = try? URL(fileURLWithPath: compressedPath).resourceValues(forKeys: [.fileSizeKey]).fileSize
        return (size ?? 0) > 0
    }
    var hasPlayableAudio: Bool {
        guard let audioPath else { return false }
        return FileManager.default.fileExists(atPath: audioPath)
    }
}

@MainActor
final class OfficialCloudAudioStore {
    private struct Index: Codable {
        var records: [String: OfficialCloudAudioRecord] = [:]
        var suppressed = Set<String>()
        var cloudDeleted: Set<String>?
        var automaticallyDownload = false
    }
    let ownerScope: String
    let directory: URL
    private var index = Index()
    var records: [String: OfficialCloudAudioRecord] { index.records }
    var suppressed: Set<String> { index.suppressed }
    var cloudDeleted: Set<String> { index.cloudDeleted ?? [] }
    var automaticallyDownload: Bool { index.automaticallyDownload }

    init(configuration: OfficialFirmwareConfiguration) throws {
        ownerScope = try OfficialRecordingUploadStore.accountScope(configuration: configuration).uuidString
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenRayneo/RecordingLibrary/OfficialCloudAudio", isDirectory: true)
            .appendingPathComponent(ownerScope, isDirectory: true)
        let file = directory.appendingPathComponent("index.json")
        if FileManager.default.fileExists(atPath: file.path) { index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: file)) }
    }

    func save(_ record: OfficialCloudAudioRecord) throws {
        var updated = index; updated.records[record.taskID] = record; try persist(updated)
    }
    func suppress(taskID: String) throws {
        var updated = index; updated.suppressed.insert(taskID); try persist(updated)
    }
    func allow(taskID: String) throws {
        guard !cloudDeleted.contains(taskID) else { throw OfficialMemoryFailure(message: "该官方云会话已删除，不能从旧音频地址恢复。") }
        var updated = index; updated.suppressed.remove(taskID); try persist(updated)
    }
    func suppressCloud(taskID: String) throws {
        let file = directory.appendingPathComponent("index.json")
        var updated = FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode(Index.self, from: Data(contentsOf: file)) : index
        updated.suppressed.insert(taskID)
        var deleted = updated.cloudDeleted ?? []; deleted.insert(taskID); updated.cloudDeleted = deleted
        try persist(updated)
    }
    func setAutomatic(_ enabled: Bool) throws {
        var updated = index; updated.automaticallyDownload = enabled; try persist(updated)
    }
    func assetDirectory(_ record: OfficialCloudAudioRecord) -> URL { directory.appendingPathComponent(record.id.uuidString, isDirectory: true) }

    private func persist(_ value: Index) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("index.json")
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        index = value
    }
}
