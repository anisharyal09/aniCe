// SPDX-License-Identifier: GPL-3.0-or-later
// Owns source selection, playback revisions, permissions and observation leases for the Mac application.
import AppKit
import Foundation
import Observation
import ImageIO
import CryptoKit
import CoreServices

struct MediaSource: Equatable, Identifiable {
  let id: String
  let pid: Int32
  let bundle: String
  let launched: Date?
  let name: String
  let playing: Bool
}
struct MediaPlayback: Equatable {
  var source = "", revision = "", title = "", artist = "", player = "", recording = ""
  var state: Int64 = 0, position: Int64 = -1, duration: Int64 = -1, rate: Int64 = 0, actions: Int64 = 0
  var sampledAt = ProcessInfo.processInfo.systemUptime
  var artworkHash = Data()
  func elapsed(at now: TimeInterval) -> Double {
    guard position >= 0 else { return 0 }
    let value = Double(position)/1000 + (state == 1 ? max(0,now-sampledAt)*Double(rate)/1000 : 0)
    return duration > 0 ? min(value, Double(duration)/1000) : value
  }
}
struct MediaPresence {
  private(set) var deadline: TimeInterval?
  mutating func update(genuine: Bool, state: Int64, now: TimeInterval) -> Bool {
    guard genuine, (1...2).contains(state) else { deadline=nil;return false }
    if state==1 { deadline=nil;return true }
    if deadline==nil { deadline=now+90 }
    return now < deadline!
  }
}
private final class PlaybackEvent: @unchecked Sendable {
  let event: NSAppleEventDescriptor
  init(_ event: NSAppleEventDescriptor) { self.event=event }
  func run() -> Bool {
    guard let reply = try? event.sendEvent(options:[.waitForReply,.neverInteract,.dontRecord], timeout:1) else { return false }
    return (reply.paramDescriptor(forKeyword:AEKeyword(keyErrorNumber))?.int32Value ?? 0)==0
  }
}
@Observable @MainActor final class MacPlaybackModel: FeatureHandler {
  func available(_ channel: any SecuredChannel) { let d=channel.descriptor; self.channel(d.transport,token:d.instance,send:channel.sendData) }
  func retired(_ descriptor: ChannelDescriptor) {
    guard sessionLink.isCurrent(descriptor.transport, token: descriptor.instance) else { return }
    channel(descriptor.transport,token:nil) { _ in throw SessionFailure.cancelled }
  }
  func capacityAvailable(_ descriptor: ChannelDescriptor) {
    guard sessionLink.isCurrent(descriptor.transport, token: descriptor.instance) else { return }
    capacity(descriptor.transport)
  }
  func handle(_ bytes: Data, on descriptor: ChannelDescriptor) async -> DataHandling {
    sessionLink.handle(bytes,channel:descriptor.transport,token:descriptor.instance)
  }
  let outputVolume: MacOutputVolume
  private(set) var playback = MediaPlayback()
  private(set) var sources: [MediaSource] = []
  private(set) var selection = ""
  private(set) var catalogue = UUID().uuidString
  private(set) var artwork: Data?
  private var cachedThumbnail: Data?
  private var cachedThumbnailHash = Data()
  private var artworkTask: Task<Void,Never>?
  private var artworkToken = UUID()
  private(set) var artworkImage: NSImage?
  private var idleStop: Task<Void,Never>?
  private var seekPreview: MediaPlayback?
  private var seekDeadline: Task<Void,Never>?
  var displayedPlayback: MediaPlayback { seekPreview ?? playback }
  private struct VolumeTarget: Hashable { let pid: Int32;let bundle: String;let launched: Date?;let property: UInt32 }
  private var verifiedVolumes = Set<VolumeTarget>()
  private var volumeState=PlayerVolumeState()
  var playerVolume: Int64? { volumeState.level }
  private(set) var volumeCandidate = false
  private(set) var volumeStatus = "Select a player to check volume support."
  private(set) var controlStatus = "No current playback."
  private var capabilityState = "discovering"
  private var nativeCapabilities: [String: Bool] = [:]
  private var routes = PlaybackRoutes(native:[:],scripting:nil,state:0,duration:-1)
  private var volumeProperty: PlaybackAutomationCapabilities.Position?
  private var volumeReading = false
  private var volumeWork: PlayerVolumeEvent?
  private var volumePreview = VolumePreview()
  private var volumePreviewDeadline: Task<Void,Never>?
  var displayedVolume: Int64? { volumePreview.value(at:ProcessInfo.processInfo.systemUptime) ?? playerVolume }
  private var presence=MediaPresence()
  private var pauseTask: Task<Void,Never>?
  private(set) var compactVisible = false
  private(set) var feedback = ""
  private(set) var busy = false
  private(set) var mainVisible = false
  private(set) var companionVisible = false
  private(set) var showOnMac: Bool
  private var companionInterested = false
  @ObservationIgnored private let preferences: UserDefaults
  private var mainInterested = false
  private var leases = Set<String>()
  @ObservationIgnored private lazy var bridge: MediaProcessBridge = {
    let bridge=MediaProcessBridge()
    bridge.received={ [weak self] bytes in self?.read(bytes) }
    bridge.failure={ [weak self] reason in self?.failed(reason) }
    bridge.started={ [weak self] in self?.feedback="" }
    return bridge
  }()
  @ObservationIgnored private lazy var sessionLink = MediaSessionLink(model:self)
  var phoneSubscribed: Bool { sessionLink.subscription != nil }
  private var operationID: UUID?
  private var nativeContext: PlaybackContext?
  private var lastNativeObservation: TimeInterval = 0
  private var pendingSample: PlaybackContext?
  private var permissionTarget: MediaSource?
  private var automation: PlaybackAutomationCapabilities?
  private var pending: (@MainActor (Int64)->Void)?
  private var validation: String?
  private var afterValidation: (@MainActor ()->Void)?
  private var commandDeadline: Task<Void,Never>?
  private var retry: Task<Void,Never>?
  private var retries = 0
  private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private let requestSink: (@MainActor (PlaybackRequest)->Bool)?
  init(preferences: UserDefaults = .standard, requestSink: (@MainActor (PlaybackRequest)->Bool)? = nil, outputVolume: MacOutputVolume? = nil) {
    self.outputVolume=outputVolume ?? MacOutputVolume()
    self.preferences=preferences
    self.showOnMac=preferences.bool(forKey:"media.showOnMac")
    self.requestSink=requestSink
    self.outputVolume.changed={ [weak self] in self?.sessionLink.publishOutput() }
    for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
      observers.append(NotificationCenter.default.addObserver(forName:name, object:nil, queue:.main) { [weak self] note in
        let window=note.object as? NSWindow
        MainActor.assumeIsolated {
          guard let self else { return }
          if name == NSApplication.didHideNotification { self.setLease("main",false); return }
          if name == NSApplication.didUnhideNotification {
            self.setLease("main",self.mainInterested && NSApp.windows.contains { ($0.title == "aniCe" || $0.identifier?.rawValue == "main") && $0.isVisible && !$0.isMiniaturized }); return
          }
          guard window?.title == "aniCe" || window?.identifier?.rawValue == "main" else { return }
          self.setLease("main",name == NSWindow.didDeminiaturizeNotification && self.mainInterested)
        }
      })
    }
  }
  func setShowOnMac(_ enabled: Bool) {
    guard enabled != showOnMac else { return }
    showOnMac=enabled; preferences.set(enabled,forKey:"media.showOnMac")
    presented("companion",companionInterested)
  }
  func presented(_ surface: String, _ visible: Bool) {
    if surface=="companion" { companionInterested=visible }
    if surface=="main" { mainInterested=visible }
    let shown = surface != "main" || (!NSApp.isHidden && !NSApp.windows.contains { ($0.title == "aniCe" || $0.identifier?.rawValue == "main") && $0.isMiniaturized })
    setLease(surface,visible && shown && (surface != "companion" || showOnMac))
  }
  private func setLease(_ surface: String, _ visible: Bool) {
    if surface=="main" { mainVisible=visible }
    if surface=="companion" { companionVisible=visible }
    if visible { leases.insert(surface) } else { leases.remove(surface) }
    idleStop?.cancel();idleStop=nil
    if leases.isEmpty && !phoneSubscribed {
      outputVolume.stop()
      idleStop=Task { [weak self] in
        do { try await Task.sleep(for:.seconds(30)) } catch { return }
        guard let self, self.leases.isEmpty, !self.phoneSubscribed else { return }
        self.stop()
      }
    } else { outputVolume.start();if !bridge.running && retry == nil { launch() } }
  }
  func retryObservation() { retries=0; retry?.cancel(); retry=nil; if !leases.isEmpty || phoneSubscribed { launch() } }
  func channel(_ kind: String, token: String?, send: @escaping @MainActor (Data) async throws -> Void) { sessionLink.channel(kind,token:token,send:send) }
  func capacity(_ kind: String) { sessionLink.capacity(kind) }
  func receive(_ data: Data, channel kind: String) -> Bool { sessionLink.handle(data,channel:kind) != .unrecognized }
  private func publish() { reconcileSeekPreview();refreshCompactPresence(); sessionLink.publish() }
  private func refreshCompactPresence() {
    let old=presence.deadline, now=ProcessInfo.processInfo.systemUptime
    compactVisible=presence.update(genuine:!playback.source.isEmpty,state:playback.state,now:now)
    guard presence.deadline != old else { return }
    pauseTask?.cancel();pauseTask=nil
    if let deadline=presence.deadline {
      pauseTask=Task { [weak self] in
        try? await Task.sleep(for:.seconds(max(0,deadline-now)))
        guard !Task.isCancelled, self?.presence.deadline==deadline else { return }
        self?.compactVisible=false;self?.pauseTask=nil
      }
    }
  }
  private func launch() {
    guard requestSink==nil, !bridge.running, !leases.isEmpty || phoneSubscribed else { return }
    bridge.launch()
  }
  private func stop() {
    idleStop?.cancel();idleStop=nil;artworkTask?.cancel();artworkTask=nil;artworkToken=UUID();artworkImage=nil;cachedThumbnailHash=Data();clearSeekPreview()
    lastNativeObservation=0
    outputVolume.stop();bridge.stop(); retry?.cancel(); retry=nil
    pauseTask?.cancel();pauseTask=nil;presence=MediaPresence();compactVisible=false
    volumePreview.clear();volumePreviewDeadline?.cancel();nativeCapabilities=[:];controlStatus="No current playback.";volumeStatus="Select a player to check volume support."
    finish(5); playback=MediaPlayback(); sources=[]; selection=""; catalogue=UUID().uuidString; nativeContext=nil; artwork=nil; cachedThumbnail=nil; permissionTarget=nil; automation=nil;volumeState=PlayerVolumeState();volumeCandidate=false;volumeProperty=nil
  }
  private func failed(_ reason: String) {
    stop(); feedback=reason; publish()
    guard (!leases.isEmpty || phoneSubscribed), retries<3 else { return }
    retries+=1
    retry=Task { [weak self] in try? await Task.sleep(for:.seconds(1)); guard !Task.isCancelled else { return }; self?.retry=nil; self?.launch() }
  }
  private func write(_ request: PlaybackRequest) -> Bool {
    var request=request; request.requestID=operationID
    guard let message=request.message, message.utf8.count<=2048 else { return false }
    if let requestSink { return requestSink(request) }
    return bridge.write(request)
  }

  private func trace(_ event: String) {
    #if DEBUG
    if ProcessInfo.processInfo.environment["ANICE_MEDIA_TIMING"]=="1" {
      NSLog("media %@ %.3f pid=%d source=%@ revision=%@ actions=%lld native=%lld scripting=%lld capability=%@ duration=%lld position=%lld",event,ProcessInfo.processInfo.systemUptime,permissionTarget?.pid ?? 0,playback.source,playback.revision,playback.actions,routes.native,routes.scripting,capabilityState,playback.duration,playback.position)
    }
    #endif
  }
  func read(_ bytes: Data) {
    guard let row=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any] else { failed("Invalid playback adapter reply"); return }
    if row["error"] != nil { failed("Playback metadata unavailable"); return }
    if let sent=row["sent"] as? Bool { if row["requestID"] as? String == operationID?.uuidString, operationID != nil { finish(sent ? 0:1) }; return }
    if let id=row["validationRequest"] as? String {
      guard id==validation else { return }; validation=nil
      if row["validationOK"] as? Bool==true { let action=afterValidation; afterValidation=nil; action?() } else { finish(1) }; return
    }
    if row["sampleOnly"] as? Bool==true, PlaybackContext(reply:row) != nativeContext { return }
    if row["capabilitiesOnly"] as? Bool != true, let started=row["observationStartedAt"] as? Double, started.isFinite {
      if PlaybackContext(reply:row)==nativeContext && started<lastNativeObservation { return }
      lastNativeObservation=started
    }
    func sample(_ key: String, scale: Double, max: Double, missing: Int64) -> Int64 {
      guard let number=row[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return missing }
      let value=number.doubleValue*scale; return value.isFinite && value>=0 && value<=max ? Int64(value):missing
    }
    if row["sampleOnly"] as? Bool == true {
      guard let context=PlaybackContext(reply:row), context==nativeContext, !playback.source.isEmpty else { return }
      let now=ProcessInfo.processInfo.systemUptime
      let continuing=playback.position>=0 ? Int64(min(604800000,playback.elapsed(at:now)*1000)) : -1
      playback.position=sample("kMRMediaRemoteNowPlayingInfoElapsedTime",scale:1000,max:604800000,missing:continuing)
      if row["kMRMediaRemoteNowPlayingInfoDuration"] != nil {
        playback.duration=sample("kMRMediaRemoteNowPlayingInfoDuration",scale:1000,max:604800000,missing:-1)
      }
      if playback.duration>0 { playback.position=min(playback.position,playback.duration) }
      if let playing=row["isPlaying"] as? Bool { playback.state=playing ? 1:2 }
      let oldActions=playback.actions
      playback.actions=resolvedActions(state:playback.state,duration:playback.duration)
      if oldActions != playback.actions { playback.revision=UUID().uuidString }
      playback.rate=sample("kMRMediaRemoteNowPlayingInfoPlaybackRate",scale:1000,max:16000,missing:playback.rate)
      if playback.state==2 { playback.rate=0 }
      playback.sampledAt=now;trace("sample"); publish(); return
    }
    if row["capabilitiesOnly"] as? Bool==true {
      guard PlaybackContext(reply:row)==nativeContext, !playback.source.isEmpty else { return }
      capabilityState=row["capabilityState"] as? String ?? "unavailable"
      // A discovery timeout carries no support verdict; only explicit values replace known capabilities.
      if capabilityState=="unsupported" { nativeCapabilities=[:] }
      else {
        for key in ["canSendCommandsDirectly","canToggle","canPlay","canPause","canSkipPrevious","canSkipNext","canSeek"] { if let value=row[key] as? Bool { nativeCapabilities[key]=value } }
      }
      let actions=resolvedActions(state:playback.state,duration:playback.duration)
      if actions != playback.actions { finish(1);playback.revision=UUID().uuidString;playback.actions=actions }
      trace("capabilities");publish();return
    }
    func bounded(_ text: String, _ max: Int) -> String {
      var result="";for character in text where character != "\0" { let next=result+String(character); if next.utf8.count>max { break }; result=next }; return result
    }
    let oldSources=sources
    sources=PlaybackSource.decode(row["sources"],selectedPID:PlaybackSource.decodePID(row["selectedPID"])).prefix(16).compactMap { item in
      guard let app=NSRunningApplication(processIdentifier:item.pid), !app.isTerminated else { return nil }
      let old=oldSources.first { $0.pid==item.pid && $0.bundle==item.bundleIdentifier && $0.launched==app.launchDate }
      return MediaSource(id:old?.id ?? UUID().uuidString,pid:item.pid,bundle:item.bundleIdentifier,launched:app.launchDate,name:bounded(item.displayName ?? app.localizedName ?? item.bundleIdentifier,96),playing:item.isPlaying)
    }
    if sources != oldSources { catalogue=UUID().uuidString }
    selection=(row["sourceIsAutomatic"] as? Bool)==false ? sources.first { $0.pid==PlaybackSource.decodePID(row["selectedPID"]) }?.id ?? "":""
    let context=PlaybackContext(reply:row)
    let source=sources.first { $0.pid==context?.pid }
    var next=MediaPlayback()
    if let source, let context {
      // Partial metadata may omit timing; retain it only within the native recording and process identity.
      let continuing=nativeContext==context && playback.source==source.id
      let position=continuing && playback.position>=0 ? Int64(playback.elapsed(at:next.sampledAt)*1000) : -1
      next.recording=context.revision.uuidString
      next.source=source.id; next.title=bounded(row["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? "",512)
      next.artist=bounded(row["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? "",256); next.player=source.name
      next.state=(row["isPlaying"] as? Bool).map { $0 ? 1:2 } ?? (continuing ? playback.state:0)
      next.position=sample("kMRMediaRemoteNowPlayingInfoElapsedTime",scale:1000,max:604800000,missing:row["kMRMediaRemoteNowPlayingInfoElapsedTime"]==nil ? position:-1)
      next.duration=sample("kMRMediaRemoteNowPlayingInfoDuration",scale:1000,max:604800000,missing:continuing && row["kMRMediaRemoteNowPlayingInfoDuration"]==nil ? playback.duration:-1)
      next.rate=sample("kMRMediaRemoteNowPlayingInfoPlaybackRate",scale:1000,max:16000,missing:continuing && row["kMRMediaRemoteNowPlayingInfoPlaybackRate"]==nil ? playback.rate:0)
      if next.duration>0 { next.position=min(next.position,next.duration) }
      if next.state==2 { next.rate=0 }
      permissionTarget=source
      if playback.source != next.source { automation=nil }
      capabilityState=row["capabilityState"] as? String ?? "ready"
      if playback.source != next.source || capabilityState=="unsupported" { nativeCapabilities=[:] }
      for key in ["canSendCommandsDirectly","canToggle","canPlay","canPause","canSkipPrevious","canSkipNext","canSeek"] { if let value=row[key] as? Bool { nativeCapabilities[key]=value } }
      if playback.source != next.source, let url=NSRunningApplication(processIdentifier:source.pid)?.bundleURL { automation=PlaybackAutomationCapabilities.load(bundleURL:url) }
      next.actions=resolvedActions(state:next.state,duration:next.duration)
      next.revision = nativeContext==context && playback.source==next.source && playback.actions==next.actions ? playback.revision:UUID().uuidString
      if nativeContext != context { prepareArtwork(nil,context:context) }
      if row["artworkUnchanged"] as? Bool==true {
        if let cachedThumbnail { artwork=cachedThumbnail;next.artworkHash=cachedThumbnailHash }
      } else if let base64=row["artworkBase64"] as? String {
        prepareArtwork(base64,context:context)
      } else if nativeContext==context, playback.source==next.source {
        // MediaRemote can omit artwork for a transient metadata sample; keep the last cover for this recording.
        next.artworkHash=playback.artworkHash
      } else {
        prepareArtwork(nil,context:context)
      }
    } else { prepareArtwork(nil,context:nil); permissionTarget=nil; automation=nil }
    if next.source != playback.source {
      volumePreview.clear();volumePreviewDeadline?.cancel();volumeState=PlayerVolumeState();volumeProperty=nil;volumeCandidate=false
      if let source, source.launched != nil, ["com.apple.Music","com.spotify.client"].contains(source.bundle),
        let url=NSRunningApplication(processIdentifier:source.pid)?.bundleURL {
        volumeProperty=PlaybackAutomationCapabilities.load(bundleURL:url)?.volume
        volumeCandidate=volumeProperty != nil
        if let property=volumeProperty, verifiedVolumes.contains(VolumeTarget(pid:source.pid,bundle:source.bundle,launched:source.launched,property:property.code)), permission(source,ask:false)==noErr { volumeState.restoreProof(true) }

      }
    }
    if volumeState.supported, let source, permission(source,ask:false) != noErr, volumeState.receive(result:4,level:nil) { next.revision=UUID().uuidString }
    if busy, playback.source != next.source || playback.revision != next.revision { finish(1) }
    nativeContext=context; playback=next
    if next.source.isEmpty { controlStatus="No current playback." }
    refreshVolumeStatus();publish();samplePlayerVolume()
  }
  private func prepareArtwork(_ base64: String?, context: PlaybackContext?) {
    artworkTask?.cancel();artworkToken=UUID()
    let token=artworkToken
    let sameRecording=nativeContext==context
    if !sameRecording { cachedThumbnail=nil;cachedThumbnailHash=Data();artwork=nil;artworkImage=nil }
    guard let base64, base64.utf8.count<=16*1024*1024 else { return }
    artworkTask=Task { [weak self] in
      guard !Task.isCancelled else { return }
      let worker=Task.detached(priority:.utility) {
        guard !Task.isCancelled, let data=Data(base64Encoded:base64), !Task.isCancelled,
          let thumbnail=Self.thumbnail(data), !Task.isCancelled else { return Optional<(Data,Data)>.none }
        return (thumbnail,Data(SHA256.hash(data:thumbnail)))
      }
      let prepared=await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
      guard !Task.isCancelled, let self, self.artworkToken==token, self.nativeContext==context else { return }
      guard let (bytes,hash)=prepared else { return }
      if self.cachedThumbnail != nil, self.cachedThumbnailHash==hash {
        self.playback.artworkHash=hash;self.publish();return
      }
      self.cachedThumbnail=bytes;self.cachedThumbnailHash=hash;self.artwork=bytes
      self.artworkImage=NSImage(data:bytes);self.playback.artworkHash=hash;self.publish()
    }
  }
  private func clearSeekPreview() { seekPreview=nil;seekDeadline?.cancel();seekDeadline=nil }
  private func reconcileSeekPreview() {
    guard let preview=seekPreview else { return }
    if preview.source != playback.source || preview.revision != playback.revision || abs(preview.elapsed(at:ProcessInfo.processInfo.systemUptime)-playback.elapsed(at:ProcessInfo.processInfo.systemUptime))<=1 { clearSeekPreview() }
  }
  private func resolvedActions(state: Int64, duration: Int64) -> Int64 {
    routes=PlaybackRoutes(native:nativeCapabilities,scripting:automation,state:state,duration:duration)
    var actions=routes.actions
    if routes.scripting & ~routes.native != 0, let target=permissionTarget, permission(target,ask:false) != noErr { actions |= 16 }
    controlStatus=actions & 16 != 0 ? "Some controls require permission on this Mac.":actions & 15 != 0 ? "Directed playback controls available.":capabilityState=="discovering" ? "Discovering this player’s controls…":capabilityState=="unavailable" ? "Player controls temporarily unavailable. Refresh to check again.":"This player has no supported directed controls."
    return actions
  }
  func refreshCapabilities() {
    guard !busy else { return }
    outputVolume.refresh();samplePlayerVolume()
    if !write(PlaybackRequest(command:.refresh)) { feedback="Player refresh unavailable. Retry observation." }
  }
  nonisolated static func thumbnail(_ data: Data) -> Data? {
    guard data.count<=12*1024*1024, let source=CGImageSourceCreateWithData(data as CFData,nil),
      let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:256,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else { return nil }
    let bitmap=NSBitmapImageRep(cgImage:image)
    for quality in [0.8,0.6,0.4] { if let result=bitmap.representation(using:.jpeg,properties:[.compressionFactor:quality]), result.count<=65536 { return result } }
    return nil
  }
  private func permission(_ source: MediaSource, ask: Bool) -> OSStatus {
    guard let app=NSRunningApplication(processIdentifier:source.pid), !app.isTerminated, app.launchDate==source.launched else { return OSStatus(errAEEventNotPermitted) }
    return AEDeterminePermissionToAutomateTarget(NSAppleEventDescriptor(processIdentifier:source.pid).aeDesc,typeWildCard,typeWildCard,ask)
  }
  func requestPermission() {
    guard let source=permissionTarget, automation != nil || volumeCandidate else { return }
    let status=permission(source,ask:true); feedback=status==noErr ? "Playback control allowed":"Playback permission was not granted"
    if status==noErr { playback.actions=resolvedActions(state:playback.state,duration:playback.duration);refreshVolumeStatus(); playback.revision=UUID().uuidString; publish();if volumeCandidate { if volumeState.proven { samplePlayerVolume() } else { verifyPlayerVolume() } } }
  }
  func command(source: String, revision: String, action: Int64, value: Int64=0, completion: @escaping @MainActor (Int64)->Void = { _ in }) {
    trace("command")
    guard !busy else { completion(6); return }
    if action==5 || action==6 {
      guard revision==catalogue else { completion(1); return }
      let target=sources.first { $0.id==source }
      guard action==6 || target != nil else { completion(1); return }
      if let target { guard let app=NSRunningApplication(processIdentifier:target.pid), !app.isTerminated, app.launchDate==target.launched, app.bundleIdentifier==target.bundle else { completion(1); return } }
      operationID=UUID(); busy=true; pending=completion
      let selected=target.map { PlaybackSource.Selection(pid:$0.pid,bundleIdentifier:$0.bundle) }
      let sent=write(PlaybackRequest(command:.source(action==6 ? nil:selected)))
      if !sent { finish(5) } else { startDeadline() }; return
    }
    guard source==playback.source, revision==playback.revision, let context=nativeContext else { completion(1); return }
    let mask: Int64 = action==1 ? 1:action==2 ? 2:action==3 ? 4:action==4 ? 8:0
    guard mask != 0, playback.actions & mask != 0 else { completion(2); return }
    guard action != 4 || (value>=0 && value<=playback.duration) else { completion(1); return }
    let command: PlaybackCommand = action==1 ? .toggle:action==2 ? .previous:action==3 ? .next:.seek(Double(value)/1000)
    if routes.usesScripting(action), let automation, let target=permissionTarget {
      let access=permission(target,ask:false)
      guard access==noErr else { feedback="Allow playback control on this Mac"; completion(access==OSStatus(errAEEventNotPermitted) ? 4:3); return }
      operationID=UUID(); busy=true; pending=completion; pendingSample=context; validation=UUID().uuidString
      afterValidation = { [weak self] in
        guard let self, self.playback.source==source, self.playback.revision==revision, let app=NSRunningApplication(processIdentifier:target.pid), app.launchDate==target.launched else { self?.finish(1); return }
        let address=NSAppleEventDescriptor(processIdentifier:target.pid)
        let event: NSAppleEventDescriptor
        if case .seek(let position)=command, let property=automation.position {
          event=NSAppleEventDescriptor(eventClass:kAECoreSuite,eventID:kAESetData,targetDescriptor:address,returnID:AEReturnID(kAutoGenerateReturnID),transactionID:AETransactionID(kAnyTransactionID))
          let object=NSAppleEventDescriptor.record()
          object.setDescriptor(NSAppleEventDescriptor(typeCode:typeProperty),forKeyword:AEKeyword(keyAEDesiredClass))
          object.setDescriptor(NSAppleEventDescriptor(enumCode:OSType(formPropertyID)),forKeyword:AEKeyword(keyAEKeyForm))
          object.setDescriptor(NSAppleEventDescriptor(typeCode:property.code),forKeyword:AEKeyword(keyAEKeyData))
          object.setDescriptor(NSAppleEventDescriptor.null(),forKeyword:AEKeyword(keyAEContainer))
          guard let propertyObject=object.coerce(toDescriptorType:typeObjectSpecifier) else { self.finish(2); return }
          event.setParam(propertyObject,forKeyword:AEKeyword(keyDirectObject))
          event.setParam(property.integer ? NSAppleEventDescriptor(int32:Int32(position.rounded())):NSAppleEventDescriptor(double:position),forKeyword:AEKeyword(keyAEData))
        } else if let code=automation.event(for:command,isPlaying:self.playback.state==1) {
          event=NSAppleEventDescriptor(eventClass:code.eventClass,eventID:code.eventID,targetDescriptor:address,returnID:AEReturnID(kAutoGenerateReturnID),transactionID:AETransactionID(kAnyTransactionID))
        } else { self.finish(2); return }
        guard self.permission(target,ask:false)==noErr, self.pending != nil else { self.finish(4); return }
        let work=PlaybackEvent(event), gen=self.bridge.generation, operation=self.operationID
        DispatchQueue.global().async { [weak self] in let success=work.run(); Task { @MainActor [weak self] in if self?.bridge.generation==gen, self?.operationID==operation, operation != nil { self?.finish(success ? 0:7) } } }
      }
      guard write(PlaybackRequest(command:.validate(UUID(uuidString:validation!)!,context))) else { finish(5); return }
    } else {
      operationID=UUID(); busy=true; pending=completion; pendingSample=context
      guard write(PlaybackRequest(command:command,context:context)) else { finish(5); return }
    }
    if action==4 {
      var preview=playback;preview.position=value;preview.sampledAt=ProcessInfo.processInfo.systemUptime
      seekPreview=preview;seekDeadline?.cancel()
      seekDeadline=Task { [weak self] in
        do { try await Task.sleep(for:.seconds(6)) } catch { return }
        self?.clearSeekPreview();self?.feedback="Seek was not confirmed. Showing the player’s latest position."
      }
    }
    startDeadline()
  }
  func verifyPlayerVolume() { volumeOperation(value:nil,source:playback.source,revision:playback.revision) { [weak self] result in
    self?.feedback=result==0 ? "Player volume verified":result==3 || result==4 ? "Allow player volume control on this Mac":"Player volume could not be verified"
  } }
  func commandOutputVolume(target: String, revision: String, value: Int64, completion: @escaping @MainActor (Int64)->Void) {
    guard !playback.source.isEmpty else { completion(5);return }
    guard !busy else { completion(6);return }
    completion(outputVolume.command(target:target,revision:revision,value:value));sessionLink.publishOutput()
  }
  func commandVolume(source: String, revision: String, value: Int64, completion: @escaping @MainActor (Int64)->Void) {
    guard source==playback.source, revision==playback.revision else { completion(1);return }
    guard playerVolume != nil else { completion(2);return }
    guard (0...100).contains(value) else { completion(1);return }
    guard !busy else { completion(6);return }
    volumePreview.begin(value,now:ProcessInfo.processInfo.systemUptime)
    volumePreviewDeadline?.cancel()
    volumePreviewDeadline=Task { [weak self] in
      try? await Task.sleep(for:.seconds(6));guard !Task.isCancelled, let self, self.volumePreview.pending else { return }
      self.volumePreview.clear();self.feedback="Volume was not confirmed. Showing the player’s latest value."
    }
    volumeOperation(value:value,source:source,revision:revision) { [weak self] result in if result != 0 { self?.volumePreview.clear() };completion(result) }
  }
  private func volumeOperation(value: Int64?, source: String, revision: String, completion: @escaping @MainActor (Int64)->Void) {
    guard !busy else { completion(6);return }
    guard source==playback.source, revision==playback.revision, let context=nativeContext, let target=permissionTarget else { completion(1);return }
    guard volumeCandidate, let property=volumeProperty else { completion(2);return }
    let access=permission(target,ask:false)
    guard access==noErr else { completion(access==OSStatus(errAEEventNotPermitted) ? 4:3);return }
    operationID=UUID();busy=true;pending=completion;validation=UUID().uuidString
    afterValidation={ [weak self] in
      guard let self, self.playback.source==source, self.playback.revision==revision, self.permission(target,ask:false)==noErr else { self?.finish(1);return }
      let work=PlayerVolumeEvent(target:target,property:property.code), generation=self.bridge.generation, operation=self.operationID
      self.volumeWork=work
      DispatchQueue.global().async { [weak self] in
        let (result,level)=work.run(value:value)
        Task { @MainActor [weak self] in
          guard let self, self.bridge.generation==generation, self.operationID==operation else { return }
          guard self.playback.source==source, self.playback.revision==revision, self.permission(target,ask:false)==noErr else { self.finish(1);return }
          if result==0, let level {
            if self.volumeState.receive(result:0,level:level) { self.playback.revision=UUID().uuidString }
            self.volumePreview.confirm(level)
            if self.verifiedVolumes.count>=16 { self.verifiedVolumes.removeAll() }
            self.verifiedVolumes.insert(VolumeTarget(pid:target.pid,bundle:target.bundle,launched:target.launched,property:property.code))
          } else if self.volumeState.receive(result:result,level:nil) { self.playback.revision=UUID().uuidString }
          if result != 0 { self.volumePreview.clear() }
          self.refreshVolumeStatus();self.finish(result);self.publish()
        }
      }
    }
    guard write(PlaybackRequest(command:.validate(UUID(uuidString:validation!)!,context))) else { finish(5);return }
    startDeadline()
  }
  private func refreshVolumeStatus() {
    guard let target=permissionTarget, !playback.source.isEmpty else { volumeStatus="Select a player to check volume support.";return }
    if !volumeCandidate { volumeStatus="Player volume is unsupported for this player; Mac output volume is separate." }
    else if permission(target,ask:false) != noErr { volumeStatus="Allow player volume control on this Mac." }
    else if playerVolume != nil { volumeStatus="Selected-player volume available." }
    else if !verifiedVolumes.contains(VolumeTarget(pid:target.pid,bundle:target.bundle,launched:target.launched,property:volumeProperty?.code ?? 0)) { volumeStatus="Verify this player’s volume on this Mac." }
    else { volumeStatus="Player volume temporarily unavailable. Refresh to read it again." }
  }
  private func samplePlayerVolume() {
    guard !busy, !volumeReading, let target=permissionTarget, let property=volumeProperty,
      verifiedVolumes.contains(VolumeTarget(pid:target.pid,bundle:target.bundle,launched:target.launched,property:property.code)), volumeState.canRead(permitted:permission(target,ask:false)==noErr) else { return }
    volumeReading=true
    let source=playback.source, revision=playback.revision, generation=bridge.generation
    let work=PlayerVolumeEvent(target:target,property:property.code)
    DispatchQueue.global().async { [weak self] in
      let (result,level)=work.read()
      Task { @MainActor [weak self] in
        guard let self else { return };self.volumeReading=false
        guard self.bridge.generation==generation, self.playback.source==source, self.playback.revision==revision, !self.busy else { return }
        if self.volumeState.receive(result:result,level:level) { self.playback.revision=UUID().uuidString }
        if result==0 { self.volumePreview.confirm(level) }
        self.refreshVolumeStatus();self.publish()
      }
    }
  }
  private func startDeadline() {
    let operation=operationID
    commandDeadline=Task { [weak self] in try? await Task.sleep(for:.seconds(4)); if !Task.isCancelled, self?.operationID==operation { self?.finish(7) } }
  }
  func finish(_ result: Int64) {
    trace("result \(result)")
    if result != 0 { clearSeekPreview() }
    volumeWork?.cancel();volumeWork=nil
    let refresh=pendingSample; pendingSample=nil
    let completion=pending; pending=nil; operationID=nil; busy=false; validation=nil; afterValidation=nil; commandDeadline?.cancel(); commandDeadline=nil
    if completion != nil { feedback=result==0 ? "":result==1 ? "Playback changed. Try again.":result==3 || result==4 ? "Allow playback control on this Mac":"Playback action could not be completed" }
    completion?(result)
    if result==0, let refresh, nativeContext==refresh { _ = write(PlaybackRequest(command:.sample,context:refresh)) }
  }
}
