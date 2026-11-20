// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

#ifndef OPENRAYNEO_AUDIO_RING_H
#define OPENRAYNEO_AUDIO_RING_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

enum {
    kOpenRayneoRingFrames = 65536,
    kOpenRayneoClockPeriod = 16384,
    kOpenRayneoLoopbackFrames = 1024,
    kOpenRayneoSampleRate = 48000
};

__extension__ typedef unsigned __int128 openrayneo_u128;

typedef struct {
    uint32_t numer;
    uint32_t denom;
    uint32_t sampleRate;
} OpenRayneoTimebase;

static inline void openRayneoRingClear(_Atomic uint64_t *slots) {
    for (uint32_t i = 0; i < kOpenRayneoRingFrames; i++) {
        atomic_store_explicit(&slots[i], 0ULL, memory_order_relaxed);
    }
    atomic_thread_fence(memory_order_release);
}

static inline uint32_t openRayneoRingFrameTag(int64_t globalFrame) {
    if (globalFrame < 0) {
        return 0u;
    }
    uint32_t tag = (uint32_t)((uint64_t)globalFrame >> 16) + 1u;
    return tag == 0u ? 1u : tag;
}

static inline void openRayneoRingWriteFrame(_Atomic uint64_t *slots, int64_t globalFrame, float sample) {
    if (globalFrame < 0) {
        return;
    }
    uint32_t index = (uint32_t)((uint64_t)globalFrame & (kOpenRayneoRingFrames - 1u));
    uint32_t tag = openRayneoRingFrameTag(globalFrame);
    uint32_t bits = 0u;
    memcpy(&bits, &sample, sizeof(bits));
    uint64_t packed = ((uint64_t)tag << 32) | (uint64_t)bits;
    atomic_store_explicit(&slots[index], packed, memory_order_release);
}

static inline float openRayneoRingReadFrame(_Atomic uint64_t *slots, int64_t globalFrame) {
    if (globalFrame < 0) {
        return 0.0f;
    }
    uint32_t index = (uint32_t)((uint64_t)globalFrame & (kOpenRayneoRingFrames - 1u));
    uint32_t expectedTag = openRayneoRingFrameTag(globalFrame);
    uint64_t packed = atomic_load_explicit(&slots[index], memory_order_acquire);
    if ((uint32_t)(packed >> 32) != expectedTag) {
        return 0.0f;
    }
    uint32_t bits = (uint32_t)(packed & 0xFFFFFFFFu);
    float sample = 0.0f;
    memcpy(&sample, &bits, sizeof(sample));
    return sample;
}

static inline int64_t openRayneoRoundSampleTime(double sampleTime) {
    return sampleTime >= 0.0 ? (int64_t)(sampleTime + 0.5) : (int64_t)(sampleTime - 0.5);
}

static inline uint64_t openRayneoTicksToFrames(uint64_t elapsedTicks, OpenRayneoTimebase tb) {
    if (tb.numer == 0u || tb.denom == 0u || tb.sampleRate == 0u) {
        return 0ULL;
    }
    openrayneo_u128 numerator = (openrayneo_u128)elapsedTicks * (openrayneo_u128)tb.numer * (openrayneo_u128)tb.sampleRate;
    openrayneo_u128 denominator = (openrayneo_u128)tb.denom * (openrayneo_u128)1000000000ULL;
    return (uint64_t)(numerator / denominator);
}

static inline uint64_t openRayneoFramesToTicks(uint64_t frames, OpenRayneoTimebase tb) {
    if (tb.numer == 0u || tb.denom == 0u || tb.sampleRate == 0u || frames == 0ULL) {
        return 0ULL;
    }
    openrayneo_u128 numerator = (openrayneo_u128)frames * (openrayneo_u128)tb.denom * (openrayneo_u128)1000000000ULL;
    openrayneo_u128 denominator = (openrayneo_u128)tb.numer * (openrayneo_u128)tb.sampleRate;
    return (uint64_t)((numerator + denominator - 1u) / denominator);
}

static inline uint64_t openRayneoAlignBaseFrame(uint64_t epochTicks, uint64_t nowTicks, OpenRayneoTimebase tb) {
    uint64_t elapsed = nowTicks >= epochTicks ? (nowTicks - epochTicks) : 0ULL;
    uint64_t nowFrames = openRayneoTicksToFrames(elapsed, tb);
    return (nowFrames / (uint64_t)kOpenRayneoClockPeriod) * (uint64_t)kOpenRayneoClockPeriod;
}

static inline void openRayneoComputeZeroTimestamp(
    uint64_t epochTicks,
    uint64_t nowTicks,
    uint64_t baseFrame,
    OpenRayneoTimebase tb,
    double *outSampleTime,
    uint64_t *outHostTicks
) {
    uint64_t elapsed = nowTicks >= epochTicks ? (nowTicks - epochTicks) : 0ULL;
    uint64_t nowFrames = openRayneoTicksToFrames(elapsed, tb);
    uint64_t periods = nowFrames >= baseFrame
        ? (nowFrames - baseFrame) / (uint64_t)kOpenRayneoClockPeriod
        : 0ULL;
    uint64_t boundaryFrame = baseFrame + periods * (uint64_t)kOpenRayneoClockPeriod;
    *outSampleTime = (double)(periods * (uint64_t)kOpenRayneoClockPeriod);
    *outHostTicks = epochTicks + openRayneoFramesToTicks(boundaryFrame, tb);
}

#endif // OPENRAYNEO_AUDIO_RING_H
