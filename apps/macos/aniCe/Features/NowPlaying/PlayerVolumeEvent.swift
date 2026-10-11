// SPDX-License-Identifier: GPL-3.0-or-later
// Reads and writes a selected player's integer application property through PID-addressed Apple Events.
import AppKit
import CoreServices

final class PlayerVolumeEvent: @unchecked Sendable {
  private let lock=NSLock()
  private var cancelled=false
  func cancel() { lock.withLock { cancelled=true } }
  private let pid: Int32
  private let property: UInt32
  private let bundle: String
  private let launched: Date?
  init(target: MediaSource, property: UInt32) { self.pid=target.pid;self.bundle=target.bundle;self.launched=target.launched;self.property=property }
  private func event(value: Int64?) -> NSAppleEventDescriptor? {
    let event=NSAppleEventDescriptor(eventClass:kAECoreSuite,eventID:value==nil ? kAEGetData:kAESetData,
      targetDescriptor:NSAppleEventDescriptor(processIdentifier:pid),returnID:AEReturnID(kAutoGenerateReturnID),transactionID:AETransactionID(kAnyTransactionID))
    let object=NSAppleEventDescriptor.record()
    object.setDescriptor(NSAppleEventDescriptor(typeCode:typeProperty),forKeyword:AEKeyword(keyAEDesiredClass))
    object.setDescriptor(NSAppleEventDescriptor(enumCode:OSType(formPropertyID)),forKeyword:AEKeyword(keyAEKeyForm))
    object.setDescriptor(NSAppleEventDescriptor(typeCode:property),forKeyword:AEKeyword(keyAEKeyData))
    object.setDescriptor(NSAppleEventDescriptor.null(),forKeyword:AEKeyword(keyAEContainer))
    guard let specifier=object.coerce(toDescriptorType:typeObjectSpecifier) else { return nil }
    event.setParam(specifier,forKeyword:AEKeyword(keyDirectObject))
    if let value {
      guard (0...100).contains(value) else { return nil }
      event.setParam(NSAppleEventDescriptor(int32:Int32(value)),forKeyword:AEKeyword(keyAEData))
    }
    return event
  }
  private func send(_ value: Int64?) -> (Int64,NSAppleEventDescriptor?) {
    guard !lock.withLock({ cancelled }) else { return (5,nil) }
    guard let app=NSRunningApplication(processIdentifier:pid), !app.isTerminated, app.bundleIdentifier==bundle, app.launchDate==launched, launched != nil else { return (1,nil) }
    guard let event=event(value:value) else { return (2,nil) }
    do {
      let reply=try event.sendEvent(options:[.waitForReply,.neverInteract,.dontRecord],timeout:1)
      let error=reply.paramDescriptor(forKeyword:AEKeyword(keyErrorNumber))?.int32Value ?? 0
      return (error==0 ? 0:error==errAEEventNotPermitted ? 4:7,reply)
    } catch { return ((error as NSError).code==Int(errAEEventNotPermitted) ? 4:7,nil) }
  }
  func read() -> (Int64,Int64?) {
    let (status,reply)=send(nil)
    guard status==0, let value=reply?.paramDescriptor(forKeyword:AEKeyword(keyDirectObject)),
      [typeSInt16,typeSInt32].contains(value.descriptorType), (0...100).contains(value.int32Value) else { return (status==0 ? 7:status,nil) }
    return (0,Int64(value.int32Value))
  }
  func run(value: Int64?) -> (Int64,Int64?) {
    let (readStatus,initial)=read()
    guard readStatus==0, let initial else { return (readStatus,nil) }
    let requested=value ?? initial
    let (writeStatus,_)=send(requested)
    guard writeStatus==0 else { return (writeStatus,nil) }
    let (status,actual)=read()
    return status==0 && actual==requested ? (0,actual):(status==0 ? 7:status,nil)
  }
}

/// Keeps a released volume preview until a matching authoritative sample or a fixed deadline.
struct VolumePreview {
  private var requested: Int64?
  private var deadline: TimeInterval=0
  var pending: Bool { requested != nil }
  mutating func begin(_ value: Int64, now: TimeInterval) { requested=value;deadline=now+6 }
  func value(at now: TimeInterval) -> Int64? { now<deadline ? requested:nil }
  mutating func confirm(_ level: Int64?) { if level==requested { clear() } }
  mutating func clear() { requested=nil }
}

/// A transient read hides current support without discarding the process-bound write proof.
struct PlayerVolumeState {
  private(set) var proven=false
  private(set) var level: Int64?
  mutating func restoreProof(_ proof: Bool) { proven=proof;level=nil }
  var supported: Bool { level != nil }
  func canRead(permitted: Bool) -> Bool { proven && permitted }
  @discardableResult mutating func receive(result: Int64, level: Int64?) -> Bool {
    let old=supported
    if result==0, let level, (0...100).contains(level) { proven=true;self.level=level }
    else { self.level=nil }
    return old != supported
  }
}
