// SPDX-License-Identifier: GPL-3.0-or-later
// Delivers native user notifications for incoming and completed file transfers.
import AppKit
import Foundation
import UserNotifications

// Pure notification payload builder decoupled from UNUserNotificationCenter for deterministic unit testing.
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
  static func completed(fileCount: Int, totalBytes: Int64, folder: URL?) -> TransferNotificationContent {
    let countStr = "\(fileCount) file\(fileCount == 1 ? "" : "s")"
    let sizeStr = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    let folderName = folder?.lastPathComponent ?? "Downloads"
    return TransferNotificationContent(
      identifier: "transfer-result-\(UUID().uuidString.prefix(8))",
      categoryIdentifier: MacTransferNotifier.Category.result,
      title: "Transfer complete",
      body: "\(countStr) (\(sizeStr)) saved to \(folderName).",
      userInfo: [:]
    )
  }

  static func failed(reason: String) -> TransferNotificationContent {
    return TransferNotificationContent(
      identifier: "transfer-failed-\(UUID().uuidString.prefix(8))",
      categoryIdentifier: MacTransferNotifier.Category.result,
      title: "Transfer failed",
      body: reason,
      userInfo: [:]
    )
  }

  // Shown when an action is clicked on a banner whose offer was already cancelled or expired.
  static func staleOfferNotice() -> TransferNotificationContent {
    return TransferNotificationContent(
      identifier: "transfer-stale-\(UUID().uuidString.prefix(8))",
      categoryIdentifier: MacTransferNotifier.Category.result,
      title: "Transfer unavailable",
      body: "The offer is no longer available.",
      userInfo: [:]
    )
  }
}

@MainActor final class MacTransferNotifier: NSObject {
  enum Category {
    static let offer = "FILE_TRANSFER_OFFER"
    static let result = "TRANSFER_RESULT"
  }

  enum Action {
    static let accept = "ACCEPT_ACTION"
    static let choose = "CHOOSE_ACTION"
    static let decline = "DECLINE_ACTION"
    static let showInFinder = "SHOW_IN_FINDER"
  }

  private weak var model: MacTransferModel?
  private let openMainWindow: () -> Void
  private let center: UNUserNotificationCenter
  private var hasRequestedAuth = false
  private var activeOfferIdentifier: String?

  init(model: MacTransferModel, openMainWindow: @escaping () -> Void, center: UNUserNotificationCenter = .current()) {
    self.model = model
    self.openMainWindow = openMainWindow
    self.center = center
    super.init()
  }

  // Registers modal actions: Accept saves unattended to ~/Downloads; Choose folder foregrounds aniCe for destination selection; Decline rejects; Show in Finder reveals published files.
  static func notificationCategories() -> Set<UNNotificationCategory> {
    let acceptAction = UNNotificationAction(
      identifier: Action.accept,
      title: "Accept",
      options: []
    )
    let chooseAction = UNNotificationAction(
      identifier: Action.choose,
      title: "Choose folder…",
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
      options: []
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
      options: []
    )

    return [offerCategory, resultCategory]
  }

  func handle(_ event: TransferEvent) {
    switch event {
    case .incomingOffer(let batch):
      requestAuthIfNeeded()
      let content = TransferNotificationContent.offer(batch: batch)
      activeOfferIdentifier = content.identifier
      post(content)

    case .completed(let fileCount, let totalBytes):
      clearActiveOffer()
      let content = TransferNotificationContent.completed(
        fileCount: fileCount,
        totalBytes: totalBytes,
        folder: model?.receiveFolder
      )
      post(content)

    case .failed(let reason):
      clearActiveOffer()
      let content = TransferNotificationContent.failed(reason: reason)
      post(content)
    }
  }

  private func clearActiveOffer() {
    if let id = activeOfferIdentifier {
      center.removeDeliveredNotifications(withIdentifiers: [id])
      center.removePendingNotificationRequests(withIdentifiers: [id])
      activeOfferIdentifier = nil
    }
  }

  // Requests notification authorization lazily on first transfer event.
  // Permission denial must never gate transfer execution, falling back to companion activity and main window.
  private func requestAuthIfNeeded() {
    guard !hasRequestedAuth else { return }
    hasRequestedAuth = true
    center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  private func post(_ notification: TransferNotificationContent) {
    let content = UNMutableNotificationContent()
    content.title = notification.title
    content.body = notification.body
    content.categoryIdentifier = notification.categoryIdentifier
    content.userInfo = notification.userInfo
    content.sound = .default

    let request = UNNotificationRequest(
      identifier: notification.identifier,
      content: content,
      trigger: nil
    )
    center.add(request) { error in
      if let error {
        NSLog("Transfer notification delivery failed: %@", error.localizedDescription)
      }
    }
  }

  // Fences action execution against stale offers: verifies pendingOffer != nil before dispatching.
  // Stale actions post an explicit notice rather than silently no-oping.
  func handleAction(_ actionIdentifier: String) {
    switch actionIdentifier {
    case Action.accept:
      guard let model, model.pendingOffer != nil else {
        post(TransferNotificationContent.staleOfferNotice())
        return
      }
      let destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory())
      Task { [weak model] in
        await model?.acceptIncomingOffer(destination: destination)
      }

    case Action.choose:
      openMainWindow()

    case Action.decline:
      guard let model, model.pendingOffer != nil else {
        post(TransferNotificationContent.staleOfferNotice())
        return
      }
      Task { [weak model] in
        await model?.rejectIncomingOffer()
      }

    case Action.showInFinder:
      if let urls = model?.publishedURLs, !urls.isEmpty {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
      } else if let folder = model?.receiveFolder {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
      }

    case UNNotificationDefaultActionIdentifier:
      openMainWindow()

    default:
      break
    }
  }
}
