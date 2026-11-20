package com.openrayneo.android

import org.junit.Assert.*
import org.junit.Test

class BleIdentityGateTest {
    @Test fun unsolicitedMtuCannotStartIdentityReadBeforeServicesExist() {
        val gate = BleIdentityGate()
        assertFalse(gate.mtuReady())
        assertTrue(gate.servicesReady())
        assertTrue(gate.mtuReady())
    }
    @Test fun repeatedMtuDoesNotStartOverlappingGattReads() {
        val gate = BleIdentityGate()
        assertTrue(gate.servicesReady())
        assertTrue(gate.mtuReady())
        assertFalse(gate.mtuReady())
        assertFalse(gate.servicesReady())
    }
    @Test fun reconnectRequiresFreshServiceDiscovery() {
        val gate = BleIdentityGate()
        gate.servicesReady(); gate.mtuReady(); gate.reset()
        assertFalse(gate.mtuReady())
        assertTrue(gate.servicesReady())
        assertTrue(gate.mtuReady())
    }
}
