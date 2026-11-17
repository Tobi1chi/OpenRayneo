// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import CoreText
import Foundation

/// Original APK fonts: Roboto Condensed, Source Han Sans fallback, and RayNeo icon glyphs.
enum DashboardPreviewFonts {
    static func register() { _ = registration }
    private static let registration: Void = {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("DashboardFonts", isDirectory: true)
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("assets/fonts", isDirectory: true)
        for name in ["RobotoCondensed-Light", "RobotoCondensed-Regular", "RobotoCondensed-Medium", "SourceHanSansCN_Regular", "rn_icon_v2"] {
            let file = (bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? development)
                .appendingPathComponent(name).appendingPathExtension("ttf")
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }()
}
