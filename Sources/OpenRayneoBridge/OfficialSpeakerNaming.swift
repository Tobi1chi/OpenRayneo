// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum OfficialSpeakerNamingScope: String, CaseIterable {
    case currentClip, allClipsForSpeaker
    var title: String { self == .currentClip ? "仅此片段" : "该说话人的全部片段" }
}

struct OfficialSpeakerNamingPlan {
    let source: OfficialSpeakerSnapshot
    let result: OfficialSpeakerSnapshot

    func project(onto clips: [OfficialTranscriptClip]) throws -> [OfficialTranscriptClip] {
        let assignments = Dictionary(uniqueKeysWithValues: result.clips.map { ($0.clipID, $0.speakerID) })
        let identities = Dictionary(uniqueKeysWithValues: result.identities.map { ($0.id, $0) })
        guard clips.count == assignments.count else {
            throw OfficialMemoryFailure(message: "说话人计划与当前转写片段不一致，请重新打开编辑器。")
        }
        return try clips.map { original in
            guard let clipID = original.clipID, let speakerID = assignments[clipID],
                  let identity = identities[speakerID] else {
                throw OfficialMemoryFailure(message: "说话人计划缺少片段的身份信息。")
            }
            var clip = original
            clip.speakerID = identity.id; clip.speakerName = identity.name; clip.speakerType = identity.role.rawValue
            return clip
        }
    }
}

enum OfficialSpeakerNaming {
    private static func key(_ name: String) -> String { OfficialSpeakerNormalization.nameKey(name) }
    private static func trim(_ name: String) -> String { OfficialSpeakerNormalization.trimmed(name) }

    static func single(_ source: OfficialSpeakerSnapshot, clipID: String, name: String,
                       scope: OfficialSpeakerNamingScope) throws -> OfficialSpeakerNamingPlan {
        let name = trim(name)
        guard !name.isEmpty else { throw OfficialMemoryFailure(message: "请输入说话人名字。") }
        guard let clip = source.clips.first(where: { $0.clipID == clipID }),
              let speaker = source.identities.first(where: { $0.id == clip.speakerID }) else {
            throw OfficialMemoryFailure(message: "找不到所选片段的说话人，请刷新会话。")
        }
        let candidates = source.identities.filter {
            key(source.visibleDisplayNames[$0.id] ?? $0.name) == key(name)
        }
        var identities = source.identities, clips = source.clips
        if candidates.isEmpty || (candidates.count == 1 && candidates[0].id == speaker.id) {
            if scope == .currentClip, clips.filter({ $0.speakerID == speaker.id }).count > 1 {
                var number = 1001
                let used = Set(identities.map(\.id))
                while used.contains(String(number)) { number += 1 }
                let id = String(number)
                clips = clips.map { $0.clipID == clipID ? .init(clipID: $0.clipID, speakerID: id) : $0 }
                identities.append(.init(id: id, name: name, role: .others))
            } else {
                identities = identities.map { $0.id == speaker.id ? .init(id: $0.id, name: name, role: $0.role) : $0 }
            }
        } else {
            let target = choose(candidates)
            let merged = Set(candidates.map(\.id))
            clips = clips.map {
                let selected = $0.speakerID == speaker.id && (scope == .allClipsForSpeaker || $0.clipID == clipID)
                return merged.contains($0.speakerID) || selected ? .init(clipID: $0.clipID, speakerID: target.id) : $0
            }
            identities.removeAll { merged.contains($0.id) && $0.id != target.id }
        }
        return finish(source, identities: identities, clips: clips)
    }

    static func global(_ source: OfficialSpeakerSnapshot, names: [String: String]) throws -> OfficialSpeakerNamingPlan {
        let ids = Set(source.identities.map(\.id))
        guard names.keys.allSatisfy({ ids.contains($0) }) else {
            throw OfficialMemoryFailure(message: "说话人列表已变化，请重新打开编辑器。")
        }
        let desired = Dictionary(uniqueKeysWithValues: source.identities.map { identity in
            let input = trim(names[identity.id] ?? "")
            return (identity.id, input.isEmpty ? identity.name : input)
        })
        let permutations = permutationIDs(source.identities, desired: desired)
        var output = source.identities.filter { permutations.contains($0.id) }.map {
            OfficialSpeakerIdentity(id: $0.id, name: desired[$0.id]!, role: $0.role)
        }
        let active = source.identities.filter { !permutations.contains($0.id) }
        var parent = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0.id) })
        func root(_ id: String) -> String {
            var value = id
            while let next = parent[value], next != value { value = next }
            return value
        }
        func merge(_ a: String, _ b: String) {
            let first = root(a), second = root(b)
            if OfficialSpeakerNormalization.idLess(first, second) { parent[second] = first }
            else { parent[first] = second }
        }
        let groups = Dictionary(grouping: active, by: { key(desired[$0.id]!) })
        for group in groups.values {
            if let first = group.first { for identity in group.dropFirst() { merge(first.id, identity.id) } }
        }
        var aliases: [(String, String)] = []
        for identity in active {
            let input = trim(names[identity.id] ?? "")
            guard !input.isEmpty else { continue }
            for target in active where target.id != identity.id && trim(names[target.id] ?? "").isEmpty {
                let visible = source.visibleDisplayNames[target.id] ?? target.name
                if visible != target.name && key(input) == key(visible) {
                    merge(identity.id, target.id); aliases.append((identity.id, target.id))
                }
            }
        }
        var clips = source.clips
        for group in Dictionary(grouping: active, by: { root($0.id) }).values {
            let myself = group.filter { $0.role == .myself }
            let unchanged = group.filter { key($0.name) == key(desired[$0.id]!) }
            let target = choose(!myself.isEmpty ? myself : (!unchanged.isEmpty ? unchanged : group))
            let members = Set(group.map(\.id))
            let viaAlias = aliases.contains { members.contains($0.0) && members.contains($0.1) }
            let name = viaAlias ? target.name : desired[target.id]!
            output.append(.init(id: target.id, name: name, role: target.role))
            clips = clips.map { members.contains($0.speakerID) ? .init(clipID: $0.clipID, speakerID: target.id) : $0 }
        }
        return finish(source, identities: output, clips: clips)
    }

    // One-to-one cycles rename identities without merging them (for example, A/B exchanging names).
    private static func permutationIDs(_ identities: [OfficialSpeakerIdentity], desired: [String: String]) -> Set<String> {
        let originals = Dictionary(grouping: identities, by: { key($0.name) })
        let counts = Dictionary(grouping: desired.values, by: key).mapValues(\.count)
        var edges: [String: String] = [:]
        for identity in identities {
            if let matches = originals[key(desired[identity.id]!)], matches.count == 1,
               matches[0].id != identity.id { edges[identity.id] = matches[0].id }
        }
        var visited = Set<String>(), result = Set<String>()
        for start in edges.keys {
            var path: [String] = [], positions: [String: Int] = [:], current: String? = start
            while let id = current, !visited.contains(id), positions[id] == nil {
                positions[id] = path.count; path.append(id); current = edges[id]
            }
            if let id = current, let index = positions[id] {
                let cycle = path[index...]
                if cycle.allSatisfy({ counts[key(desired[$0]!)] == 1 }) { result.formUnion(cycle) }
            }
            visited.formUnion(path)
        }
        return result
    }

    private static func choose(_ identities: [OfficialSpeakerIdentity]) -> OfficialSpeakerIdentity {
        identities.sorted {
            if $0.role != $1.role { return $0.role == .myself }
            return OfficialSpeakerNormalization.idLess($0.id, $1.id)
        }[0]
    }

    private static func finish(_ source: OfficialSpeakerSnapshot, identities: [OfficialSpeakerIdentity],
                               clips: [OfficialNormalizedSpeakerClip]) -> OfficialSpeakerNamingPlan {
        var result = source
        let used = Set(clips.map(\.speakerID))
        result.identities = identities.filter { used.contains($0.id) }.sorted { OfficialSpeakerNormalization.idLess($0.id, $1.id) }
        result.clips = clips.sorted {
            $0.clipID == $1.clipID ? OfficialSpeakerNormalization.idLess($0.speakerID, $1.speakerID)
                : OfficialSpeakerNormalization.idLess($0.clipID, $1.clipID)
        }
        result.visibleDisplayNames = Dictionary(uniqueKeysWithValues: result.identities.map { identity in
            let original = source.identities.first { $0.id == identity.id }
            let unchanged = original?.name == identity.name && original?.role == identity.role
            return (identity.id, unchanged ? source.visibleDisplayNames[identity.id] ?? identity.name : identity.name)
        })
        return .init(source: source, result: result)
    }
}
