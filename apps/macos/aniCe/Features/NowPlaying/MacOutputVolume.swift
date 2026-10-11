// SPDX-License-Identifier: GPL-3.0-or-later
// Observes and controls the current native Mac output device without player scripting or audio capture.
import Foundation
import CoreAudio
import AudioToolbox
import Observation

struct OutputDeviceVolume {
  let device: AudioDeviceID
  let uid: String
  let selector: AudioObjectPropertySelector
  let scalar: Float32
  var identity: String { "\(device):\(uid):\(selector)" }
}
enum OutputAudio {
  static func address(_ selector: UInt32, output: Bool=false) -> AudioObjectPropertyAddress {
    .init(mSelector:selector,mScope:output ? kAudioDevicePropertyScopeOutput:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
  }
  static func device() -> AudioDeviceID {
    var a=address(kAudioHardwarePropertyDefaultOutputDevice), id=AudioDeviceID(0), size=UInt32(MemoryLayout<AudioDeviceID>.size)
    return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,&size,&id)==noErr ? id:0
  }
  static func read() -> OutputDeviceVolume? {
    let id=device();guard id != 0 else { return nil }
    var uid="" as CFString, size=UInt32(MemoryLayout<CFString>.size), a=address(kAudioDevicePropertyDeviceUID)
    guard AudioObjectGetPropertyData(id,&a,0,nil,&size,&uid)==noErr else { return nil }
    for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume,kAudioDevicePropertyVolumeScalar] {
      a=address(selector,output:true);var settable: DarwinBoolean=false, scalar: Float32=0;size=4
      guard AudioObjectHasProperty(id,&a),AudioObjectIsPropertySettable(id,&a,&settable)==noErr,settable.boolValue,
        AudioObjectGetPropertyData(id,&a,0,nil,&size,&scalar)==noErr,scalar.isFinite,(0...1).contains(scalar) else { continue }
      return .init(device:id,uid:uid as String,selector:selector,scalar:scalar)
    }
    return nil
  }
  static func write(_ target: OutputDeviceVolume, _ value: Float32) -> Int64 {
    guard value.isFinite,(0...1).contains(value) else { return 1 }
    guard let fresh=read() else { return 5 }
    guard fresh.identity==target.identity else { return 1 }
    var a=address(target.selector,output:true), scalar=value
    return AudioObjectSetPropertyData(target.device,&a,0,nil,4,&scalar)==noErr ? 0:7
  }
}
private final class OutputAudioObservation: @unchecked Sendable {
  private let object: AudioObjectID
  private let block: AudioObjectPropertyListenerBlock
  private var addresses: [AudioObjectPropertyAddress]=[]
  init(_ object: AudioObjectID, _ properties: [AudioObjectPropertyAddress], changed: @escaping @Sendable ()->Void) {
    self.object=object;block={ _,_ in changed() }
    for var a in properties where AudioObjectHasProperty(object,&a) {
      if AudioObjectAddPropertyListenerBlock(object,&a,.main,block)==noErr { addresses.append(a) }
    }
  }
  deinit { for var a in addresses { AudioObjectRemovePropertyListenerBlock(object,&a,.main,block) } }
}
@Observable @MainActor final class MacOutputVolume {
  private(set) var target=""
  private(set) var revision=""
  private(set) var level: Int64?
  var changed: @MainActor ()->Void = {}
  @ObservationIgnored private let reader: ()->OutputDeviceVolume?
  @ObservationIgnored private let writer: (OutputDeviceVolume,Float32)->Int64
  @ObservationIgnored private let observeNative: Bool
  @ObservationIgnored private var systemObservation: OutputAudioObservation?
  @ObservationIgnored private var deviceObservation: OutputAudioObservation?
  private var observedDevice: AudioDeviceID=0
  private var identity=""
  private var active=false
  private var generation=UUID()
  init(observeNative: Bool=true, read: @escaping ()->OutputDeviceVolume?=OutputAudio.read, write: @escaping (OutputDeviceVolume,Float32)->Int64=OutputAudio.write) {
    self.observeNative=observeNative;reader=read;writer=write
  }
  func start() {
    guard !active else { return };active=true;generation=UUID()
    if observeNative {
      let gen=generation
      systemObservation=OutputAudioObservation(AudioObjectID(kAudioObjectSystemObject),[OutputAudio.address(kAudioHardwarePropertyDefaultOutputDevice)]) { [weak self] in
        Task { @MainActor [weak self] in guard self?.generation==gen else { return };self?.refresh() }
      }
    }
    refresh()
  }
  func stop() {
    active=false;generation=UUID();systemObservation=nil;deviceObservation=nil;observedDevice=0
    target="";revision="";level=nil;identity=""
  }
  func refresh() {
    guard active else { return }
    if observeNative {
      let device=OutputAudio.device()
      if device != observedDevice {
        observedDevice=device;deviceObservation=nil;let gen=generation
        if device != 0 {
          deviceObservation=OutputAudioObservation(device,[OutputAudio.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,output:true),OutputAudio.address(kAudioDevicePropertyVolumeScalar,output:true),OutputAudio.address(kAudioDevicePropertyDeviceIsAlive)]) { [weak self] in
            Task { @MainActor [weak self] in guard self?.generation==gen else { return };self?.refresh() }
          }
        }
      }
    }
    let sample=reader().flatMap { $0.scalar.isFinite && (0...1).contains($0.scalar) ? $0:nil }, next=sample?.identity ?? ""
    if identity != next { identity=next;target=sample==nil ? "":UUID().uuidString;revision=sample==nil ? "":UUID().uuidString }
    level=sample.map { Int64(($0.scalar*100).rounded()) };changed()
  }
  func command(target: String, revision: String, value: Int64) -> Int64 {
    guard active else { return 5 };guard (0...100).contains(value) else { return 1 }
    guard !target.isEmpty,target==self.target,revision==self.revision else { return 1 }
    guard let sample=reader() else { refresh();return 5 }
    guard sample.identity==identity else { refresh();return 1 }
    let result=writer(sample,Float32(value)/100);refresh()
    return result==0 && level != value ? 7:result
  }
}
