// SPDX-License-Identifier: GPL-3.0-or-later
// Owns media subscription identity, bounded command deduplication and coalesced pre-seal submissions.
import Foundation
import Observation

@MainActor private final class MediaLink {
  let token: String
  let send: @MainActor (Data) async throws -> Void
  var controls: [MediaMessage] = []
  var volumeControls: [PlayerVolumeMessage] = []
  var volumeSnapshot: PlayerVolumeMessage?
  var volumeCompatible = false
  var outputCompatible = false
  var outputSnapshot: PlayerVolumeMessage?
  var snapshot: MediaMessage?
  var artwork = Data(), hash = Data()
  var artworkRevision = ""
  var offset = 0
  var sending = false
  var wake = false
  init(token: String, send: @escaping @MainActor (Data) async throws -> Void) { self.token=token; self.send=send }
}
@Observable @MainActor final class MediaSessionLink {
  private unowned let model: MacPlaybackModel
  init(model: MacPlaybackModel) { self.model=model }
  private var playback: MediaPlayback { model.playback }
  private var sources: [MediaSource] { model.sources }
  private var selection: String { model.selection }
  private var catalogue: String { model.catalogue }
  private var artwork: Data? { model.artwork }
  private var links: [String:MediaLink] = [:]
  private var subscribed: String?
  private(set) var subscription: String?
  private var inFlight = Set<Int64>()
  private var highWater: Int64 = 0
  private var results: [Int64:Int64] = [:]
  private var resultOrder: [Int64] = []
  private var resultKinds: [Int64:Int] = [:]
  func channel(_ kind: String, token: String?, send: @escaping @MainActor (Data) async throws -> Void) {
    if links[kind]?.token == token { return }
    if subscribed == kind { retireSubscription() }
    links[kind] = token.map { MediaLink(token:$0,send:send) }
    if let link=links[kind] { link.controls=[MediaMessage(kind:1,fields:[.integer(1),.bool(kind=="lan")])];link.volumeControls=[PlayerVolumeMessage(kind:1,fields:[.integer(1)]),PlayerVolumeMessage(kind:1,fields:[.integer(1)],scope:.output)]; pump(kind) }
  }
  func capacity(_ kind: String) { if let link=links[kind], link.sending { link.wake=true } else { pump(kind) } }
  func handle(_ data: Data, channel kind: String) -> DataHandling {
    do {
      if let message=try MediaMessage.decode(data) { return receive(message,channel:kind) ? .handled:.discarded }
      if let message=try PlayerVolumeMessage.decode(data) { return receiveVolume(message,channel:kind) ? .handled:.discarded }
      return .unrecognized
    } catch is MediaWireError { return .discarded } catch { return .unrecognized }
  }
  private func receive(_ message: MediaMessage, channel kind: String) -> Bool {
    guard let link = links[kind] else { return true }
    switch message.kind {
    case 2:
      if subscribed != kind || subscription != message.string(0) {
        retireSubscription(); subscribed=kind; subscription=message.string(0); highWater=0; results=[:]; resultOrder=[];resultKinds=[:]
      }
      enqueue(MediaMessage(kind:3,fields:[.text(message.string(0))]),kind)
      model.presented("remote",true); publish()
    case 4: if subscribed==kind && subscription==message.string(0) { retireSubscription() }
    case 6:
      guard subscribed==kind, subscription==message.string(0) else { return true }
      dispatchCommand(kind,sub:message.string(0),id:message.number(1),source:message.string(2),revision:message.string(3),action:message.number(4),value:message.number(5))
    default: break
    }
    return true
  }
  private func receiveVolume(_ message: PlayerVolumeMessage, channel kind: String) -> Bool {
    guard let link=links[kind] else { return true }
    if message.kind==1 { if message.scope == .output { link.outputCompatible=true } else { link.volumeCompatible=true };publish();return true }
    if message.kind==3, subscribed==kind, subscription==message.string(0), (message.scope == .output ? link.outputCompatible:link.volumeCompatible) {
      dispatchCommand(kind,sub:message.string(0),id:message.number(1),source:message.string(2),revision:message.string(3),action:nil,value:message.number(4),volumeScope:message.scope)
    }
    return true
  }
  private func dispatchCommand(_ kind: String, sub: String, id: Int64, source: String, revision: String, action: Int64?, value: Int64, volumeScope: VolumeScope = .player) {
    guard let link=links[kind] else { return }
    let volume=action==nil, token=link.token
    let commandKind=volume ? (volumeScope == .output ? 2:1):0
    func respond(_ result: Int64) {
      if volume { enqueueVolume(PlayerVolumeMessage(kind:4,fields:[.text(sub),.integer(id),.integer(result)],scope:volumeScope),kind) }
      else { enqueue(MediaMessage(kind:7,fields:[.text(sub),.integer(id),.integer(result)]),kind) }
    }
    if inFlight.contains(id) { return }
    if let result=results[id] { respond(resultKinds[id]==commandKind ? result:1);return }
    guard id>highWater else { respond(1);return }
    highWater=id;inFlight.insert(id)
    let finish: @MainActor (Int64)->Void = { [weak self] result in
      guard let self, self.links[kind]?.token==token, self.subscribed==kind, self.subscription==sub else { return }
      self.inFlight.remove(id);self.results[id]=result;self.resultKinds[id]=commandKind;self.resultOrder.append(id)
      if self.resultOrder.count>32 { let old=self.resultOrder.removeFirst();self.results[old]=nil;self.resultKinds[old]=nil }
      if volume { self.enqueueVolume(PlayerVolumeMessage(kind:4,fields:[.text(sub),.integer(id),.integer(result)],scope:volumeScope),kind) }
      else { self.enqueue(MediaMessage(kind:7,fields:[.text(sub),.integer(id),.integer(result)]),kind) }
    }
    if link.controls.count+link.volumeControls.count>=12 { finish(6) }
    else if let action { model.command(source:source,revision:revision,action:action,value:value,completion:finish) }
    else if volumeScope == .output { model.commandOutputVolume(target:source,revision:revision,value:value,completion:finish) }
    else { model.commandVolume(source:source,revision:revision,value:value,completion:finish) }
  }
  private func enqueueVolume(_ message: PlayerVolumeMessage, _ kind: String) {
    guard let link=links[kind] else { return }
    if link.controls.count+link.volumeControls.count<16 { link.volumeControls.append(message) }
    pump(kind)
  }
  private func retireSubscription() {
    if let kind=subscribed { links[kind]?.snapshot=nil;links[kind]?.volumeSnapshot=nil;links[kind]?.outputSnapshot=nil;links[kind]?.volumeControls.removeAll { $0.kind != 1 }; links[kind]?.artwork=Data(); links[kind]?.hash=Data(); links[kind]?.controls.removeAll { $0.kind != 1 } }
    model.finish(5); inFlight.removeAll()
    subscription=nil; subscribed=nil; highWater=0; results=[:]; resultOrder=[];resultKinds=[:]; model.presented("remote",false)
  }
  private func enqueue(_ message: MediaMessage, _ kind: String) {
    guard let link=links[kind] else { return }
    if link.controls.count+link.volumeControls.count<16 { link.controls.append(message) }
    pump(kind)
  }
  private func snapshot(_ sub: String, artwork: Bool) -> MediaMessage {
    MediaMessage(kind:5,fields:[.text(sub),.text(playback.source),.text(playback.revision),.text(playback.title),.text(playback.artist),.text(playback.player),
      .integer(playback.state),.integer(playback.position),.integer(playback.duration),.integer(playback.rate),.integer(playback.actions),.text(selection),.text(catalogue),
      .array(sources.map { .array([.text($0.id),.text($0.name),.integer($0.playing ? 1:2)]) }),.bytes(artwork ? playback.artworkHash:Data())])
  }
  func publish() {
    guard let kind=subscribed, let sub=subscription, let link=links[kind] else { return }
    link.snapshot=snapshot(sub,artwork:kind=="lan")
    if link.volumeCompatible {
      link.volumeSnapshot=PlayerVolumeMessage(kind:2,fields:[.text(sub),.text(playback.source),.text(playback.revision),.bool(model.playerVolume != nil),.integer(model.playerVolume ?? -1)])
    }
    publishOutput()
    if kind=="lan", link.hash != playback.artworkHash || link.artworkRevision != playback.revision {
      link.artworkRevision=playback.revision; link.hash=playback.artworkHash; link.artwork=artwork ?? Data(); link.offset=0
    }
    pump(kind)
  }
  func publishOutput() {
    guard let kind=subscribed,let sub=subscription,let link=links[kind],link.outputCompatible else { return }
    let output=model.outputVolume, supported = !playback.source.isEmpty && output.level != nil
    link.outputSnapshot=PlayerVolumeMessage(kind:2,fields:[.text(sub),.text(supported ? output.target:""),.text(supported ? output.revision:""),.bool(supported),.integer(supported ? output.level!:-1)],scope:.output)
    pump(kind)
  }
  private func pump(_ kind: String) {
    guard let link=links[kind], !link.sending else { return }
    link.sending=true
    Task { [weak self, weak link, model] in
      guard let self, let link else { return }; defer { withExtendedLifetime(model) {}; link.sending=false; if link.wake { link.wake=false; self.pump(kind) } }
      while self.links[kind] === link {
        let volume=link.controls.isEmpty ? link.volumeControls.first:nil
        let volumeSample=link.controls.isEmpty && link.volumeControls.isEmpty && link.snapshot==nil ? link.volumeSnapshot ?? link.outputSnapshot:nil
        if let next=volume ?? volumeSample {
          do { try await link.send(next.encode()) } catch { return }
          guard self.links[kind] === link else { return }
          if volume != nil { if link.volumeControls.first==next { link.volumeControls.removeFirst() } }
          else if link.volumeSnapshot==next { link.volumeSnapshot=nil }
          else if link.outputSnapshot==next { link.outputSnapshot=nil }
          continue
        }
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
}
