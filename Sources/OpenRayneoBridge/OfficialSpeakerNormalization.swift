// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum OfficialSpeakerRole: String, Equatable, Sendable {
    case myself, others
}

struct OfficialSpeakerIdentity: Equatable, Sendable {
    var id: String
    var name: String
    var role: OfficialSpeakerRole
}

struct OfficialNormalizedSpeakerClip: Equatable, Sendable {
    var clipID: String
    var speakerID: String
}

struct OfficialSpeakerSnapshot: Equatable, Sendable {
    var sessionID: String
    var srcType: String
    var identities: [OfficialSpeakerIdentity]
    var clips: [OfficialNormalizedSpeakerClip]
    var visibleDisplayNames: [String: String]
    var diagnostics: [String]
}

enum OfficialSpeakerNormalization {
    private struct Evidence {
        let clipID: String
        let role: OfficialSpeakerRole
        let name: String
        let explicitID: String?
    }

    private struct MissingGroup {
        let role: OfficialSpeakerRole
        let name: String
        var representative: String
        var id: String = ""
    }

    static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func nameKey(_ value: String) -> String {
        trimmed(value).lowercased()
    }

    static func idLess(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
    }

    static func displayNames(for identities: [OfficialSpeakerIdentity],
                             labels: OfficialSpeakerDisplayLabels = .simplifiedChinese) -> [String: String] {
        let others = identities.filter { $0.role == .others }.sorted { idLess($0.id, $1.id) }
        let numbers = Dictionary(uniqueKeysWithValues: others.enumerated().map { ($0.element.id, $0.offset + 1) })
        return Dictionary(uniqueKeysWithValues: identities.map { identity in
            let name = trimmed(identity.name)
            let indexed = name.range(of: "^speaker-[1-9][0-9]*$", options: .regularExpression) != nil
            let isDefault = name.isEmpty || name == "me" || name == "others" || indexed
            let visible: String
            if !isDefault { visible = identity.name }
            else if identity.role == .myself { visible = labels.myself }
            else if indexed { visible = labels.numbered(numbers[identity.id] ?? 1) }
            else { visible = labels.speaker }
            return (identity.id, visible)
        })
    }

    static func normalize(clips: [OfficialTranscriptClip], sessionID: String, srcType: String,
                          visibleDisplayNames: [String: String] = [:]) throws -> OfficialSpeakerSnapshot {
        var seen = Set<String>()
        for clip in clips {
            guard let id = clip.clipID, !trimmed(id).isEmpty else {
                throw OfficialMemoryFailure(message: "有转写片段缺少有效 ID，无法规划说话人，请刷新会话。")
            }
            guard seen.insert(id).inserted else {
                throw OfficialMemoryFailure(message: "转写片段 ID 重复，无法规划说话人，请刷新会话。")
            }
        }

        var diagnostics: [String] = []
        let evidence = clips.map { clip -> Evidence in
            let role = OfficialSpeakerRole(rawValue: nameKey(clip.speakerType ?? ""))
            if role == nil { diagnostics.append("unknownRole:\(clip.clipID ?? "")") }
            let id = clip.speakerID.flatMap { $0.isEmpty ? nil : $0 }
            return Evidence(clipID: clip.clipID!, role: role ?? .others,
                            name: trimmed(clip.speakerName ?? ""), explicitID: id)
        }

        var missing: [MissingGroup] = []
        for item in evidence where item.explicitID == nil {
            if let index = missing.firstIndex(where: { $0.role == item.role && $0.name == item.name }) {
                if idLess(item.clipID, missing[index].representative) {
                    missing[index].representative = item.clipID
                }
            } else {
                missing.append(MissingGroup(role: item.role, name: item.name, representative: item.clipID))
            }
        }
        missing.sort {
            if $0.representative != $1.representative { return idLess($0.representative, $1.representative) }
            if $0.role != $1.role { return idLess($0.role.rawValue, $1.role.rawValue) }
            return idLess($0.name, $1.name)
        }
        var used = Set(evidence.compactMap(\.explicitID))
        var nextID = 1001
        for index in missing.indices {
            while used.contains(String(nextID)) { nextID += 1 }
            missing[index].id = String(nextID)
            used.insert(String(nextID))
            nextID += 1
        }

        func assignedID(_ item: Evidence) -> String {
            item.explicitID ?? missing.first { $0.role == item.role && $0.name == item.name }!.id
        }
        var grouped: [String: [Evidence]] = [:]
        for item in evidence { grouped[assignedID(item), default: []].append(item) }

        func resolve(_ id: String, _ items: [Evidence]) -> OfficialSpeakerIdentity {
            let hasMyself = items.contains { $0.role == .myself }
            let hasOthers = items.contains { $0.role == .others }
            if hasMyself && hasOthers { diagnostics.append("conflictingRoles:\(id)") }
            let role: OfficialSpeakerRole = hasMyself ? .myself : .others
            var counts: [String: Int] = [:]
            for item in items where item.role == role { counts[item.name, default: 0] += 1 }
            let name = counts.keys.sorted {
                if counts[$0] != counts[$1] { return counts[$0]! > counts[$1]! }
                return idLess($0, $1)
            }.first ?? ""
            return OfficialSpeakerIdentity(id: id, name: name, role: role)
        }

        var identities = grouped.keys.sorted(by: idLess).map { resolve($0, grouped[$0]!) }
        let myselfIDs = identities.filter { $0.role == .myself }.map(\.id).sorted(by: idLess)
        var remap: [String: String] = [:]
        if myselfIDs.count > 1, let retainedID = myselfIDs.first {
            let mergedEvidence = myselfIDs.flatMap { grouped[$0]! }
            let merged = resolve(retainedID, mergedEvidence)
            identities.removeAll { myselfIDs.contains($0.id) }
            identities.append(merged)
            for id in myselfIDs { remap[id] = retainedID }
            diagnostics.append("multipleMyselfIdentitiesMerged:\(retainedID)")
        }
        identities.sort { idLess($0.id, $1.id) }
        let normalizedClips = evidence.map { item in
            let id = assignedID(item)
            return OfficialNormalizedSpeakerClip(clipID: item.clipID, speakerID: remap[id] ?? id)
        }.sorted {
            if $0.clipID != $1.clipID { return idLess($0.clipID, $1.clipID) }
            return idLess($0.speakerID, $1.speakerID)
        }
        let names = Dictionary(uniqueKeysWithValues: identities.map {
            ($0.id, visibleDisplayNames[$0.id] ?? $0.name)
        })
        return OfficialSpeakerSnapshot(sessionID: sessionID, srcType: srcType, identities: identities,
                                       clips: normalizedClips, visibleDisplayNames: names,
                                       diagnostics: diagnostics.sorted(by: idLess))
    }
}
