// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

#include "OpenRayneoAudioRing.h"

// Each logical microphone channel exposes one public input-only device for capture apps
// and one hidden output-only sink device written exclusively by OpenRayneo Bridge.
// Both share a phase-locked global frame clock and a single-word 64-bit atomic ring buffer.
enum {
    kInputDevice1 = 2,
    kInputStream1 = 3,
    kSinkDevice1  = 4,
    kSinkStream1  = 5,
    kInputDevice2 = 6,
    kInputStream2 = 7,
    kSinkDevice2  = 8,
    kSinkStream2  = 9,
    kDeviceCount  = 4,
    kClockDomainID = 0x4F524E41 // 'ORNA'
};

static const double kRate = (double)kOpenRayneoSampleRate;

typedef struct {
    _Atomic uint64_t slots[kOpenRayneoRingFrames];
} ChannelRing;

typedef struct {
    _Atomic uint32_t runningClients;
    _Atomic uint64_t baseFrame;
    _Atomic uint64_t seed;
} DeviceClock;

static ChannelRing gChannels[2];
static DeviceClock gDevices[kDeviceCount];
static pthread_mutex_t gStateLock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic uint32_t gReferences = 1;
static AudioServerPlugInHostRef gHost;
static OpenRayneoTimebase gTimebase;
static uint64_t gEpochTicks;
static AudioServerPlugInDriverInterface gInterface;
static AudioServerPlugInDriverInterface *gInterfacePointer = &gInterface;
static AudioServerPlugInDriverRef gDriver = &gInterfacePointer;

static Boolean isInputDevice(AudioObjectID object) {
    return object == kInputDevice1 || object == kInputDevice2;
}
static Boolean isSinkDevice(AudioObjectID object) {
    return object == kSinkDevice1 || object == kSinkDevice2;
}
static Boolean isDevice(AudioObjectID object) {
    return isInputDevice(object) || isSinkDevice(object);
}
static Boolean isInputStream(AudioObjectID object) {
    return object == kInputStream1 || object == kInputStream2;
}
static Boolean isSinkStream(AudioObjectID object) {
    return object == kSinkStream1 || object == kSinkStream2;
}
static Boolean isStream(AudioObjectID object) {
    return isInputStream(object) || isSinkStream(object);
}
static int channelIndex(AudioObjectID object) {
    if (object >= kInputDevice1 && object <= kSinkStream1) return 0;
    if (object >= kInputDevice2 && object <= kSinkStream2) return 1;
    return -1;
}
static int deviceSlotIndex(AudioObjectID device) {
    switch (device) {
        case kInputDevice1: return 0;
        case kSinkDevice1:  return 1;
        case kInputDevice2: return 2;
        case kSinkDevice2:  return 3;
        default:            return -1;
    }
}
static AudioObjectID streamForDevice(AudioObjectID device) {
    switch (device) {
        case kInputDevice1: return kInputStream1;
        case kSinkDevice1:  return kSinkStream1;
        case kInputDevice2: return kInputStream2;
        case kSinkDevice2:  return kSinkStream2;
        default:            return kAudioObjectUnknown;
    }
}
static AudioObjectID ownerForStream(AudioObjectID stream) {
    switch (stream) {
        case kInputStream1: return kInputDevice1;
        case kSinkStream1:  return kSinkDevice1;
        case kInputStream2: return kInputDevice2;
        case kSinkStream2:  return kSinkDevice2;
        default:            return kAudioObjectUnknown;
    }
}
static AudioClassID objectClass(AudioObjectID object) {
    if (object == kAudioObjectPlugInObject) return kAudioPlugInClassID;
    if (isDevice(object)) return kAudioDeviceClassID;
    return kAudioStreamClassID;
}
static CFStringRef deviceUID(AudioObjectID device) {
    switch (device) {
        case kInputDevice1: return CFSTR("com.openrayneo.microphone.channel1");
        case kSinkDevice1:  return CFSTR("com.openrayneo.microphone.sink1");
        case kInputDevice2: return CFSTR("com.openrayneo.microphone.channel2");
        case kSinkDevice2:  return CFSTR("com.openrayneo.microphone.sink2");
        default:            return CFSTR("");
    }
}
static CFStringRef objectName(AudioObjectID object) {
    switch (object) {
        case kAudioObjectPlugInObject: return CFSTR("OpenRayneo Audio");
        case kInputDevice1:            return CFSTR("OpenRayneo Microphone Channel 1");
        case kInputDevice2:            return CFSTR("OpenRayneo Microphone Channel 2");
        case kSinkDevice1:             return CFSTR("OpenRayneo Audio Sink Channel 1");
        case kSinkDevice2:             return CFSTR("OpenRayneo Audio Sink Channel 2");
        case kInputStream1:
        case kInputStream2:            return CFSTR("Microphone");
        default:                       return CFSTR("Bridge audio sink");
    }
}
static AudioStreamBasicDescription streamFormat(void) {
    return (AudioStreamBasicDescription) {
        .mSampleRate = kRate, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagsNativeFloatPacked,
        .mBytesPerPacket = sizeof(float), .mFramesPerPacket = 1,
        .mBytesPerFrame = sizeof(float), .mChannelsPerFrame = 1, .mBitsPerChannel = 32
    };
}

static HRESULT queryInterface(void *driver, REFIID uuid, LPVOID *result) {
    if (!result || driver != gDriver) return E_NOINTERFACE;
    *result = NULL;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, uuid);
    Boolean supported = CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requested);
    if (!supported) return E_NOINTERFACE;
    atomic_fetch_add(&gReferences, 1);
    *result = gDriver;
    return S_OK;
}
static ULONG addReference(void *driver) { return atomic_fetch_add(&gReferences, 1) + 1; }
static ULONG releaseReference(void *driver) {
    uint32_t count = atomic_load(&gReferences);
    while (count > 0 && !atomic_compare_exchange_weak(&gReferences, &count, count - 1)) {}
    return count > 0 ? count - 1 : 0;
}
static OSStatus initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    gHost = host;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    gTimebase = (OpenRayneoTimebase) {
        .numer = timebase.numer ? timebase.numer : 1u,
        .denom = timebase.denom ? timebase.denom : 1u,
        .sampleRate = (uint32_t)kOpenRayneoSampleRate
    };
    gEpochTicks = mach_absolute_time();
    for (int ch = 0; ch < 2; ch++) {
        openRayneoRingClear(gChannels[ch].slots);
    }
    for (int i = 0; i < kDeviceCount; i++) {
        atomic_store_explicit(&gDevices[i].runningClients, 0u, memory_order_relaxed);
        atomic_store_explicit(&gDevices[i].baseFrame, 0ULL, memory_order_relaxed);
        atomic_store_explicit(&gDevices[i].seed, 1ULL, memory_order_relaxed);
    }
    return noErr;
}
static OSStatus createDevice(AudioServerPlugInDriverRef driver, CFDictionaryRef description,
                             const AudioServerPlugInClientInfo *client, AudioObjectID *device) {
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus destroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID device) {
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus deviceClient(AudioServerPlugInDriverRef driver, AudioObjectID device,
                             const AudioServerPlugInClientInfo *client) {
    return isDevice(device) ? noErr : kAudioHardwareBadObjectError;
}
static OSStatus configurationChange(AudioServerPlugInDriverRef driver, AudioObjectID device,
                                    UInt64 action, void *info) {
    return kAudioHardwareUnsupportedOperationError;
}

static Boolean hasProperty(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
                            const AudioObjectPropertyAddress *address) {
    if (!address || object < kAudioObjectPlugInObject || object > kSinkStream2 ||
        address->mElement != kAudioObjectPropertyElementMain) {
        return false;
    }
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyCustomPropertyInfoList: return true;
    }
    if (object == kAudioObjectPlugInObject) {
        switch (address->mSelector) {
            case kAudioPlugInPropertyBundleID:
            case kAudioPlugInPropertyDeviceList:
            case kAudioPlugInPropertyTranslateUIDToDevice:
            case kAudioPlugInPropertyBoxList:
            case kAudioPlugInPropertyClockDeviceList: return true;
        }
    } else if (isDevice(object)) {
        switch (address->mSelector) {
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:
            case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyRelatedDevices:
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyLatency:
            case kAudioObjectPropertyControlList:
            case kAudioDevicePropertyStreams:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyNominalSampleRate:
            case kAudioDevicePropertyAvailableNominalSampleRates:
            case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertyZeroTimeStampPeriod:
            case kAudioDevicePropertyClockIsStable: return true;
        }
    } else if (isStream(object)) {
        switch (address->mSelector) {
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyLatency:
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyPhysicalFormat:
            case kAudioStreamPropertyAvailablePhysicalFormats: return true;
        }
    }
    return false;
}

static UInt32 objectList(AudioObjectID object, const AudioObjectPropertyAddress *address,
                          UInt32 qualifierSize, const void *qualifier, AudioObjectID *result) {
    AudioObjectID candidates[kDeviceCount];
    UInt32 count = 0;
    if (object == kAudioObjectPlugInObject) {
        candidates[count++] = kInputDevice1;
        candidates[count++] = kSinkDevice1;
        candidates[count++] = kInputDevice2;
        candidates[count++] = kSinkDevice2;
    } else if (isInputDevice(object)) {
        if (address->mScope != kAudioObjectPropertyScopeOutput) {
            candidates[count++] = streamForDevice(object);
        }
    } else if (isSinkDevice(object)) {
        if (address->mScope != kAudioObjectPropertyScopeInput) {
            candidates[count++] = streamForDevice(object);
        }
    }
    UInt32 matched = 0;
    for (UInt32 i = 0; i < count; i++) {
        Boolean include = qualifierSize == 0;
        if (qualifier && address->mSelector == kAudioObjectPropertyOwnedObjects) {
            const AudioClassID *classes = qualifier;
            for (UInt32 j = 0; j < qualifierSize / sizeof(AudioClassID); j++) {
                if (classes[j] == kAudioObjectClassID || classes[j] == objectClass(candidates[i])) {
                    include = true;
                }
            }
        } else {
            include = true;
        }
        if (include) {
            result[matched++] = candidates[i];
        }
    }
    return matched;
}

static OSStatus propertySize(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
                              const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
                              const void *qualifier, UInt32 *size) {
    if (!size) return kAudioHardwareIllegalOperationError;
    if (!hasProperty(driver, object, client, address)) return kAudioHardwareUnknownPropertyError;
    switch (address->mSelector) {
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyBundleID:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID: *size = sizeof(CFStringRef); break;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
        case kAudioDevicePropertyStreams: {
            AudioObjectID list[kDeviceCount];
            *size = objectList(object, address, qualifierSize, qualifier, list) * sizeof(AudioObjectID);
            break;
        }
        case kAudioDevicePropertyRelatedDevices: *size = sizeof(AudioObjectID); break;
        case kAudioObjectPropertyControlList:
        case kAudioObjectPropertyCustomPropertyInfoList:
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyClockDeviceList: *size = 0; break;
        case kAudioDevicePropertyNominalSampleRate: *size = sizeof(Float64); break;
        case kAudioDevicePropertyAvailableNominalSampleRates: *size = sizeof(AudioValueRange); break;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: *size = sizeof(AudioStreamBasicDescription); break;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: *size = sizeof(AudioStreamRangedDescription); break;
        default: *size = sizeof(UInt32); break;
    }
    return noErr;
}

static OSStatus getProperty(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
                             const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
                             const void *qualifier, UInt32 capacity, UInt32 *size, void *output) {
    OSStatus error = propertySize(driver, object, client, address, qualifierSize, qualifier, size);
    if (error != noErr) return error;
    if (capacity < *size) return kAudioHardwareBadPropertySizeError;
    if (*size == 0) return noErr;
    if (!output) return kAudioHardwareIllegalOperationError;
    UInt32 value = 0;
    CFStringRef string = NULL;
    switch (address->mSelector) {
        case kAudioObjectPropertyName: string = objectName(object); break;
        case kAudioObjectPropertyManufacturer: string = CFSTR("OpenRayneo"); break;
        case kAudioPlugInPropertyBundleID: string = CFSTR("com.openrayneo.audio.driver"); break;
        case kAudioDevicePropertyDeviceUID: string = deviceUID(object); break;
        case kAudioDevicePropertyModelUID:
            string = isSinkDevice(object) ? CFSTR("com.openrayneo.microphone.sink") : CFSTR("com.openrayneo.microphone");
            break;
        case kAudioObjectPropertyBaseClass: value = kAudioObjectClassID; break;
        case kAudioObjectPropertyClass: value = objectClass(object); break;
        case kAudioObjectPropertyOwner:
            value = object == kAudioObjectPlugInObject
                ? kAudioObjectUnknown
                : (isDevice(object) ? kAudioObjectPlugInObject : ownerForStream(object));
            break;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
        case kAudioDevicePropertyStreams:
            objectList(object, address, qualifierSize, qualifier, output);
            return noErr;
        case kAudioDevicePropertyRelatedDevices:
            *(AudioObjectID *)output = object;
            return noErr;
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (qualifierSize != sizeof(CFStringRef) || !qualifier) return kAudioHardwareBadPropertySizeError;
            CFStringRef targetUID = *(CFStringRef const *)qualifier;
            if (!targetUID) return kAudioHardwareIllegalOperationError;
            const AudioObjectID devices[kDeviceCount] = { kInputDevice1, kSinkDevice1, kInputDevice2, kSinkDevice2 };
            value = kAudioObjectUnknown;
            for (int i = 0; i < kDeviceCount; i++) {
                if (CFEqual(targetUID, deviceUID(devices[i]))) {
                    value = devices[i];
                    break;
                }
            }
            break;
        }
        case kAudioDevicePropertyTransportType: value = kAudioDeviceTransportTypeVirtual; break;
        case kAudioDevicePropertyClockDomain: value = kClockDomainID; break;
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyClockIsStable:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyStartingChannel: value = 1; break;
        case kAudioDevicePropertyDeviceIsRunning: {
            int slot = deviceSlotIndex(object);
            value = slot >= 0 && atomic_load_explicit(&gDevices[slot].runningClients, memory_order_acquire) > 0;
            break;
        }
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            value = isInputDevice(object) && address->mScope == kAudioObjectPropertyScopeInput;
            break;
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertySafetyOffset:
        case kAudioStreamPropertyLatency: value = 0; break;
        case kAudioDevicePropertyIsHidden: value = isSinkDevice(object) ? 1 : 0; break;
        case kAudioDevicePropertyLatency:
            value = (isInputDevice(object) && address->mScope != kAudioObjectPropertyScopeOutput)
                ? kOpenRayneoLoopbackFrames : 0;
            break;
        case kAudioDevicePropertyZeroTimeStampPeriod: value = kOpenRayneoClockPeriod; break;
        case kAudioStreamPropertyDirection: value = isInputStream(object) ? 1 : 0; break;
        case kAudioStreamPropertyTerminalType:
            value = isInputStream(object) ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeLine;
            break;
        case kAudioDevicePropertyNominalSampleRate: *(Float64 *)output = kRate; return noErr;
        case kAudioDevicePropertyAvailableNominalSampleRates: *(AudioValueRange *)output = (AudioValueRange){ kRate, kRate }; return noErr;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: *(AudioStreamBasicDescription *)output = streamFormat(); return noErr;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *(AudioStreamRangedDescription *)output = (AudioStreamRangedDescription){ streamFormat(), { kRate, kRate } }; return noErr;
        default: return kAudioHardwareUnknownPropertyError;
    }
    if (string) { *(CFStringRef *)output = CFRetain(string); }
    else { *(UInt32 *)output = value; }
    return noErr;
}

static OSStatus propertySettable(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
                                  const AudioObjectPropertyAddress *address, Boolean *settable) {
    if (!hasProperty(driver, object, client, address)) return kAudioHardwareUnknownPropertyError;
    if (!settable) return kAudioHardwareIllegalOperationError;
    *settable = address->mSelector == kAudioDevicePropertyNominalSampleRate ||
                address->mSelector == kAudioStreamPropertyVirtualFormat || address->mSelector == kAudioStreamPropertyPhysicalFormat;
    return noErr;
}
static OSStatus setProperty(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
                             const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
                             const void *qualifier, UInt32 size, const void *input) {
    Boolean settable = false;
    OSStatus error = propertySettable(driver, object, client, address, &settable);
    if (error != noErr) return error;
    if (!settable || !input) return kAudioHardwareIllegalOperationError;
    if (address->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (size != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return *(const Float64 *)input == kRate ? noErr : kAudioHardwareIllegalOperationError;
    }
    if (size != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
    const AudioStreamBasicDescription *format = input;
    AudioStreamBasicDescription expected = streamFormat();
    return format->mSampleRate == expected.mSampleRate && format->mFormatID == expected.mFormatID &&
           format->mFormatFlags == expected.mFormatFlags && format->mBytesPerPacket == expected.mBytesPerPacket &&
           format->mFramesPerPacket == expected.mFramesPerPacket && format->mBytesPerFrame == expected.mBytesPerFrame &&
           format->mChannelsPerFrame == expected.mChannelsPerFrame && format->mBitsPerChannel == expected.mBitsPerChannel
        ? noErr : kAudioHardwareIllegalOperationError;
}

static OSStatus startIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client) {
    int slot = deviceSlotIndex(device);
    int ch = channelIndex(device);
    if (slot < 0 || ch < 0) return kAudioHardwareBadObjectError;
    DeviceClock *dev = &gDevices[slot];
    pthread_mutex_lock(&gStateLock);
    if (atomic_load_explicit(&dev->runningClients, memory_order_relaxed) == 0) {
        if (isSinkDevice(device)) {
            openRayneoRingClear(gChannels[ch].slots);
        }
        uint64_t base = openRayneoAlignBaseFrame(gEpochTicks, mach_absolute_time(), gTimebase);
        atomic_store_explicit(&dev->baseFrame, base, memory_order_relaxed);
        atomic_fetch_add_explicit(&dev->seed, 1ULL, memory_order_release);
    }
    atomic_fetch_add_explicit(&dev->runningClients, 1u, memory_order_release);
    pthread_mutex_unlock(&gStateLock);
    return noErr;
}
static OSStatus stopIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client) {
    int slot = deviceSlotIndex(device);
    int ch = channelIndex(device);
    if (slot < 0 || ch < 0) return kAudioHardwareBadObjectError;
    DeviceClock *dev = &gDevices[slot];
    pthread_mutex_lock(&gStateLock);
    uint32_t clients = atomic_load_explicit(&dev->runningClients, memory_order_relaxed);
    if (clients > 0) {
        uint32_t remaining = clients - 1u;
        atomic_store_explicit(&dev->runningClients, remaining, memory_order_release);
        if (remaining == 0u && isSinkDevice(device)) {
            openRayneoRingClear(gChannels[ch].slots);
        }
    }
    pthread_mutex_unlock(&gStateLock);
    return noErr;
}
static OSStatus zeroTimestamp(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client,
                               Float64 *sample, UInt64 *host, UInt64 *seed) {
    int slot = deviceSlotIndex(device);
    if (slot < 0) return kAudioHardwareBadObjectError;
    if (!sample || !host || !seed) return kAudioHardwareIllegalOperationError;
    DeviceClock *dev = &gDevices[slot];
    uint64_t s1, s2, base;
    do {
        s1 = atomic_load_explicit(&dev->seed, memory_order_acquire);
        base = atomic_load_explicit(&dev->baseFrame, memory_order_relaxed);
        s2 = atomic_load_explicit(&dev->seed, memory_order_acquire);
    } while (s1 != s2);
    double sampleTime = 0.0;
    uint64_t hostTicks = 0ULL;
    openRayneoComputeZeroTimestamp(gEpochTicks, mach_absolute_time(), base, gTimebase, &sampleTime, &hostTicks);
    *sample = sampleTime;
    *host = hostTicks;
    *seed = s2;
    return noErr;
}
static OSStatus willDoIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client,
                          UInt32 operation, Boolean *willDo, Boolean *inPlace) {
    if (!isDevice(device)) return kAudioHardwareBadObjectError;
    if (!willDo || !inPlace) return kAudioHardwareIllegalOperationError;
    if (isInputDevice(device)) {
        *willDo = operation == kAudioServerPlugInIOOperationReadInput;
    } else {
        *willDo = operation == kAudioServerPlugInIOOperationWriteMix;
    }
    *inPlace = true;
    return noErr;
}
static OSStatus boundaryIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client,
                            UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) {
    return isDevice(device) ? noErr : kAudioHardwareBadObjectError;
}
static OSStatus doIO(AudioServerPlugInDriverRef driver, AudioObjectID device, AudioObjectID stream,
                     UInt32 client, UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle,
                     void *main, void *secondary) {
    int slot = deviceSlotIndex(device);
    int ch = channelIndex(device);
    if (slot < 0 || ch < 0 || stream != streamForDevice(device)) return kAudioHardwareBadObjectError;
    if (!main || !cycle) return kAudioHardwareIllegalOperationError;
    int64_t base = (int64_t)atomic_load_explicit(&gDevices[slot].baseFrame, memory_order_acquire);
    ChannelRing *ring = &gChannels[ch];
    float *audio = main;
    if (operation == kAudioServerPlugInIOOperationWriteMix && isSinkDevice(device)) {
        int64_t start = base + openRayneoRoundSampleTime(cycle->mOutputTime.mSampleTime);
        for (UInt32 frame = 0; frame < frames; frame++) {
            openRayneoRingWriteFrame(ring->slots, start + (int64_t)frame, audio[frame]);
        }
    } else if (operation == kAudioServerPlugInIOOperationReadInput && isInputDevice(device)) {
        int64_t start = base + openRayneoRoundSampleTime(cycle->mInputTime.mSampleTime) - kOpenRayneoLoopbackFrames;
        for (UInt32 frame = 0; frame < frames; frame++) {
            audio[frame] = openRayneoRingReadFrame(ring->slots, start + (int64_t)frame);
        }
    }
    return noErr;
}

static AudioServerPlugInDriverInterface gInterface = {
    NULL, queryInterface, addReference, releaseReference,
    initialize, createDevice, destroyDevice, deviceClient, deviceClient,
    configurationChange, configurationChange, hasProperty, propertySettable,
    propertySize, getProperty, setProperty, startIO, stopIO, zeroTimestamp,
    willDoIO, boundaryIO, doIO, boundaryIO
};

__attribute__((visibility("default")))
void *OpenRayneoAudioFactory(CFAllocatorRef allocator, CFUUIDRef type) {
    return CFEqual(type, kAudioServerPlugInTypeUUID) ? gDriver : NULL;
}
