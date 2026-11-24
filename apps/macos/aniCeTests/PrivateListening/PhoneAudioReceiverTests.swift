// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies reverse stream ownership, stale/duplicate fencing and output-loss retirement without audio hardware.
import Foundation
import XCTest
@testable import aniCe

private actor PhoneOutputFake: PhoneAudioOutput {
  private var prepares = 0
  private var stops = 0
  private var received = [Data]()
  private var admission = PhoneAudioOutputAdmission.accepted
  func prepare() throws { prepares += 1; admission = .accepted }
  func offer(_ pcm: Data) -> PhoneAudioOutputAdmission {
    if admission == .accepted { received.append(pcm) }
    return admission
  }
  func stop() { stops += 1 }
  var queuedFrames: Int { 0 }
  func setAdmission(_ value: PhoneAudioOutputAdmission) { admission = value }
  func counts() -> (prepares: Int, stops: Int, received: Int) {
    (prepares, stops, received.count)
  }
}

@MainActor final class PhoneAudioReceiverTests: XCTestCase {
  private let streamID = "01234567-89ab-4cde-8fab-0123456789ab"

  func testBindPreparesOnceAndDuplicateStartIsIdempotent() async throws {
    let output = PhoneOutputFake()
    let receiver = PhoneAudioReceiver(output: output)
    let descriptor = try descriptor()
    let first = try await receiver.bind(start(streamID), on: descriptor)
    let duplicate = try await receiver.bind(start(streamID), on: descriptor)
    let other = try await receiver.bind(start("01234567-89ab-4cde-8fab-0123456789ac"),
      on: descriptor)
    XCTAssertTrue(first)
    XCTAssertTrue(duplicate)
    XCTAssertFalse(other)
    let counts = await output.counts()
    XCTAssertEqual(counts.prepares, 1)
  }

  func testAudioRequiresBoundCredentialAndStream() async throws {
    let output = PhoneOutputFake()
    let receiver = PhoneAudioReceiver(output: output)
    let channel = try descriptor()
    let beforeBind = await receiver.receive(audio(streamID, 1), on: channel)
    let bound = try await receiver.bind(start(streamID), on: channel)
    let otherDescriptor = try descriptor("other")
    let otherChannel = await receiver.receive(audio(streamID, 1), on: otherDescriptor)
    let otherStream = await receiver.receive(audio("01234567-89ab-4cde-8fab-0123456789ac", 1),
      on: channel)
    let accepted = await receiver.receive(audio(streamID, 1), on: channel)
    XCTAssertEqual(beforeBind, .unbound)
    XCTAssertTrue(bound)
    XCTAssertEqual(otherChannel, .unbound)
    XCTAssertEqual(otherStream, .staleStream)
    XCTAssertEqual(accepted, .accepted)
    let counts = await output.counts()
    XCTAssertEqual(counts.received, 1)
  }

  func testDuplicateAndOlderSequenceAreRejectedWhileGapKeepsNewestAudio() async throws {
    let output = PhoneOutputFake()
    let receiver = PhoneAudioReceiver(output: output)
    let channel = try descriptor()
    let bound = try await receiver.bind(start(streamID), on: channel)
    let first = await receiver.receive(audio(streamID, 5), on: channel)
    let duplicate = await receiver.receive(audio(streamID, 5), on: channel)
    let older = await receiver.receive(audio(streamID, 4), on: channel)
    let gap = await receiver.receive(audio(streamID, 7), on: channel)
    XCTAssertTrue(bound)
    XCTAssertEqual(first, .accepted)
    XCTAssertEqual(duplicate, .duplicate)
    XCTAssertEqual(older, .duplicate)
    XCTAssertEqual(gap, .accepted)
    XCTAssertEqual(receiver.acceptedPackets, 2)
    XCTAssertEqual(receiver.gapPackets, 1)
    let counts = await output.counts()
    XCTAssertEqual(counts.received, 2)
  }

  func testOutputLossRetiresTheOperationInsteadOfAccumulatingSilence() async throws {
    let output = PhoneOutputFake()
    let receiver = PhoneAudioReceiver(output: output)
    let channel = try descriptor()
    let bound = try await receiver.bind(start(streamID), on: channel)
    await output.setAdmission(.unavailable)
    let lost = await receiver.receive(audio(streamID, 1), on: channel)
    let late = await receiver.receive(audio(streamID, 2), on: channel)
    let counts = await output.counts()
    XCTAssertTrue(bound)
    XCTAssertEqual(lost, .outputUnavailable)
    XCTAssertEqual(late, .unbound)
    XCTAssertNil(receiver.stream)
    XCTAssertEqual(receiver.unavailablePackets, 1)
    XCTAssertEqual(counts.stops, 1)
    let rebound = try await receiver.bind(start(streamID), on: channel)
    let fresh = await receiver.receive(audio(streamID, 1), on: channel)
    XCTAssertTrue(rebound)
    XCTAssertEqual(fresh, .accepted)
  }

  func testStopClearsOwnershipAndLateAudioCannotReviveIt() async throws {
    let output = PhoneOutputFake()
    let receiver = PhoneAudioReceiver(output: output)
    let channel = try descriptor()
    let bound = try await receiver.bind(start(streamID), on: channel)
    await receiver.stop()
    let late = await receiver.receive(audio(streamID, 1), on: channel)
    let counts = await output.counts()
    XCTAssertTrue(bound)
    XCTAssertNil(receiver.stream)
    XCTAssertEqual(late, .unbound)
    XCTAssertEqual(counts.stops, 1)
  }

  private func descriptor(_ instance: String = "phone-audio") throws -> ChannelDescriptor {
    let helper = SessionFixtures()
    let row = try XCTUnwrap((helper.root()["valid"] as? [[String: Any]])?.first)
    return ChannelDescriptor(instance: instance, transport: "lan",
      peer: try helper.identity(row, "initiator"))
  }

  private func start(_ id: String) -> PrivateListeningMessage {
    PrivateListeningMessage(kind: 1, fields: [.text(id), .integer(48000), .integer(2),
      .integer(16), .integer(960)])
  }

  private func audio(_ id: String, _ sequence: Int64) -> PrivateListeningMessage {
    PrivateListeningMessage(kind: 3, fields: [.text(id), .integer(sequence),
      .integer((sequence - 1) * 960), .bytes(Data(count: 3840))])
  }
}
