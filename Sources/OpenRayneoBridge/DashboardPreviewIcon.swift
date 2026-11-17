// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

@MainActor
struct DashboardPreviewIcon: View {
    let name: String
    var body: some View {
        Image(nsImage: Self.image(name)).resizable().renderingMode(.template).scaledToFit()
            .foregroundStyle(Color(red: 68 / 255, green: 1, blue: 102 / 255))
    }
    private static var images: [String: NSImage] = [:]
    private static func image(_ name: String) -> NSImage {
        if let image = images[name] { return image }
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("DashboardIcons", isDirectory: true)
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("assets/dashboard-preview", isDirectory: true)
        let directory = bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? development
        let ext = name.hasPrefix("icon_email_") || name == "icon_outlook_mail" ? "png" : "pdf"
        let image = NSImage(contentsOf: directory.appendingPathComponent(name).appendingPathExtension(ext))!
        images[name] = image
        return image
    }
}
