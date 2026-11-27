// SPDX-License-Identifier: GPL-3.0-or-later
// Clips converted stereo Float32 samples into fixed PCM16 packets while preserving source timeline gaps.
import Foundation

struct AudioSharingCapturedPacket: Sendable {
  let sequence: Int64
  let pcm: Data
}

struct AudioSharingPacketizer {
  private var pcm = Data(count: AudioSharingMessage.pcmBytes)
  private var filledFrames = 0
  private var nextFrame: Int64 = 0
  private(set) var completeSourceFrames: Int64 = 0

  mutating func reset(nextFrame: Int64 = 0) {
    filledFrames = 0
    self.nextFrame = nextFrame
    completeSourceFrames = nextFrame / 960 * 960
  }

  mutating func append(_ stereo: UnsafeBufferPointer<Float>, sourceOffset: Int64) throws
    -> [AudioSharingCapturedPacket] {
    guard sourceOffset >= 0, stereo.count.isMultiple(of: 2),
      stereo.count / 2 <= Int64.max - sourceOffset else { throw AudioSharingWireError.malformed }
    if sourceOffset != nextFrame {
      filledFrames = 0
      nextFrame = sourceOffset
    }
    var packets = [AudioSharingCapturedPacket]()
    for frame in 0..<(stereo.count / 2) {
      // After a discontinuity, skip the incomplete slot instead of disguising it as continuous audio.
      if filledFrames == 0, nextFrame % 960 != 0 {
        nextFrame += 1
        continue
      }
      let position = filledFrames * 4
      for channel in 0..<2 {
        let value = Self.pcm16(stereo[frame * 2 + channel])
        pcm[position + channel * 2] = UInt8(truncatingIfNeeded: value)
        pcm[position + channel * 2 + 1] = UInt8(truncatingIfNeeded: UInt16(bitPattern: value) >> 8)
      }
      filledFrames += 1
      nextFrame += 1
      if filledFrames == 960 {
        let sequence = nextFrame / 960
        guard (1...AudioSharingMessage.maximumSequence).contains(sequence) else {
          throw AudioSharingWireError.malformed
        }
        packets.append(AudioSharingCapturedPacket(sequence: sequence, pcm: pcm))
        completeSourceFrames = nextFrame
        filledFrames = 0
      }
    }
    return packets
  }

  static func pcm16(_ sample: Float) -> Int16 {
    if sample.isNaN { return 0 }
    if sample >= 1 { return .max }
    if sample <= -1 { return .min }
    return Int16((sample * 32768).rounded().clamped(to: -32768...32767))
  }
}

private extension Float {
  func clamped(to range: ClosedRange<Float>) -> Float { min(range.upperBound, max(range.lowerBound, self)) }
}
