// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises adapter parsing, source eligibility and scheduling without invoking MediaRemote.
import Foundation
import XCTest
@testable import aniCe

final class PlaybackAdapterTests: XCTestCase {
  func testRequestsAndSplitFramingRejectMalformedOrUnboundCommands() {
    let revision = "00000000-0000-0000-0000-000000000001"
    let positive = ["source-auto", "source 10 dGVzdC5wbGF5ZXI=", "validate \(revision) 10 \(revision)",
      "play 10 \(revision) toggle", "play 10 \(revision) next", "play 10 \(revision) previous",
      "play 10 \(revision) seek 0", "play 10 \(revision) seek 604800"]
    let negative = ["toggle", "next", "previous", "seek 1", "play 0 \(revision) toggle",
      "play 10 invalid toggle", "play 10 \(revision) seek nan", "play 10 \(revision) seek inf",
      "play 10 \(revision) seek -1", "play 10 \(revision) seek 604801",
      "source 10 !!!", "source 10 ", "source -1 dGVzdA==", "queue-stop", "",
      "play 2147483648 \(revision) toggle", String(repeating: "x", count: 2049)]
    for message in positive { XCTAssertNotNil(PlaybackRequest(message: message), message) }
    for message in negative { XCTAssertNil(PlaybackRequest(message: message), message) }
    var framer = PlaybackCommandFramer()
    let framed = Data((String(repeating: "x", count: 2049) + "\n" + positive[3] + "\n").utf8)
    var replies = [PlaybackRequest?]()
    for byte in framed { replies += framer.append(Data([byte])) }
    XCTAssertEqual(replies.count, 2)
    XCTAssertNil(replies[0])
    XCTAssertNotNil(replies[1])
    let malformed = framer.append(Data([0xff, 10]))
    XCTAssertEqual(malformed.count, 1)
    XCTAssertNil(malformed[0])
    XCTAssertNil(PlaybackRequest(message: "sample"))
    XCTAssertEqual(PlaybackRequest(message: "play 10 \(revision) sample")?.command, .sample)
    XCTAssertNil(PlaybackRequest(message: "play 0 \(revision) sample"))
    let tagged = "request \(revision) play 10 \(revision) toggle"
    XCTAssertEqual(PlaybackRequest(message: tagged)?.message, tagged)
    XCTAssertNil(PlaybackRequest(message: "request \(revision) request \(revision) source-auto"))
    XCTAssertEqual(PlaybackRequest(message: "refresh")?.command, .refresh)
  }

  func testSourceRankingAndNativeIdentifiersKeepManualSelectionBound() {
    let music = PlaybackSource(pid: 10, bundleIdentifier: "com.apple.Music", isMusicApp: true, isPlaying: false, hasTrack: true)
    let browser = PlaybackSource(pid: 20, bundleIdentifier: "browser", isMusicApp: false, isPlaying: true, hasTrack: true)
    func preferred(_ sources: [PlaybackSource], previous: Int32?, system: Int32?, selection: PlaybackSource.Selection? = nil) -> PlaybackSource? {
      PlaybackSource.preferred(in: sources, previousPID: previous, systemPID: system, selection: selection, includeOtherPlayers: true)
    }
    XCTAssertEqual(preferred([music, browser], previous: 10, system: 10), browser)
    XCTAssertEqual(preferred([music, browser], previous: 20, system: 10, selection: music.selection), music)
    let activeMusic = PlaybackSource(pid: 10, bundleIdentifier: "com.apple.Music", isMusicApp: true, isPlaying: true, hasTrack: true)
    XCTAssertEqual(preferred([activeMusic, browser], previous: 20, system: 10), browser)
    XCTAssertEqual(preferred([browser, activeMusic], previous: nil, system: 10), activeMusic)
    XCTAssertEqual(preferred([browser, activeMusic], previous: nil, system: nil), activeMusic)
    XCTAssertNil(preferred([browser], previous: 10, system: 20, selection: music.selection))
    XCTAssertNil(preferred([], previous: 10, system: 10))
    for pid: Any in [true, 1.5, 0, NSNumber(value: Int64.max)] {
      XCTAssertNil(PlaybackSource.decodePID(pid))
    }
    XCTAssertTrue(PlaybackSource.hasRecording(["itemIdentifier": "track-1"]))
    XCTAssertTrue(PlaybackSource.hasRecording(["kMRMediaRemoteNowPlayingInfoTitle": "Track"]))
    XCTAssertFalse(PlaybackSource.hasRecording([:]))
    XCTAssertFalse(PlaybackSource.hasRecording(["itemIdentifier": "", "kMRMediaRemoteNowPlayingInfoTitle": " "]))
    XCTAssertNil(PlaybackSource.recordingIdentifier(["itemIdentifier": "bad\0identifier"]))
  }

  func testBlockedCatalogScanDoesNotDelayValidationOrCommandConfirmation() {
    let work = PlaybackDispatch()
    let started = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0)
    let commanded = DispatchSemaphore(value:0), selected = DispatchSemaphore(value:0)
    work.observation.async { started.signal(); release.wait() }
    defer { release.signal() }
    XCTAssertEqual(started.wait(timeout:.now()+5), .success)
    work.submit(.source(nil)) { selected.signal() }
    work.submit(.validate(UUID(),PlaybackContext(pid:10,revision:UUID()))) { commanded.signal() }
    XCTAssertEqual(commanded.wait(timeout:.now()+5), .success, "Blocked scan delayed validation")
    XCTAssertEqual(selected.wait(timeout:.now()+0.02), .timedOut, "Selection bypassed its scan")
    release.signal()
    XCTAssertEqual(selected.wait(timeout:.now()+5), .success)
    let confirmationWork = PlaybackDispatch()
    let scanStarted = DispatchSemaphore(value:0), finishScan = DispatchSemaphore(value:0)
    let confirmation = DispatchSemaphore(value:0)
    confirmationWork.observation.async { scanStarted.signal(); finishScan.wait() }
    defer { finishScan.signal() }
    XCTAssertEqual(scanStarted.wait(timeout:.now()+5), .success)
    confirmationWork.submit(.sample) { confirmation.signal() }
    let confirmationReady = confirmation.wait(timeout:.now()+5)
    finishScan.signal()
    XCTAssertEqual(confirmationReady, .success, "Catalog scan delayed command confirmation")
  }

  func testBlockedSampleDoesNotDelayTheNextValidationOrPlaybackAction() {
    let sampleWork = PlaybackDispatch()
    let sampling = DispatchSemaphore(value:0), finishSample = DispatchSemaphore(value:0)
    let validation = DispatchSemaphore(value:0), toggle = DispatchSemaphore(value:0)
    sampleWork.submit(.sample) { sampling.signal(); finishSample.wait() }
    defer { finishSample.signal() }
    XCTAssertEqual(sampling.wait(timeout:.now()+5), .success)
    sampleWork.submit(.validate(UUID(),PlaybackContext(pid:10,revision:UUID()))) { validation.signal() }
    sampleWork.submit(.toggle) { toggle.signal() }
    let validationReady = validation.wait(timeout:.now()+5)
    let toggleReady = toggle.wait(timeout:.now()+5)
    finishSample.signal()
    XCTAssertEqual(validationReady, .success, "Blocked sample delayed validation")
    XCTAssertEqual(toggleReady, .success, "Blocked sample delayed playback")
  }
}
