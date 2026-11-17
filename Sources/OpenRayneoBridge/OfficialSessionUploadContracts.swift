// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct OfficialSessionBucketInfo: Decodable {
    let tempBucket: String
    let bucket: String
}

/// Runtime-only OSS credentials returned by the official business API.
struct OfficialSessionTempAK: Decodable {
    let ak: String
    let sk: String
    let st: String
    let endpoint: String
    let bucketName: String
    let regionName: String
    let reqId: String
    let expiration: String
}

struct OfficialSessionCreateRequest {
    enum TaskType: String {
        case recording
        case caption = "cc"
    }

    let taskID: String
    let taskType: TaskType
    let name: String
    let timeZone: String
    let region: String
    let startTimeMs: Int64?
    let endTimeMs: Int64?
    let createTimeMs: Int64
    let audioSaveFlag: Bool?
    let recordingDurationMs: Int64?

    init(taskID: String, taskType: TaskType = .recording, name: String, timeZone: String, region: String,
         startTimeMs: Int64?, endTimeMs: Int64?, createTimeMs: Int64, audioSaveFlag: Bool?, recordingDurationMs: Int64?) {
        self.taskID = taskID
        self.taskType = taskType
        self.name = name
        self.timeZone = timeZone
        self.region = region
        self.startTimeMs = startTimeMs
        self.endTimeMs = endTimeMs
        self.createTimeMs = createTimeMs
        self.audioSaveFlag = audioSaveFlag
        self.recordingDurationMs = recordingDurationMs
    }

    var jsonBody: [String: Any] {
        ["deviceType": "RayNeoS3", "taskId": taskID, "taskType": taskType.rawValue, "name": name,
         "phoneDeviceId": NSNull(), "glassDeviceId": NSNull(), "timeZone": timeZone, "region": region,
         "context": ["startTime": startTimeMs as Any? ?? NSNull(), "endTime": endTimeMs as Any? ?? NSNull()],
         "createTime": createTimeMs, "audioSaveFlag": audioSaveFlag as Any? ?? NSNull(),
         "recordingDurationMs": recordingDurationMs as Any? ?? NSNull()]
    }
}

struct OfficialSessionUploadMark {
    struct Remark {
        let hashtag: String?
        let remark: String?

        var jsonBody: [String: Any] {
            ["hashtag": hashtag as Any? ?? NSNull(), "remark": remark as Any? ?? NSNull()]
        }
    }

    let markId: String?
    /// Epoch milliseconds, after converting a local recording-relative position.
    let markTime: Int64?
    let remarks: [Remark]?

    var jsonBody: [String: Any] {
        ["markId": markId as Any? ?? NSNull(), "markTime": markTime as Any? ?? NSNull(),
         "remarks": remarks?.map(\.jsonBody) as Any? ?? NSNull()]
    }
}

struct OfficialSessionTranscriptionRequest {
    let taskID: String
    let recordingStartTimeMs: Int64
    let bucketName: String
    let objectKey: String
    let sourceLanguage: String?
    let targetLanguage: String?
    let separateSpeakers: Bool
    let summaryModel: String
    let channelNumber: Int
    let marks: [OfficialSessionUploadMark]?

    init(taskID: String, recordingStartTimeMs: Int64, bucketName: String, objectKey: String,
         sourceLanguage: String? = nil, targetLanguage: String? = nil, separateSpeakers: Bool,
         summaryModel: String, channelNumber: Int, marks: [OfficialSessionUploadMark]? = nil) {
        self.taskID = taskID
        self.recordingStartTimeMs = recordingStartTimeMs
        self.bucketName = bucketName
        self.objectKey = objectKey
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.separateSpeakers = separateSpeakers
        self.summaryModel = summaryModel
        self.channelNumber = channelNumber
        self.marks = marks
    }

    var jsonBody: [String: Any] {
        ["taskId": taskID, "recordingStartTime": recordingStartTimeMs, "marks": marks?.map(\.jsonBody) as Any? ?? NSNull(),
         "bucketName": bucketName, "objectKey": objectKey, "sourceLanguage": sourceLanguage ?? "auto",
         "targetLanguage": targetLanguage as Any? ?? NSNull(), "separateSpeakers": separateSpeakers,
         "summaryModel": summaryModel, "channelNumber": channelNumber]
    }
}
