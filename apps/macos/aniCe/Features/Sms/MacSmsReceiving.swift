// SPDX-License-Identifier: GPL-3.0-or-later
// Reassembles authenticated SMS streams and admits live, provider and search rows.
import CryptoKit
import Foundation

extension MacSmsModel {
  func beginStream(_ state: PeerState, _ m: SmsMessage, _ descriptor: ChannelDescriptor) -> Bool {
    let streamId = m.text(0)
    let requestId = m.text(1)
    if !requestId.isEmpty {
      let history = state.conversations.values.contains { $0.requestId == requestId && $0.transport == descriptor.transport }
      let searching = state.search?.requestId == requestId && state.search?.transport == descriptor.transport
      if !history && !searching { return false }
    }
    if let existing = state.assemblies[streamId] {
      if existing.descriptor == descriptor, existing.begin == m { return true }
      state.assemblies[streamId] = nil
      // A conflicting duplicate on one channel is invalid; a retry on the other channel restarts the stream.
      if existing.descriptor == descriptor {
        if existing.requestId.isEmpty { ack(descriptor, streamId, 6) }
        return true
      }
    }
    guard state.assemblies.count < 16 else { if requestId.isEmpty { ack(descriptor, streamId, 2) }; return false }
    state.assemblies[streamId] = Assembly(descriptor, m, deadline: requestDeadline(descriptor.transport))
    schedule()
    return true
  }

  func fragment(_ state: PeerState, _ m: SmsMessage, _ descriptor: ChannelDescriptor) -> Bool {
    let streamId = m.text(0)
    guard let assembly = state.assemblies[streamId], assembly.descriptor == descriptor, !assembly.committing else { return false }
    let index = Int(m.number(1)), data = m.bytes(2)
    let expected = index == assembly.count - 1 ? assembly.totalBytes - index * 3072 : 3072
    guard index < assembly.count, data.count == expected, index <= assembly.fragments.count,
      index == assembly.fragments.count || assembly.fragments[index] == data else {
      state.assemblies[streamId] = nil
      if assembly.requestId.isEmpty { ack(descriptor, streamId, 6) }
      return true
    }
    if index == assembly.fragments.count { assembly.fragments.append(data) }
    return true
  }

  func commit(_ state: PeerState, _ m: SmsMessage, _ descriptor: ChannelDescriptor) async -> DataHandling {
    let streamId = m.text(0)
    guard let assembly = state.assemblies[streamId], assembly.descriptor == descriptor else { return .discarded }
    guard assembly.fragments.count == assembly.count, !assembly.committing else {
      state.assemblies[streamId] = nil
      if assembly.requestId.isEmpty { ack(descriptor, streamId, 6) }
      return .handled
    }
    assembly.committing = true
    let fragments = assembly.fragments, digest = assembly.digest
    let text = await Task.detached { () -> String? in
      let data = fragments.reduce(into: Data()) { $0.append($1) }
      guard Data(SHA256.hash(data: data)) == digest, let body = String(data: data, encoding: .utf8),
        !body.contains("\0") else { return nil }
      return body
    }.value
    guard live(descriptor), peers[key(descriptor.peer)] === state,
      state.assemblies[streamId] === assembly, assembly.deadline > now(),
      assembly.requestId.isEmpty || state.conversations.values.contains(where: { $0.requestId == assembly.requestId })
        || state.search?.requestId == assembly.requestId else { return .discarded }
    state.assemblies[streamId] = nil
    guard let text else {
      if assembly.requestId.isEmpty { ack(descriptor, streamId, 6) }
      return .handled
    }
    // Search hits stay in the peer's search buffer; they never touch conversations, threads or notifications.
    if assembly.requestId.isEmpty {
      ack(descriptor, streamId, 0)
      await admitLive(state, assembly, body: text, digest: digest, peer: descriptor.peer)
    } else if state.search?.requestId == assembly.requestId {
      admitSearch(state, assembly, body: text)
    } else {
      admitProvider(state, assembly, body: text, digest: digest)
    }
    return .handled
  }

  func admitLive(_ state: PeerState, _ assembly: Assembly, body: String, digest: Data, peer: DeviceIdentity) async {
    let time = now()
    let normalized = smsNormalizedAddress(assembly.address)
    let mark = state.contents.firstIndex { contentMatches($0, assembly, digest: digest, normalized: normalized) && $0.expiry > time }
    // A provider copy of the same message owns its row, but only a delivered notification suppresses the next one:
    // an event that lands after the panel already fetched the provider copy still announces the message.
    let announced = mark.map { state.contents[$0].notified } ?? false
    let duplicate = state.known[assembly.messageId] != nil || mark != nil
    state.known[assembly.messageId] = time + 600
    if let index = mark {
      state.contents[index].expiry = time + 600
      if assembly.messageId.hasPrefix("live:") { state.contents[index].liveMessageId = assembly.messageId }
    } else {
      state.contents.append(ContentMark(address: normalized, digest: digest, dateMillis: assembly.dateMillis,
        expiry: time + 600, notified: false, liveMessageId: assembly.messageId, direction: assembly.direction,
        subscriptionId: assembly.subscriptionId))
    }
    state.liveReceived += 1
    if duplicate { state.liveSuppressed += 1 }
    guard let conversation = conversation(state, normalized) else { return }
    if !duplicate {
      let row = SmsMessageRow(messageId: assembly.messageId, address: assembly.address, dateMillis: assembly.dateMillis,
        direction: assembly.direction, unread: assembly.unread, body: body, digest: digest,
        subscriptionId: assembly.subscriptionId)
      conversation.live.append(row)
      noteArrival(conversation, assembly.messageId)
      upsertCard(state, address: assembly.address, snippet: body, dateMillis: assembly.dateMillis, unread: assembly.unread ? 1 : 0)
    }
    if announced { return }
    state.status = "Message received"
    let outcome = await notifier.post(SmsNotification(identifier: smsNotificationPrefix + assembly.messageId, peerKey: key(peer),
      peerName: peer.deviceName, address: assembly.address, threadId: conversation.threadId,
      threadIdentifier: normalized, body: body, failure: false))
    guard peers[key(peer)] === state, live(assembly.descriptor) else { return }
    if outcome == .submitted || outcome == .duplicate {
      if outcome == .submitted { state.liveNotified += 1 }
      if let index = state.contents.firstIndex(where: {
        contentMatches($0, assembly, digest: digest, normalized: normalized)
      }) { state.contents[index].notified = true }
    }
    schedule()
  }

  /** One content key with live-ID tolerance and subscription awareness, so two SIM copies never collapse. */
  func contentMatches(_ mark: ContentMark, _ assembly: Assembly, digest: Data, normalized: String) -> Bool {
    guard mark.direction == assembly.direction, mark.address == normalized, mark.digest == digest,
      abs(mark.dateMillis - assembly.dateMillis) <= 5000 else { return false }
    guard mark.subscriptionId == 0 || assembly.subscriptionId == 0 || mark.subscriptionId == assembly.subscriptionId else { return false }
    return mark.liveMessageId == nil || mark.liveMessageId == assembly.messageId || !assembly.messageId.hasPrefix("live:")
  }

  func admitProvider(_ state: PeerState, _ assembly: Assembly, body: String, digest: Data) {
    guard let (normalized, conversation) = state.conversations.first(where: { $0.value.requestId == assembly.requestId }) else { return }
    let time = now()
    state.known[assembly.messageId] = time + 600
    // The provider copy never notifies; an existing mark keeps the announced state its live copy may have set.
    if let index = state.contents.firstIndex(where: {
      contentMatches($0, assembly, digest: digest, normalized: normalized)
    }) {
      state.contents[index].expiry = time + 600
    } else {
      state.contents.append(ContentMark(address: normalized, digest: digest, dateMillis: assembly.dateMillis,
        expiry: time + 600, notified: false, direction: assembly.direction, subscriptionId: assembly.subscriptionId))
    }
    // The provider record wins: its live copy is replaced and an existing posted notification is untouched.
    // The replacement inherits the live copy's arrival slot, so a refresh cannot demote a newer answer.
    if let index = conversation.live.firstIndex(where: {
      !$0.pending && assembly.dateMillis >= $0.earliestProviderMillis &&
        $0.direction == assembly.direction && $0.digest == digest &&
        ($0.messageId == assembly.messageId || !$0.isProviderRecord && abs($0.dateMillis - assembly.dateMillis) <= 5000) &&
        smsNormalizedAddress($0.address) == normalized &&
        ($0.subscriptionId == 0 || assembly.subscriptionId == 0 || $0.subscriptionId == assembly.subscriptionId)
    }) {
      let id = conversation.live[index].messageId
      let order = conversation.arrival.removeValue(forKey: id)
      let sortDate = conversation.sortDates.removeValue(forKey: id)
      conversation.live.remove(at: index)
      if let sortDate { conversation.sortDates[assembly.messageId] = sortDate }
      if let order, conversation.arrival[assembly.messageId] == nil { conversation.arrival[assembly.messageId] = order }
    }
    conversation.rows.removeAll { $0.messageId == assembly.messageId }
    conversation.rows.append(SmsMessageRow(messageId: assembly.messageId, address: assembly.address, dateMillis: assembly.dateMillis,
      direction: assembly.direction, unread: assembly.unread, body: body, digest: digest, subscriptionId: assembly.subscriptionId))
    if let index = state.threads.firstIndex(where: { $0.key == normalized }) {
      var card = state.threads[index]
      card.threadId = assembly.threadId
      state.threads[index] = card
    }
  }

  /** A search hit adds nothing to live dedupe, the thread list or notification state. */
  func admitSearch(_ state: PeerState, _ assembly: Assembly, body: String) {
    guard let search = state.search, search.requestId == assembly.requestId,
      search.results.count < 200, !search.results.contains(where: { $0.messageId == assembly.messageId }) else { return }
    search.results.append(SmsSearchRow(messageId: assembly.messageId, threadId: assembly.threadId,
      address: assembly.address, dateMillis: assembly.dateMillis, direction: assembly.direction, body: body,
      subscriptionId: assembly.subscriptionId))
  }

}
