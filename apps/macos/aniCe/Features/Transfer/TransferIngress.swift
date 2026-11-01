// SPDX-License-Identifier: GPL-3.0-or-later
// Bounds and orders authenticated transfer data before feature processing.
import Foundation

// MainActor owns admission and accounting; one FIFO consumer orders chunks, receiver resumes and storage awaits.
@MainActor final class TransferIngress {
  private struct Entry { let descriptor: ChannelDescriptor; let epoch: UUID; let bytes: Data }
  private let consume: @MainActor (ChannelDescriptor, UUID, Data) async -> Void
  private var pending: [Entry] = []
  private var worker: Task<Void, Never>?
  private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  private var active: ChannelDescriptor?
  private var count = 0
  private var bytes = 0
  init(consume: @escaping @MainActor (ChannelDescriptor, UUID, Data) async -> Void) { self.consume = consume }
  // Capacity includes the active write until it completes, not merely entries still in FIFO.
  func enqueue(_ data: Data, on descriptor: ChannelDescriptor, epoch: UUID,
    byteLimit: Int, recordLimit: Int, live: () -> Bool) async -> Bool {
    guard data.count <= byteLimit else { return false }
    let started = SessionTiming.start()
    while live(), !Task.isCancelled {
      if count < recordLimit, bytes <= byteLimit - data.count {
        SessionTiming.end(self, "transfer_ingress_admission", started, bytes: data.count,
          profile: descriptor.maximumDataBytes > 4000 ? 3 : 1, direction: "receive")
        pending.append(Entry(descriptor: descriptor, epoch: epoch, bytes: data))
        count += 1; bytes += data.count
        startWorker()
        return true
      }
      await changed()
    }
    return false
  }
  private func startWorker() {
    guard worker == nil, !pending.isEmpty else { return }
    // A successor epoch must not inherit the cancelled consumer's task context.
    worker = Task { @MainActor in await self.run() }
  }
  private func run() async {
    defer { worker = nil; startWorker(); wake() }
    while !Task.isCancelled, !pending.isEmpty {
      let next = pending.removeFirst()
      active = next.descriptor
      let started = SessionTiming.start()
      await consume(next.descriptor, next.epoch, next.bytes)
      SessionTiming.end(self, "transfer_ingress_delivery", started, bytes: next.bytes.count,
        profile: next.descriptor.maximumDataBytes > 4000 ? 3 : 1, direction: "receive")
      active = nil; count -= 1; bytes -= next.bytes.count; wake()
    }
  }
  func invalidate(_ descriptor: ChannelDescriptor? = nil) {
    pending.removeAll { next in
      guard descriptor == nil || next.descriptor == descriptor else { return false }
      count -= 1; bytes -= next.bytes.count; return true
    }
    // Actor entry checks cancellation before writing; a synchronous write already running may finish.
    if active != nil, descriptor == nil || active == descriptor { worker?.cancel() }
    wake()
  }
  func drain(_ descriptor: ChannelDescriptor? = nil, timeout: Duration = .seconds(10)) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    let timer = Task { [weak self] in
      do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
      self?.wake()
    }
    defer { timer.cancel() }
    func hasWork() -> Bool {
      guard let descriptor else { return count > 0 }
      return active == descriptor || pending.contains { $0.descriptor == descriptor }
    }
    while hasWork(), !Task.isCancelled, ContinuousClock.now < deadline { await changed() }
    return !hasWork()
  }
  private func changed() async {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled { continuation.resume() } else { waiters[id] = continuation }
      }
    } onCancel: { Task { @MainActor in self.waiters.removeValue(forKey: id)?.resume() } }
  }
  private func wake() {
    let current = waiters.values; waiters.removeAll()
    for waiter in current { waiter.resume() }
  }
}
