// SPDX-License-Identifier: GPL-3.0-or-later
// Owns one event-driven playback adapter, immutable command targets and bounded foreground media subscriptions.
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
  var source = "", revision = "", title = "", artist = "", player = ""
  var state: Int64 = 0, position: Int64 = -1, duration: Int64 = -1, rate: Int64 = 0, actions: Int64 = 0
  var sampledAt = ProcessInfo.processInfo.systemUptime
  var artworkHash = Data()
  func elapsed(at now: TimeInterval) -> Double {
    guard position >= 0 else { return 0 }
    let value = Double(position)/1000 + (state == 1 ? max(0,now-sampledAt)*Double(rate)/1000 : 0)
    return duration > 0 ? min(value, Double(duration)/1000) : value
  }
}
@MainActor private final class MediaLink {
  let token: String
  let send: @MainActor (Data) async throws -> Void
  var controls: [MediaMessage] = []
  var snapshot: MediaMessage?
  var artwork = Data(), hash = Data()
  var artworkRevision = ""
  var offset = 0
  var sending = false
  var wake = false
  init(token: String, send: @escaping @MainActor (Data) async throws -> Void) { self.token=token; self.send=send }
}
private final class PlaybackPipe: @unchecked Sendable {
  private let lock = NSLock()
  private var bytes = Data()
  func append(_ data: Data) -> [Data]? {
    lock.lock(); defer { lock.unlock() }
    guard bytes.count + data.count <= 17*1024*1024 else { return nil }
    bytes.append(data); var result: [Data] = []
    while let i = bytes.firstIndex(of:10) { result.append(Data(bytes.prefix(upTo:i))); bytes.removeSubrange(...i) }
    return result
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
@Observable @MainActor final class MacPlayback {
  private(set) var playback = MediaPlayback()
  private(set) var sources: [MediaSource] = []
  private(set) var selection = ""
  private(set) var catalogue = UUID().uuidString
  private(set) var artwork: Data?
  private var cachedThumbnail: Data?
  private(set) var feedback = ""
  private(set) var busy = false
  private(set) var mainVisible = false
  private(set) var companionVisible = false
  private(set) var showOnMac: Bool
  private var companionInterested = false
  @ObservationIgnored private let preferences: UserDefaults
  private var mainInterested = false
  private var leases = Set<String>()
  private var links: [String:MediaLink] = [:]
  private var subscribed: String?
  private var subscription: String?
  var phoneSubscribed: Bool { subscription != nil }
  private var inFlight = Set<Int64>()
  private var operationID: UUID?
  private var highWater: Int64 = 0
  private var results: [Int64:Int64] = [:]
  private var resultOrder: [Int64] = []
  private var process: Process?
  private var input: FileHandle?
  private var output: FileHandle?
  private var generation = UUID()
  private var nativeContext: PlaybackContext?
  private var pendingSample: PlaybackContext?
  private var playPauseSupport = (toggle:false, play:false, pause:false)
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
  init(preferences: UserDefaults = .standard, requestSink: (@MainActor (PlaybackRequest)->Bool)? = nil) {
    self.preferences=preferences
    self.showOnMac=preferences.bool(forKey:"media.showOnMac")
    self.requestSink=requestSink
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
    if leases.isEmpty && subscription == nil { stop() } else if process == nil && retry == nil { launch() }
  }
  func retryObservation() { retries=0; retry?.cancel(); retry=nil; if !leases.isEmpty || subscription != nil { launch() } }
  func channel(_ kind: String, token: String?, send: @escaping @MainActor (Data) async throws -> Void) {
    if links[kind]?.token == token { return }
    if subscribed == kind { retireSubscription() }
    links[kind] = token.map { MediaLink(token:$0,send:send) }
    if let link=links[kind] { link.controls=[MediaMessage(kind:1,fields:[.integer(1),.bool(kind=="lan")])]; pump(kind) }
  }
  func capacity(_ kind: String) { if let link=links[kind], link.sending { link.wake=true } else { pump(kind) } }
  func receive(_ data: Data, channel kind: String) -> Bool {
    guard let message = try? MediaMessage.decode(data) else { return false }
    guard let link = links[kind] else { return true }
    switch message.kind {
    case 2:
      if subscribed != kind || subscription != message.string(0) {
        retireSubscription(); subscribed=kind; subscription=message.string(0); highWater=0; results=[:]; resultOrder=[]
      }
      enqueue(MediaMessage(kind:3,fields:[.text(message.string(0))]),kind)
      presented("remote",true); publish()
    case 4: if subscribed==kind && subscription==message.string(0) { retireSubscription() }
    case 6:
      guard subscribed==kind, subscription==message.string(0) else { return true }
      let id=message.number(1), sub=message.string(0), token=link.token
      if inFlight.contains(id) { return true }
      if let result=results[id] { enqueue(MediaMessage(kind:7,fields:[.text(sub),.integer(id),.integer(result)]),kind); return true }
      guard id>highWater else { enqueue(MediaMessage(kind:7,fields:[.text(sub),.integer(id),.integer(1)]),kind); return true }
      highWater=id; inFlight.insert(id)
      let finish: @MainActor (Int64)->Void = { [weak self] result in
        guard let self, self.links[kind]?.token==token, self.subscribed==kind, self.subscription==sub else { return }
        self.inFlight.remove(id)
        self.results[id]=result; self.resultOrder.append(id)
        if self.resultOrder.count>32 { self.results[self.resultOrder.removeFirst()]=nil }
        self.enqueue(MediaMessage(kind:7,fields:[.text(sub),.integer(id),.integer(result)]),kind)
      }
      if link.controls.count>=12 { finish(6) }
      else { command(source:message.string(2),revision:message.string(3),action:message.number(4),value:message.number(5),completion:finish) }
    default: break
    }
    return true
  }
  private func retireSubscription() {
    if let kind=subscribed { links[kind]?.snapshot=nil; links[kind]?.artwork=Data(); links[kind]?.hash=Data(); links[kind]?.controls.removeAll { $0.kind != 1 } }
    finish(5); inFlight.removeAll()
    subscription=nil; subscribed=nil; highWater=0; results=[:]; resultOrder=[]; presented("remote",false)
  }
  private func enqueue(_ message: MediaMessage, _ kind: String) {
    guard let link=links[kind] else { return }
    if link.controls.count<16 { link.controls.append(message) }
    pump(kind)
  }
  private func snapshot(_ sub: String, artwork: Bool) -> MediaMessage {
    MediaMessage(kind:5,fields:[.text(sub),.text(playback.source),.text(playback.revision),.text(playback.title),.text(playback.artist),.text(playback.player),
      .integer(playback.state),.integer(playback.position),.integer(playback.duration),.integer(playback.rate),.integer(playback.actions),.text(selection),.text(catalogue),
      .array(sources.map { .array([.text($0.id),.text($0.name),.integer($0.playing ? 1:2)]) }),.bytes(artwork ? playback.artworkHash:Data())])
  }
  private func publish() {
    guard let kind=subscribed, let sub=subscription, let link=links[kind] else { return }
    link.snapshot=snapshot(sub,artwork:kind=="lan")
    if kind=="lan", link.hash != playback.artworkHash || link.artworkRevision != playback.revision {
      link.artworkRevision=playback.revision; link.hash=playback.artworkHash; link.artwork=artwork ?? Data(); link.offset=0
    }
    pump(kind)
  }
  private func pump(_ kind: String) {
    guard let link=links[kind], !link.sending else { return }
    link.sending=true
    Task { [weak self, weak link] in
      guard let self, let link else { return }; defer { link.sending=false; if link.wake { link.wake=false; self.pump(kind) } }
      while self.links[kind] === link {
        let message: MediaMessage
        let priority: Int
        if let first=link.controls.first { message=first; priority=0 }
        else if let snapshot=link.snapshot { message=snapshot; priority=1 }
        else if kind=="lan", self.subscribed==kind, let sub=self.subscription, link.offset<link.artwork.count, !self.playback.source.isEmpty {
          let end=min(link.artwork.count,link.offset+2048)
          message=MediaMessage(kind:8,fields:[.text(sub),.text(self.playback.source),.text(self.playback.revision),.bytes(link.hash),.integer(Int64(link.artwork.count)),.integer(Int64(link.offset)),.bytes(link.artwork.subdata(in:link.offset..<end))]); priority=2
        } else { return }
        do { try await link.send(message.encode()) }
        catch is SessionBackpressure { return }
        catch { return }
        guard self.links[kind] === link else { return }
        if priority==0 { if link.controls.first==message { link.controls.removeFirst() } }
        else if priority==1 { if link.snapshot==message { link.snapshot=nil } }
        else if message.fields[3] == .bytes(link.hash), message.string(2)==link.artworkRevision { link.offset += (try? message.fields[6].bytes().count) ?? 0 }
      }
    }
  }
  private func launch() {
    guard requestSink==nil, process==nil, !leases.isEmpty || subscription != nil else { return }
    guard let root=Bundle.main.resourceURL?.appendingPathComponent("NowPlaying") else { feedback="Playback adapter unavailable"; return }
    let child=Process(), incoming=Pipe(), outgoing=Pipe(), reader=PlaybackPipe(), gen=UUID()
    generation=gen
    guard fcntl(incoming.fileHandleForWriting.fileDescriptor,F_SETNOSIGPIPE,1) != -1 else { feedback="Playback pipe unavailable"; return }
    child.executableURL=URL(fileURLWithPath:"/usr/bin/perl")
    child.arguments=[root.appendingPathComponent("now-playing.pl").path,root.appendingPathComponent("libaniCeNowPlaying.dylib").path,"watch_all"]
    child.standardInput=incoming; child.standardOutput=outgoing; child.standardError=FileHandle.nullDevice
    process=child; input=incoming.fileHandleForWriting; output=outgoing.fileHandleForReading
    outgoing.fileHandleForReading.readabilityHandler = { [weak self] file in
      let data=file.availableData
      if data.isEmpty { file.readabilityHandler=nil; return }
      guard let lines=reader.append(data) else { Task { @MainActor in if self?.generation==gen { self?.failed("Playback adapter output exceeded its limit") } }; return }
      for line in lines { Task { @MainActor [weak self] in guard self?.generation==gen else { return }; self?.read(line) } }
    }
    child.terminationHandler = { [weak self] _ in Task { @MainActor in if self?.generation==gen { self?.failed("Playback adapter stopped") } } }
    do { try child.run(); feedback="" } catch { failed("Playback adapter could not start") }
  }
  private func stop() {
    generation=UUID(); retry?.cancel(); retry=nil
    output?.readabilityHandler=nil; try? input?.close(); try? output?.close(); input=nil; output=nil
    if process?.isRunning==true { process?.terminate() }; process=nil
    finish(5); playback=MediaPlayback(); sources=[]; selection=""; catalogue=UUID().uuidString; nativeContext=nil; artwork=nil; cachedThumbnail=nil; permissionTarget=nil; automation=nil
  }
  private func failed(_ reason: String) {
    stop(); feedback=reason; publish()
    guard (!leases.isEmpty || subscription != nil), retries<3 else { return }
    retries+=1
    retry=Task { [weak self] in try? await Task.sleep(for:.seconds(1)); guard !Task.isCancelled else { return }; self?.retry=nil; self?.launch() }
  }
  private func write(_ request: PlaybackRequest) -> Bool {
    var request=request; request.requestID=operationID
    guard let message=request.message, message.utf8.count<=2048 else { return false }
    if let requestSink { return requestSink(request) }
    guard let input, process?.isRunning==true else { return false }
    do { try input.write(contentsOf:Data((message+"\n").utf8)); return true } catch { return false }
  }
  func read(_ bytes: Data) {
    guard let row=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any] else { failed("Invalid playback adapter reply"); return }
    if row["error"] != nil { failed("Playback metadata unavailable"); return }
    if let sent=row["sent"] as? Bool { if row["requestID"] as? String == operationID?.uuidString, operationID != nil { finish(sent ? 0:1) }; return }
    if let id=row["validationRequest"] as? String {
      guard id==validation else { return }; validation=nil
      if row["validationOK"] as? Bool==true { let action=afterValidation; afterValidation=nil; action?() } else { finish(1) }; return
    }
    func sample(_ key: String, scale: Double, max: Double, missing: Int64) -> Int64 {
      guard let number=row[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return missing }
      let value=number.doubleValue*scale; return value.isFinite && value>=0 && value<=max ? Int64(value):missing
    }
    if row["sampleOnly"] as? Bool == true {
      guard let context=PlaybackContext(reply:row), context==nativeContext, !playback.source.isEmpty else { return }
      let now=ProcessInfo.processInfo.systemUptime
      let continuing=Int64(playback.elapsed(at:now)*1000)
      playback.position=sample("kMRMediaRemoteNowPlayingInfoElapsedTime",scale:1000,max:604800000,missing:continuing)
      if playback.duration>0 { playback.position=min(playback.position,playback.duration) }
      if let playing=row["isPlaying"] as? Bool { playback.state=playing ? 1:2 }
      let canToggle = automation.map { $0.commands["playpause"] != nil || $0.commands[playback.state==1 ? "pause":"play"] != nil }
        ?? (playPauseSupport.toggle || (playback.state==1 && playPauseSupport.pause) || (playback.state==2 && playPauseSupport.play))
      let oldActions=playback.actions
      if canToggle { playback.actions |= 1 } else { playback.actions &= ~1 }
      if oldActions != playback.actions { playback.revision=UUID().uuidString }
      playback.rate=sample("kMRMediaRemoteNowPlayingInfoPlaybackRate",scale:1000,max:16000,missing:playback.rate)
      if playback.state==2 { playback.rate=0 }
      playback.sampledAt=now; publish(); return
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
      next.source=source.id; next.title=bounded(row["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? "",512)
      next.artist=bounded(row["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? "",256); next.player=source.name
      next.state=(row["isPlaying"] as? Bool).map { $0 ? 1:2 } ?? 0
      next.position=sample("kMRMediaRemoteNowPlayingInfoElapsedTime",scale:1000,max:604800000,missing:-1)
      next.duration=sample("kMRMediaRemoteNowPlayingInfoDuration",scale:1000,max:604800000,missing:-1)
      next.rate=sample("kMRMediaRemoteNowPlayingInfoPlaybackRate",scale:1000,max:16000,missing:0)
      permissionTarget=source; automation=nil
      playPauseSupport=(row["canToggle"] as? Bool==true,row["canPlay"] as? Bool==true,row["canPause"] as? Bool==true)
      if row["canSendCommandsDirectly"] as? Bool==true {
        if row["canToggle"] as? Bool==true || (next.state==1 && row["canPause"] as? Bool==true) || (next.state==2 && row["canPlay"] as? Bool==true) { next.actions |= 1 }
        if row["canSkipPrevious"] as? Bool==true { next.actions |= 2 }
        if row["canSkipNext"] as? Bool==true { next.actions |= 4 }
        if row["canSeek"] as? Bool==true && next.duration>0 { next.actions |= 8 }
      } else if let url=NSRunningApplication(processIdentifier:source.pid)?.bundleURL, let capabilities=PlaybackAutomationCapabilities.load(bundleURL:url) {
        automation=capabilities
        if capabilities.commands["playpause"] != nil || (next.state==1 && capabilities.commands["pause"] != nil) || (next.state==2 && capabilities.commands["play"] != nil) { next.actions |= 1 }; if capabilities.commands["previous track"] != nil { next.actions |= 2 }
        if capabilities.commands["next track"] != nil { next.actions |= 4 }; if capabilities.position != nil && next.duration>0 { next.actions |= 8 }
        if permission(source,ask:false) != noErr { next.actions |= 16 }
      }
      next.revision = nativeContext==context && playback.source==next.source && playback.actions==next.actions ? playback.revision:UUID().uuidString
      if row["artworkUnchanged"] as? Bool==true, let cachedThumbnail { artwork=cachedThumbnail; next.artworkHash=Data(SHA256.hash(data:cachedThumbnail)) }
      else if let base64=row["artworkBase64"] as? String, base64.utf8.count<=16*1024*1024, let data=Data(base64Encoded:base64), let thumbnail=Self.thumbnail(data) {
        artwork=thumbnail; cachedThumbnail=thumbnail; next.artworkHash=Data(SHA256.hash(data:thumbnail))
      } else { artwork=nil; if row["artworkUnchanged"] as? Bool != true { cachedThumbnail=nil } }
    } else { artwork=nil; permissionTarget=nil; automation=nil }
    if busy, playback.source != next.source || playback.revision != next.revision { finish(1) }
    nativeContext=context; playback=next; publish()
  }
  static func thumbnail(_ data: Data) -> Data? {
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
    guard let source=permissionTarget, automation != nil else { return }
    let status=permission(source,ask:true); feedback=status==noErr ? "Playback control allowed":"Playback permission was not granted"
    if status==noErr { playback.actions &= ~16; playback.revision=UUID().uuidString; publish() }
  }
  func command(source: String, revision: String, action: Int64, value: Int64=0, completion: @escaping @MainActor (Int64)->Void = { _ in }) {
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
    if let automation, let target=permissionTarget {
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
        let work=PlaybackEvent(event), gen=self.generation, operation=self.operationID
        DispatchQueue.global().async { [weak self] in let success=work.run(); Task { @MainActor [weak self] in if self?.generation==gen, self?.operationID==operation, operation != nil { self?.finish(success ? 0:7) } } }
      }
      guard write(PlaybackRequest(command:.validate(UUID(uuidString:validation!)!,context))) else { finish(5); return }
    } else {
      operationID=UUID(); busy=true; pending=completion; pendingSample=context
      guard write(PlaybackRequest(command:command,context:context)) else { finish(5); return }
    }
    startDeadline()
  }
  private func startDeadline() {
    let operation=operationID
    commandDeadline=Task { [weak self] in try? await Task.sleep(for:.seconds(4)); if !Task.isCancelled, self?.operationID==operation { self?.finish(7) } }
  }
  private func finish(_ result: Int64) {
    let refresh=pendingSample; pendingSample=nil
    let completion=pending; pending=nil; operationID=nil; busy=false; validation=nil; afterValidation=nil; commandDeadline?.cancel(); commandDeadline=nil
    if completion != nil { feedback=result==0 ? "":result==1 ? "Playback changed. Try again.":result==3 || result==4 ? "Allow playback control on this Mac":"Playback action could not be completed" }
    completion?(result)
    if result==0, let refresh, nativeContext==refresh { _ = write(PlaybackRequest(command:.sample,context:refresh)) }
  }
}
