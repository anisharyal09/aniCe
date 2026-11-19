// SPDX-License-Identifier: GPL-3.0-or-later
// Copies Float32 audio into a lock-free bounded SPSC ring without allocating or overwriting consumer-owned frames.
#include "PrivateListeningRing.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <limits.h>

struct AniceListeningRing {
    uint32_t capacity;
    float *samples;
    uint64_t *positions;
    _Atomic uint64_t written;
    _Atomic uint64_t read;
    _Atomic uint64_t sourceFrames;
    _Atomic uint64_t droppedFrames;
    _Atomic bool forwarding;
    _Atomic bool invalidated;
};

AniceListeningRing *AniceListeningRingCreate(uint32_t capacityFrames) {
    if (capacityFrames == 0 || capacityFrames > 38400) return NULL;
    AniceListeningRing *ring = calloc(1, sizeof(*ring));
    if (!ring) return NULL;
    ring->capacity = capacityFrames;
    atomic_init(&ring->written, 0);
    atomic_init(&ring->read, 0);
    atomic_init(&ring->sourceFrames, 0);
    atomic_init(&ring->droppedFrames, 0);
    atomic_init(&ring->forwarding, true);
    atomic_init(&ring->invalidated, false);
    // A volatile startup result keeps the capability check explicit on targets where Clang folds it.
    volatile bool lockFree = atomic_is_lock_free(&ring->written) && atomic_is_lock_free(&ring->read) &&
        atomic_is_lock_free(&ring->sourceFrames) && atomic_is_lock_free(&ring->droppedFrames) &&
        atomic_is_lock_free(&ring->forwarding) && atomic_is_lock_free(&ring->invalidated);
    if (!lockFree) {
        free(ring);
        return NULL;
    }
    ring->samples = calloc((size_t)capacityFrames * 2, sizeof(float));
    ring->positions = calloc(capacityFrames, sizeof(uint64_t));
    if (!ring->samples || !ring->positions) {
        AniceListeningRingDestroy(ring);
        return NULL;
    }
    return ring;
}

void AniceListeningRingDestroy(AniceListeningRing *ring) {
    if (!ring) return;
    free(ring->samples);
    free(ring->positions);
    free(ring);
}

void AniceListeningRingSetForwarding(AniceListeningRing *ring, bool forwarding) {
    atomic_store_explicit(&ring->forwarding, forwarding, memory_order_release);
}

void AniceListeningRingInvalidate(AniceListeningRing *ring) {
    atomic_store_explicit(&ring->invalidated, true, memory_order_release);
}

bool AniceListeningRingInvalidated(const AniceListeningRing *ring) {
    return atomic_load_explicit(&ring->invalidated, memory_order_acquire);
}

uint64_t AniceListeningRingSourceFrames(const AniceListeningRing *ring) {
    return atomic_load_explicit(&ring->sourceFrames, memory_order_acquire);
}

uint64_t AniceListeningRingDroppedFrames(const AniceListeningRing *ring) {
    return atomic_load_explicit(&ring->droppedFrames, memory_order_relaxed);
}

uint32_t AniceListeningRingQueuedFrames(const AniceListeningRing *ring) {
    const uint64_t read = atomic_load_explicit(&ring->read, memory_order_acquire);
    const uint64_t written = atomic_load_explicit(&ring->written, memory_order_acquire);
    const uint64_t count = written - read;
    return (uint32_t)(count > ring->capacity ? ring->capacity : count);
}

void AniceListeningRingDiscard(AniceListeningRing *ring) {
    const uint64_t written = atomic_load_explicit(&ring->written, memory_order_acquire);
    atomic_store_explicit(&ring->read, written, memory_order_release);
}

uint32_t AniceListeningRingTrim(AniceListeningRing *ring, uint32_t maximumFrames) {
    const uint64_t read = atomic_load_explicit(&ring->read, memory_order_relaxed);
    const uint64_t written = atomic_load_explicit(&ring->written, memory_order_acquire);
    const uint64_t count = written - read;
    if (count <= maximumFrames) return 0;
    const uint32_t discarded = (uint32_t)(count - maximumFrames);
    atomic_store_explicit(&ring->read, read + discarded, memory_order_release);
    atomic_fetch_add_explicit(&ring->droppedFrames, discarded, memory_order_relaxed);
    return discarded;
}

bool AniceListeningRingWrite(AniceListeningRing *ring, const float *left,
                            const float *right, uint32_t stride, uint32_t frames) {
    const uint64_t start = atomic_load_explicit(&ring->sourceFrames, memory_order_relaxed);
    if (!left || !right || stride == 0 || frames > INT64_MAX - start) {
        AniceListeningRingInvalidate(ring);
        return false;
    }
    atomic_store_explicit(&ring->sourceFrames, start + frames, memory_order_release);
    if (!atomic_load_explicit(&ring->forwarding, memory_order_acquire)) return true;
    const uint64_t written = atomic_load_explicit(&ring->written, memory_order_relaxed);
    const uint64_t read = atomic_load_explicit(&ring->read, memory_order_acquire);
    if (frames > ring->capacity - (written - read)) {
        atomic_fetch_add_explicit(&ring->droppedFrames, frames, memory_order_relaxed);
        return false;
    }
    for (uint32_t frame = 0; frame < frames; frame++) {
        const uint32_t slot = (uint32_t)((written + frame) % ring->capacity);
        ring->samples[slot * 2] = left[(size_t)frame * stride];
        ring->samples[slot * 2 + 1] = right[(size_t)frame * stride];
        ring->positions[slot] = start + frame;
    }
    atomic_store_explicit(&ring->written, written + frames, memory_order_release);
    return true;
}

uint32_t AniceListeningRingRead(AniceListeningRing *ring, float *stereo,
                               uint32_t maximumFrames, uint64_t *sourceOffset) {
    if (!stereo || !sourceOffset || maximumFrames == 0) return 0;
    const uint64_t read = atomic_load_explicit(&ring->read, memory_order_relaxed);
    const uint64_t written = atomic_load_explicit(&ring->written, memory_order_acquire);
    uint32_t count = (uint32_t)(written - read);
    if (count == 0) return 0;
    if (count > maximumFrames) count = maximumFrames;
    const uint64_t start = ring->positions[read % ring->capacity];
    uint32_t copied = 0;
    for (; copied < count; copied++) {
        const uint32_t slot = (uint32_t)((read + copied) % ring->capacity);
        if (ring->positions[slot] != start + copied) break;
        stereo[copied * 2] = ring->samples[slot * 2];
        stereo[copied * 2 + 1] = ring->samples[slot * 2 + 1];
    }
    *sourceOffset = start;
    atomic_store_explicit(&ring->read, read + copied, memory_order_release);
    return copied;
}

OSStatus AniceListeningCapture(AudioObjectID device, const AudioTimeStamp *now,
                              const AudioBufferList *input, const AudioTimeStamp *inputTime,
                              AudioBufferList *output, const AudioTimeStamp *outputTime,
                              void *clientData) {
    (void)device; (void)now; (void)inputTime; (void)output; (void)outputTime;
    AniceListeningRing *ring = clientData;
    if (!ring || !input || input->mNumberBuffers == 0) return noErr;
    const AudioBuffer *first = &input->mBuffers[0];
    if (first->mDataByteSize == 0) return noErr;
    if (!first->mData) { AniceListeningRingInvalidate(ring); return noErr; }
    const float *left = first->mData;
    const float *right = left;
    uint32_t stride = first->mNumberChannels;
    if (input->mNumberBuffers == 1 && (stride == 1 || stride == 2)) {
        if (stride == 2) right++;
    } else if (input->mNumberBuffers == 2 && stride == 1) {
        const AudioBuffer *second = &input->mBuffers[1];
        if (second->mNumberChannels != 1 || !second->mData ||
            second->mDataByteSize != first->mDataByteSize) {
            AniceListeningRingInvalidate(ring); return noErr;
        }
        right = second->mData;
    } else { AniceListeningRingInvalidate(ring); return noErr; }
    if (first->mDataByteSize % (stride * sizeof(float)) != 0) {
        AniceListeningRingInvalidate(ring); return noErr;
    }
    AniceListeningRingWrite(ring, left, right, stride,
                           first->mDataByteSize / (stride * sizeof(float)));
    return noErr;
}
