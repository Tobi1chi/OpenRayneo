// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Reads the on-disk library on every operation so the GUI and API see each other's saves.
final class TeleprompterRepository {
    private let directory: URL
    private let lock = NSLock()

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenRayneo/Teleprompter", isDirectory: true)
    }

    func listDocuments() throws -> [TeleprompterLibraryDocument] {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try urls.filter {
            $0.pathExtension == "json" && $0.lastPathComponent.caseInsensitiveCompare("pending-sync.json") != .orderedSame
        }.map {
            try JSONDecoder().decode(TeleprompterLibraryDocument.self, from: Data(contentsOf: $0))
        }.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }

    func listMetadata() throws -> [[String: Any]] {
        try listDocuments().map(\.metadata)
    }

    func load(did: String) throws -> TeleprompterLibraryDocument? {
        lock.lock()
        defer { lock.unlock() }
        return try readDocument(at: fileURL(did))
    }

    @discardableResult
    func upsert(did: String, title: String, text: String, settings: TeleprompterPlaybackSettings,
                pageOffset: Int, highLightOffset: Int) throws -> TeleprompterLibraryDocument {
        lock.lock()
        defer { lock.unlock() }
        let url = try fileURL(did)
        var document = try readDocument(at: url) ?? TeleprompterLibraryDocument(id: did, title: title, text: text)
        document.title = title
        document.text = text
        document.settings = settings
        document.pageOffset = pageOffset
        document.highLightOffset = highLightOffset
        let position = document.playbackPosition
        document.position = position.page
        document.pageOffset = position.page
        document.highLightOffset = position.highlight
        document.updatedAt = Date()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(document).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return document
    }

    private func readDocument(at url: URL) throws -> TeleprompterLibraryDocument? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(TeleprompterLibraryDocument.self, from: Data(contentsOf: url))
    }

    private func fileURL(_ did: String) throws -> URL {
        guard !did.isEmpty, did != ".", did != "..", !did.contains("/"), !did.contains("\\"), !did.contains("\0") else {
            throw BridgeError(status: 400, message: "Teleprompter did must be a nonempty file name without path separators")
        }
        guard did.caseInsensitiveCompare("pending-sync") != .orderedSame else {
            throw BridgeError(status: 400, message: "Teleprompter did pending-sync is reserved for the synchronization queue")
        }
        return directory.appendingPathComponent(did).appendingPathExtension("json")
    }
}
