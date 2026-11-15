// SPDX-License-Identifier: GPL-3.0-or-later
// Owns the Mac release check, install state and user-visible prompts.
import AppKit
import Foundation
import Observation
import SwiftUI
import Network
import UserNotifications

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
  var reviewing = false {
    didSet {
      if !reviewing {
        scheduleNextCheck()
        if oldValue { Task { [weak self] in await self?.refreshAutomatic() } }
      }
    }
  }
  private var checkAgain = false
  private var automaticStarted = false
  private var timer: Timer?
  private let network = NWPathMonitor()
  private var observations: [NSObjectProtocol] = []
  private var wakeObservation: NSObjectProtocol?
  static let notificationCategory = "ANICE_UPDATE"
  private static let notificationIdentifier = "anice.update"
  var includeBeta: Bool {
    didSet {
      discovery.includeBeta = includeBeta
      if !includeBeta { clearNotification() }
      if !includeBeta, release?.version.prerelease == true {
        release = nil; reviewing = false; clearNotification()
      }
      Task { await check(force: true) }
    }
  }
  init(discovery: MacReleaseDiscovery = MacReleaseDiscovery()) {
    self.discovery = discovery
    self.includeBeta = discovery.includeBeta
  }

  func startAutomaticChecks() {
    guard !automaticStarted, !IdentityView.isTesting else { return }
    automaticStarted = true
    restoreCachedRelease()
    network.pathUpdateHandler = { [weak self] path in
      guard path.status == .satisfied else { return }
      Task { @MainActor in await self?.refreshAutomatic() }
    }
    network.start(queue: DispatchQueue(label: "aniCe.updates.network"))
    for name in [NSApplication.didBecomeActiveNotification, NSNotification.Name.NSSystemClockDidChange] {
      observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in await self?.refreshAutomatic() }
      })
    }
    wakeObservation = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in await self?.refreshAutomatic() }
      }
    scheduleNextCheck()
  }

  func stopAutomaticChecks() {
    automaticStarted = false
    timer?.invalidate(); timer = nil
    network.cancel()
    observations.forEach { NotificationCenter.default.removeObserver($0) }
    observations.removeAll()
    if let wakeObservation { NSWorkspace.shared.notificationCenter.removeObserver(wakeObservation) }
    wakeObservation = nil
  }

  private func refreshAutomatic() async {
    guard automaticStarted else { return }
    if network.currentPath.status == .satisfied { await check() }
    else { scheduleNextCheck() }
  }

  private func scheduleNextCheck() {
    guard automaticStarted, !checking, (!reviewing || release == nil) else { return }
    timer?.invalidate(); timer = nil
    let now = Date()
    let next = installing ? UpdateSchedule.latestEvening(now).addingTimeInterval(UpdateSchedule.day)
      : discovery.nextAutomaticCheck(now: now)
    // An offline overdue check waits for a path event instead of repeatedly waking the app.
    if next <= now, network.currentPath.status != .satisfied { return }
    let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
      Task { @MainActor in await self?.refreshAutomatic() }
    }
    timer.tolerance = 30
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  func check(force: Bool = false) async {
    guard !checking else { if force { checkAgain = true }; return }
    guard !installing else { return }
    guard force || !reviewing || release == nil else { return }
    guard let name = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
      let current = UpdateVersion.parse("v\(name)") else { status = "Installed version is not supported for update checks."; return }
    checking = true; status = "Checking for updates…"
    defer {
      checking = false
      scheduleNextCheck()
      if checkAgain { checkAgain = false; Task { await check(force: true) } }
    }
    let result = await discovery.check(current: current, force: force)
    if !force, reviewing, let release {
      status = "Update \(release.version.tag) is available."
      if case .failed(let message) = result { status = message }
      return
    }
    switch result {
    case .available(let found):
      guard discovery.isEligible(found) else { release = nil; reviewing = false; status = ""; return }
      release = found; status = "Update \(found.version.tag) is available."
      await notifyIfNeeded(found)
    case .upToDate: release = nil; reviewing = false; status = "You’re up to date."; clearNotification()
    case .deferred: status = ""
    case .failed(let message): status = message
    }
  }
  private func restoreCachedRelease() {
    guard release == nil,
      let name = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
      let current = UpdateVersion.parse("v\(name)"),
      let cached = try? discovery.cachedNotice(current: current) else { return }
    release = cached
    status = "Update \(cached.version.tag) is available."
  }

  func review() {
    restoreCachedRelease()
    guard release != nil else { return }
    reviewing = true
    clearNotification()
  }
  func skip(_ version: UpdateVersion) {
    guard !installing, release?.version == version else { return }
    if let release { discovery.skip(release.version.tag) }
    release = nil; reviewing = false; status = ""; clearNotification()
  }

  private func notifyIfNeeded(_ found: AvailableMacRelease) async {
    guard !IdentityView.isTesting, !MacAppStorage.isPreview, !NSApp.isActive, discovery.shouldNotify(found) else { return }
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
      settings.notificationCenterSetting == .enabled || settings.alertSetting == .enabled,
      !NSApp.isActive, release == found, discovery.shouldNotify(found) else { return }
    let content = UNMutableNotificationContent()
    content.title = "aniCe \(found.version.tag) is available"
    content.body = "Review release notes when you’re ready."
    content.categoryIdentifier = Self.notificationCategory
    content.interruptionLevel = .passive
    do {
      try await center.add(UNNotificationRequest(identifier: Self.notificationIdentifier, content: content, trigger: nil))
      discovery.markNotified(found)
      if release != found || (!includeBeta && found.version.prerelease) { clearNotification() }
    } catch {
      // The persistent in-app notice remains available when system notification delivery fails.
    }
  }

  private func clearNotification() {
    guard !IdentityView.isTesting, !MacAppStorage.isPreview else { return }
    let center = UNUserNotificationCenter.current()
    center.removeDeliveredNotifications(withIdentifiers: [Self.notificationIdentifier])
    center.removePendingNotificationRequests(withIdentifiers: [Self.notificationIdentifier])
  }

  func confirmStartup() {
    guard !MacAppStorage.isPreview else { return }
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    recoveryMessage = MacUpdateRecovery.confirmStartup(version: version)
  }

  func install(_ version: UpdateVersion) {
    guard installTask == nil, let release, release.version == version, !installing, !checking else { return }
    installing = true; installError = nil; progress = 0
    installTask = Task {
      defer { installing = false; installTask = nil; scheduleNextCheck() }
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
  var body: some View {
    if let release = model.release {
      PendingRequestRow(title: "Update \(release.version.tag) available", detail: "Review release notes and install") { model.review() }
        .sheet(isPresented: $model.reviewing) {
          VStack(alignment: .leading, spacing: 16) {
            Text("Update \(release.version.tag)").font(.title3.weight(.semibold))
            ScrollView { ReleaseNotesView(notes: release.notes) }
              .frame(minHeight: 100, maxHeight: 300)
            HStack {
              Button("Skip version") { model.skip(release.version) }.buttonStyle(AniCeButtonStyle())
                .disabled(model.installing || model.checking)
              Spacer()
              Button("Later") { model.reviewing = false }.buttonStyle(AniCeButtonStyle())
                .keyboardShortcut(.cancelAction)
              Button("Open release on GitHub") { NSWorkspace.shared.open(release.pageURL) }
                .buttonStyle(AniCeButtonStyle())
              if model.installProblem != nil {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                  .buttonStyle(AniCeButtonStyle())
              }
              if model.installProblem == nil {
                Button("Install Update") { model.install(release.version) }
                  .buttonStyle(AniCeButtonStyle(prominent: true))
                  .keyboardShortcut(.defaultAction).disabled(model.installing || model.checking)
              }
            }
            if model.installing {
              HStack {
                ProgressView(value: model.progress) { Text("Downloading…") }
                Button("Cancel") { model.cancelInstall() }.buttonStyle(AniCeButtonStyle())
              }
            }
            if let error = model.installError { Text(error).font(.caption).foregroundStyle(.red) }
            if let problem = model.installProblem { Text(problem).font(.caption).foregroundStyle(.secondary) }
          }.padding(24).frame(minWidth: 440, idealWidth: 520)
        }
    }
  }
}
