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

// Each device has one mono input and one mono loopback sink. No client HAL calls
// or IPC are made inside the driver. The existing Bridge writes to the sinks.
enum { kDevice1 = 2, kInput1 = 3, kOutput1 = 4,
       kDevice2 = 5, kInput2 = 6, kOutput2 = 7,
       kRingFrames = 65536, kClockPeriod = 16384, kLoopbackFrames = 1024 };
static const double kRate = 48000.0;

typedef struct {
    _Atomic uint32_t samples[kRingFrames];
    _Atomic int64_t tags[kRingFrames];
    _Atomic uint32_t runningClients;
    _Atomic uint64_t anchor;
    _Atomic uint64_t seed;
} Channel;

static Channel gChannels[2];
static pthread_mutex_t gStateLock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic uint32_t gReferences = 1;
static AudioServerPlugInHostRef gHost;
static double gTicksPerFrame;
static AudioServerPlugInDriverInterface gInterface;
static AudioServerPlugInDriverInterface *gInterfacePointer = &gInterface;
static AudioServerPlugInDriverRef gDriver = &gInterfacePointer;

static int channelIndex(AudioObjectID object) {
    if (object >= kDevice1 && object <= kOutput1) return 0;
    if (object >= kDevice2 && object <= kOutput2) return 1;
    return -1;
}
static Boolean isDevice(AudioObjectID object) { return object == kDevice1 || object == kDevice2; }
static Boolean isStream(AudioObjectID object) { return object == kInput1 || object == kOutput1 || object == kInput2 || object == kOutput2; }
static Boolean isInput(AudioObjectID object) { return object == kInput1 || object == kInput2; }
static AudioObjectID deviceID(int channel) { return channel == 0 ? kDevice1 : kDevice2; }
static AudioClassID objectClass(AudioObjectID object) {
    return object == kAudioObjectPlugInObject ? kAudioPlugInClassID : isDevice(object) ? kAudioDeviceClassID : kAudioStreamClassID;
}
static CFStringRef deviceUID(int channel) {
    return channel == 0 ? CFSTR("com.openrayneo.microphone.channel1") : CFSTR("com.openrayneo.microphone.channel2");
}
static CFStringRef objectName(AudioObjectID object) {
    if (object == kAudioObjectPlugInObject) return CFSTR("OpenRayneo Audio");
    if (isStream(object)) return isInput(object) ? CFSTR("Microphone") : CFSTR("Bridge audio sink");
    return channelIndex(object) == 0 ? CFSTR("OpenRayneo Microphone Channel 1") : CFSTR("OpenRayneo Microphone Channel 2");
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
    gTicksPerFrame = (1.0e9 * timebase.denom / timebase.numer) / kRate;
    for (int channel = 0; channel < 2; channel++) {
        for (int frame = 0; frame < kRingFrames; frame++) atomic_store(&gChannels[channel].tags[frame], INT64_MIN);
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
    if (!address || object < 1 || object > kOutput2 || address->mElement != kAudioObjectPropertyElementMain) return false;
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
    AudioObjectID candidates[2];
    UInt32 count = 0;
    if (object == kAudioObjectPlugInObject) {
        candidates[count++] = kDevice1;
        candidates[count++] = kDevice2;
    } else if (isDevice(object)) {
        int channel = channelIndex(object);
        if (address->mScope != kAudioObjectPropertyScopeOutput) candidates[count++] = deviceID(channel) + 1;
        if (address->mScope != kAudioObjectPropertyScopeInput) candidates[count++] = deviceID(channel) + 2;
    }
    UInt32 matched = 0;
    for (UInt32 i = 0; i < count; i++) {
        Boolean include = qualifierSize == 0;
        if (qualifier && address->mSelector == kAudioObjectPropertyOwnedObjects) {
            const AudioClassID *classes = qualifier;
            for (UInt32 j = 0; j < qualifierSize / sizeof(AudioClassID); j++) {
                if (classes[j] == kAudioObjectClassID || classes[j] == objectClass(candidates[i])) include = true;
            }
        } else include = true;
        if (include) result[matched++] = candidates[i];
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
            AudioObjectID list[2];
            *size = objectList(object, address, qualifierSize, qualifier, list) * sizeof(AudioObjectID);
            break;
        }
        case kAudioDevicePropertyRelatedDevices: *size = 2 * sizeof(AudioObjectID); break;
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
    int channel = channelIndex(object);
    UInt32 value = 0;
    CFStringRef string = NULL;
    switch (address->mSelector) {
        case kAudioObjectPropertyName: string = objectName(object); break;
        case kAudioObjectPropertyManufacturer: string = CFSTR("OpenRayneo"); break;
        case kAudioPlugInPropertyBundleID: string = CFSTR("com.openrayneo.audio.driver"); break;
        case kAudioDevicePropertyDeviceUID: string = deviceUID(channel); break;
        case kAudioDevicePropertyModelUID: string = CFSTR("com.openrayneo.microphone"); break;
        case kAudioObjectPropertyBaseClass: value = kAudioObjectClassID; break;
        case kAudioObjectPropertyClass: value = objectClass(object); break;
        case kAudioObjectPropertyOwner: value = object == kAudioObjectPlugInObject ? kAudioObjectUnknown : isDevice(object) ? kAudioObjectPlugInObject : deviceID(channel); break;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
        case kAudioDevicePropertyStreams: objectList(object, address, qualifierSize, qualifier, output); return noErr;
        case kAudioDevicePropertyRelatedDevices: {
            AudioObjectID list[] = { kDevice1, kDevice2 };
            memcpy(output, list, sizeof(list)); return noErr;
        }
        case kAudioPlugInPropertyTranslateUIDToDevice:
            if (qualifierSize != sizeof(CFStringRef) || !qualifier) return kAudioHardwareBadPropertySizeError;
            for (int i = 0; i < 2; i++) if (CFEqual(*(CFStringRef const *)qualifier, deviceUID(i))) value = deviceID(i);
            break;
        case kAudioDevicePropertyTransportType: value = kAudioDeviceTransportTypeVirtual; break;
        case kAudioDevicePropertyClockDomain: value = 0; break;
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyClockIsStable:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyStartingChannel: value = 1; break;
        case kAudioDevicePropertyDeviceIsRunning: value = atomic_load(&gChannels[channel].runningClients) > 0; break;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: value = address->mScope == kAudioObjectPropertyScopeInput; break;
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden: value = 0; break;
        case kAudioDevicePropertyLatency: value = isDevice(object) && address->mScope == kAudioObjectPropertyScopeInput ? kLoopbackFrames : 0; break;
        case kAudioDevicePropertyZeroTimeStampPeriod: value = kClockPeriod; break;
        case kAudioStreamPropertyDirection: value = isInput(object) ? 1 : 0; break;
        case kAudioStreamPropertyTerminalType: value = isInput(object) ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeLine; break;
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
    if (!isDevice(device)) return kAudioHardwareBadObjectError;
    Channel *channel = &gChannels[channelIndex(device)];
    pthread_mutex_lock(&gStateLock);
    if (atomic_load(&channel->runningClients) == 0) {
        for (int frame = 0; frame < kRingFrames; frame++) atomic_store_explicit(&channel->tags[frame], INT64_MIN, memory_order_relaxed);
        atomic_store(&channel->anchor, mach_absolute_time());
        atomic_fetch_add(&channel->seed, 1);
    }
    atomic_fetch_add(&channel->runningClients, 1);
    pthread_mutex_unlock(&gStateLock);
    return noErr;
}
static OSStatus stopIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client) {
    if (!isDevice(device)) return kAudioHardwareBadObjectError;
    Channel *channel = &gChannels[channelIndex(device)];
    pthread_mutex_lock(&gStateLock);
    uint32_t clients = atomic_load(&channel->runningClients);
    if (clients > 0) atomic_fetch_sub(&channel->runningClients, 1);
    pthread_mutex_unlock(&gStateLock);
    return noErr;
}
static OSStatus zeroTimestamp(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client,
                               Float64 *sample, UInt64 *host, UInt64 *seed) {
    if (!isDevice(device)) return kAudioHardwareBadObjectError;
    Channel *channel = &gChannels[channelIndex(device)];
    uint64_t anchor = atomic_load(&channel->anchor);
    uint64_t now = mach_absolute_time();
    double ticksPerPeriod = gTicksPerFrame * kClockPeriod;
    uint64_t periods = now >= anchor ? (uint64_t)((now - anchor) / ticksPerPeriod) : 0;
    *sample = (double)periods * kClockPeriod;
    *host = anchor + (uint64_t)(periods * ticksPerPeriod);
    *seed = atomic_load(&channel->seed);
    return noErr;
}
static OSStatus willDoIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client,
                          UInt32 operation, Boolean *willDo, Boolean *inPlace) {
    if (!isDevice(device)) return kAudioHardwareBadObjectError;
    *willDo = operation == kAudioServerPlugInIOOperationReadInput || operation == kAudioServerPlugInIOOperationWriteMix;
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
    if (!isDevice(device) || channelIndex(stream) != channelIndex(device) || !isStream(stream)) return kAudioHardwareBadObjectError;
    if (!main || !cycle) return kAudioHardwareIllegalOperationError;
    Channel *channel = &gChannels[channelIndex(device)];
    float *audio = main;
    if (operation == kAudioServerPlugInIOOperationWriteMix && !isInput(stream)) {
        int64_t start = (int64_t)cycle->mOutputTime.mSampleTime;
        for (UInt32 frame = 0; frame < frames; frame++) {
            int64_t time = start + frame;
            uint32_t index = (uint64_t)time % kRingFrames;
            uint32_t bits;
            memcpy(&bits, &audio[frame], sizeof(bits));
            atomic_store_explicit(&channel->tags[index], INT64_MIN, memory_order_release);
            atomic_store_explicit(&channel->samples[index], bits, memory_order_relaxed);
            atomic_store_explicit(&channel->tags[index], time, memory_order_release);
        }
    } else if (operation == kAudioServerPlugInIOOperationReadInput && isInput(stream)) {
        int64_t start = (int64_t)cycle->mInputTime.mSampleTime - kLoopbackFrames;
        for (UInt32 frame = 0; frame < frames; frame++) {
            int64_t time = start + frame;
            uint32_t index = (uint64_t)time % kRingFrames;
            audio[frame] = 0;
            if (atomic_load_explicit(&channel->tags[index], memory_order_acquire) == time) {
                uint32_t bits = atomic_load_explicit(&channel->samples[index], memory_order_relaxed);
                if (atomic_load_explicit(&channel->tags[index], memory_order_acquire) == time) memcpy(&audio[frame], &bits, sizeof(bits));
            }
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
