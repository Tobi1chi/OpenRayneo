// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum OfficialSummarySpeakerNames {
    private static let pattern = try! NSRegularExpression(pattern: #"\{\{([^}\r\n]+)\}\}"#)

    static func referencedIDs(in text: String) -> [String] {
        let value = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: value.length)).map {
            value.substring(with: $0.range(at: 1))
        }
    }

    static func resolve(identities: [OfficialSpeakerIdentity], texts: [String],
                        labels: OfficialSpeakerDisplayLabels = .simplifiedChinese) -> [String: String] {
        var names = OfficialSpeakerNormalization.displayNames(for: identities, labels: labels)
        let others = identities.filter { $0.role == .others }.sorted { OfficialSpeakerNormalization.idLess($0.id, $1.id) }
        var reserved = Set(others.enumerated().compactMap { index, identity -> Int? in
            let name = OfficialSpeakerNormalization.trimmed(identity.name)
            return name.range(of: "^speaker-[1-9][0-9]*$", options: .regularExpression) != nil ? index + 1 : nil
        })
        let unknown = Set(texts.flatMap(referencedIDs).compactMap { raw -> String? in
            if names[raw] != nil { return nil }
            let id = raw.replacingOccurrences(of: #"\-"#, with: "-")
            return names[id] == nil ? id : nil
        })
        var number = 1
        for id in unknown.sorted(by: OfficialSpeakerNormalization.idLess) {
            while reserved.contains(number) { number += 1 }
            names[id] = labels.numbered(number)
            reserved.insert(number); number += 1
        }
        return names
    }

    static func display(_ text: String, names: [String: String]) -> String {
        let source = text as NSString
        var value = text
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let id = source.substring(with: match.range(at: 1))
            let replacement = names[id] ?? names[id.replacingOccurrences(of: #"\-"#, with: "-")] ?? id
            value = (value as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return value
    }
}
