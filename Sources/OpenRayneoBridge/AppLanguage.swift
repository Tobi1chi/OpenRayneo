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
    nonisolated static let syncGlassesKey = "openrayneo.syncGlassesLanguage"
    static let shared = AppLanguageStore()

    @Published var mode: AppLanguageMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.storageKey)
        }
    }

    @Published var syncGlassesLanguage: Bool {
        didSet {
            UserDefaults.standard.set(syncGlassesLanguage, forKey: Self.syncGlassesKey)
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.storageKey)
        self.mode = AppLanguageMode(rawValue: saved ?? "") ?? .system
        if UserDefaults.standard.object(forKey: Self.syncGlassesKey) == nil {
            self.syncGlassesLanguage = true
        } else {
            self.syncGlassesLanguage = UserDefaults.standard.bool(forKey: Self.syncGlassesKey)
        }
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

    nonisolated static func preferredGlassesLanguage(isEnglish: Bool, supported: [String]) -> String? {
        guard !supported.isEmpty else { return nil }
        let preferred = isEnglish ? "en-us" : "zh-cn"
        let prefix = isEnglish ? "en" : "zh"
        if let exact = supported.first(where: { $0.lowercased() == preferred }) { return exact }
        return supported.first(where: { $0.lowercased().hasPrefix(prefix) })
    }

    nonisolated static func appMode(forGlassesLanguage code: String) -> AppLanguageMode? {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("zh") { return .zh }
        if normalized.hasPrefix("en") { return .en }
        return nil
    }
}

func L(_ zh: String, _ en: String) -> String {
    AppLanguageStore.currentIsEnglish() ? en : zh
}
