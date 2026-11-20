// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Combine
import Foundation

enum AppLanguageMode: String, CaseIterable, Identifiable {
    case system
    case zh
    case en

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return L("跟随系统", "System")
        case .zh: return "简体中文"
        case .en: return "English"
        }
    }
}

@MainActor
final class AppLanguageStore: ObservableObject {
    nonisolated static let storageKey = "openrayneo.appLanguage"
    static let shared = AppLanguageStore()

    @Published var mode: AppLanguageMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.storageKey)
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.storageKey)
        self.mode = AppLanguageMode(rawValue: saved ?? "") ?? .system
    }

    nonisolated static func currentIsEnglish() -> Bool {
        let saved = UserDefaults.standard.string(forKey: storageKey)
        let mode = AppLanguageMode(rawValue: saved ?? "") ?? .system
        switch mode {
        case .zh: return false
        case .en: return true
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "zh"
            return !preferred.hasPrefix("zh")
        }
    }
}

func L(_ zh: String, _ en: String) -> String {
    AppLanguageStore.currentIsEnglish() ? en : zh
}
