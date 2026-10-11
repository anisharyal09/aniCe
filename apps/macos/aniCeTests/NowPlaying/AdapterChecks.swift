// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises source eligibility and adversarial native pipe requests without invoking MediaRemote.
import Foundation

@main enum AdapterChecks {
  static func main() {
    let revision = "00000000-0000-0000-0000-000000000001"
    let positive = ["source-auto", "source 10 dGVzdC5wbGF5ZXI=", "validate \(revision) 10 \(revision)",
      "play 10 \(revision) toggle", "play 10 \(revision) next", "play 10 \(revision) previous",
      "play 10 \(revision) seek 0", "play 10 \(revision) seek 604800"]
    let negative = ["toggle", "next", "previous", "seek 1", "play 0 \(revision) toggle",
      "play 10 invalid toggle", "play 10 \(revision) seek nan", "play 10 \(revision) seek inf",
      "play 10 \(revision) seek -1", "play 10 \(revision) seek 604801",
      "source 10 !!!", "source 10 ", "source -1 dGVzdA==", "queue-stop", "",
      "play 2147483648 \(revision) toggle", String(repeating: "x", count: 2049)]
    precondition(positive.count >= 8 && negative.count >= 17)
    for message in positive { precondition(PlaybackRequest(message: message) != nil, message) }
    for message in negative { precondition(PlaybackRequest(message: message) == nil, message) }
    var framer = PlaybackCommandFramer()
    let framed = Data((String(repeating: "x", count: 2049) + "\n" + positive[3] + "\n").utf8)
    var replies = [PlaybackRequest?]()
    for byte in framed { replies += framer.append(Data([byte])) }
    precondition(replies.count == 2 && replies[0] == nil && replies[1] != nil)
    precondition(framer.append(Data([0xff, 10])).first! == nil)
    let music = PlaybackSource(pid: 10, bundleIdentifier: "com.apple.Music", isMusicApp: true, isPlaying: false, hasTrack: true)
    let browser = PlaybackSource(pid: 20, bundleIdentifier: "browser", isMusicApp: false, isPlaying: true, hasTrack: true)
    func preferred(_ sources: [PlaybackSource], previous: Int32?, system: Int32?, selection: PlaybackSource.Selection? = nil) -> PlaybackSource? {
      PlaybackSource.preferred(in: sources, previousPID: previous, systemPID: system, selection: selection, includeOtherPlayers: true)
    }
    precondition(preferred([music, browser], previous: 10, system: 10) == browser)
    precondition(preferred([music, browser], previous: 20, system: 10, selection: music.selection) == music)
    let activeMusic = PlaybackSource(pid: 10, bundleIdentifier: "com.apple.Music", isMusicApp: true, isPlaying: true, hasTrack: true)
    precondition(preferred([activeMusic, browser], previous: 20, system: 10) == browser)
    precondition(preferred([browser, activeMusic], previous: nil, system: 10) == activeMusic)
    precondition(preferred([browser, activeMusic], previous: nil, system: nil) == activeMusic)
    precondition(preferred([browser], previous: 10, system: 20, selection: music.selection) == nil)
    precondition(preferred([], previous: 10, system: 10) == nil)
    precondition(PlaybackSource.decodePID(true) == nil)
    precondition(PlaybackSource.decodePID(1.5) == nil)
    precondition(PlaybackSource.decodePID(0) == nil)
    precondition(PlaybackSource.decodePID(NSNumber(value: Int64.max)) == nil)
    precondition(PlaybackSource.hasRecording(["itemIdentifier":"track-1"]))
    precondition(PlaybackSource.hasRecording(["kMRMediaRemoteNowPlayingInfoTitle":"Track"]))
    precondition(!PlaybackSource.hasRecording([:]))
    precondition(!PlaybackSource.hasRecording(["itemIdentifier":"", "kMRMediaRemoteNowPlayingInfoTitle":" "]))
    precondition(PlaybackSource.recordingIdentifier(["itemIdentifier":"bad\0identifier"]) == nil)
    precondition(PlaybackRequest(message:"sample") == nil)
    precondition(PlaybackRequest(message:"play 10 \(revision) sample")?.command == .sample)
    precondition(PlaybackRequest(message:"play 0 \(revision) sample") == nil)
    let tagged="request \(revision) play 10 \(revision) toggle"
    precondition(PlaybackRequest(message:tagged)?.message == tagged)
    precondition(PlaybackRequest(message:"request \(revision) request \(revision) source-auto") == nil)
    precondition(PlaybackRequest(message:"refresh")?.command == .refresh)
    let work = PlaybackDispatch()
    let started = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0)
    let commanded = DispatchSemaphore(value:0), selected = DispatchSemaphore(value:0)
    work.observation.async { started.signal(); release.wait() }
    precondition(started.wait(timeout:.now()+1) == .success)
    work.submit(.source(nil)) { selected.signal() }
    work.submit(.validate(UUID(),PlaybackContext(pid:10,revision:UUID()))) { commanded.signal() }
    precondition(commanded.wait(timeout:.now()+1) == .success, "Blocked scan delayed validation")
    precondition(selected.wait(timeout:.now()+0.02) == .timedOut, "Selection bypassed its scan")
    release.signal()
    precondition(selected.wait(timeout:.now()+1) == .success)
    print("PASS: 8 positive/17 negative requests, split/oversized/invalid UTF-8 framing, source ranking/manual gaps, PID bounds, read-only samples and scan/command isolation")
  }
}
