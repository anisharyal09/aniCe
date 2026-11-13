// SPDX-License-Identifier: GPL-3.0-or-later
// Owns the Mac release check, install state and user-visible prompts.
import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor @Observable final class MacUpdateModel {
  static let shared = MacUpdateModel()
  private let discovery: MacReleaseDiscovery
  private(set) var release: AvailableMacRelease?
  private(set) var status = ""
  private(set) var recoveryMessage: String?
  private(set) var checking = false
  private(set) var installing = false
  private(set) var progress = 0.0
  private(set) var installError: String?
  var installProblem: String? { MacUpdateInstall.problem() }
  private var installTask: Task<Void, Never>?
  var includeBeta: Bool {
    didSet {
      discovery.includeBeta = includeBeta
      if !includeBeta, release?.version.prerelease == true { release = nil }
      Task { await check(force: true) }
    }
  }
  private init() {
    let discovery = MacReleaseDiscovery()
    self.discovery = discovery
    self.includeBeta = discovery.includeBeta
  }

  func check(force: Bool = false) async {
    guard !checking else { return }
    guard let name = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
      let current = UpdateVersion.parse("v\(name)") else { status = "Installed version is not supported for update checks."; return }
    checking = true; status = "Checking for updates…"; defer { checking = false }
    switch await discovery.check(current: current, force: force) {
    case .available(let found): release = found; status = "Update \(found.version.tag) is available."
    case .upToDate: release = nil; status = "You’re up to date."
    case .deferred: status = ""
    case .failed(let message): status = message
    }
  }
  func skip() { if let release { discovery.skip(release.version.tag) }; release = nil; status = "" }

  func confirmStartup() {
    guard !MacAppStorage.isPreview else { return }
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    recoveryMessage = MacUpdateRecovery.confirmStartup(version: version)
  }

  func install() {
    guard installTask == nil, let release, !installing else { return }
    installing = true; installError = nil; progress = 0
    installTask = Task {
      defer { installing = false; installTask = nil }
      do {
        try await MacUpdateInstall.launch(release) { received, total in
          guard let total, total > 0 else { return }
          await MainActor.run { self.progress = min(1, Double(received) / Double(total)) }
        }
        NSApplication.shared.terminate(nil)
      } catch is CancellationError {
        installError = "Update download cancelled."
      } catch {
        installError = error.localizedDescription
      }
    }
  }

  func cancelInstall() { installTask?.cancel() }
}

struct BetaUpdateConsent {
  private(set) var confirming = false

  mutating func request(_ requested: Bool, current: Bool) -> Bool? {
    if requested && !current {
      confirming = true
      return nil
    }
    confirming = false
    return requested
  }

  mutating func confirm() -> Bool {
    confirming = false
    return true
  }

  mutating func cancel() {
    confirming = false
  }
}

struct BetaUpdatePreference: View {
  @Binding var checked: Bool
  @AppStorage("ui.fontScale") private var fontScale = 1.0
  @State private var consent = BetaUpdateConsent()
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle("Include beta releases", isOn: Binding(
        get: { checked },
        set: { requested in
          if let resolved = consent.request(requested, current: checked) { checked = resolved }
        }))
        .toggleStyle(.checkbox).aniCeControlFeedback(feedbackPadding: 3)
        .accessibilityHint("Confirms before enabling beta updates")
      Text(checked ? "Turning this off keeps your installed version." : "Get early builds and help test aniCe.")
        .font(.system(size: 12 * fontScale)).foregroundStyle(AniCePalette.secondaryText(scheme))
    }
    .alert("Try beta updates?", isPresented: Binding(
      get: { consent.confirming },
      set: { if !$0 { consent.cancel() } })) {
      Button("Enable beta updates") { if consent.confirm() { checked = true } }
      Button("Not now", role: .cancel) { consent.cancel() }
    } message: {
      Text("You’ll be helping test aniCe. Beta builds may have bugs, interrupt connections or file transfers, and occasionally need recovery or re-adding trusted devices. Normal updates are intended to keep your settings and pairings.")
    }
  }
}

struct MacUpdateNotice: View {
  @Bindable var model: MacUpdateModel
  @State private var showing = false
  var body: some View {
    if let release = model.release {
      PendingRequestRow(title: "Update \(release.version.tag) available", detail: "Review release notes and install") { showing = true }
        .sheet(isPresented: $showing) {
          VStack(alignment: .leading, spacing: 16) {
            Text("Update \(release.version.tag)").font(.title3.weight(.semibold))
            ScrollView { Text(verbatim: release.notes.isEmpty ? "No release notes provided." : release.notes)
              .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
              .frame(minHeight: 100, maxHeight: 300)
            HStack {
              Button("Skip version") { model.skip(); showing = false }
              Spacer()
              Button("Later") { showing = false }.keyboardShortcut(.cancelAction)
              Button("Open release on GitHub") { NSWorkspace.shared.open(release.pageURL) }
              if model.installProblem != nil {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
              }
              if model.installProblem == nil {
                Button("Install Update") { model.install() }
                  .keyboardShortcut(.defaultAction).disabled(model.installing)
              }
            }
            if model.installing {
              HStack {
                ProgressView(value: model.progress) { Text("Downloading…") }
                Button("Cancel") { model.cancelInstall() }
              }
            }
            if let error = model.installError { Text(error).font(.caption).foregroundStyle(.red) }
            if let problem = model.installProblem { Text(problem).font(.caption).foregroundStyle(.secondary) }
          }.padding(24).frame(minWidth: 440, idealWidth: 520)
        }
    }
  }
}
