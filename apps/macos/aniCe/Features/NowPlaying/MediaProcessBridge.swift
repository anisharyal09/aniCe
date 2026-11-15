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

// DispatchIO owns ordered pipe writes; queued bytes are bounded independently of helper consumption.
final class PlaybackInputPipe: @unchecked Sendable {
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "aniCe playback pipe writes")
  private let channel: DispatchIO
  private let failed: @Sendable () -> Void
  private var pendingBytes = 0
  private var closed = false

  init(_ input: FileHandle, failed: @escaping @Sendable () -> Void) throws {
    guard fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    self.failed = failed
    channel = DispatchIO(type: .stream, fileDescriptor: input.fileDescriptor, queue: queue) { _ in
      try? input.close()
    }
  }

  func send(_ bytes: Data) -> Bool {
    lock.lock()
    guard !closed, (1...2049).contains(bytes.count), pendingBytes <= 65536 - bytes.count else {
      lock.unlock(); return false
    }
    pendingBytes += bytes.count
    lock.unlock()
    let data = bytes.withUnsafeBytes { DispatchData(bytes: $0) }
    channel.write(offset: 0, data: data, queue: queue) { [self] done, _, error in
      guard done else { return }
      lock.lock()
      pendingBytes -= bytes.count
      let notify = error != 0 && !closed
      if notify { closed = true }
      lock.unlock()
      if notify { channel.close(flags: .stop); failed() }
    }
    return true
  }

  func close() {
    lock.lock()
    let wasClosed = closed
    closed = true
    lock.unlock()
    if !wasClosed { channel.close(flags: .stop) }
  }
}

@MainActor final class MediaProcessBridge {
  private var process: Process?
  private var input: PlaybackInputPipe?
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
    let writer: PlaybackInputPipe
    do {
      writer = try PlaybackInputPipe(incoming.fileHandleForWriting) { [weak self] in
        Task { @MainActor in if self?.generation == gen { self?.failure("Playback adapter input failed") } }
      }
    } catch { failure("Playback pipe unavailable"); return }
    child.executableURL=URL(fileURLWithPath:"/usr/bin/perl")
    child.arguments=[root.appendingPathComponent("now-playing.pl").path,root.appendingPathComponent("libaniCeNowPlaying.dylib").path,"watch_all"]
    child.standardInput=incoming; child.standardOutput=outgoing; child.standardError=FileHandle.nullDevice
    process=child; input=writer; output=outgoing.fileHandleForReading
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
    output?.readabilityHandler=nil; input?.close(); try? output?.close(); input=nil; output=nil
    if process?.isRunning==true { process?.terminate() }; process=nil
  }
  func write(_ request: PlaybackRequest) -> Bool {
    guard let message=request.message, message.utf8.count<=2048, let input, process?.isRunning==true else { return false }
    return input.send(Data((message+"\n").utf8))
  }
}
