// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import CoreFoundation
import Foundation

struct OfficialCloudSyncConfiguration: Sendable {
    let syncFlag: Bool
    let autoSync: Bool
    let onlyWifiSync: Bool
    let capacity: Int64?
    let usedCapacity: Int64?

    // APK CloudConfigVo 0x15e0864 defaults absent flags to false / true / false.
    init(json: [String: Any]) {
        func flag(_ key: String, default fallback: Bool, other: Bool) -> Bool {
            guard let value = json[key], !(value is NSNull) else { return fallback }
            if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
                if "cCsSiIlLqQ".contains(String(cString: number.objCType)) { return number.int64Value != 0 }
            }
            return other
        }
        func integer(_ key: String) -> Int64? {
            guard let value = json[key] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            return value.int64Value
        }
        syncFlag = flag("syncFlag", default: false, other: true)
        autoSync = flag("autoSync", default: true, other: true)
        onlyWifiSync = flag("onlyWifiSync", default: false, other: false)
        capacity = integer("capacity"); usedCapacity = integer("usedCapacity")
    }
}

struct OfficialCloudSyncSettingsRequest: Sendable {
    let syncFlag: Bool
    let autoSync: Bool
    let onlyWifiSync: Bool

    // EditConfigRequest 0x21c05d4 emits all three fields as integers.
    var jsonBody: [String: Any] {
        ["syncFlag": syncFlag ? 1 : 0, "autoSync": autoSync ? 1 : 0, "onlyWifiSync": onlyWifiSync ? 1 : 0]
    }
}

/// A Session row's audio address, independent of any temporary OSS credentials.
struct OfficialCloudAudioItem: Sendable {
    let taskID: String
    let title: String
    let taskType: String?
    let createdAtMilliseconds: Int64?
    let updatedAtMilliseconds: Int64?
    let bucketName: String?
    let objectKey: String?

    init(taskID: String, title: String, taskType: String? = nil,
         createdAtMilliseconds: Int64? = nil, updatedAtMilliseconds: Int64? = nil,
         bucketName: String? = nil, objectKey: String? = nil) {
        self.taskID = taskID; self.title = title; self.taskType = taskType
        self.createdAtMilliseconds = createdAtMilliseconds; self.updatedAtMilliseconds = updatedAtMilliseconds
        self.bucketName = bucketName; self.objectKey = objectKey
    }

    init?(session: [String: Any]) {
        guard let taskID = OfficialMemoryRow.text(session["taskId"]) else { return nil }
        self.init(taskID: taskID, title: session["name"] as? String ?? "", taskType: session["taskType"] as? String,
            createdAtMilliseconds: OfficialMemoryRow.milliseconds(session["createTime"]),
            updatedAtMilliseconds: OfficialMemoryRow.milliseconds(session["updateTime"]),
            bucketName: session["bucketName"] as? String, objectKey: session["objectKey"] as? String)
    }
}

struct OfficialCloudAudioDifference: Sendable {
    let localOnly: [OfficialCloudAudioItem]
    let cloudOnly: [OfficialCloudAudioItem]

    /// Supply a complete cloud snapshot and only completed, nonempty local audio.
    /// APK 0x15da29c does not upload local IDs missing from the cloud Session list.
    static func calculate(local: [OfficialCloudAudioItem], cloud: [OfficialCloudAudioItem]) -> Self {
        let localIDs = Set(local.map(\.taskID))
        var cloudByID: [String: OfficialCloudAudioItem] = [:]
        for item in cloud { cloudByID[item.taskID] = item }
        let uploads = local.filter { item in
            guard let remote = cloudByID[item.taskID] else { return false }
            return remote.objectKey?.isEmpty != false
        }
        let downloads = cloud.filter { item in
            item.objectKey?.isEmpty == false && !localIDs.contains(item.taskID)
        }
        return Self(localOnly: uploads, cloudOnly: downloads)
    }
}
