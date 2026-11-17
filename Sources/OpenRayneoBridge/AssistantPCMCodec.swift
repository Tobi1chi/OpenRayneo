// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation

/// Explicit stereo transport is additive; legacy callers still receive their selected mono lane.
enum AssistantPCMCodec {
    static func encode(_ buffer: AVAudioPCMBuffer, channel: Int, stereo: Bool) -> Data {
        var result = Data(capacity: Int(buffer.frameLength) * (stereo ? 4 : 2))
        func append(_ sample: Float) {
            var value = Int16(max(-32768, min(32767, Int(sample * 32768)))).littleEndian
            withUnsafeBytes(of: &value) { result.append(contentsOf: $0) }
        }
        let left = buffer.floatChannelData![0], right = buffer.floatChannelData![1]
        for frame in 0..<Int(buffer.frameLength) {
            if stereo { append(left[frame]); append(right[frame]) }
            else { append(channel == 1 ? left[frame] : channel == 2 ? right[frame] : (left[frame] + right[frame]) * 0.5) }
        }
        return result
    }
}
