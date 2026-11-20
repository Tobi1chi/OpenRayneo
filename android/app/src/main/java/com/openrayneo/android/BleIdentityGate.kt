// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

/** Android can report an unsolicited MTU before service discovery, or report it twice. */
internal class BleIdentityGate {
    private var requested = false
    private var consumed = false

    fun servicesReady(): Boolean {
        if (requested) return false
        requested = true
        return true
    }

    fun mtuReady(): Boolean {
        if (!requested || consumed) return false
        consumed = true
        return true
    }

    fun reset() {
        requested = false
        consumed = false
    }
}
