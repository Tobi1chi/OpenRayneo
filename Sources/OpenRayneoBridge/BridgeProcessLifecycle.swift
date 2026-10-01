// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Darwin

enum BridgeProcessLifecycle {
    /// Cleanup must finish even when the operation that owned the child was cancelled.
    static func stop(_ child: Process) async -> Bool {
        await Task.detached {
            if child.isRunning { child.terminate() }
            let graceDeadline = Date(timeIntervalSinceNow: 2)
            while child.isRunning, Date() < graceDeadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            let exitDeadline = Date(timeIntervalSinceNow: 2)
            while child.isRunning, Date() < exitDeadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !child.isRunning else { return false }
            child.waitUntilExit()
            return true
        }.value
    }
}
