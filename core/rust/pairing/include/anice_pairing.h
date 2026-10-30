// SPDX-License-Identifier: GPL-3.0-or-later
// Exposes bounded pairing operations over caller-owned C ABI buffers.
#ifndef ANICE_PAIRING_H
#define ANICE_PAIRING_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Non-overlapping valid buffers; returns byte count or -1. See README for operations.
intptr_t anice_pake(uint32_t operation, const uint8_t *input, size_t input_length,
                   uint8_t *output, size_t output_capacity);
#ifdef __cplusplus
}
#endif
#endif
