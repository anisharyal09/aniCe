// SPDX-License-Identifier: GPL-3.0-or-later
// Reports microphone authorization and handles an explicit, bounded access request.
import AVFoundation
import Foundation

enum MicrophoneAccess {
  /// Reads current authorization without prompting or caching an earlier answer.
  static var isGranted: Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return true
    case .notDetermined, .denied, .restricted: return false
    @unknown default: return false
    }
  }

  /// Requests authorization for --request-mic and bounds the wait for a system response.
  static func requestOnce(timeout: TimeInterval = 30) async -> Bool {
    if isGranted { return true }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return false }
    let box = AnswerBox()
    return await withCheckedContinuation { continuation in
      box.attach(continuation)
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        box.finish(granted)
      }
      // A headless process may not get a prompt at all. Do not hang the probe.
      Task {
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        box.finish(isGranted)
      }
    }
  }

  static var stateName: String {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "not determined (never asked)"
    @unknown default: return "unknown"
    }
  }

  static let remedy = """
    Grant microphone access, then rerun the probe:
      1. System Settings → Privacy & Security → Microphone, enable "CallAudioProbe".
         If the probe is not listed, rerun with --request-mic to request access.
      2. If a stale entry exists, remove it with:
           tccutil reset Microphone io.github.anisharyal09.anice.callprobe
         then rerun.
    Without this access the probe can still enumerate CoreAudio and inspect
    exposed endpoints, but it cannot prove that the endpoint carries usable
    audio.
    """
}

/// One-shot answer shared by the system callback and the timeout path, so the
/// continuation can never be resumed twice.
private final class AnswerBox: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Bool, Never>?
  private var finished = false

  func attach(_ continuation: CheckedContinuation<Bool, Never>) {
    lock.lock()
    if finished {
      lock.unlock()
      continuation.resume(returning: false)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  func finish(_ answer: Bool) {
    lock.lock()
    if finished {
      lock.unlock()
      return
    }
    finished = true
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(returning: answer)
  }
}
