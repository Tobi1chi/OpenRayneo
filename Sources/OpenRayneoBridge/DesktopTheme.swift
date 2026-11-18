// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

// Colors come only from the generated `Token` (assets/design-tokens, VS Code-style semantic keys).
// Neutral greyscale structure with one pine brand green for actions and live state; phosphor green stays on the lens.

struct CardBackground: ViewModifier {
    var padding: CGFloat = 20
    func body(content: Content) -> some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(Token.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Token.cardBorder))
    }
}

extension View {
    func card(padding: CGFloat = 20) -> some View { modifier(CardBackground(padding: padding)) }
}

/// Every panel's GroupBox becomes a titled card, so all pages share one surface language.
/// Panels pad their GroupBox content by ~10pt themselves; the label takes the same inset so both align.
struct PanelGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            configuration.label.font(.system(size: 14, weight: .semibold)).foregroundStyle(Token.foreground)
                .padding(.horizontal, 10).padding(.top, 8)
            configuration.content
        }.card(padding: 10)
    }
}

/// Section heading used inside a page: small, semibold, quiet.
struct SectionTitle: View {
    let text: String
    var detail: String?
    init(_ text: String, detail: String? = nil) { self.text = text; self.detail = detail }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).font(.system(size: 15, weight: .semibold))
            if let detail { Text(detail).font(.callout).foregroundStyle(Token.descriptionForeground).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct SignalDot: View {
    var active: Bool
    var size: CGFloat = 7
    var body: some View {
        Circle().fill(active ? Token.statusIndicatorActive : Token.statusIndicatorInactive).frame(width: size, height: size)
    }
}

struct StatusChip: View {
    let text: String
    var active = true
    var body: some View {
        HStack(spacing: 7) {
            SignalDot(active: active, size: 6)
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1)
                .foregroundStyle(active ? Token.badgeForeground : Token.badgeInactiveForeground)
        }.padding(.horizontal, 10).padding(.vertical, 5)
            .background(active ? Token.badgeBackground : Token.badgeInactiveBackground, in: Capsule())
    }
}

/// The approved OR app icon (assets/icons, same artwork as the README logo) on its charcoal tile.
struct BrandMark: View {
    var size: CGFloat = 30
    private static let icon: NSImage = {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("OpenRayneo.icns")
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("assets/icons/OpenRayneo.icns")
        return NSImage(contentsOf: bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? development)!
    }()
    var body: some View {
        Image(nsImage: Self.icon).resizable().interpolation(.high).frame(width: size, height: size)
            .background(Token.brandMarkBackground, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(Token.brandMarkBorder))
            .accessibilityLabel("OpenRayneo")
    }
}

/// Dark lens surface for anything that mirrors what the glasses show.
struct LensSurface<Content: View>: View {
    let title: String
    var live = false
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(live ? Token.hudForeground : Token.hudIndicatorInactive).frame(width: 6, height: 6)
                Text(title).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Token.hudDescriptionForeground)
            }
            content.foregroundStyle(Token.hudForeground)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Token.hudBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Token.hudBorder))
    }
}

struct StepBadge: View {
    let number: Int
    let complete: Bool
    var body: some View {
        ZStack {
            Circle().fill(complete ? Token.buttonBackground : Token.buttonSecondaryBackground)
            if complete { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Token.buttonForeground) }
            else { Text("\(number)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Token.buttonSecondaryForeground) }
        }.frame(width: 28, height: 28)
    }
}

/// Front view of the glasses for connect actions: one straight brow line carrying two rounded D-shaped lenses,
/// stroked at the weight of a regular SF Symbol so it sits evenly beside button text.
struct GlassesGlyph: View {
    var width: CGFloat = 20
    var lineWidth: CGFloat = 1.5
    var body: some View {
        GlassesOutline().stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .frame(width: width, height: width * 0.42)
    }
}

private struct GlassesOutline: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y) }
        let top: CGFloat = 0.16, bottom: CGFloat = 0.92
        var path = Path()
        path.move(to: point(0.02, top)); path.addLine(to: point(0.98, top))
        for (left, right) in [(0.08, 0.44), (0.56, 0.92)] as [(CGFloat, CGFloat)] {
            let middle = (left + right) / 2, inset = (right - left) * 0.14
            path.move(to: point(right, top))
            path.addCurve(to: point(middle, bottom), control1: point(right, top + (bottom - top) * 0.75), control2: point(right - inset, bottom))
            path.addCurve(to: point(left, top), control1: point(left + inset, bottom), control2: point(left, top + (bottom - top) * 0.75))
        }
        return path
    }
}
