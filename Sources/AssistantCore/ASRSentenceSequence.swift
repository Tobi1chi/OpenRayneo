// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Preserves capture order when an earlier cloud stream is draining while a later stream returns text.
public actor ASRSentenceSequence {
    private var order: [String] = []
    private var buffers: [String: [Sentence]] = [:]
    private var ended = Set<String>()
    private var draining = false
    private let sink: @Sendable (Sentence) async -> Void
    public init(sink: @escaping @Sendable (Sentence) async -> Void) { self.sink = sink }
    public func begin(_ round: String) {
        guard buffers[round] == nil else { return }
        order.append(round); buffers[round] = []
    }
    public func accept(_ sentence: Sentence) async {
        guard buffers[sentence.roundID] != nil else { return }
        buffers[sentence.roundID, default: []].append(sentence)
        await drain()
    }
    public func finish(_ round: String) async {
        ended.insert(round); await drain()
    }
    private func drain() async {
        guard !draining else { return }
        draining = true; defer { draining = false }
        while let round = order.first {
            if let first = buffers[round]?.first {
                buffers[round]?.removeFirst(); await sink(first)
            } else if ended.contains(round) {
                order.removeFirst(); buffers[round] = nil; ended.remove(round)
            } else { return }
        }
    }
}
