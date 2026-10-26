// SPDX-License-Identifier: GPL-3.0-or-later
// Owns the packaged helper process, bounded newline framing and generation-fenced pipe delivery.
import Foundation

final class PlaybackPipe: @unchecked Sendable {
  private let lock = NSLock()
  private var bytes = Data()
  private var pending: [Data] = []
  private var pendingBytes = 0
  private var drainScheduled = false
  func append(_ data: Data) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard bytes.count + pendingBytes + data.count <= 17*1024*1024 else { return false }
    bytes.append(data)
    while let i = bytes.firstIndex(of:10) {
      let line=Data(bytes.prefix(upTo:i))
      pending.append(line);pendingBytes += line.count+1
      bytes.removeSubrange(...i)
    }
    return true
  }
  func take() -> [Data] {
    lock.lock(); defer { lock.unlock() }
    let result=pending;pending=[];pendingBytes=0
    drainScheduled=false
    return result
  }
  func scheduleDrain() -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard !pending.isEmpty, !drainScheduled else { return false }
    drainScheduled=true
    return true
  }
}
@MainActor final class MediaProcessBridge {
  private var process: Process?
  private var input: FileHandle?
  private var output: FileHandle?
  private(set) var generation = UUID()
  var running: Bool { process != nil }
  var received: @MainActor (Data)->Void = { _ in }
  var failure: @MainActor (String)->Void = { _ in }
  var started: @MainActor ()->Void = {}
  func launch() {
    guard process==nil else { return }
    guard let root=Bundle.main.resourceURL?.appendingPathComponent("NowPlaying") else { failure("Playback adapter unavailable"); return }
    let child=Process(), incoming=Pipe(), outgoing=Pipe(), reader=PlaybackPipe(), gen=UUID()
    generation=gen
    guard fcntl(incoming.fileHandleForWriting.fileDescriptor,F_SETNOSIGPIPE,1) != -1 else { failure("Playback pipe unavailable"); return }
    child.executableURL=URL(fileURLWithPath:"/usr/bin/perl")
    child.arguments=[root.appendingPathComponent("now-playing.pl").path,root.appendingPathComponent("libaniCeNowPlaying.dylib").path,"watch_all"]
    child.standardInput=incoming; child.standardOutput=outgoing; child.standardError=FileHandle.nullDevice
    process=child; input=incoming.fileHandleForWriting; output=outgoing.fileHandleForReading
    outgoing.fileHandleForReading.readabilityHandler = { [weak self] file in
      let data=file.availableData
      if data.isEmpty { file.readabilityHandler=nil; return }
      guard reader.append(data) else {
        file.readabilityHandler=nil
        Task { @MainActor in if self?.generation==gen { self?.failure("Playback adapter output exceeded its limit") } }
        return
      }
      guard reader.scheduleDrain() else { return }
      // One FIFO drain preserves metadata/capability order across independently scheduled callbacks.
      Task { @MainActor [weak self] in
        self?.drain(reader,generation:gen)
      }
    }
    child.terminationHandler = { [weak self] _ in Task { @MainActor in if self?.generation==gen { self?.failure("Playback adapter stopped") } } }
    do { try child.run(); started() } catch { failure("Playback adapter could not start") }
  }
  func drain(_ reader: PlaybackPipe, generation expected: UUID) {
    for line in reader.take() {
      guard generation==expected else { return }
      received(line)
    }
  }
  func stop() {
    generation=UUID()
    output?.readabilityHandler=nil; try? input?.close(); try? output?.close(); input=nil; output=nil
    if process?.isRunning==true { process?.terminate() }; process=nil
  }
  func write(_ request: PlaybackRequest) -> Bool {
    guard let message=request.message, message.utf8.count<=2048, let input, process?.isRunning==true else { return false }
    do { try input.write(contentsOf:Data((message+"\n").utf8)); return true } catch { return false }
  }
}
