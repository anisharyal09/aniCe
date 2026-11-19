// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises real-time ring ownership and PCM packet conversion without opening audio devices or requesting capture permission.
import Foundation
import AVFAudio
import CoreAudio
import XCTest
@testable import aniCe

private final class ListeningRingTestPointer: @unchecked Sendable {
  let pointer: OpaquePointer
  init(_ pointer: OpaquePointer) { self.pointer = pointer }
}

final class PrivateListeningCaptureTests: XCTestCase {
  func testNativeCallbackAcceptsStereoAndRejectsUnsupportedBufferLayout() throws {
    let ring = try XCTUnwrap(AniceListeningRingCreate(4))
    defer { AniceListeningRingDestroy(ring) }
    var time = AudioTimeStamp(), inputTime = AudioTimeStamp(), outputTime = AudioTimeStamp()
    var output = AudioBufferList(mNumberBuffers: 0, mBuffers: AudioBuffer(
      mNumberChannels: 0, mDataByteSize: 0, mData: nil))
    let samples: [Float] = [0.25, -0.25, 0.5, -0.5]
    samples.withUnsafeBufferPointer { data in
      var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
        mNumberChannels: 2, mDataByteSize: 16,
        mData: UnsafeMutableRawPointer(mutating: data.baseAddress)))
      XCTAssertEqual(AniceListeningCapture(0, &time, &input, &inputTime, &output,
        &outputTime, UnsafeMutableRawPointer(ring)), noErr)
      input.mBuffers.mNumberChannels = 3
      XCTAssertEqual(AniceListeningCapture(0, &time, &input, &inputTime, &output,
        &outputTime, UnsafeMutableRawPointer(ring)), noErr)
    }
    XCTAssertTrue(AniceListeningRingInvalidated(ring))
    XCTAssertEqual(AniceListeningRingSourceFrames(ring), 2)
    var captured = [Float](repeating: 0, count: 4)
    var offset: UInt64 = 99
    captured.withUnsafeMutableBufferPointer {
      XCTAssertEqual(AniceListeningRingRead(ring, $0.baseAddress, 2, &offset), 2)
    }
    XCTAssertEqual(offset, 0)
    XCTAssertEqual(captured, samples)
  }

  func testWorkerResamples44100StereoWithoutOpeningAnAudioDevice() throws {
    let input = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
      sampleRate: 44100, channels: 2, interleaved: true))
    let output = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
      sampleRate: 48000, channels: 2, interleaved: true))
    let converter = try XCTUnwrap(AVAudioConverter(from: input, to: output))
    var samples = [Float]()
    for frame in 0..<4410 {
      let value = Float(sin(Double(frame) * 2 * .pi * 1000 / 44100)) * 0.5
      samples.append(value)
      samples.append(-value)
    }
    var converted = 0
    for _ in 0..<10 {
      let buffer = try samples.withUnsafeBufferPointer {
        try MacAudioTapEngine.convert($0, frames: 4410, using: converter)
      }
      converted += Int(buffer.frameLength)
      let raw = try XCTUnwrap(buffer.audioBufferList.pointee.mBuffers.mData)
        .assumingMemoryBound(to: Float.self)
      for frame in 0..<Int(buffer.frameLength) {
        XCTAssertTrue(raw[frame * 2].isFinite)
        XCTAssertEqual(raw[frame * 2], -raw[frame * 2 + 1], accuracy: 0.0001)
      }
    }
    XCTAssertGreaterThan(converted, 47000)
    XCTAssertLessThanOrEqual(converted, 48512)
    XCTAssertThrowsError(try samples.withUnsafeBufferPointer {
      try MacAudioTapEngine.convert($0, frames: 4411, using: converter)
    })
  }

  func testConcurrentProducerConsumerNeverReadsOverwrittenSlots() throws {
    let ring = try XCTUnwrap(AniceListeningRingCreate(64))
    defer { AniceListeningRingDestroy(ring) }
    let reference = ListeningRingTestPointer(ring)
    let finished = expectation(description: "producer finished")
    DispatchQueue.global().async {
      for frame in 0..<10000 {
        var value = Float(frame)
        withUnsafePointer(to: &value) {
          _ = AniceListeningRingWrite(reference.pointer, $0, $0, 1, 1)
        }
      }
      finished.fulfill()
    }
    var samples = [Float](repeating: 0, count: 32)
    var last: UInt64?
    for _ in 0..<20000 {
      var offset: UInt64 = 0
      let count = samples.withUnsafeMutableBufferPointer {
        AniceListeningRingRead(ring, $0.baseAddress, 16, &offset)
      }
      if count > 0 {
        if let last { XCTAssertGreaterThan(offset, last) }
        for frame in 0..<Int(count) {
          XCTAssertEqual(samples[frame * 2], Float(offset + UInt64(frame)))
          XCTAssertEqual(samples[frame * 2 + 1], Float(offset + UInt64(frame)))
        }
        last = offset + UInt64(count) - 1
      }
      if AniceListeningRingSourceFrames(ring) == 10000 && AniceListeningRingQueuedFrames(ring) == 0 { break }
    }
    wait(for: [finished], timeout: 5)
    XCTAssertEqual(AniceListeningRingSourceFrames(ring), 10000)
  }

  func testRingRejectsInvalidCapacityAndPreservesUnreadFramesOnOverflow() throws {
    XCTAssertNil(AniceListeningRingCreate(0))
    XCTAssertNil(AniceListeningRingCreate(38401))
    let ring = try XCTUnwrap(AniceListeningRingCreate(4))
    defer { AniceListeningRingDestroy(ring) }
    let first: [Float] = [1, -1, 2, -2, 3, -3, 4, -4]
    let incoming: [Float] = [9, -9]
    XCTAssertTrue(first.withUnsafeBufferPointer {
      AniceListeningRingWrite(ring, $0.baseAddress, $0.baseAddress! + 1, 2, 4)
    })
    XCTAssertFalse(incoming.withUnsafeBufferPointer {
      AniceListeningRingWrite(ring, $0.baseAddress, $0.baseAddress! + 1, 2, 1)
    })
    XCTAssertEqual(AniceListeningRingQueuedFrames(ring), 4)
    XCTAssertEqual(AniceListeningRingSourceFrames(ring), 5)
    XCTAssertEqual(AniceListeningRingDroppedFrames(ring), 1)
    var copy = [Float](repeating: 0, count: 8)
    var offset: UInt64 = 99
    let read = copy.withUnsafeMutableBufferPointer {
      AniceListeningRingRead(ring, $0.baseAddress, 4, &offset)
    }
    XCTAssertEqual(read, 4)
    XCTAssertEqual(offset, 0)
    XCTAssertEqual(copy, first)
    XCTAssertEqual(AniceListeningRingQueuedFrames(ring), 0)
  }

  func testRingReturnsContiguousIntervalsAcrossOverflowAndWrap() throws {
    let ring = try XCTUnwrap(AniceListeningRingCreate(4))
    defer { AniceListeningRingDestroy(ring) }
    let input: [Float] = [10, 20, 30]
    input.withUnsafeBufferPointer {
      XCTAssertTrue(AniceListeningRingWrite(ring, $0.baseAddress, $0.baseAddress, 1, 3))
      XCTAssertFalse(AniceListeningRingWrite(ring, $0.baseAddress, $0.baseAddress, 1, 3))
    }
    var output = [Float](repeating: 0, count: 8)
    var offset: UInt64 = 99
    output.withUnsafeMutableBufferPointer {
      XCTAssertEqual(AniceListeningRingRead(ring, $0.baseAddress, 2, &offset), 2)
    }
    input.withUnsafeBufferPointer {
      XCTAssertTrue(AniceListeningRingWrite(ring, $0.baseAddress, $0.baseAddress, 1, 3))
    }
    output.withUnsafeMutableBufferPointer {
      XCTAssertEqual(AniceListeningRingRead(ring, $0.baseAddress, 4, &offset), 1)
    }
    XCTAssertEqual(offset, 2)
    XCTAssertEqual(Array(output.prefix(2)), [30, 30])
    output.withUnsafeMutableBufferPointer {
      XCTAssertEqual(AniceListeningRingRead(ring, $0.baseAddress, 4, &offset), 3)
    }
    XCTAssertEqual(offset, 6)
    XCTAssertEqual(Array(output.prefix(6)), [10, 10, 20, 20, 30, 30])
  }

  func testDiscardModeKeepsTheSourceTimelineAdvancing() throws {
    let ring = try XCTUnwrap(AniceListeningRingCreate(4))
    defer { AniceListeningRingDestroy(ring) }
    let input: [Float] = [1, 2]
    AniceListeningRingSetForwarding(ring, false)
    input.withUnsafeBufferPointer {
      XCTAssertTrue(AniceListeningRingWrite(ring, $0.baseAddress, $0.baseAddress, 1, 2))
    }
    XCTAssertEqual(AniceListeningRingSourceFrames(ring), 2)
    XCTAssertEqual(AniceListeningRingQueuedFrames(ring), 0)
    AniceListeningRingSetForwarding(ring, true)
    input.withUnsafeBufferPointer {
      XCTAssertTrue(AniceListeningRingWrite(ring, $0.baseAddress, $0.baseAddress, 1, 2))
    }
    var output = [Float](repeating: 0, count: 4)
    var offset: UInt64 = 0
    output.withUnsafeMutableBufferPointer {
      XCTAssertEqual(AniceListeningRingRead(ring, $0.baseAddress, 2, &offset), 2)
    }
    XCTAssertEqual(offset, 2)
    XCTAssertFalse(AniceListeningRingInvalidated(ring))
    AniceListeningRingInvalidate(ring)
    XCTAssertTrue(AniceListeningRingInvalidated(ring))
    AniceListeningRingDiscard(ring)
    XCTAssertEqual(AniceListeningRingQueuedFrames(ring), 0)
  }

  func testPCMConversionClipsAndHandlesNonfiniteSamples() {
    let values: [Float] = [.nan, .infinity, -.infinity, 2, -2, 1, -1, 0, 0.5, -0.5]
    XCTAssertEqual(values.map(PrivateListeningPacketizer.pcm16),
      [0, .max, .min, .max, .min, .max, .min, 0, 16384, -16384])
  }

  func testPacketizerJoinsBlocksAndPreservesOwnedPCM() throws {
    var packetizer = PrivateListeningPacketizer()
    let left = [Float](repeating: 0.5, count: 480 * 2)
    XCTAssertTrue(try left.withUnsafeBufferPointer { try packetizer.append($0, sourceOffset: 0) }.isEmpty)
    let first = try left.withUnsafeBufferPointer { try packetizer.append($0, sourceOffset: 480) }
    XCTAssertEqual(first.count, 1)
    XCTAssertEqual(first[0].sequence, 1)
    XCTAssertEqual(first[0].pcm.count, 3840)
    XCTAssertEqual(Array(first[0].pcm.prefix(4)), [0, 64, 0, 64])
    let next = [Float](repeating: -0.5, count: 960 * 2)
    let second = try next.withUnsafeBufferPointer { try packetizer.append($0, sourceOffset: 960) }
    XCTAssertEqual(second[0].sequence, 2)
    XCTAssertEqual(Array(second[0].pcm.prefix(4)), [0, 192, 0, 192])
    XCTAssertEqual(Array(first[0].pcm.prefix(4)), [0, 64, 0, 64])
    XCTAssertEqual(packetizer.completeSourceFrames, 1920)
  }

  func testPacketizerDropsIncompleteTimelineSlotsInsteadOfPaddingGaps() throws {
    var packetizer = PrivateListeningPacketizer()
    let prefix = [Float](repeating: 1, count: 200 * 2)
    _ = try prefix.withUnsafeBufferPointer { try packetizer.append($0, sourceOffset: 0) }
    let partial = [Float](repeating: -1, count: 760 * 2)
    XCTAssertTrue(try partial.withUnsafeBufferPointer { try packetizer.append($0, sourceOffset: 1160) }.isEmpty)
    let current = [Float](repeating: 0, count: 960 * 2)
    let packets = try current.withUnsafeBufferPointer { try packetizer.append($0, sourceOffset: 1920) }
    XCTAssertEqual(packets.map(\.sequence), [3])
    XCTAssertEqual(packets[0].pcm, Data(count: 3840))
    XCTAssertThrowsError(try current.withUnsafeBufferPointer { try packetizer.append($0, sourceOffset: -1) })
    XCTAssertThrowsError(try current.withUnsafeBufferPointer { try packetizer.append($0, sourceOffset: Int64.max) })
  }
}
