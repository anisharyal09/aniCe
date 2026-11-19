// SPDX-License-Identifier: GPL-3.0-or-later
// Exposes a preallocated single-producer/single-consumer Float32 capture handoff and its Core Audio callback.
#ifndef ANICE_PRIVATE_LISTENING_RING_H
#define ANICE_PRIVATE_LISTENING_RING_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct AniceListeningRing AniceListeningRing;

AniceListeningRing * _Nullable AniceListeningRingCreate(uint32_t capacityFrames);
// Destroy only after the IOProc and every property listener have been detached.
void AniceListeningRingDestroy(AniceListeningRing * _Nullable ring);
void AniceListeningRingSetForwarding(AniceListeningRing * _Nonnull ring, bool forwarding);
void AniceListeningRingInvalidate(AniceListeningRing * _Nonnull ring);
bool AniceListeningRingInvalidated(const AniceListeningRing * _Nonnull ring);
uint64_t AniceListeningRingSourceFrames(const AniceListeningRing * _Nonnull ring);
uint64_t AniceListeningRingDroppedFrames(const AniceListeningRing * _Nonnull ring);
uint32_t AniceListeningRingQueuedFrames(const AniceListeningRing * _Nonnull ring);
void AniceListeningRingDiscard(AniceListeningRing * _Nonnull ring);
// Consumer-only: keep the newest bounded interval; producers never advance the read cursor.
uint32_t AniceListeningRingTrim(AniceListeningRing * _Nonnull ring, uint32_t maximumFrames);
// The producer owns the write cursor; overflow drops this entire incoming block.
bool AniceListeningRingWrite(AniceListeningRing * _Nonnull ring, const float * _Nullable left,
                            const float * _Nullable right, uint32_t stride, uint32_t frames);
// The consumer returns only a contiguous source interval, with interleaved stereo samples.
uint32_t AniceListeningRingRead(AniceListeningRing * _Nonnull ring, float * _Nullable stereo,
                               uint32_t maximumFrames, uint64_t * _Nullable sourceOffset);
OSStatus AniceListeningCapture(AudioObjectID device, const AudioTimeStamp * _Nonnull now,
                              const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull inputTime,
                              AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime,
                              void * _Nullable clientData);

#endif
