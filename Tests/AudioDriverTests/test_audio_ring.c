// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

#include "../../Drivers/OpenRayneoAudio/OpenRayneoAudioRing.h"

#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

static _Atomic uint64_t gTestRing[kOpenRayneoRingFrames];

static float expectedSampleForFrame(int64_t frame) {
    int32_t mod = (int32_t)(frame % 997);
    return (float)(mod - 498) / 512.0f;
}

static void testEmptyAndNegativeFrames(void) {
    openRayneoRingClear(gTestRing);
    assert(openRayneoRingReadFrame(gTestRing, -1024) == 0.0f);
    assert(openRayneoRingReadFrame(gTestRing, -1) == 0.0f);
    for (int64_t f = 0; f < kOpenRayneoRingFrames * 2; f += 257) {
        assert(openRayneoRingReadFrame(gTestRing, f) == 0.0f);
    }
    openRayneoRingWriteFrame(gTestRing, -5, 0.75f);
    assert(openRayneoRingReadFrame(gTestRing, -5) == 0.0f);
}

static void testWraparoundAndStaleSilence(void) {
    openRayneoRingClear(gTestRing);

    // Write first full ring [0, 65536).
    for (int64_t f = 0; f < kOpenRayneoRingFrames; f++) {
        openRayneoRingWriteFrame(gTestRing, f, expectedSampleForFrame(f));
    }
    for (int64_t f = 0; f < kOpenRayneoRingFrames; f++) {
        assert(openRayneoRingReadFrame(gTestRing, f) == expectedSampleForFrame(f));
        // Next generation [65536, 131072) has NOT been written yet -> must return silence 0.0f!
        assert(openRayneoRingReadFrame(gTestRing, f + kOpenRayneoRingFrames) == 0.0f);
    }

    // Overwrite half of generation 1 [65536, 98304).
    for (int64_t f = kOpenRayneoRingFrames; f < kOpenRayneoRingFrames + 32768; f++) {
        openRayneoRingWriteFrame(gTestRing, f, expectedSampleForFrame(f));
    }
    for (int64_t f = 0; f < 32768; f++) {
        // Generation 0 slot was overwritten by generation 1 -> old frame reads 0.0f, new frame reads exact value.
        assert(openRayneoRingReadFrame(gTestRing, f) == 0.0f);
        assert(openRayneoRingReadFrame(gTestRing, f + kOpenRayneoRingFrames) == expectedSampleForFrame(f + kOpenRayneoRingFrames));
    }
    for (int64_t f = 32768; f < kOpenRayneoRingFrames; f++) {
        // Second half still holds generation 0; generation 1 is still unwritten -> silence!
        assert(openRayneoRingReadFrame(gTestRing, f) == expectedSampleForFrame(f));
        assert(openRayneoRingReadFrame(gTestRing, f + kOpenRayneoRingFrames) == 0.0f);
    }

    // Clearing immediately silences all frames.
    openRayneoRingClear(gTestRing);
    assert(openRayneoRingReadFrame(gTestRing, kOpenRayneoRingFrames) == 0.0f);
    assert(openRayneoRingReadFrame(gTestRing, 40000) == 0.0f);
}

static void verifyTimebaseInvariants(OpenRayneoTimebase tb, uint64_t ticksPerSecond) {
    const uint64_t epoch = 1000000ULL;

    // 72 hours exact frame count = 72 * 3600 * 48000 = 12,441,600,000 frames.
    uint64_t seventyTwoHoursTicks = 72ULL * 3600ULL * ticksPerSecond;
    uint64_t frames = openRayneoTicksToFrames(seventyTwoHoursTicks, tb);
    assert(frames == 72ULL * 3600ULL * 48000ULL);
    uint64_t backTicks = openRayneoFramesToTicks(frames, tb);
    assert(backTicks == seventyTwoHoursTicks);

    // Sink starts at t = 0.25s; Input starts over 1 hour later at t = 3723.6s.
    uint64_t sinkStart = epoch + ticksPerSecond / 4ULL;
    uint64_t inputStart = epoch + 3723ULL * ticksPerSecond + (ticksPerSecond * 3ULL) / 5ULL;
    uint64_t sinkBase = openRayneoAlignBaseFrame(epoch, sinkStart, tb);
    uint64_t inputBase = openRayneoAlignBaseFrame(epoch, inputStart, tb);
    assert(sinkBase % kOpenRayneoClockPeriod == 0ULL);
    assert(inputBase % kOpenRayneoClockPeriod == 0ULL);
    assert(inputBase > sinkBase);

    // Probe 500 timestamps after both devices are running:
    // Both must produce the EXACT same hostTicks boundary AND global frame!
    for (uint64_t step = 0; step < 500; step++) {
        uint64_t now = inputStart + step * (ticksPerSecond / 37ULL) + step * 13ULL;
        double sinkSample = 0.0;
        uint64_t sinkHost = 0ULL;
        double inputSample = 0.0;
        uint64_t inputHost = 0ULL;
        openRayneoComputeZeroTimestamp(epoch, now, sinkBase, tb, &sinkSample, &sinkHost);
        openRayneoComputeZeroTimestamp(epoch, now, inputBase, tb, &inputSample, &inputHost);

        // Zero-timestamp host ticks must match identically and never lie in the future.
        assert(sinkHost == inputHost);
        assert(sinkHost <= now);

        uint64_t sinkGlobalBoundary = sinkBase + (uint64_t)openRayneoRoundSampleTime(sinkSample);
        uint64_t inputGlobalBoundary = inputBase + (uint64_t)openRayneoRoundSampleTime(inputSample);
        assert(sinkGlobalBoundary == inputGlobalBoundary);

        uint64_t nextBoundaryHost = epoch + openRayneoFramesToTicks(sinkGlobalBoundary + kOpenRayneoClockPeriod, tb);
        assert(now < nextBoundaryHost);
    }
}

typedef struct {
    _Atomic int64_t latestFrame;
    _Atomic bool done;
} StressState;

static void *writerThreadMain(void *arg) {
    StressState *state = (StressState *)arg;
    for (int64_t f = 0; f < 400000; f++) {
        openRayneoRingWriteFrame(gTestRing, f, expectedSampleForFrame(f));
        if ((f & 63) == 0) {
            atomic_store_explicit(&state->latestFrame, f, memory_order_release);
        }
    }
    atomic_store_explicit(&state->done, true, memory_order_release);
    return NULL;
}

static void *readerThreadMain(void *arg) {
    StressState *state = (StressState *)arg;
    while (!atomic_load_explicit(&state->done, memory_order_acquire)) {
        int64_t head = atomic_load_explicit(&state->latestFrame, memory_order_acquire);
        int64_t target = head - kOpenRayneoLoopbackFrames;
        if (target >= 0) {
            float value = openRayneoRingReadFrame(gTestRing, target);
            assert(isfinite(value));
            // Either exact match or 0.0f if writer lapped the full 65536-frame ring while reader was preempted.
            assert(value == 0.0f || value == expectedSampleForFrame(target));
        }
    }
    return NULL;
}

static void testConcurrentReadWrite(void) {
    openRayneoRingClear(gTestRing);
    StressState state;
    atomic_init(&state.latestFrame, 0);
    atomic_init(&state.done, false);

    pthread_t writer;
    pthread_t readers[2];
    assert(pthread_create(&writer, NULL, writerThreadMain, &state) == 0);
    for (int i = 0; i < 2; i++) {
        assert(pthread_create(&readers[i], NULL, readerThreadMain, &state) == 0);
    }
    assert(pthread_join(writer, NULL) == 0);
    for (int i = 0; i < 2; i++) {
        assert(pthread_join(readers[i], NULL) == 0);
    }
}

int main(void) {
    assert(openRayneoRoundSampleTime(0.0) == 0);
    assert(openRayneoRoundSampleTime(511.999999999) == 512);
    assert(openRayneoRoundSampleTime(1024.0000001) == 1024);

    testEmptyAndNegativeFrames();
    testWraparoundAndStaleSilence();

    // Apple Silicon Mach timebase: 24 MHz counter -> 125 / 3 ns per tick.
    OpenRayneoTimebase appleSilicon = { .numer = 125u, .denom = 3u, .sampleRate = 48000u };
    verifyTimebaseInvariants(appleSilicon, 24000000ULL);

    // Intel Mach timebase: 1 GHz nanoseconds -> 1 / 1 ns per tick.
    OpenRayneoTimebase intel = { .numer = 1u, .denom = 1u, .sampleRate = 48000u };
    verifyTimebaseInvariants(intel, 1000000000ULL);

    testConcurrentReadWrite();
    printf("All OpenRayneoAudioRing tests passed.\n");
    return 0;
}
