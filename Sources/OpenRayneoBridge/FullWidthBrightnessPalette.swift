// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoreText
import CoreGraphics

/// Brightness reference for full-width cells. Actual glasses glyphs still need visual validation.
enum FullWidthBrightnessPalette {
    struct Entry {
        let character: Character
        let coverage: Double
        let brightness: Double
    }

    static let entries: [Entry] = {
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, 32, nil)
        let characters: [UniChar] = [0x3000] + (0xFF01...0xFF5E).map { UniChar($0) }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        let width = Int(ceil(advances.map(\.width).max()!))
        let descent = ceil(CTFontGetDescent(font))
        let height = Int(ceil(CTFontGetAscent(font) + descent + CTFontGetLeading(font)))
        let measured: [(character: Character, coverage: Double)] = glyphs.enumerated().compactMap { index, glyph in
            guard glyph != 0, abs(advances[index].width - advances[0].width) < 0.01 else { return nil }
            var pixels = [UInt8](repeating: 0, count: width * height)
            pixels.withUnsafeMutableBytes { storage in
                let context = CGContext(data: storage.baseAddress, width: width, height: height,
                                        bitsPerComponent: 8, bytesPerRow: width,
                                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
                context.setFillColor(gray: 1, alpha: 1)
                context.setShouldAntialias(true)
                var glyph = glyph
                var position = CGPoint(x: 0, y: descent)
                CTFontDrawGlyphs(font, &glyph, &position, 1, context)
            }
            let coverage = Double(pixels.reduce(0) { $0 + Int($1) }) / Double(width * height * 255)
            return (Character(UnicodeScalar(Int(characters[index]))!), coverage)
        }
        let maximum = measured.map(\.coverage).max()!
        return measured.map { Entry(character: $0.character, coverage: $0.coverage, brightness: $0.coverage / maximum * 255) }
            .sorted { lhs, rhs in
                lhs.brightness == rhs.brightness ? lhs.character.unicodeScalars.first!.value < rhs.character.unicodeScalars.first!.value : lhs.brightness < rhs.brightness
            }
    }()

    private static let lookup: [Character] = (0...255).map { value in
        entries.min { abs($0.brightness - Double(value)) < abs($1.brightness - Double(value)) }!.character
    }

    static func character(for brightness: UInt8) -> Character { lookup[Int(brightness)] }

    /// A 2×4 normalized box convolution followed by decimation to 26 full-width columns.
    static func render(_ samples: [UInt8], inverted: Bool) -> String {
        let columns = 26
        let kernelWidth = 2
        var rows: [String] = []
        for row in 0..<7 {
            var line = ""
            for column in 0..<columns {
                var sum = 0
                for y in 0..<4 {
                    for x in 0..<kernelWidth { sum += Int(samples[(row * 4 + y) * 52 + column * kernelWidth + x]) }
                }
                let mean = sum / (kernelWidth * 4)
                line.append(character(for: UInt8(inverted ? 255 - mean : mean)))
            }
            rows.append(line)
        }
        return rows.joined(separator: "\n")
    }
}
