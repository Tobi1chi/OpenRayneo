// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum OfficialFeedbackBundle {
    static func create(draft: OfficialFeedbackDraft, directory: URL) async throws -> URL {
        let work = Task.detached(priority: .utility) {
            let manager = FileManager.default
            let folder = directory.appendingPathComponent(draft.id.uuidString, isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let contents = folder.appendingPathComponent("contents", isDirectory: true)
            let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.dateFormat = "yyyy-MM-dd_HHmmss"
            let archive = folder.appendingPathComponent(date.string(from: Date()) + "_feedback_bundle.zip")
            do {
                try manager.createDirectory(at: contents, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                var names = Set<String>()
                for attachment in draft.attachments {
                    try Task.checkCancellation()
                    let original = URL(fileURLWithPath: attachment.path)
                    let name = attachment.name
                    var entry = name, suffix = 1
                    while names.contains(entry) {
                        let url = URL(fileURLWithPath: name)
                        entry = url.deletingPathExtension().lastPathComponent + "_\(suffix)"
                            + (url.pathExtension.isEmpty ? "" : "." + url.pathExtension)
                        suffix += 1
                    }
                    names.insert(entry)
                    try manager.copyItem(at: original, to: contents.appendingPathComponent(entry))
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                process.currentDirectoryURL = contents
                process.arguments = ["-q", "-r", archive.path, "."]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    try process.run()
                    if Task.isCancelled && process.isRunning { process.terminate() }
                    process.waitUntilExit()
                    try Task.checkCancellation()
                    guard process.terminationStatus == 0 else { throw OfficialMemoryFailure(message: "反馈附件 ZIP 打包失败。") }
                } onCancel: { if process.isRunning { process.terminate() } }
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
                try manager.trashItem(at: contents, resultingItemURL: nil)
                return archive
            } catch {
                try? manager.trashItem(at: folder, resultingItemURL: nil)
                throw error
            }
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}
