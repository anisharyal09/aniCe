// SPDX-License-Identifier: GPL-3.0-or-later
// Delivers optional background offer and verified receive-completion notices.
import AppKit
import Foundation
import Observation
import UserNotifications

// Delivery and sound are independent local preferences; neither changes transfer approval or execution.
@Observable @MainActor final class TransferNotificationPreferences {
  private let storage: UserDefaults?
  var enabled: Bool { didSet { storage?.set(enabled, forKey: "transfer.offerNotifications"); changed() } }
  var sound: Bool { didSet { storage?.set(sound, forKey: "transfer.sound") } }
  @ObservationIgnored var changed: () -> Void = {}
  init(storage: UserDefaults? = nil) {
    self.storage = storage
    enabled = storage?.object(forKey: "transfer.offerNotifications") as? Bool ?? false
    sound = storage?.object(forKey: "transfer.sound") as? Bool ?? true
  }
}

/// Local consent to receive future batches from a specific trusted identity.
@Observable @MainActor final class TransferAutoReceivePreferences {
  private let storage: UserDefaults?
  private static let keyPrefix = "transfer.autoReceive."
  private(set) var enabledKeys: Set<String>

  init(storage: UserDefaults? = nil) {
    self.storage = storage
    enabledKeys = Set(storage?.dictionaryRepresentation().compactMap { entry in
      entry.key.hasPrefix(Self.keyPrefix) && (entry.value as? Bool == true) ? entry.key : nil
    } ?? [])
  }

  func enabled(for peer: DeviceIdentity) -> Bool {
    enabledKeys.contains(key(peer))
  }

  func setEnabled(_ enabled: Bool, for peer: DeviceIdentity) {
    let key = key(peer)
    if enabled { enabledKeys.insert(key) } else { enabledKeys.remove(key) }
    // Keep opt-outs explicit so changing the default never affects an existing peer.
    storage?.set(enabled, forKey: key)
  }

  func enableForNewPeer(_ peer: DeviceIdentity) { setEnabled(true, for: peer) }

  func prune(_ peers: [DeviceIdentity]) {
    let keep = Set(peers.map(key))
    for storedKey in storedKeys.subtracting(keep) { storage?.removeObject(forKey: storedKey) }
    enabledKeys.formIntersection(keep)
  }

  func clear() {
    for storedKey in storedKeys { storage?.removeObject(forKey: storedKey) }
    enabledKeys.removeAll()
  }

  private var storedKeys: Set<String> {
    Set(storage?.dictionaryRepresentation().keys.filter { $0.hasPrefix(Self.keyPrefix) } ?? [])
  }

  private func key(_ peer: DeviceIdentity) -> String {
    Self.keyPrefix + peer.deviceId + ":" + peer.fingerprint
  }
}

struct TransferReceiveDestinationSelection: Sendable {
  let bookmark: Data?
}

@Observable @MainActor final class TransferReceiveDestinationPreferences {
  private let storage: UserDefaults?
  private let key = "transfer.receiveDestinationBookmark"
  private var bookmark: Data?

  init(storage: UserDefaults? = nil) {
    self.storage = storage
    bookmark = storage?.data(forKey: key)
  }

  var hasCustomFolder: Bool { bookmark != nil }

  var summary: String {
    do { return try configuredFolder(selection()).lastPathComponent }
    catch { return "Unavailable folder" }
  }

  func selection() -> TransferReceiveDestinationSelection {
    TransferReceiveDestinationSelection(bookmark: bookmark)
  }

  func save(folder: URL) throws {
    try Self.validate(folder)
    let data = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    bookmark = data
    storage?.set(data, forKey: key)
  }

  func reset() {
    bookmark = nil
    storage?.removeObject(forKey: key)
  }

  func folderForReceive() throws -> URL {
    try folderForReceive(selection())
  }

  func folderForReceive(_ selection: TransferReceiveDestinationSelection) throws -> URL {
    let folder = try configuredFolder(selection)
    if selection.bookmark == nil {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    }
    return folder
  }

  private func configuredFolder(_ selection: TransferReceiveDestinationSelection) throws -> URL {
    guard let bookmark = selection.bookmark else {
      let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
      return downloads.appendingPathComponent("aniCe", isDirectory: true)
    }
    var stale = false
    let folder = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    guard !stale else { throw CocoaError(.fileReadNoPermission, userInfo: [NSLocalizedDescriptionKey: "The saved folder link has expired. Choose it again or reset to Downloads/aniCe."]) }
    try Self.validate(folder)
    return folder
  }

  private static func validate(_ folder: URL) throws {
    let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .volumeIsLocalKey])
    guard folder.isFileURL, values.isDirectory == true, values.isSymbolicLink != true,
      values.volumeIsLocal != false else {
      throw CocoaError(.fileReadNoPermission, userInfo: [NSLocalizedDescriptionKey: "Choose an available local folder."])
    }
  }
}

// Separates offer delivery and legacy-notice cleanup from the native notification center.
protocol TransferNotificationCenter: AnyObject {
  func pendingIdentifiers(completionHandler: @escaping @Sendable ([String]) -> Void)
  func deliveredIdentifiers(completionHandler: @escaping @Sendable ([String]) -> Void)
  func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping @Sendable (Bool, Error?) -> Void)
  func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?)
  func removeDeliveredNotifications(withIdentifiers identifiers: [String])
  func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: TransferNotificationCenter {}

// Builds transfer notification payloads without exposing incoming file names.
struct TransferNotificationContent: Equatable {
  let identifier: String
  let categoryIdentifier: String
  let title: String
  let body: String
  let userInfo: [String: String]

  // Offer text displays authenticated peerName, file count, and aggregate size only.
  // Peer-supplied file names are unvalidated CBOR strings that must not be presented in system banners.
  static func offer(batch: TransferBatch) -> TransferNotificationContent {
    let count = batch.files.count
    let countStr = "\(count) file\(count == 1 ? "" : "s")"
    let sizeStr = ByteCountFormatter.string(fromByteCount: batch.totalBytes, countStyle: .file)
    return TransferNotificationContent(
      identifier: "transfer-offer-\(batch.idString)",
      categoryIdentifier: MacTransferNotifier.Category.offer,
      title: "Incoming files from \(batch.peerName)",
      body: "\(countStr) · \(sizeStr)",
      userInfo: ["batchId": batch.idString]
    )
  }

  // Reports the verified destination folder where files were published on disk.
  static func completed(fileCount: Int, totalBytes: Int64, folder: URL?, batchId: UUID = UUID()) -> TransferNotificationContent {
    let countStr = "\(fileCount) file\(fileCount == 1 ? "" : "s")"
    let sizeStr = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    let folderName = folder?.lastPathComponent ?? "Downloads"
    return TransferNotificationContent(
      identifier: "transfer-received-\(batchId.uuidString.lowercased())",
      categoryIdentifier: MacTransferNotifier.Category.result,
      title: "Files received",
      body: "\(countStr) (\(sizeStr)) saved to \(folderName).",
      userInfo: ["batchId": batchId.uuidString.lowercased()]
    )
  }

}

@MainActor final class MacTransferNotifier: NSObject {
  enum Category {
    static let offer = "FILE_TRANSFER_OFFER"
    static let result = "TRANSFER_RESULT"
    static let paused = "FILE_TRANSFER_PAUSED"
    static let pausedSender = "FILE_TRANSFER_PAUSED_SENDER"
  }

  enum Action {
    static let accept = "ACCEPT_ACTION"
    static let choose = "CHOOSE_ACTION"
    static let decline = "DECLINE_ACTION"
    static let showInFinder = "SHOW_IN_FINDER"
    static let continueOverBluetooth = "CONTINUE_OVER_BLUETOOTH"
    static let cancelTransfer = "CANCEL_TRANSFER"
  }

  private weak var model: MacTransferModel?
  private let openMainWindow: () -> Void
  private let center: any TransferNotificationCenter
  private let preferences: TransferNotificationPreferences
  private let applicationIsActive: () -> Bool
  private let revealReceivedFolder: (URL) -> Void
  private let scheduleAction: (@escaping @MainActor () async -> Void) -> Void
  private let startupCleanup: Task<Void, Never>
  private var deliveryGeneration = 0
  private var activeOfferIdentifier: String?
  private var announcedCompletion: UUID?
  private struct Delivery {
    let content: TransferNotificationContent
    let operation: UUID
    let batchId: UUID
    let token: UUID
    let folder: URL?
  }
  private var pending: [String: Delivery] = [:]
  private var targets: [String: Delivery] = [:]
  private var completionOrder: [String] = []

  init(model: MacTransferModel, openMainWindow: @escaping () -> Void,
    center: any TransferNotificationCenter = UNUserNotificationCenter.current(),
    applicationIsActive: @escaping () -> Bool = { NSApp.isActive },
    revealReceivedFolder: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
    scheduleAction: @escaping (@escaping @MainActor () async -> Void) -> Void = { action in
      Task { @MainActor in await action() }
    }) {
    self.model = model
    self.openMainWindow = openMainWindow
    self.center = center
    self.applicationIsActive = applicationIsActive
    self.revealReceivedFolder = revealReceivedFolder
    self.scheduleAction = scheduleAction
    startupCleanup = Task { @MainActor [center] in
      let pending = await withCheckedContinuation { continuation in
        center.pendingIdentifiers { continuation.resume(returning: $0) }
      }
      let delivered = await withCheckedContinuation { continuation in
        center.deliveredIdentifiers { continuation.resume(returning: $0) }
      }
      let ids = Array(Set(pending + delivered).filter(Self.ownsIdentifier))
      center.removeDeliveredNotifications(withIdentifiers: ids)
      center.removePendingNotificationRequests(withIdentifiers: ids)
    }
    preferences = model.notificationPreferences
    super.init()
    model.onStateChanged = { [weak self] in self?.reconcilePending() }
    preferences.changed = { [weak self] in
      guard let self, !self.preferences.enabled else { return }
      self.deliveryGeneration += 1
      self.announcedCompletion = nil
      self.clearActiveOffer()
      for identifier in Array(self.pending.keys) { self.clear(identifier) }
    }
  }

  // Legacy pause categories stay recognizable for cleanup; unbound old responses are inert.
  static func notificationCategories() -> Set<UNNotificationCategory> {
    let acceptAction = UNNotificationAction(
      identifier: Action.accept,
      title: "Accept",
      options: []
    )
    let chooseAction = UNNotificationAction(
      identifier: Action.choose,
      title: "Review files",
      options: [.foreground]
    )
    let declineAction = UNNotificationAction(
      identifier: Action.decline,
      title: "Decline",
      options: [.destructive]
    )
    let offerCategory = UNNotificationCategory(
      identifier: Category.offer,
      actions: [acceptAction, chooseAction, declineAction],
      intentIdentifiers: [],
      options: [.customDismissAction]
    )

    let showAction = UNNotificationAction(
      identifier: Action.showInFinder,
      title: "Show in Finder",
      options: [.foreground]
    )
    let resultCategory = UNNotificationCategory(
      identifier: Category.result,
      actions: [showAction],
      intentIdentifiers: [],
      options: [.customDismissAction]
    )

    let continueAction = UNNotificationAction(
      identifier: Action.continueOverBluetooth,
      title: "Continue over Bluetooth",
      options: []
    )
    let cancelTransferAction = UNNotificationAction(
      identifier: Action.cancelTransfer,
      title: "Cancel transfer",
      options: [.destructive]
    )
    let pausedCategory = UNNotificationCategory(
      identifier: Category.paused,
      actions: [cancelTransferAction],
      intentIdentifiers: [],
      options: []
    )
    let pausedSenderCategory = UNNotificationCategory(
      identifier: Category.pausedSender,
      actions: [continueAction, cancelTransferAction],
      intentIdentifiers: [],
      options: []
    )

    return [offerCategory, resultCategory, pausedCategory, pausedSenderCategory]
  }

  func handle(_ event: TransferEvent) {
    switch event {
    case .incomingOffer(let batch):
      guard preferences.enabled, !applicationIsActive() else { return }
      let content = TransferNotificationContent.offer(batch: batch)
      guard activeOfferIdentifier != content.identifier else { return }
      activeOfferIdentifier = content.identifier
      post(content, batchId: batch.id)

    case .completed(let count, let bytes):
      clearActiveOffer()
      guard preferences.enabled, !applicationIsActive(), let model, model.receiving,
        case .completed(let batchId, let savedCount, let savedBytes) = model.state,
        savedCount == count, savedBytes == bytes, count > 0,
        model.publishedURLs.count == count, let folder = model.receiveFolder,
        announcedCompletion != batchId else { return }
      announcedCompletion = batchId
      post(TransferNotificationContent.completed(fileCount: count, totalBytes: bytes,
        folder: folder, batchId: batchId), batchId: batchId, folder: folder)

    case .paused, .resumed, .failed, .sentFromDrop:
      // Reconnection and progress transitions belong to the activity panel, not repeated system alerts.
      clearActiveOffer()
    }
  }

  private func clearActiveOffer() {
    if let id = activeOfferIdentifier {
      activeOfferIdentifier = nil
      clear(id)
    }
  }

  private func clear(_ identifier: String) {
    pending[identifier] = nil
    targets[identifier] = nil
    completionOrder.removeAll { $0 == identifier }
    center.removeDeliveredNotifications(withIdentifiers: [identifier])
    center.removePendingNotificationRequests(withIdentifiers: [identifier])
  }

  private static func ownsIdentifier(_ identifier: String) -> Bool {
    ["transfer-offer-", "transfer-received-", "transfer-paused-"].contains { identifier.hasPrefix($0) }
  }

  private func isCurrent(_ delivery: Delivery) -> Bool {
    guard let model, model.epoch == delivery.operation else { return false }
    if delivery.content.categoryIdentifier == Category.offer {
      return model.pendingOffer?.id == delivery.batchId && !model.autoReceivePreparing
    }
    guard case .completed(let batchId, _, _) = model.state else { return false }
    return model.receiving && batchId == delivery.batchId
  }

  private func reconcilePending() {
    guard activeOfferIdentifier != nil || !pending.isEmpty else { return }
    if let identifier = activeOfferIdentifier,
      targets[identifier].map({ !isCurrent($0) }) ?? pending[identifier].map({ !isCurrent($0) }) ?? true {
      clearActiveOffer()
    }
    for identifier in pending.filter({ !isCurrent($0.value) }).map(\.key) { clear(identifier) }
  }

  private func post(_ notification: TransferNotificationContent, batchId: UUID, folder: URL? = nil) {
    guard preferences.enabled, let model else { return }
    let delivery = Delivery(content: notification, operation: model.epoch, batchId: batchId, token: UUID(), folder: folder)
    pending[notification.identifier] = delivery
    let generation = deliveryGeneration
    // Authorization is asynchronous; publishing before approval can lose the first notice.
    center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
      Task { @MainActor in
        guard let self else { return }
        await self.startupCleanup.value
        guard self.pending[notification.identifier]?.token == delivery.token else { return }
        guard granted, self.preferences.enabled, self.deliveryGeneration == generation,
          self.isCurrent(delivery), !self.applicationIsActive() else {
          self.clear(notification.identifier)
          return
        }
        self.deliver(delivery)
      }
    }
  }

  private func deliver(_ delivery: Delivery) {
    let notification = delivery.content
    let content = UNMutableNotificationContent()
    content.title = notification.title
    content.body = notification.body
    content.categoryIdentifier = notification.categoryIdentifier
    content.userInfo = notification.userInfo
    content.userInfo["anice.transfer.token"] = delivery.token.uuidString.lowercased()
    content.threadIdentifier = "anice-file-transfer"
    content.sound = preferences.sound ? .default : nil

    let request = UNNotificationRequest(
      identifier: notification.identifier,
      content: content,
      trigger: nil
    )
    targets[notification.identifier] = delivery
    center.add(request) { [weak self] error in
      Task { @MainActor in
        guard let self else { return }
        guard self.targets[notification.identifier]?.token == delivery.token else {
          if self.targets[notification.identifier] == nil, self.pending[notification.identifier] == nil {
            self.center.removeDeliveredNotifications(withIdentifiers: [notification.identifier])
            self.center.removePendingNotificationRequests(withIdentifiers: [notification.identifier])
          }
          return
        }
        guard error == nil, self.pending[notification.identifier]?.token == delivery.token,
          self.isCurrent(delivery), self.preferences.enabled else {
          self.clear(notification.identifier)
          return
        }
        self.pending[notification.identifier] = nil
        if notification.categoryIdentifier == Category.result {
          self.completionOrder.append(notification.identifier)
          while self.completionOrder.count > 32 { self.clear(self.completionOrder[0]) }
        }
      }
    }
  }

  // Native responses carry only a local token; the original operation/folder stays in memory.
  func handleAction(_ actionIdentifier: String, identifier: String? = nil,
    category: String? = nil, sourceToken: String? = nil) {
    guard let identifier, let target = targets[identifier],
      target.content.categoryIdentifier == category,
      target.token.uuidString.lowercased() == sourceToken else { return }
    if actionIdentifier == UNNotificationDismissActionIdentifier { clear(identifier); return }
    if target.content.categoryIdentifier == Category.result {
      guard [Action.showInFinder, UNNotificationDefaultActionIdentifier].contains(actionIdentifier),
        let folder = target.folder, folder.isFileURL else { return }
      clear(identifier)
      revealReceivedFolder(folder)
      return
    }
    guard target.content.categoryIdentifier == Category.offer, isCurrent(target) else { return }
    switch actionIdentifier {
    case Action.accept, Action.decline:
      clearActiveOffer()
      clear(identifier)
      let generation = deliveryGeneration
      scheduleAction { [weak self] in
        guard let self, self.deliveryGeneration == generation,
          let model = self.model, self.isCurrent(target) else { return }
        if actionIdentifier == Action.accept { await model.acceptIncomingOffer() }
        else { await model.rejectIncomingOffer() }
      }
    case Action.choose, UNNotificationDefaultActionIdentifier:
      clearActiveOffer()
      clear(identifier)
      openMainWindow()
    default:
      break
    }
  }

  func clearAll() {
    deliveryGeneration += 1
    activeOfferIdentifier = nil
    for identifier in Array(Set(pending.keys).union(targets.keys)) { clear(identifier) }
  }
}
