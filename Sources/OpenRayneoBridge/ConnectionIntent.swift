// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

/// Application registration is separate from the macOS Bluetooth bond.
enum ConnectionIntent: String {
    case register, reconnect
    var pairValue: UInt8 { self == .register ? 1 : 2 }
}
