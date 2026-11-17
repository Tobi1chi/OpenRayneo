// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct OfficialRecordingUploadRecord: Codable {
    struct Object: Codable {
        var bucketName: String
        var objectKey: String
        var uploaded = false
        var fileID: String?
        var registered = false
    }

    let entryID: UUID
    let taskID: String
    let title: String
    let startMilliseconds: Int64
    let timeZone: String
    let region: String
    var backupAudio: Bool
    var requestedTranscription: Bool
    var sourceLanguage: String
    var separateSpeakers: Bool
    var summaryModel: String?
    var markers: [RecordingMarker]?
    var automaticallyResume: Bool?
    var paused: Bool?
    var priority: Int?
    var queueSource: String?
    var queuedAtMilliseconds: Int64?
    var queueSequence: Int64?
    var prioritySequence: Int64?
    var nativeIdentity: String?
    var transferDirectoryID: UUID?
    var officialPolicyRequired: Bool?
    var stagedFilePath: String?
    var durationMilliseconds: Int64?
    var channelCount: Int?
    var sessionCreated = false
    var object: Object?
    // A submitted request with an unknown outcome must be read back before retry.
    var transcriptionState = "not_submitted"
    var summaryState: String?
    var phase = "等待准备音频"
    var lastError: String?
    var updatedAt = Date()

    var recordingStart: Date { Date(timeIntervalSince1970: Double(startMilliseconds) / 1000) }
    var endMilliseconds: Int64? { durationMilliseconds.map { startMilliseconds + $0 } }
    var needsUpload: Bool {
        !sessionCreated || object?.uploaded != true || (backupAudio && object?.registered != true)
            || (requestedTranscription && transcriptionState == "not_submitted")
    }
    var needsResult: Bool {
        requestedTranscription && sessionCreated
            && (["submitting", "uncertain", "accepted"].contains(transcriptionState)
                || (transcriptionState == "completed" && !["completed", "failed"].contains(summaryState ?? "")))
    }
    var canAutomaticallyContinue: Bool {
        automaticallyResume == true && paused != true && (transcriptionState != "failed" || needsUpload) && (needsUpload || needsResult)
    }
}

/// Separate from the cloud read cache: this journal owns pending local uploads.
@MainActor
final class OfficialRecordingUploadStore {
    let directory: URL
    let ownerScope: String
    private(set) var records: [String: OfficialRecordingUploadRecord] = [:]

    init(configuration: OfficialFirmwareConfiguration) throws {
        let scope = try Self.accountScope(configuration: configuration)
        ownerScope = scope.uuidString
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenRayneo/OfficialRecordingUploads", isDirectory: true)
            .appendingPathComponent(ownerScope, isDirectory: true)
        let file = directory.appendingPathComponent("index.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            records = try decoder.decode([String: OfficialRecordingUploadRecord].self, from: Data(contentsOf: file))
        }
    }

    static func accountScope(configuration: OfficialFirmwareConfiguration) throws -> UUID {
        guard !configuration.accountID.isEmpty else {
            throw OfficialMemoryFailure(message: "录音上传需要官方账号 ID，请先在官方账号页登录或补充已有会话。")
        }
        let key = [configuration.accountID, configuration.baseURL.absoluteString, configuration.region.rawValue]
            .map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        var scopes = UserDefaults.standard.dictionary(forKey: "officialRecordingUploadScopes") as? [String: String] ?? [:]
        let scope: UUID
        let legacyKey = [configuration.accountID, configuration.baseURL.absoluteString]
            .map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        if let value = scopes[key] ?? scopes[legacyKey], let saved = UUID(uuidString: value) {
            scope = saved
            scopes[key] = value; UserDefaults.standard.set(scopes, forKey: "officialRecordingUploadScopes")
        }
        else {
            // Adopt this identity's existing directory on the first upgrade. Later logins
            // to the same account retain pending work; in-flight ownership still uses epochs.
            scope = configuration.identityEpoch ?? UUID(); scopes[key] = scope.uuidString
            UserDefaults.standard.set(scopes, forKey: "officialRecordingUploadScopes")
        }
        return scope
    }

    func save(_ value: OfficialRecordingUploadRecord) throws {
        var record = value; record.updatedAt = Date()
        if record.queueSequence == nil {
            record.queueSequence = records[record.entryID.uuidString]?.queueSequence ?? nextSequence
        }
        var updated = records; updated[record.entryID.uuidString] = record
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(updated)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("index.json")
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        records = updated
    }

    var nextSequence: Int64 {
        (records.values.flatMap { [$0.queueSequence, $0.prioritySequence].compactMap { $0 } }.max() ?? 0) + 1
    }

    func taskDirectory(_ record: OfficialRecordingUploadRecord) -> URL {
        directory.appendingPathComponent(record.transferDirectoryID?.uuidString ?? record.taskID, isDirectory: true)
    }
}
