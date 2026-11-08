// SPDX-License-Identifier: GPL-3.0-or-later
// Receives Android notifications, presents native Mac alerts and forwards user actions.
import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UserNotifications

struct MirroredNotification: Equatable, Sendable {
  let snapshotToken: String
  let id: String
  let epoch: String
  let sequence: Int64
  let packageName: String
  let appName: String
  let title: String
  let body: String
  let sourceIcon: Data?
  let actions: [MirroredNotificationAction]
}

struct MirroredNotificationAction: Equatable, Sendable {
  let index: Int
  let title: String
  let replyPlaceholder: String
}

private struct NotificationSnapshot {
  let peerKey: String
  let epoch: String
  let highWater: Int64
  var seen = Set<String>()
}

private struct StoredNotification {
  let peerKey: String
  let value: MirroredNotification
}

struct MacMirrorCategorySnapshot: @unchecked Sendable {
  let values: Set<UNNotificationCategory>
}

protocol MacMirrorNotificationCenter: AnyObject {
  func mirrorPendingIdentifiers(completionHandler: @escaping @Sendable ([String]) -> Void)
  func mirrorDeliveredIdentifiers(completionHandler: @escaping @Sendable ([String]) -> Void)
  func mirrorCategories(completionHandler: @escaping @Sendable (MacMirrorCategorySnapshot) -> Void)
  func setMirrorCategories(_ categories: Set<UNNotificationCategory>)
  func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?)
  func removeDeliveredNotifications(withIdentifiers identifiers: [String])
  func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: MacMirrorNotificationCenter {
  func mirrorPendingIdentifiers(completionHandler: @escaping @Sendable ([String]) -> Void) {
    getPendingNotificationRequests { completionHandler($0.map(\.identifier)) }
  }
  func mirrorDeliveredIdentifiers(completionHandler: @escaping @Sendable ([String]) -> Void) {
    getDeliveredNotifications { completionHandler($0.map { $0.request.identifier }) }
  }
  func mirrorCategories(completionHandler: @escaping @Sendable (MacMirrorCategorySnapshot) -> Void) {
    getNotificationCategories { completionHandler(MacMirrorCategorySnapshot(values: $0)) }
  }
  func setMirrorCategories(_ categories: Set<UNNotificationCategory>) { setNotificationCategories(categories) }
}

@MainActor
final class MacNotificationMirrorNotifier: NSObject {
  nonisolated static let categoryPrefix = "ANICE_MIRROR_"
  private struct Target {
    let peerKey: String
    let sourceId: String
    let epoch: String
    let sequence: Int64
    let category: String
    let actions: [Int: MirroredNotificationAction]
    var consumedActions: Set<String> = []
  }
  enum UserAction {
    case invoke(index: Int, text: String)
    case dismiss
  }

  var onAction: (String, String, String, Int64, UserAction) -> Void = { _, _, _, _, _ in }
  private let center: any MacMirrorNotificationCenter
  private var targets: [String: Target] = [:]
  private var registeredCategories: [String: UNNotificationCategory] = [:]
  private var generations: [String: (peerKey: String, token: String)] = [:]
  private let startupCleanup: Task<Void, Never>

  init(center: any MacMirrorNotificationCenter = UNUserNotificationCenter.current()) {
    self.center = center
    startupCleanup = Task { @MainActor [weak center] in
      guard let center else { return }
      let pending = await withCheckedContinuation { continuation in
        center.mirrorPendingIdentifiers { continuation.resume(returning: $0) }
      }
      let delivered = await withCheckedContinuation { continuation in
        center.mirrorDeliveredIdentifiers { continuation.resume(returning: $0) }
      }
      let ids = Set(pending + delivered)
        .filter { $0.hasPrefix(Self.identifierPrefix) }
      center.removePendingNotificationRequests(withIdentifiers: Array(ids))
      center.removeDeliveredNotifications(withIdentifiers: Array(ids))
    }
    super.init()
  }

  func post(peerKey: String, value: MirroredNotification) async {
    let identifier = Self.identifier(peerKey: peerKey, sourceId: value.id)
    let generation = UUID().uuidString.lowercased()
    generations[identifier] = (peerKey, generation)
    await startupCleanup.value
    let category = categoryFor(value.actions)
    await register(category: category, actions: value.actions)
    guard generations[identifier]?.token == generation else { return }
    targets[identifier] = Target(peerKey: peerKey, sourceId: value.id, epoch: value.epoch,
      sequence: value.sequence, category: category, actions: Dictionary(uniqueKeysWithValues: value.actions.map { ($0.index, $0) }))
    center.removeDeliveredNotifications(withIdentifiers: [identifier])
    center.removePendingNotificationRequests(withIdentifiers: [identifier])
    let content = UNMutableNotificationContent()
    content.title = value.title.isEmpty ? value.appName : value.title
    content.subtitle = value.title.isEmpty ? "" : value.appName
    content.body = value.body
    content.categoryIdentifier = category
    content.threadIdentifier = value.packageName
    content.userInfo = ["anice.mirror.epoch": value.epoch, "anice.mirror.sequence": value.sequence]
    content.sound = value.snapshotToken.isEmpty ? .default : nil
    content.interruptionLevel = value.snapshotToken.isEmpty ? .active : .passive
    let iconAttachment = sourceIconAttachment(value.sourceIcon)
    if let iconAttachment { content.attachments = [iconAttachment.value] }
    let iconFileURL = iconAttachment?.url
    center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { [weak self] error in
      if let iconFileURL { try? FileManager.default.removeItem(at: iconFileURL) }
      guard error != nil else { return }
      Task { @MainActor in
        guard let self, self.generations[identifier]?.token == generation else { return }
        self.targets[identifier] = nil
      }
    }
  }

  private func sourceIconAttachment(_ data: Data?) -> (value: UNNotificationAttachment, url: URL)? {
    guard let data,
          let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
          (1...128).contains(image.width), (1...128).contains(image.height) else { return nil }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("anice-mirror-\(UUID().uuidString).png", isDirectory: false)
    do {
      try data.write(to: url, options: .atomic)
      let value = try UNNotificationAttachment(identifier: "source-app-icon", url: url,
        options: [UNNotificationAttachmentOptionsTypeHintKey: UTType.png.identifier])
      return (value, url)
    } catch {
      try? FileManager.default.removeItem(at: url)
      return nil
    }
  }

  func clear(peerKey: String) {
    for identifier in generations.filter({ $0.value.peerKey == peerKey }).map(\.key) { clear(identifier: identifier) }
  }

  func clear(peerKey: String, sourceId: String) {
    clear(identifier: Self.identifier(peerKey: peerKey, sourceId: sourceId))
  }

  func clearAll() {
    let known = Set(generations.keys)
    for identifier in known { clear(identifier: identifier) }
    Task { @MainActor [center] in
      let pending = await withCheckedContinuation { continuation in
        center.mirrorPendingIdentifiers { continuation.resume(returning: $0) }
      }
      let delivered = await withCheckedContinuation { continuation in
        center.mirrorDeliveredIdentifiers { continuation.resume(returning: $0) }
      }
      let ids = Set(pending + delivered)
        .filter { $0.hasPrefix(Self.identifierPrefix) }
      center.removePendingNotificationRequests(withIdentifiers: Array(ids))
      center.removeDeliveredNotifications(withIdentifiers: Array(ids))
    }
  }

  @discardableResult
  func handleAction(category: String, action: String, identifier: String, userText: String,
    sourceEpoch: String?, sourceSequence: Int64?) -> Bool {
    guard category.hasPrefix(Self.categoryPrefix), var target = targets[identifier], target.category == category,
          target.epoch == sourceEpoch, target.sequence == sourceSequence else { return false }
    if action == UNNotificationDismissActionIdentifier {
      targets[identifier] = nil
      onAction(target.peerKey, target.sourceId, target.epoch, target.sequence, .dismiss)
      return true
    }
    if action == UNNotificationDefaultActionIdentifier {
      guard target.consumedActions.insert(action).inserted else { return false }
      targets[identifier] = target
      onAction(target.peerKey, target.sourceId, target.epoch, target.sequence, .invoke(index: -1, text: ""))
      return true
    }
    guard action.hasPrefix("ANICE_MIRROR_ACTION_"),
          let index = Int(action.dropFirst("ANICE_MIRROR_ACTION_".count)), target.actions[index] != nil else { return false }
    guard target.consumedActions.insert(action).inserted else { return false }
    targets[identifier] = target
    let text = notificationText(userText, maxBytes: 1024)
    onAction(target.peerKey, target.sourceId, target.epoch, target.sequence,
      .invoke(index: index, text: target.actions[index]?.replyPlaceholder.isEmpty == false ? text : ""))
    return true
  }

  private func clear(identifier: String) {
    generations[identifier] = nil
    targets[identifier] = nil
    center.removeDeliveredNotifications(withIdentifiers: [identifier])
    center.removePendingNotificationRequests(withIdentifiers: [identifier])
  }

  private func categoryFor(_ actions: [MirroredNotificationAction]) -> String {
    let shape = actions.map { "\($0.index):\($0.title):\($0.replyPlaceholder)" }.joined(separator: "|")
    let digest = SHA256.hash(data: Data(shape.utf8)).map { String(format: "%02x", $0) }.joined()
    return Self.categoryPrefix + String(digest.prefix(24))
  }

  private func register(category identifier: String, actions: [MirroredNotificationAction]) async {
    guard registeredCategories[identifier] == nil else { return }
    let nativeActions: [UNNotificationAction] = actions.map { item in
      let actionId = "ANICE_MIRROR_ACTION_\(item.index)"
      if !item.replyPlaceholder.isEmpty {
        return UNTextInputNotificationAction(identifier: actionId, title: item.title, options: [],
          textInputButtonTitle: "Send", textInputPlaceholder: item.replyPlaceholder)
      }
      return UNNotificationAction(identifier: actionId, title: item.title, options: [])
    }
    let next = UNNotificationCategory(identifier: identifier, actions: nativeActions, intentIdentifiers: [], options: [.customDismissAction])
    let existing = await withCheckedContinuation { continuation in
      center.mirrorCategories { continuation.resume(returning: $0) }
    }
    registeredCategories[identifier] = next
    center.setMirrorCategories(existing.values.union(registeredCategories.values))
  }

  private static let identifierPrefix = "anice-mirror-"
  private static func identifier(peerKey: String, sourceId: String) -> String {
    let peerHash = SHA256.hash(data: Data(peerKey.utf8)).map { String(format: "%02x", $0) }.joined()
    return identifierPrefix + String(peerHash.prefix(16)) + "-" + sourceId
  }
}

@MainActor
final class MacNotificationMirrorModel: FeatureHandler {
  private struct Link {
    let channel: any SecuredChannel
    var remoteCapability = false
  }
  private var links: [String: Link] = [:]
  private var epochs: [String: String] = [:]
  private var snapshots: [String: NotificationSnapshot] = [:]
  private var records: [String: StoredNotification] = [:]
  private var removals: [String: Int64] = [:]
  private var snapshotFloors: [String: Int64] = [:]
  private var sourceIcons: [String: Data] = [:]
  private let notifier: MacNotificationMirrorNotifier

  init(notifier: MacNotificationMirrorNotifier) {
    self.notifier = notifier
    notifier.onAction = { [weak self] peerKey, id, epoch, sequence, action in
      self?.perform(peerKey: peerKey, id: id, epoch: epoch, sequence: sequence, action: action)
    }
  }

  func available(_ channel: any SecuredChannel) {
    guard channel.descriptor.peer.platform == "android" else { return }
    let transport = channel.descriptor.transport
    if let old = links[transport] { retired(old.channel.descriptor) }
    links[transport] = Link(channel: channel)
    send(NotificationWireMessage(kind: 1, fields: [.integer(NotificationWireMessage.maxActions)]), on: channel)
  }

  func retired(_ descriptor: ChannelDescriptor) {
    guard links[descriptor.transport]?.channel.descriptor == descriptor else { return }
    links[descriptor.transport] = nil
    let peerKey = key(descriptor.peer)
    guard !links.values.contains(where: { key($0.channel.descriptor.peer) == peerKey }) else { return }
    epochs[peerKey] = nil
    snapshotFloors[peerKey] = nil
    removals = removals.filter { !$0.key.hasPrefix(peerKey + ":") }
    snapshots = snapshots.filter { $0.value.peerKey != peerKey }
    sourceIcons = sourceIcons.filter { !$0.key.hasPrefix(peerKey + ":") }
    for recordKey in records.filter({ $0.value.peerKey == peerKey }).map(\.key) { records[recordKey] = nil }
    notifier.clear(peerKey: peerKey)
  }

  func capacityAvailable(_ descriptor: ChannelDescriptor) {}

  func handle(_ bytes: Data, on descriptor: ChannelDescriptor) async -> DataHandling {
    guard let link = links[descriptor.transport], link.channel.descriptor == descriptor else { return .discarded }
    let message: NotificationWireMessage
    do { guard let decoded = try NotificationWireMessage.decode(bytes) else { return .unrecognized }; message = decoded }
    catch { return .discarded }
    if message.kind == 1 {
      if !link.remoteCapability {
        links[descriptor.transport]?.remoteCapability = true
        send(NotificationWireMessage(kind: 1, fields: [.integer(NotificationWireMessage.maxActions)]), on: link.channel)
      }
      return .handled
    }
    guard link.remoteCapability else { return .discarded }
    let peerKey = key(descriptor.peer)
    do {
      switch message.kind {
      case 2: try await receive(message, peerKey: peerKey)
      case 3: try remove(message, peerKey: peerKey)
      case 4: try beginSnapshot(message, peerKey: peerKey)
      case 5: try await finishSnapshot(message, peerKey: peerKey)
      case 7: break
      case 9:
        guard descriptor.transport == "lan" else { return .discarded }
        try cacheSourceIcon(message, peerKey: peerKey)
      default: return .discarded
      }
      return .handled
    } catch { return .discarded }
  }

  private func cacheSourceIcon(_ message: NotificationWireMessage, peerKey: String) throws {
    let packageName = try message.text(0)
    let key = peerKey + ":" + packageName
    if sourceIcons[key] == nil, sourceIcons.count >= 128, let oldest = sourceIcons.keys.first {
      sourceIcons[oldest] = nil
    }
    sourceIcons[key] = try message.bytes(1)
  }

  private func beginSnapshot(_ message: NotificationWireMessage, peerKey: String) throws {
    let token = try message.text(0), epoch = try message.text(1), highWater = try message.number(2)
    if epochs[peerKey] != epoch {
      epochs[peerKey] = epoch
      snapshotFloors[peerKey] = nil
      removals = removals.filter { !$0.key.hasPrefix(peerKey + ":") }
      let oldKeys = records.filter { $0.value.peerKey == peerKey }.map(\.key)
      for recordKey in oldKeys {
        guard let record = records.removeValue(forKey: recordKey) else { continue }
        notifier.clear(peerKey: peerKey, sourceId: record.value.id)
      }
    }
    snapshots[token] = NotificationSnapshot(peerKey: peerKey, epoch: epoch, highWater: highWater)
    while snapshots.count > 8, let oldest = snapshots.keys.first { snapshots[oldest] = nil }
  }

  private func receive(_ message: NotificationWireMessage, peerKey: String) async throws {
    let token = try message.text(0)
    let packageName = try message.text(4)
    let value = MirroredNotification(
      snapshotToken: token, id: try message.text(1), epoch: try message.text(2), sequence: try message.number(3),
      packageName: packageName, appName: try message.text(5), title: try message.text(6), body: try message.text(7),
      sourceIcon: sourceIcons[peerKey + ":" + packageName],
      actions: try message.actionRows(8).map { .init(index: $0.0, title: $0.1, replyPlaceholder: $0.2) },
    )
    if !token.isEmpty {
      guard var snapshot = snapshots[token], snapshot.peerKey == peerKey, snapshot.epoch == value.epoch else { throw NotificationWireError.malformed }
      guard value.sequence <= snapshot.highWater else { throw NotificationWireError.malformed }
      snapshot.seen.insert(value.id)
      snapshots[token] = snapshot
    }
    if epochs[peerKey] == nil && token.isEmpty { epochs[peerKey] = value.epoch }
    guard epochs[peerKey] == value.epoch else { return }
    let recordKey = peerKey + ":" + value.id
    if let old = records[recordKey], old.value.epoch == value.epoch, old.value.sequence >= value.sequence {
      guard old.value.sequence == value.sequence, old.value.sourceIcon == nil,
            let icon = sourceIcons[peerKey + ":" + packageName] else { return }
      // A matching LAN snapshot can enrich an alert first received over BLE without sounding again.
      let enriched = MirroredNotification(snapshotToken: token.isEmpty ? "icon-refresh" : token,
        id: value.id, epoch: value.epoch, sequence: value.sequence, packageName: value.packageName,
        appName: value.appName, title: value.title, body: value.body, sourceIcon: icon, actions: value.actions)
      records[recordKey] = StoredNotification(peerKey: peerKey, value: enriched)
      await notifier.post(peerKey: peerKey, value: enriched)
      return
    }
    guard value.sequence > (snapshotFloors[peerKey] ?? 0),
          value.sequence > (removals[recordKey] ?? 0) else { return }
    records[recordKey] = StoredNotification(peerKey: peerKey, value: value)
    await notifier.post(peerKey: peerKey, value: value)
  }

  private func remove(_ message: NotificationWireMessage, peerKey: String) throws {
    let id = try message.text(0), epoch = try message.text(1), sequence = try message.number(2)
    guard epochs[peerKey] == epoch else { return }
    let recordKey = peerKey + ":" + id
    if sequence > (snapshotFloors[peerKey] ?? 0) {
      removals[recordKey] = max(removals[recordKey] ?? 0, sequence)
    }
    guard let current = records[recordKey], current.value.epoch == epoch, sequence >= current.value.sequence else { return }
    records[recordKey] = nil
    notifier.clear(peerKey: peerKey, sourceId: id)
  }

  private func finishSnapshot(_ message: NotificationWireMessage, peerKey: String) async throws {
    let token = try message.text(0)
    guard snapshots[token]?.peerKey == peerKey else { return }
    guard let snapshot = snapshots.removeValue(forKey: token) else { return }
    guard epochs[snapshot.peerKey] == snapshot.epoch else { return }
    let staleKeys = records.compactMap { recordKey, record in
      record.peerKey == snapshot.peerKey && record.value.epoch == snapshot.epoch &&
        record.value.sequence <= snapshot.highWater && !snapshot.seen.contains(record.value.id) ? recordKey : nil
    }
    for recordKey in staleKeys {
      guard let record = records.removeValue(forKey: recordKey) else { continue }
      notifier.clear(peerKey: snapshot.peerKey, sourceId: record.value.id)
    }
    // A completed snapshot replaces older removal entries with one shared revision floor.
    let floor = max(snapshotFloors[snapshot.peerKey] ?? 0, snapshot.highWater)
    snapshotFloors[snapshot.peerKey] = floor
    removals = removals.filter { !$0.key.hasPrefix(snapshot.peerKey + ":") || $0.value > floor }
  }

  private func perform(peerKey: String, id: String, epoch: String, sequence: Int64,
    action: MacNotificationMirrorNotifier.UserAction) {
    guard let record = records[peerKey + ":" + id], record.value.epoch == epoch, record.value.sequence == sequence,
          let channel = links.values.map(\.channel).filter({ key($0.descriptor.peer) == peerKey })
            .sorted(by: { $0.descriptor.transport == "lan" && $1.descriptor.transport != "lan" }).first else { return }
    let requestId = UUID().uuidString.lowercased()
    let message: NotificationWireMessage
    switch action {
    case .invoke(let index, let text):
      let safeText = notificationText(text, maxBytes: 1024)
      message = NotificationWireMessage(kind: 6, fields: [
        .text(requestId), .text(id), .text(epoch), .integer(sequence), .integer(Int64(index)), .text(safeText),
      ])
    case .dismiss:
      message = NotificationWireMessage(kind: 8, fields: [
        .text(requestId), .text(id), .text(epoch), .integer(sequence),
      ])
      records[peerKey + ":" + id] = nil
      removals[peerKey + ":" + id] = sequence
    }
    send(message, on: channel)
  }

  private func send(_ message: NotificationWireMessage, on channel: any SecuredChannel) {
    Task { try? await channel.sendData(message.encode()) }
  }

  private func key(_ peer: DeviceIdentity) -> String { peer.deviceId + ":" + peer.fingerprint }
}
