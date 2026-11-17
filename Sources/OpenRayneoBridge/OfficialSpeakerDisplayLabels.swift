// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct OfficialSpeakerDisplayLabels: Sendable {
    let myself: String
    let speaker: String
    let indexedPrefix: String
    func numbered(_ number: Int) -> String { indexedPrefix + String(number) }

    static let simplifiedChinese = Self(myself: "我", speaker: "其他人", indexedPrefix: "说话人")

    private static let resources: [String: Self] = [
        "zh": simplifiedChinese,
        "zh-hk": Self(myself: "我", speaker: "其他人", indexedPrefix: "說話者"),
        "zh-tw": Self(myself: "我", speaker: "其他人", indexedPrefix: "說話人"),
        "en": Self(myself: "Me", speaker: "Other person", indexedPrefix: "Speaker "),
        "fr": Self(myself: "Moi", speaker: "Autre personne", indexedPrefix: "Intervenant "),
        "de": Self(myself: "Ich", speaker: "Andere Person", indexedPrefix: "Sprecher "),
        "es": Self(myself: "Yo", speaker: "Otra persona", indexedPrefix: "Interlocutor "),
        "it": Self(myself: "Io", speaker: "Altra persona", indexedPrefix: "Interlocutore "),
        "ja": Self(myself: "自分", speaker: "他の人", indexedPrefix: "話者"),
        "ko": Self(myself: "나", speaker: "다른 사람", indexedPrefix: "화자 "),
        "pl": Self(myself: "Ja", speaker: "Inna osoba", indexedPrefix: "Mówca ")
    ]

    static func forSummary(languageCode: String?, fallback: Self = .simplifiedChinese) -> Self {
        for candidate in languageCandidates(languageCode) {
            if let labels = resources[candidate] { return labels }
        }
        return fallback
    }

    private static func languageCandidates(_ code: String?) -> [String] {
        guard let code else { return [] }
        let tag = OfficialSpeakerNormalization.trimmed(code).replacingOccurrences(of: "_", with: "-")
        guard !tag.isEmpty else { return [] }
        let parts = tag.components(separatedBy: "-")
        guard parts.allSatisfy({ $0.range(of: "^[A-Za-z0-9]{1,8}$", options: .regularExpression) != nil }) else { return [] }
        let language = parts[0].lowercased()
        guard language.range(of: "^[a-z]{2,3}$", options: .regularExpression) != nil else { return [] }
        let region = parts.dropFirst().first {
            $0.range(of: "^(?:[A-Za-z]{2}|[0-9]{3})$", options: .regularExpression) != nil
        }?.uppercased()
        var result = [tag.lowercased()]
        if let region { result.append((language + "-" + region).lowercased()) }
        result.append(language)
        return result
    }
}
