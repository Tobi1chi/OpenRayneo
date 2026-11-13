// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum NavigationDirection: String, CaseIterable, Identifiable {
    case left, right, straight, uturn
    var id: String { rawValue }
    var title: String {
        switch self {
        case .left: return "左转"
        case .right: return "右转"
        case .straight: return "直行"
        case .uturn: return "掉头"
        }
    }

    var arrow: [String] {
        let left = ["  █    ", " █     ", "██████ ", " █   █ ", "  █  █ "]
        switch self {
        case .left: return left
        case .right: return left.map { String($0.reversed()) }
        case .straight: return ["   █   ", "  ███  ", " █████ ", "   █   ", "   █   "]
        case .uturn: return ["  ████ ", " █   █ ", " █   █ ", "███  █ ", " █   █ "]
        }
    }
}

enum NavigationFrame {
    static func rows(direction: NavigationDirection, meters: Int) -> [String] {
        var cells = Array(repeating: Array(repeating: Character(" "), count: 20), count: 5)
        func put(_ text: String, x: Int, y: Int) {
            for (offset, character) in text.enumerated() { cells[y][x + offset] = character }
        }
        for (row, text) in direction.arrow.enumerated() { put(text, x: 2, y: row) }
        let distance = max(0, min(meters, 9999))
        put(distance == 0 ? "现在" : "\(distance)米", x: 12, y: 1)
        put(direction.title, x: 12, y: 3)
        return cells.map { row in
            String(row.map { character in
                if character == " " { return Character("\u{3000}") }
                if let value = character.asciiValue, (33...126).contains(value) {
                    return Character(UnicodeScalar(Int(value) + 0xFEE0)!)
                }
                return character
            })
        }
    }

    static func payload(direction: NavigationDirection, meters: Int, compensateFirstCell: Bool = false) -> [String: Any] {
        // The desktop controller enables the prefix after the first successful frame of a session.
        ["text": (compensateFirstCell ? "\u{3000}" : "") + rows(direction: direction, meters: meters).joined(separator: "\n"), "final": true]
    }
}
