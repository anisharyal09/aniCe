// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies native session security and presentation readiness against fixtures and adversarial transitions.
import CryptoKit
import AppKit
import Foundation
import XCTest
import SwiftUI
import Observation

@testable import aniCe

final class MediaTests: XCTestCase {
  @MainActor func testArtworkCompletionAndSeekPreviewStayBoundToRecording() async throws {
    let model=MacPlaybackModel(requestSink:{ _ in true })
    let pid=ProcessInfo.processInfo.processIdentifier, recording=UUID().uuidString
    var row: [String:Any] = ["pid":pid,"playbackRevision":recording,
      "sources":[["pid":pid,"bundleIdentifier":Bundle.main.bundleIdentifier!,"isMusicApp":false,"isPlaying":false,"hasTrack":true]],
      "kMRMediaRemoteNowPlayingInfoTitle":"Track","kMRMediaRemoteNowPlayingInfoDuration":100,
      "kMRMediaRemoteNowPlayingInfoElapsedTime":10,"isPlaying":false,"canSendCommandsDirectly":true,"canToggle":true,"canSeek":true]
    let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:16,pixelsHigh:16,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
    row["artworkBase64"]=try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).base64EncodedString()
    model.read(try JSONSerialization.data(withJSONObject:row))
    for _ in 0..<100 where model.artwork == nil { try await Task.sleep(for:.milliseconds(10)) }
    XCTAssertNotNil(model.artwork);XCTAssertNotNil(model.artworkImage)
    let retained=model.artwork
    row.removeValue(forKey:"artworkBase64");row["artworkUnchanged"]=true
    model.read(try JSONSerialization.data(withJSONObject:row))
    XCTAssertEqual(model.artwork,retained)
    let source=model.playback.source, revision=model.playback.revision
    model.command(source:source,revision:revision,action:4,value:60000)
    XCTAssertEqual(model.displayedPlayback.position,60000)
    model.finish(0)
    XCTAssertEqual(model.displayedPlayback.position,60000)
    model.read(try JSONSerialization.data(withJSONObject:row))
    XCTAssertEqual(model.displayedPlayback.position,60000)
    row["kMRMediaRemoteNowPlayingInfoElapsedTime"]=60
    model.read(try JSONSerialization.data(withJSONObject:row))
    XCTAssertEqual(model.displayedPlayback,model.playback)
    row["observationStartedAt"]=3.0
    model.read(try JSONSerialization.data(withJSONObject:row))
    row["observationStartedAt"]=2.0;row["kMRMediaRemoteNowPlayingInfoElapsedTime"]=10
    model.read(try JSONSerialization.data(withJSONObject:row))
    XCTAssertEqual(model.playback.position,60000,"An older scan cannot replace a newer confirmation")
    row["observationStartedAt"]=4.0;row["kMRMediaRemoteNowPlayingInfoElapsedTime"]=60
    model.presented("main",true);model.presented("main",false)
    XCTAssertEqual(model.playback.source,source)
    model.presented("main",true)
    XCTAssertEqual(model.playback.revision,revision)
    row["playbackRevision"]=UUID().uuidString
    model.read(try JSONSerialization.data(withJSONObject:row))
    XCTAssertEqual(model.artwork,retained,"The helper explicitly confirmed identical image bytes for the new recording")
    row.removeValue(forKey:"artworkUnchanged")
    model.read(try JSONSerialization.data(withJSONObject:row))
    XCTAssertNil(model.artwork,"Absent artwork must remove the previous cover")
    model.read(Data("{\"error\":\"test cleanup\"}".utf8))
  }
  func testPipeRetainsReplyOrderAcrossBatchedAndSplitCallbacks() {
    let pipe=PlaybackPipe()
    XCTAssertTrue(pipe.append(Data("metadata\ncapab".utf8)))
    XCTAssertTrue(pipe.scheduleDrain())
    XCTAssertTrue(pipe.append(Data("ilities\nnext metadata\npartial".utf8)))
    XCTAssertFalse(pipe.scheduleDrain())
    XCTAssertEqual(pipe.take().map { String(decoding:$0,as:UTF8.self) },["metadata","capabilities","next metadata"])
    XCTAssertTrue(pipe.take().isEmpty)
    XCTAssertTrue(pipe.append(Data(" reply\n".utf8)))
    XCTAssertTrue(pipe.scheduleDrain())
    XCTAssertEqual(pipe.take(),[Data("partial reply".utf8)])
  }
  func testPipeBoundsRepliesWaitingForMainActorDelivery() {
    let pipe=PlaybackPipe(),limit=17*1024*1024
    XCTAssertTrue(pipe.append(Data(repeating:97,count:limit-1)+Data([10])))
    XCTAssertFalse(pipe.append(Data([97,10])))
    XCTAssertEqual(pipe.take().map(\.count),[limit-1])
    XCTAssertTrue(pipe.append(Data([97,10])))
    XCTAssertEqual(pipe.take(),[Data([97])])
  }
  @MainActor func testPipeDrainStopsWhenAReplyRetiresTheHelperGeneration() {
    let bridge=MediaProcessBridge(),pipe=PlaybackPipe(),generation=bridge.generation
    var received: [Data]=[]
    bridge.received = { [weak bridge] bytes in received.append(bytes);bridge?.stop() }
    XCTAssertTrue(pipe.append(Data("first\nstale capabilities\n".utf8)))
    bridge.drain(pipe,generation:generation)
    XCTAssertEqual(received,[Data("first".utf8)])
    XCTAssertTrue(pipe.append(Data("old callback\n".utf8)))
    bridge.drain(pipe,generation:generation)
    XCTAssertEqual(received.count,1)
  }
  @MainActor func testReferencePlayerLayoutRendersBothThemesAndUnavailableStatesWithoutCommands() throws {
    var requests = 0
    let preferences = try XCTUnwrap(UserDefaults(suiteName: "anice.visual." + UUID().uuidString))
    let model = MacPlaybackModel(preferences: preferences, requestSink: { _ in requests += 1; return true })
    let pid = ProcessInfo.processInfo.processIdentifier
    let sample: [String: Any] = ["pid": pid, "playbackRevision": UUID().uuidString,
      "sourceIsAutomatic": true,
      "sources": [["pid": pid, "bundleIdentifier": Bundle.main.bundleIdentifier!, "displayName": "Fixture player",
        "isMusicApp": false, "isPlaying": true, "hasTrack": true]],
      "kMRMediaRemoteNowPlayingInfoTitle": "A Walk Home — a long title that must wrap at companion width",
      "kMRMediaRemoteNowPlayingInfoArtist": "The Evening Hours",
      "kMRMediaRemoteNowPlayingInfoDuration": 236,
      "kMRMediaRemoteNowPlayingInfoElapsedTime": 92, "kMRMediaRemoteNowPlayingInfoPlaybackRate": 1,
      "isPlaying": true, "canSendCommandsDirectly": true, "canToggle": true, "canSeek": true]
    model.read(try JSONSerialization.data(withJSONObject: sample))
    XCTAssertFalse(model.playback.source.isEmpty)
    let folder = URL(fileURLWithPath: "/private/tmp/aniCe-reference-renders", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var renders = 0
    for scheme: ColorScheme in [.light, .dark] {
      for compact in [true, false] {
        let width: CGFloat = compact ? 314 : 360
        let view = MediaView(model: model, compact: compact, visible: false)
          .frame(width: width).fixedSize(horizontal: false, vertical: true)
          .environment(\.colorScheme, scheme)
          .background(AniCePalette.surface(scheme))
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        XCTAssertEqual(size.width, width, accuracy: 1)
        XCTAssertGreaterThan(size.height, 140)
        XCTAssertLessThan(size.height, 600)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(bytes.count, 1000)
        try bytes.write(to: folder.appendingPathComponent("music-\(compact ? "companion" : "overview")-\(scheme == .light ? "light" : "dark").png"))
        renders += 1
      }
    }
    XCTAssertEqual(renders, 4)
    model.read(Data("{\"error\":\"fixture unavailable\"}".utf8))
    XCTAssertTrue(model.playback.source.isEmpty)
    let unavailable = NSHostingView(rootView: MediaView(model: model, visible: false).frame(width: 314).fixedSize(horizontal: false, vertical: true))
    XCTAssertGreaterThan(unavailable.fittingSize.height, 40)
    XCTAssertLessThan(unavailable.fittingSize.height, 600)
    XCTAssertEqual(requests, 0, "Rendering presentation must not issue commands or launch observation")
  }

  func testProgressScheduleBoundsAndStopsWhenInactive() {
    let start=Date(timeIntervalSince1970:100)
    let active=Array(MediaProgressSchedule(active:true).entries(from:start,mode:.normal).prefix(5))
    XCTAssertEqual(active.map { $0.timeIntervalSince(start) },[0,0.25,0.5,0.75,1])
    for mode: TimelineScheduleMode in [.normal,.lowFrequency] {
      XCTAssertEqual(Array(MediaProgressSchedule(active:false).entries(from:start,mode:mode).prefix(5)),[start])
    }
  }
  func testIndependentFixturesCanonicalEncodingAndNegativeInventory() throws {
    let helper=SessionFixtures(), root=try helper.root("media-vectors")
    let valid=try XCTUnwrap(root["valid"] as? [[String:Any]]), invalid=try XCTUnwrap(root["invalid"] as? [[String:Any]])
    XCTAssertGreaterThanOrEqual(valid.count,12); XCTAssertGreaterThanOrEqual(invalid.count,28)
    for row in valid {
      let bytes=try helper.b(row,"bytes"), message=try XCTUnwrap(MediaMessage.decode(bytes))
      XCTAssertEqual(message.kind,(row["kind"] as? NSNumber)?.int64Value)
      XCTAssertEqual(try message.encode(),bytes)
    }
    for row in invalid { XCTAssertThrowsError(try MediaMessage.decode(helper.b(row,"bytes")),row["name"] as? String ?? "") }
  }
  func testCompactPauseDeadlineDoesNotExtendAndUnavailableClearsImmediately() {
    var policy=MediaPresence()
    XCTAssertTrue(policy.update(genuine:true,state:1,now:0));XCTAssertNil(policy.deadline)
    XCTAssertTrue(policy.update(genuine:true,state:2,now:10));XCTAssertEqual(policy.deadline,100)
    XCTAssertTrue(policy.update(genuine:true,state:2,now:99));XCTAssertEqual(policy.deadline,100)
    XCTAssertFalse(policy.update(genuine:true,state:2,now:100))
    XCTAssertTrue(policy.update(genuine:true,state:1,now:101));XCTAssertNil(policy.deadline)
    XCTAssertTrue(policy.update(genuine:true,state:2,now:102));XCTAssertEqual(policy.deadline,192)
    XCTAssertFalse(policy.update(genuine:true,state:3,now:103));XCTAssertNil(policy.deadline)
    XCTAssertFalse(policy.update(genuine:false,state:1,now:104))
  }
  func testLocalProgressBoundsAndMissingDuration() {
    var media=MediaPlayback();media.position=10000;media.duration=200000;media.rate=1000;media.state=1;media.sampledAt=0
    XCTAssertEqual(media.elapsed(at:2),12);XCTAssertEqual(media.elapsed(at:999999),200)
    media.state=2;XCTAssertEqual(media.elapsed(at:999999),10)
    media.duration = -1;media.state=1;XCTAssertEqual(media.elapsed(at:999999),1000009)
    media.position = -1;XCTAssertEqual(media.elapsed(at:1),0)
  }
  @MainActor func testRetiredSubscriptionDuplicateStaleCommandsAndLegacyData() async throws {
    let model=MacPlaybackModel(requestSink:{ _ in true }); var outgoing:[MediaMessage]=[]
    model.channel("ble",token:"a") { if let message=try MediaMessage.decode($0) { outgoing.append(message) } else { XCTAssertNotNil(try PlayerVolumeMessage.decode($0)) } }
    let sub=UUID().uuidString, source=UUID().uuidString, revision=UUID().uuidString
    XCTAssertFalse(model.receive(Data("aniCe connection check".utf8),channel:"ble"))
    XCTAssertTrue(model.receive(try MediaMessage(kind:2,fields:[.text(sub)]).encode(),channel:"ble"))
    let command=try MediaMessage(kind:6,fields:[.text(sub),.integer(1),.text(source),.text(revision),.integer(1),.integer(0)]).encode()
    XCTAssertTrue(model.receive(command,channel:"ble"));XCTAssertTrue(model.receive(command,channel:"ble"))
    try await Task.sleep(for:.milliseconds(150))
    XCTAssertEqual(outgoing.filter { $0.kind==7 }.map { $0.number(2) },[1,1])
    XCTAssertTrue(outgoing.contains { $0.kind==3 });XCTAssertTrue(outgoing.contains { $0.kind==5 });XCTAssertTrue(model.phoneSubscribed)
    model.channel("ble",token:nil) { _ in XCTFail("Retired endpoint sent") }
    let count=outgoing.count;XCTAssertTrue(model.receive(command,channel:"ble"))
    try await Task.sleep(for:.milliseconds(100));XCTAssertEqual(outgoing.count,count)
    XCTAssertTrue(model.playback.source.isEmpty);XCTAssertTrue(model.sources.isEmpty);XCTAssertFalse(model.phoneSubscribed)
  }
  @MainActor func testLocalDisplayDefaultsOffPersistsAndDoesNotRetirePhoneSubscription() throws {
    let suite="aniCe.media-display-tests.\(UUID().uuidString)"
    let preferences=try XCTUnwrap(UserDefaults(suiteName:suite))
    defer { preferences.removePersistentDomain(forName:suite) }
    let model=MacPlaybackModel(preferences:preferences,requestSink:{ _ in true })
    XCTAssertFalse(model.showOnMac)
    model.presented("companion",true);XCTAssertFalse(model.companionVisible)
    model.channel("ble",token:"display-test") { _ in }
    let sub=UUID().uuidString
    _ = model.receive(try MediaMessage(kind:2,fields:[.text(sub)]).encode(),channel:"ble")
    XCTAssertTrue(model.phoneSubscribed)
    let pid=ProcessInfo.processInfo.processIdentifier
    model.read(try JSONSerialization.data(withJSONObject:["pid":pid,"playbackRevision":UUID().uuidString,"sourceIsAutomatic":true,
      "sources":[["pid":pid,"bundleIdentifier":Bundle.main.bundleIdentifier!,"isMusicApp":false,"isPlaying":false,"hasTrack":true]],
      "kMRMediaRemoteNowPlayingInfoTitle":"Display test","isPlaying":false,"canSendCommandsDirectly":true,"canToggle":true]))
    let retained=model.playback;XCTAssertFalse(retained.source.isEmpty)
    model.setShowOnMac(true);XCTAssertTrue(model.showOnMac);XCTAssertTrue(model.companionVisible)
    XCTAssertTrue(MacPlaybackModel(preferences:preferences,requestSink:{ _ in true }).showOnMac)
    model.setShowOnMac(false);XCTAssertFalse(model.showOnMac);XCTAssertFalse(model.companionVisible)
    XCTAssertTrue(model.phoneSubscribed);XCTAssertEqual(model.playback,retained)
    XCTAssertFalse(MacPlaybackModel(preferences:preferences,requestSink:{ _ in true }).showOnMac)
    model.setShowOnMac(true);XCTAssertTrue(model.companionVisible)
    model.presented("companion",false);model.setShowOnMac(false);model.setShowOnMac(true)
    XCTAssertFalse(model.companionVisible);XCTAssertTrue(model.phoneSubscribed)
    _ = model.receive(try MediaMessage(kind:4,fields:[.text(sub)]).encode(),channel:"ble")
    XCTAssertFalse(model.phoneSubscribed)
  }
  @MainActor func testInstalledScriptingDictionaryBoundsAndPermissionCapabilities() throws {
    let good=Data("""
      <dictionary><suite name="Playback" code="Musi"><command name="playpause" code="MusiPlPs"/><command name="next track" code="MusiNext"/><class name="application" code="capp"><property name="player position" code="pPos" type="real" access="rw"/></class></suite></dictionary>
      """.utf8)
    let parsed=try XCTUnwrap(PlaybackAutomationCapabilities.parse(good))
    XCTAssertTrue(parsed.canToggle);XCTAssertNotNil(parsed.position);XCTAssertNotNil(parsed.event(for:.next,isPlaying:true));XCTAssertNil(parsed.event(for:.previous,isPlaying:false))
    XCTAssertNil(PlaybackAutomationCapabilities.parse(Data(repeating:0,count:256*1024+1)))
    XCTAssertNil(PlaybackAutomationCapabilities.parse(Data("<!DOCTYPE dictionary [<!ENTITY x SYSTEM 'file:///tmp/secret'>]><dictionary>&x;</dictionary>".utf8)))
    let duplicate=Data("<dictionary><suite><command name='playpause' code='MusiPlPs'/><command name='playpause' code='MusiPlPs'/></suite></dictionary>".utf8)
    XCTAssertNil(PlaybackAutomationCapabilities.parse(duplicate))
    let required=Data("<dictionary><suite><command name='playpause' code='MusiPlPs'><parameter name='unsafe'/></command></suite></dictionary>".utf8)
    XCTAssertNil(PlaybackAutomationCapabilities.parse(required))
  }
  @MainActor func testThumbnailBoundsAndInvalidInput() throws {
    XCTAssertNil(MacPlaybackModel.thumbnail(Data()));XCTAssertNil(MacPlaybackModel.thumbnail(Data(repeating:0,count:12*1024*1024+1)))
    let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:512,pixelsHigh:384,bitsPerSample:8,samplesPerPixel:3,hasAlpha:false,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
    if let pixels=bitmap.bitmapData { memset(pixels,0,bitmap.bytesPerRow*bitmap.pixelsHigh) }
    let input=try XCTUnwrap(bitmap.representation(using:.jpeg,properties:[:]))
    let thumbnail=try XCTUnwrap(MacPlaybackModel.thumbnail(input)), decoded=try XCTUnwrap(NSBitmapImageRep(data:thumbnail))
    XCTAssertLessThanOrEqual(thumbnail.count,65536);XCTAssertLessThanOrEqual(max(decoded.pixelsWide,decoded.pixelsHigh),256)
  }
  @MainActor func testPackagedOwnerAgainstCurrentlyPlayingSource() async throws {
    guard ProcessInfo.processInfo.environment["ANICE_RUN_PLAYBACK_READ_TEST"]=="1" else { throw XCTSkip("Requires a manually started real player") }
    let model=MacPlaybackModel();model.presented("acceptance",true);defer { model.presented("acceptance",false) }
    try await Task.sleep(for:.seconds(3))
    XCTAssertEqual(model.feedback,"");XCTAssertFalse(model.playback.source.isEmpty);XCTAssertFalse(model.playback.title.isEmpty);XCTAssertFalse(model.playback.revision.isEmpty)
    XCTAssertTrue(model.sources.contains { $0.id==model.playback.source })
    XCTAssertFalse(model.sources.isEmpty)
  }

  @MainActor func testNativeRepliesCannotCompleteAnotherCommandAndSamplesKeepRevision() throws {
    var requests:[PlaybackRequest]=[]
    let model=MacPlaybackModel(requestSink:{requests.append($0);return true})
    let pid=ProcessInfo.processInfo.processIdentifier, nativeRevision=UUID()
    func snapshot(_ revision: UUID,_ position: Double=1) throws -> Data {
      try JSONSerialization.data(withJSONObject:["pid":pid,"playbackRevision":revision.uuidString,"sourceIsAutomatic":true,
        "sources":[["pid":pid,"bundleIdentifier":Bundle.main.bundleIdentifier!,"isMusicApp":false,"isPlaying":true,"hasTrack":true,"displayName":"Test player"]],
        "kMRMediaRemoteNowPlayingInfoTitle":"Track","kMRMediaRemoteNowPlayingInfoDuration":100,"kMRMediaRemoteNowPlayingInfoElapsedTime":position,
        "kMRMediaRemoteNowPlayingInfoPlaybackRate":1,"isPlaying":true,"canSendCommandsDirectly":true,"canToggle":true,"canSeek":true])
    }
    model.read(try snapshot(nativeRevision));XCTAssertFalse(model.playback.source.isEmpty)
    let first=model.playback
    model.read(try snapshot(nativeRevision,2));XCTAssertEqual(model.playback.revision,first.revision)
    var results:[Int64]=[]
    model.command(source:first.source,revision:first.revision,action:4,value:100001) { results.append($0) }
    XCTAssertEqual(results,[1]);XCTAssertTrue(requests.isEmpty)
    model.command(source:first.source,revision:first.revision,action:1) { results.append($0) }
    let oldID=try XCTUnwrap(requests.last?.requestID);XCTAssertTrue(model.busy)
    model.read(try snapshot(UUID()));XCTAssertFalse(model.busy);XCTAssertEqual(results,[1,1])
    let second=model.playback
    model.command(source:second.source,revision:second.revision,action:1) { results.append($0) }
    let newID=try XCTUnwrap(requests.last?.requestID)
    model.read(try JSONSerialization.data(withJSONObject:["sent":true,"requestID":oldID.uuidString]))
    XCTAssertTrue(model.busy);XCTAssertEqual(results,[1,1])
    model.read(try JSONSerialization.data(withJSONObject:["sent":true,"requestID":newID.uuidString]))
    XCTAssertFalse(model.busy);XCTAssertEqual(results,[1,1,0]);XCTAssertEqual(requests.count,3);XCTAssertEqual(requests.last?.command,.sample)
    let confirmed=model.playback
    let quick:[String:Any] = ["sampleOnly":true,"pid":pid,"playbackRevision":requests.last!.context!.revision.uuidString,"isPlaying":false,"kMRMediaRemoteNowPlayingInfoElapsedTime":42,"kMRMediaRemoteNowPlayingInfoPlaybackRate":1]
    model.read(try JSONSerialization.data(withJSONObject:quick))
    XCTAssertEqual(model.playback.position,42000);XCTAssertEqual(model.playback.state,2);XCTAssertEqual(model.playback.rate,0);XCTAssertEqual(model.playback.revision,confirmed.revision)
    var stale=quick;stale["playbackRevision"]=UUID().uuidString;stale["kMRMediaRemoteNowPlayingInfoElapsedTime"]=99
    model.read(try JSONSerialization.data(withJSONObject:stale));XCTAssertEqual(model.playback.position,42000)
    var playOnly=try XCTUnwrap(JSONSerialization.jsonObject(with:snapshot(UUID())) as? [String:Any])
    playOnly["canToggle"]=false;playOnly["canPlay"]=true;playOnly["canPause"]=false
    model.read(try JSONSerialization.data(withJSONObject:playOnly));XCTAssertEqual(model.playback.actions & 1,0)
    model.command(source:model.playback.source,revision:model.playback.revision,action:1) { results.append($0) };XCTAssertEqual(results.last,2)
    playOnly["isPlaying"]=false;model.read(try JSONSerialization.data(withJSONObject:playOnly));XCTAssertEqual(model.playback.actions & 1,1)
    let pausedRevision=model.playback.revision
    model.read(try JSONSerialization.data(withJSONObject:["sampleOnly":true,"pid":pid,"playbackRevision":playOnly["playbackRevision"]!,"isPlaying":true,"kMRMediaRemoteNowPlayingInfoElapsedTime":3,"kMRMediaRemoteNowPlayingInfoPlaybackRate":1]))
    XCTAssertEqual(model.playback.actions & 1,0);XCTAssertNotEqual(model.playback.revision,pausedRevision)
    model.read(Data("{\"error\":\"metadata timeout\"}".utf8));XCTAssertTrue(model.playback.source.isEmpty);XCTAssertFalse(model.feedback.isEmpty)
  }
  @MainActor func testAppliedRemoteCommandDuplicatesExecuteOnlyOnce() async throws {
    var requests:[PlaybackRequest]=[], sent:[MediaMessage]=[]
    let model=MacPlaybackModel(requestSink:{requests.append($0);return true})
    model.channel("ble",token:"secured") { if let message=try MediaMessage.decode($0) { sent.append(message) } else { XCTAssertNotNil(try PlayerVolumeMessage.decode($0)) } }
    let sub=UUID().uuidString;_ = model.receive(try MediaMessage(kind:2,fields:[.text(sub)]).encode(),channel:"ble")
    let pid=ProcessInfo.processInfo.processIdentifier
    model.read(try JSONSerialization.data(withJSONObject:["pid":pid,"playbackRevision":UUID().uuidString,"sourceIsAutomatic":true,
      "sources":[["pid":pid,"bundleIdentifier":Bundle.main.bundleIdentifier!,"isMusicApp":false,"isPlaying":true,"hasTrack":true]],
      "kMRMediaRemoteNowPlayingInfoTitle":"Test","isPlaying":true,"canSendCommandsDirectly":true,"canToggle":true]))
    let target=model.playback, command=try MediaMessage(kind:6,fields:[.text(sub),.integer(1),.text(target.source),.text(target.revision),.integer(1),.integer(0)]).encode()
    _ = model.receive(command,channel:"ble");_ = model.receive(command,channel:"ble")
    XCTAssertEqual(requests.count,1)
    model.read(try JSONSerialization.data(withJSONObject:["sent":true,"requestID":requests[0].requestID!.uuidString]))
    _ = model.receive(command,channel:"ble");try await Task.sleep(for:.milliseconds(100))
    XCTAssertEqual(requests.count,2);XCTAssertEqual(requests.last?.command,.sample);XCTAssertEqual(sent.filter { $0.kind==7 }.map { $0.number(2) },[0,0])
    model.channel("ble",token:nil) { _ in XCTFail("Retired") }
  }

}

final class CapabilityRepairTests: XCTestCase {
  @MainActor func testExplicitPackagedPlayerToggleAndSeekAcceptance() async throws {
    guard ProcessInfo.processInfo.environment["ANICE_RUN_DIRECTED_CONTROL_TEST"]=="1" else { throw XCTSkip("Requires explicit packaged real-player control acceptance") }
    let model=MacPlaybackModel();model.presented("control-acceptance",true);defer { model.presented("control-acceptance",false) }
    try await Task.sleep(for:.seconds(3))
    let start=model.playback
    let others=Dictionary(uniqueKeysWithValues:model.sources.filter { $0.id != start.source }.map { ($0.pid,$0.playing) })
    guard !start.source.isEmpty, start.actions & 1 != 0 else { throw XCTSkip("No controllable active player") }
    guard !others.isEmpty else { throw XCTSkip("Routing acceptance requires another discoverable player; single-player packaged controls are separate evidence") }
    func perform(_ action: Int64, value: Int64=0) async -> Int64 {
      let target=model.playback
      return await withCheckedContinuation { continuation in model.command(source:target.source,revision:target.revision,action:action,value:value) { continuation.resume(returning:$0) } }
    }
    let toggled=await perform(1);XCTAssertEqual(toggled,0);guard toggled==0 else { return }
    try await Task.sleep(for:.seconds(1))
    XCTAssertEqual(model.playback.source,start.source)
    XCTAssertEqual(model.playback.state,start.state==1 ? 2:1)
    guard model.playback.source==start.source, model.playback.title==start.title else { return }
    let restored=await perform(1);XCTAssertEqual(restored,0);guard restored==0 else { return }
    try await Task.sleep(for:.seconds(1));XCTAssertEqual(model.playback.state,start.state)
    if model.playback.actions & 8 != 0, model.playback.duration>0, model.playback.position>=0 {
      let requested=min(model.playback.position+1000,model.playback.duration)
      let sought=await perform(4,value:requested);XCTAssertEqual(sought,0);guard sought==0 else { return }
      try await Task.sleep(for:.milliseconds(300))
      XCTAssertEqual(model.playback.source,start.source)
      XCTAssertLessThan(abs(model.playback.position-requested),1500)
    }
    model.refreshCapabilities();try await Task.sleep(for:.seconds(1))
    for (pid,playing) in others { XCTAssertEqual(model.sources.first { $0.pid==pid }?.playing,playing,"Another player changed or disappeared") }
  }

  func testCapabilityCallbackBeforeAndAfterPublicationEmitsOnce() {
    let early=RecordingCapabilities(), late=RecordingCapabilities()
    let context: [String:Any]=["pid":10,"playbackRevision":UUID().uuidString]
    XCTAssertNil(early.complete(["canSeek":true]));XCTAssertEqual(early.arm(context)?["canSeek"] as? Bool,true)
    XCTAssertNil(early.complete(["canSeek":false]))
    XCTAssertNil(late.arm(context));XCTAssertEqual(late.complete(["canSeek":true])?["pid"] as? Int,10)
    XCTAssertNil(late.complete(["canSeek":false]))
    let timed=RecordingCapabilities();XCTAssertNil(timed.arm(context))
    XCTAssertEqual(timed.expire()?["capabilityState"] as? String,"unavailable");XCTAssertNil(timed.expire())
    XCTAssertEqual(timed.complete(["canSeek":true])?["canSeek"] as? Bool,true);XCTAssertNil(timed.complete(["canSeek":false]))
  }
  func testCapabilityPublicationWaitIsBoundedAndAllowsLateCompletion() {
    let early=RecordingCapabilities(), late=RecordingCapabilities()
    XCTAssertNil(early.complete(["capabilityState":"ready","canSeek":true]))
    XCTAssertTrue(early.wait(until:.now()))
    XCTAssertEqual(early.currentValues?["canSeek"] as? Bool,true)
    XCTAssertFalse(late.wait(until:.now()))
    let context: [String:Any]=["pid":10,"playbackRevision":UUID().uuidString]
    XCTAssertNil(late.arm(context))
    XCTAssertEqual(late.complete(["canSeek":true])?["pid"] as? Int,10)
    XCTAssertTrue(late.wait(until:.now()))
    XCTAssertNil(late.complete(["canSeek":false]))
    XCTAssertFalse(late.wait(until:.now()),"Duplicate callbacks must not signal a second completion")
  }
  func testLateCapabilitiesKeepLatestNativePlaybackState() {
    var controls=NativePlaybackControls()
    controls.sample(["isPlaying":true]);controls.sample(["isPlaying":false])
    controls.capabilities(["isPlaying":true,"canPlay":true,"canPause":true])
    XCTAssertEqual(controls.command,0)
    controls.sample(["isPlaying":true]);XCTAssertEqual(controls.command,1)
    controls.capabilities(["canToggle":true,"canPlay":true,"canPause":true]);XCTAssertEqual(controls.command,2)
  }
  func testPartialNativeCommandsPreserveIndependentScriptActions() {
    let dictionary=PlaybackAutomationCapabilities(commands:["playpause":.init(eventClass:1,eventID:2),"next track":.init(eventClass:1,eventID:3)],position:.init(code:1,integer:false))
    let routes=PlaybackRoutes(native:["canSendCommandsDirectly":true,"canToggle":true],scripting:dictionary,state:1,duration:100)
    XCTAssertEqual(routes.actions,13);XCTAssertFalse(routes.usesScripting(1));XCTAssertTrue(routes.usesScripting(3));XCTAssertTrue(routes.usesScripting(4));XCTAssertFalse(routes.usesScripting(2))
    let blocked=PlaybackRoutes(native:["canSendCommandsDirectly":false,"canToggle":true],scripting:nil,state:1,duration:100)
    XCTAssertEqual(blocked.actions,0)
    XCTAssertEqual(PlaybackRoutes(native:[:],scripting:dictionary,state:2,duration:-1).actions,5)
  }
  @MainActor func testDelayedCapabilitiesRejectOldRecordingAndPreservePosition() throws {
    let model=MacPlaybackModel(requestSink:{ _ in true }), pid=ProcessInfo.processInfo.processIdentifier, recording=UUID()
    let row: [String:Any]=["pid":pid,"playbackRevision":recording.uuidString,"sources":[["pid":pid,"bundleIdentifier":"test.player","isMusicApp":false,"isPlaying":true,"hasTrack":true]],"kMRMediaRemoteNowPlayingInfoTitle":"Fixture","kMRMediaRemoteNowPlayingInfoDuration":100,"kMRMediaRemoteNowPlayingInfoElapsedTime":42,"isPlaying":true,"canSendCommandsDirectly":true,"capabilityState":"discovering"]
    model.read(try JSONSerialization.data(withJSONObject:row));XCTAssertEqual(model.playback.actions,0)
    let original=model.playback
    let capabilities:[String:Any]=["capabilitiesOnly":true,"pid":pid,"playbackRevision":recording.uuidString,"canSendCommandsDirectly":true,"canToggle":true,"canSeek":true,"capabilityState":"ready"]
    model.read(try JSONSerialization.data(withJSONObject:capabilities));XCTAssertEqual(model.playback.actions,9);XCTAssertEqual(model.playback.position,42000);XCTAssertNotEqual(model.playback.revision,original.revision)
    let confirmed=model.playback
    model.read(try JSONSerialization.data(withJSONObject:row));XCTAssertEqual(model.playback.actions,9);XCTAssertEqual(model.playback.revision,confirmed.revision)
    let beforeStale=model.playback
    var stale=capabilities;stale["playbackRevision"]=UUID().uuidString;stale["canToggle"]=false
    model.read(try JSONSerialization.data(withJSONObject:stale));XCTAssertEqual(model.playback,beforeStale)
    model.refreshCapabilities();XCTAssertEqual(model.playback.source,confirmed.source)
  }
  @MainActor func testUnavailableCapabilitiesKeepSeekUntilSupportIsExplicitlyRemoved() throws {
    let model=MacPlaybackModel(requestSink:{ _ in true }), pid=ProcessInfo.processInfo.processIdentifier, recording=UUID()
    let row: [String:Any]=["pid":pid,"playbackRevision":recording.uuidString,"sources":[["pid":pid,"bundleIdentifier":"test.player","isMusicApp":false,"isPlaying":true,"hasTrack":true]],"kMRMediaRemoteNowPlayingInfoTitle":"Track","kMRMediaRemoteNowPlayingInfoDuration":100,"isPlaying":true,"canSendCommandsDirectly":true,"canToggle":true,"canSeek":true,"capabilityState":"ready"]
    model.read(try JSONSerialization.data(withJSONObject:row))
    XCTAssertEqual(model.playback.actions,9)
    let revision=model.playback.revision
    var unavailable=row
    unavailable["capabilityState"]="unavailable"
    unavailable.removeValue(forKey:"canToggle");unavailable.removeValue(forKey:"canSeek")
    model.read(try JSONSerialization.data(withJSONObject:unavailable))
    XCTAssertEqual(model.playback.actions,9)
    XCTAssertEqual(model.playback.revision,revision)
    let pending=RecordingCapabilities()
    XCTAssertNil(pending.arm(["capabilitiesOnly":true,"pid":pid,"playbackRevision":recording.uuidString,"canSendCommandsDirectly":true]))
    model.read(try JSONSerialization.data(withJSONObject:XCTUnwrap(pending.expire())))
    XCTAssertEqual(model.playback.actions,9)
    XCTAssertEqual(model.playback.revision,revision)
    model.read(try JSONSerialization.data(withJSONObject:XCTUnwrap(pending.complete(["capabilityState":"ready","canSeek":true,"canToggle":true]))))
    XCTAssertEqual(model.playback.actions,9)
    XCTAssertEqual(model.playback.revision,revision)
    var reply: [String:Any]=["capabilitiesOnly":true,"pid":pid,"playbackRevision":recording.uuidString,"capabilityState":"ready","canSeek":false,"canToggle":true]
    model.read(try JSONSerialization.data(withJSONObject:reply))
    XCTAssertEqual(model.playback.actions,1)
    XCTAssertNotEqual(model.playback.revision,revision)
    reply["canSeek"]=true;reply["playbackRevision"]=UUID().uuidString
    model.read(try JSONSerialization.data(withJSONObject:reply))
    XCTAssertEqual(model.playback.actions,1)
    reply["playbackRevision"]=recording.uuidString;reply.removeValue(forKey:"canSeek");reply["capabilityState"]="unsupported"
    model.read(try JSONSerialization.data(withJSONObject:reply))
    XCTAssertEqual(model.playback.actions,0)
    model.read(try JSONSerialization.data(withJSONObject:unavailable))
    XCTAssertEqual(model.playback.actions,0,"Unknown support must not invent seek capability")
    model.read(try JSONSerialization.data(withJSONObject:row))
    var live=row;live["kMRMediaRemoteNowPlayingInfoDuration"]=0
    model.read(try JSONSerialization.data(withJSONObject:live))
    XCTAssertEqual(model.playback.actions,1,"A live stream must still hide seek")
  }
  @MainActor func testMetadataGapRetainsOnlyTheSameRecordingsKnownTimeline() throws {
    let model=MacPlaybackModel(requestSink:{ _ in true }), pid=ProcessInfo.processInfo.processIdentifier
    let row: [String:Any]=["pid":pid,"playbackRevision":UUID().uuidString,"sources":[["pid":pid,"bundleIdentifier":"test.player","isMusicApp":false,"isPlaying":false,"hasTrack":true]],"kMRMediaRemoteNowPlayingInfoTitle":"Track","kMRMediaRemoteNowPlayingInfoDuration":100,"kMRMediaRemoteNowPlayingInfoElapsedTime":42,"kMRMediaRemoteNowPlayingInfoPlaybackRate":0,"isPlaying":false,"canSendCommandsDirectly":true,"canToggle":true,"canSeek":true,"capabilityState":"ready"]
    model.read(try JSONSerialization.data(withJSONObject:row))
    let confirmed=model.playback
    XCTAssertEqual(confirmed.actions,9)
    var gap=row
    for key in ["kMRMediaRemoteNowPlayingInfoDuration","kMRMediaRemoteNowPlayingInfoElapsedTime","kMRMediaRemoteNowPlayingInfoPlaybackRate"] { gap.removeValue(forKey:key) }
    model.read(try JSONSerialization.data(withJSONObject:gap))
    XCTAssertEqual(model.playback.duration,100000)
    XCTAssertEqual(model.playback.position,42000)
    XCTAssertEqual(model.playback.actions,9)
    XCTAssertEqual(model.playback.revision,confirmed.revision)
    gap["playbackRevision"]=UUID().uuidString
    model.read(try JSONSerialization.data(withJSONObject:gap))
    XCTAssertEqual(model.playback.duration,-1,"Another recording cannot inherit a duration")
    XCTAssertEqual(model.playback.position,-1)
    XCTAssertEqual(model.playback.actions,1)
    let invalid: [Any]=[0,-1,"invalid",true]
    XCTAssertGreaterThanOrEqual(invalid.count,4)
    for value in invalid {
      model.read(try JSONSerialization.data(withJSONObject:row))
      var explicit=row;explicit["kMRMediaRemoteNowPlayingInfoDuration"]=value
      model.read(try JSONSerialization.data(withJSONObject:explicit))
      XCTAssertEqual(model.playback.actions,1,"Explicit unknown or invalid duration removes seek")
    }
  }
  @MainActor func testPositionSampleRecoversDurationOnlyForTheCurrentRecording() throws {
    let model=MacPlaybackModel(requestSink:{ _ in true }),pid=ProcessInfo.processInfo.processIdentifier,recording=UUID()
    let row: [String:Any]=["pid":pid,"playbackRevision":recording.uuidString,"sources":[["pid":pid,"bundleIdentifier":"test.player","isMusicApp":false,"isPlaying":true,"hasTrack":true]],"kMRMediaRemoteNowPlayingInfoTitle":"Track","isPlaying":true,"canSendCommandsDirectly":true,"canToggle":true,"canSeek":true,"capabilityState":"ready"]
    model.read(try JSONSerialization.data(withJSONObject:row))
    XCTAssertEqual(model.playback.duration,-1);XCTAssertEqual(model.playback.actions,1)
    model.read(try JSONSerialization.data(withJSONObject:["sampleOnly":true,"pid":pid,"playbackRevision":recording.uuidString]))
    XCTAssertEqual(model.playback.position,-1,"A sample without timing must not invent position zero")
    var sample: [String:Any]=["sampleOnly":true,"pid":pid,"playbackRevision":recording.uuidString,"kMRMediaRemoteNowPlayingInfoDuration":100,"kMRMediaRemoteNowPlayingInfoElapsedTime":20,"isPlaying":true]
    model.read(try JSONSerialization.data(withJSONObject:sample))
    XCTAssertEqual(model.playback.duration,100000);XCTAssertEqual(model.playback.actions,9)
    let confirmed=model.playback
    sample["playbackRevision"]=UUID().uuidString;sample["kMRMediaRemoteNowPlayingInfoDuration"]=0
    model.read(try JSONSerialization.data(withJSONObject:sample));XCTAssertEqual(model.playback,confirmed)
    sample["playbackRevision"]=recording.uuidString
    model.read(try JSONSerialization.data(withJSONObject:sample))
    XCTAssertEqual(model.playback.duration,0);XCTAssertEqual(model.playback.actions,1)
  }
  func testUnavailableNativeCapabilitiesPreserveDirectedPlayPause() {
    var controls=NativePlaybackControls()
    controls.sample(["isPlaying":true]);controls.capabilities(["canPause":true])
    XCTAssertEqual(controls.command,1)
    controls.capabilities(["capabilityState":"unavailable"])
    XCTAssertEqual(controls.command,1)
    controls.capabilities(["capabilityState":"ready","canPause":false])
    XCTAssertEqual(controls.command,2)
    controls.capabilities(["canPlay":true]);controls.sample(["isPlaying":false])
    XCTAssertEqual(controls.command,0)
    controls.capabilities(["capabilityState":"unsupported"])
    XCTAssertEqual(controls.command,2)
  }
  @MainActor func testSameSourceRecordingChangeRetainsCapabilitiesWithoutActionFlicker() throws {
    let model=MacPlaybackModel(requestSink:{ _ in true }), pid=ProcessInfo.processInfo.processIdentifier
    let firstRecording=UUID()
    let initialRow: [String:Any]=["pid":pid,"playbackRevision":firstRecording.uuidString,"sources":[["pid":pid,"bundleIdentifier":"test.player","isMusicApp":false,"isPlaying":true,"hasTrack":true]],"kMRMediaRemoteNowPlayingInfoTitle":"Track 1","kMRMediaRemoteNowPlayingInfoDuration":100,"kMRMediaRemoteNowPlayingInfoElapsedTime":10,"isPlaying":true,"canSendCommandsDirectly":true,"canToggle":true,"canSeek":true,"capabilityState":"ready"]
    model.read(try JSONSerialization.data(withJSONObject:initialRow))
    XCTAssertEqual(model.playback.actions,9)
    let firstTrackRevision=model.playback.revision
    let secondRecording=UUID()
    let nextTrackRow: [String:Any]=["pid":pid,"playbackRevision":secondRecording.uuidString,"sources":[["pid":pid,"bundleIdentifier":"test.player","isMusicApp":false,"isPlaying":true,"hasTrack":true]],"kMRMediaRemoteNowPlayingInfoTitle":"Track 2","kMRMediaRemoteNowPlayingInfoDuration":200,"kMRMediaRemoteNowPlayingInfoElapsedTime":0,"isPlaying":true,"canSendCommandsDirectly":true,"capabilityState":"discovering"]
    model.read(try JSONSerialization.data(withJSONObject:nextTrackRow))
    XCTAssertEqual(model.playback.actions,9)
    XCTAssertNotEqual(model.playback.revision, firstTrackRevision)
    let secondTrackRevision=model.playback.revision
    let capabilitiesOnly: [String:Any]=["capabilitiesOnly":true,"pid":pid,"playbackRevision":secondRecording.uuidString,"canSendCommandsDirectly":true,"canToggle":true,"canSeek":true,"capabilityState":"ready"]
    model.read(try JSONSerialization.data(withJSONObject:capabilitiesOnly))
    XCTAssertEqual(model.playback.actions,9)
    XCTAssertEqual(model.playback.revision, secondTrackRevision)
    let otherPID: Int32 = 99999
    let otherSourceRow: [String:Any]=["pid":otherPID,"playbackRevision":UUID().uuidString,"sources":[["pid":otherPID,"bundleIdentifier":"other.player","isMusicApp":false,"isPlaying":true,"hasTrack":true]],"kMRMediaRemoteNowPlayingInfoTitle":"Other Track","isPlaying":true,"canSendCommandsDirectly":true,"capabilityState":"discovering"]
    model.read(try JSONSerialization.data(withJSONObject:otherSourceRow))
    XCTAssertEqual(model.playback.actions,0)
  }
  func testTransientReadRecoversWithoutReverificationOrPermissionPrompt() {
    var state=PlayerVolumeState()
    XCTAssertFalse(state.canRead(permitted:true));XCTAssertFalse(state.supported)
    XCTAssertTrue(state.receive(result:0,level:42));XCTAssertTrue(state.supported)
    XCTAssertTrue(state.receive(result:7,level:nil));XCTAssertFalse(state.supported)
    XCTAssertTrue(state.canRead(permitted:true));XCTAssertFalse(state.canRead(permitted:false))
    XCTAssertTrue(state.receive(result:0,level:45));XCTAssertTrue(state.supported)
    XCTAssertFalse(state.receive(result:0,level:46));XCTAssertEqual(state.level,46)
    XCTAssertTrue(state.receive(result:0,level:101));XCTAssertNil(state.level)
    state.restoreProof(false);XCTAssertFalse(state.canRead(permitted:true))
  }
  func testMacVolumePreviewRequiresSampleAndExpiresWithoutSnapback() {
    var preview=VolumePreview();preview.begin(70,now:10)
    preview.confirm(40);XCTAssertEqual(preview.value(at:11),70)
    preview.confirm(70);XCTAssertNil(preview.value(at:11))
    preview.begin(80,now:20);XCTAssertNil(preview.value(at:26));preview.clear();XCTAssertFalse(preview.pending)
  }
}

final class PlayerVolumeTests: XCTestCase {
  func testIndependentVolumeFixturesAndUnchangedV1Namespace() throws {
    let helper=SessionFixtures(), root=try helper.root("volume-vectors")
    let good=try XCTUnwrap(root["valid"] as? [[String:Any]]), bad=try XCTUnwrap(root["invalid"] as? [[String:Any]])
    XCTAssertGreaterThanOrEqual(good.count,9);XCTAssertGreaterThanOrEqual(bad.count,23)
    for row in good { let bytes=try helper.b(row,"bytes"), message=try XCTUnwrap(PlayerVolumeMessage.decode(bytes));XCTAssertEqual(try message.encode(),bytes);XCTAssertNil(try MediaMessage.decode(bytes)) }
    for row in bad { XCTAssertThrowsError(try PlayerVolumeMessage.decode(helper.b(row,"bytes")),row["name"] as? String ?? "") }
  }
  func testVolumeDictionaryRejectsWrongTypeAccessDuplicatesAndEntities() throws {
    func parse(_ properties: String) -> PlaybackAutomationCapabilities? { PlaybackAutomationCapabilities.parse(Data("<dictionary><suite><class name='application'>\(properties)</class></suite></dictionary>".utf8)) }
    let valid="<property name='sound volume' code='pVol' type='integer' access='rw'/>"
    XCTAssertEqual(parse(valid)?.volume?.code,0x70566f6c)
    XCTAssertNil(parse(valid.replacingOccurrences(of:"integer",with:"real"))?.volume)
    XCTAssertNil(parse(valid.replacingOccurrences(of:"rw",with:"r"))?.volume)
    XCTAssertNil(parse(valid+valid)?.volume)
    XCTAssertNil(PlaybackAutomationCapabilities.parse(Data("<!DOCTYPE dictionary [<!ENTITY x 'test'>]><dictionary>&x;</dictionary>".utf8)))
  }
  @MainActor func testUnprovenPlayersAndDuplicateVolumeCommandsNeverExecute() async throws {
    var writes=0;let model=MacPlaybackModel(requestSink:{ _ in writes += 1;return true })
    let sub=UUID().uuidString, source=UUID().uuidString, revision=UUID().uuidString
    var outgoing:[PlayerVolumeMessage]=[]
    model.channel("ble",token:"volume-test") { if let message=try PlayerVolumeMessage.decode($0) { outgoing.append(message) } else { XCTAssertNotNil(try MediaMessage.decode($0)) } }
    _ = model.receive(try PlayerVolumeMessage(kind:1,fields:[.integer(1)]).encode(),channel:"ble")
    _ = model.receive(try MediaMessage(kind:2,fields:[.text(sub)]).encode(),channel:"ble")
    let command=try PlayerVolumeMessage(kind:3,fields:[.text(sub),.integer(1),.text(source),.text(revision),.integer(55)]).encode()
    XCTAssertTrue(model.receive(command,channel:"ble"));XCTAssertTrue(model.receive(command,channel:"ble"))
    try await Task.sleep(for:.milliseconds(50))
    XCTAssertEqual(writes,0);XCTAssertEqual(outgoing.filter { $0.kind==4 }.map { $0.number(2) },[1,1])
    model.channel("ble",token:nil) { _ in XCTFail("Retired channel submitted") }
    XCTAssertTrue(model.receive(command,channel:"ble"));XCTAssertNil(model.playerVolume)
  }
}


final class OutputVolumeTests: XCTestCase {
  func testIndependentOutputFixturesAndScopeIsolation() throws {
    let helper=SessionFixtures(),root=try helper.root("output-volume-vectors")
    let good=try XCTUnwrap(root["valid"] as? [[String:Any]]),bad=try XCTUnwrap(root["invalid"] as? [[String:Any]])
    XCTAssertGreaterThanOrEqual(good.count,9);XCTAssertGreaterThanOrEqual(bad.count,23)
    for row in good { let bytes=try helper.b(row,"bytes"),message=try XCTUnwrap(PlayerVolumeMessage.decode(bytes));XCTAssertEqual(message.scope,.output);XCTAssertEqual(try message.encode(),bytes);XCTAssertNil(try MediaMessage.decode(bytes)) }
    for row in bad { XCTAssertThrowsError(try PlayerVolumeMessage.decode(helper.b(row,"bytes"))) }
  }
  @MainActor func testOutputReplacementFailuresBoundsAndStopNeverRetargetWrites() {
    var device=OutputDeviceVolume(device:1,uid:"first",selector:123,scalar:0.4),available=true,writes=0,status:Int64=0
    let owner=MacOutputVolume(observeNative:false,read:{ available ? device:nil },write:{ target,value in
      writes+=1;XCTAssertEqual(target.identity,device.identity)
      if status==0 { device=OutputDeviceVolume(device:device.device,uid:device.uid,selector:device.selector,scalar:value) };return status
    })
    owner.start();let target=owner.target,revision=owner.revision
    XCTAssertEqual(owner.command(target:target,revision:revision,value:101),1);XCTAssertEqual(writes,0)
    XCTAssertEqual(owner.command(target:target,revision:revision,value:45),0);XCTAssertEqual(owner.level,45);XCTAssertEqual(owner.revision,revision)
    device=OutputDeviceVolume(device:2,uid:"second",selector:123,scalar:0.2)
    XCTAssertEqual(owner.command(target:target,revision:revision,value:80),1);XCTAssertEqual(writes,1);XCTAssertNotEqual(owner.target,target)
    status=7;XCTAssertEqual(owner.command(target:owner.target,revision:owner.revision,value:80),7);XCTAssertEqual(writes,2)
    available=false;owner.refresh();XCTAssertNil(owner.level);XCTAssertEqual(owner.target,"")
    available=true;owner.refresh();XCTAssertNotEqual(owner.revision,revision)
    owner.stop();XCTAssertEqual(owner.command(target:target,revision:revision,value:50),5);XCTAssertEqual(writes,2)
    device=OutputDeviceVolume(device:1,uid:"bad",selector:123,scalar:.nan);owner.start();XCTAssertNil(owner.level);owner.stop()
  }
  @MainActor func testOutputNegotiationCrossKindDedupAndRetirement() async throws {
    var scalar:Float32=0.4,writes=0
    let output=MacOutputVolume(observeNative:false,read:{ .init(device:1,uid:"test",selector:1,scalar:scalar) },write:{ _,value in writes+=1;scalar=value;return 0 })
    let model=MacPlaybackModel(requestSink:{ _ in XCTFail("Output volume launched player commands");return false },outputVolume:output)
    var replies:[PlayerVolumeMessage]=[], snapshots=0
    model.channel("ble",token:"output") { if let v=try PlayerVolumeMessage.decode($0) { replies.append(v) } else if let media=try MediaMessage.decode($0), media.kind==5 { snapshots+=1 } }
    let sub=UUID().uuidString,pid=ProcessInfo.processInfo.processIdentifier
    _=model.receive(try MediaMessage(kind:2,fields:[.text(sub)]).encode(),channel:"ble")
    defer { model.channel("ble",token:nil) { _ in XCTFail("Retired") } }
    model.read(try JSONSerialization.data(withJSONObject:["pid":pid,"playbackRevision":UUID().uuidString,"sources":[["pid":pid,"bundleIdentifier":Bundle.main.bundleIdentifier!,"hasTrack":true,"isMusicApp":false,"isPlaying":true]],"kMRMediaRemoteNowPlayingInfoTitle":"Fixture","isPlaying":true]))
    let command=PlayerVolumeMessage(kind:3,fields:[.text(sub),.integer(1),.text(output.target),.text(output.revision),.integer(45)],scope:.output)
    _=model.receive(try command.encode(),channel:"ble");XCTAssertEqual(writes,0)
    _=model.receive(try PlayerVolumeMessage(kind:1,fields:[.integer(1)],scope:.output).encode(),channel:"ble")
    _=model.receive(try command.encode(),channel:"ble");_=model.receive(try command.encode(),channel:"ble");XCTAssertEqual(writes,1)
    _=model.receive(try PlayerVolumeMessage(kind:1,fields:[.integer(1)]).encode(),channel:"ble")
    _=model.receive(try PlayerVolumeMessage(kind:3,fields:command.fields).encode(),channel:"ble");XCTAssertEqual(writes,1)
    try await Task.sleep(for:.milliseconds(50));XCTAssertEqual(replies.filter { $0.kind==4 && $0.scope == .output }.map { $0.number(2) },[0,0]);XCTAssertEqual(replies.filter { $0.kind==4 && $0.scope == .player }.last?.number(2),1)
    let before=snapshots;scalar=0.6;output.refresh();try await Task.sleep(for:.milliseconds(50));XCTAssertEqual(snapshots,before,"Output event resent playback metadata")
    model.channel("ble",token:nil) { _ in XCTFail("Retired") };_=model.receive(try command.encode(),channel:"ble");XCTAssertEqual(writes,1);XCTAssertNil(output.level)
  }
  @MainActor func testExplicitPackagedOutputVolumeRoundTrip() async throws {
    guard ProcessInfo.processInfo.environment["ANICE_RUN_OUTPUT_VOLUME_TEST"]=="1" else { throw XCTSkip("Requires packaged native output-volume acceptance") }
    guard let initial=OutputAudio.read() else { throw XCTSkip("Current audio output has no native writable volume") }
    defer { XCTAssertEqual(OutputAudio.write(initial,initial.scalar),0) }
    let model=MacPlaybackModel();model.presented("output-acceptance",true);defer { model.presented("output-acceptance",false) }
    try await Task.sleep(for:.seconds(3))
    guard !model.playback.source.isEmpty,let level=model.outputVolume.level else { throw XCTSkip("Requires genuine packaged playback") }
    let expected=min(level+1,100)
    var result:Int64?;model.commandOutputVolume(target:model.outputVolume.target,revision:model.outputVolume.revision,value:expected) { result=$0 }
    XCTAssertEqual(result,0);XCTAssertEqual(model.outputVolume.level,expected)
  }
}
