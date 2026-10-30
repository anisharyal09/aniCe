// SPDX-License-Identifier: GPL-3.0-or-later
// Presents identity load, rename and reset results with storage-specific recovery actions.
import Foundation
import Observation

struct IdentityRecovery: Equatable {
  let title: String
  let message: String
  let canRetry: Bool
  let canReset: Bool
  let resetLabel: String

  init(error: IdentityError?) {
    resetLabel = error == .keyPolicyNeedsReset ? "Create new identity…" : "Reset identity…"
    switch error {
    case .keyPolicyNeedsReset:
      title = "A fresh identity is needed"
      message =
        "Your identity was created by an earlier development build. Create a new identity to continue using this Mac with aniCe."
      canRetry = false
      canReset = true
    case .keyMissing:
      title = "The saved signing key is missing"
      message =
        "This Mac’s saved identity can no longer be used. You can create a new identity to continue."
      canRetry = true
      canReset = true
    case .inconsistentStorage:
      title = "Your identity needs attention"
      message =
        "The saved identity could not be verified. Try again, or create a new identity if the problem continues."
      canRetry = true
      canReset = true
    case .accessDenied:
      title = "Keychain access is needed"
      message =
        "aniCe could not access its saved signing key. Try again and allow Keychain access when asked. Your identity has not been replaced."
      canRetry = true
      canReset = false
    case .configurationRequired:
      title = "This build needs signing setup"
      message =
        "Identity storage is unavailable with this build’s signing settings. Configure signing or use the development storage build."
      canRetry = true
      canReset = false
    default:
      title = "Identity storage is unavailable"
      message = "Unlock your Mac and try again. Your saved identity has not been replaced."
      canRetry = true
      canReset = false
    }
  }
}

@MainActor @Observable
final class IdentityViewModel {
  var onIdentityReset: () -> Void = {}
  var local: LocalIdentity?
  var recovery: IdentityRecovery?
  var canReset: Bool { local != nil || recovery?.canReset == true }
  var isWorking = false
  var showingDetails = false
  let service: IdentityService

  private var hasAttemptedLoad = false

  init(service: IdentityService) {
    self.service = service
  }

  func load(force: Bool = false) async {
    // Opening the sheet reuses the first attempt; only an explicit Retry rechecks storage.
    guard !isWorking, force || !hasAttemptedLoad else { return }
    hasAttemptedLoad = true
    isWorking = true
    defer { isWorking = false }
    do {
      local = try await service.loadOrCreate()
      recovery = nil
    } catch { report(error) }
  }

  func reset() async {
    guard !isWorking else { return }
    isWorking = true
    hasAttemptedLoad = true
    defer { isWorking = false }
    do {
      local = try await service.reset()
      recovery = nil
      onIdentityReset()
    } catch { report(error) }
  }

  func rename(_ name: String) async {
    guard !isWorking else { return }
    isWorking = true
    defer { isWorking = false }
    do {
      local = try await service.rename(name)
      recovery = nil
    } catch { recovery = IdentityRecovery(error: error as? IdentityError) }
  }

  private func report(_ error: Error) {
    local = nil
    recovery = IdentityRecovery(error: error as? IdentityError)
  }
}
