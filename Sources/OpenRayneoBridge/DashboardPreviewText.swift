// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreText
import SwiftUI

/// Fixed logical text metrics from the APK, before the complete preview is scaled.
struct DashboardPreviewText: NSViewRepresentable {
    enum Face: String {
        case light = "RobotoCondensed-Light", regular = "RobotoCondensed-Regular"
        case medium = "RobotoCondensed-Medium", icons = "rn_icon_v2"
    }
    var text: String
    var size: CGFloat
    var face: Face = .light
    var tracking: CGFloat = -0.4
    var height: CGFloat = 1.2
    var lines: Int = 1
    var opacity: CGFloat = 1
    var alignment: NSTextAlignment = .left
    var asciiEllipsis = false

    func makeNSView(context: Context) -> DashboardTextDrawingView { DashboardTextDrawingView() }
    func updateNSView(_ view: DashboardTextDrawingView, context: Context) {
        view.style = self
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.staticText)
        view.setAccessibilityLabel(text)
        view.needsDisplay = true
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DashboardTextDrawingView, context: Context) -> CGSize? {
        let natural = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed(text)), nil, nil, nil)
        let width = max(0, min(proposal.width ?? CGFloat(natural), CGFloat(natural)))
        return CGSize(width: ceil(width), height: CGFloat(layout(width: max(1, width)).count) * size * height)
    }

    private func attributed(_ value: String) -> NSAttributedString {
        let descriptor = NSFontDescriptor(name: face.rawValue, size: size).addingAttributes([
            .cascadeList: [NSFontDescriptor(name: "SourceHanSansCN-Regular", size: size)]
        ])
        return NSAttributedString(string: value, attributes: [
            .font: NSFont(descriptor: descriptor, size: size)!, .kern: tracking,
            .foregroundColor: NSColor(srgbRed: 68 / 255, green: 1, blue: 102 / 255, alpha: opacity)
        ])
    }

    func layout(width: CGFloat) -> [CTLine] {
        let value = attributed(text)
        let setter = CTTypesetterCreateWithAttributedString(value)
        var result: [CTLine] = [], offset = 0
        while offset < value.length && result.count < lines {
            let length = max(1, CTTypesetterSuggestLineBreak(setter, offset, Double(width)))
            let remaining = value.length - offset
            if result.count == lines - 1 && length < remaining {
                let tail = CTLineCreateWithAttributedString(attributed((text as NSString).substring(from: offset).replacingOccurrences(of: "\n", with: " ")))
                let marker = CTLineCreateWithAttributedString(attributed(asciiEllipsis ? "..." : "…"))
                result.append(CTLineCreateTruncatedLine(tail, Double(width), .end, marker) ?? marker)
            } else {
                result.append(CTTypesetterCreateLine(setter, CFRange(location: offset, length: min(length, remaining))))
            }
            offset += length
        }
        return result.isEmpty ? [CTLineCreateWithAttributedString(attributed(""))] : result
    }

    static func measuredHeight(_ text: String, width: CGFloat, size: CGFloat, lines: Int, height: CGFloat = 22 / 18) -> CGFloat {
        let style = Self(text: text, size: size, face: .regular, tracking: 0, height: height, lines: lines)
        return CGFloat(style.layout(width: width).count) * size * height
    }
}

final class DashboardTextDrawingView: NSView {
    var style = DashboardPreviewText(text: "", size: 18)
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: bounds)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (index, line) in style.layout(width: max(1, bounds.width)).enumerated() {
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            let x: CGFloat = style.alignment == .center ? (bounds.width - width) / 2 : style.alignment == .right ? bounds.width - width : 0
            let baseline = CGFloat(index) * style.size * style.height + (style.size * style.height - ascent - descent) / 2 + ascent
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }
}
