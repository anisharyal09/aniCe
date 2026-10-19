// SPDX-License-Identifier: GPL-3.0-or-later
// Presents phone conversations, on-demand history, replies and notification preview controls.
import AppKit
import SwiftUI

struct SmsSettingsView: View {
  let preferences: SmsPreferences
  let peers: [PeerTrustRecord]
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Messages").font(.headline)
      if peers.isEmpty {
        Text("Pair a phone to relay messages.").font(.caption)
          .foregroundStyle(AniCePalette.secondaryText(scheme))
      } else {
        ForEach(peers) { record in
          Toggle("Show message text in notifications · \(record.peer.deviceName)",
            isOn: Binding(get: { preferences.preview(record.peer) },
              set: { preferences.set(record.peer, $0) }))
            .toggleStyle(.checkbox).controlSize(.small).tint(AniCePalette.accent(scheme))
        }
        Text("Notifications hide message text until you enable this for that phone.")
          .font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
      }
    }
    .onAppear { preferences.prune(peers.map(\.peer)) }
  }
}

struct SmsView: View {
  let model: MacSmsModel
  let peers: [PeerTrustRecord]
  @State private var peerKey = ""
  @State private var address = ""
  @State private var draft = ""
  @State private var query = ""
  @State private var expanded: Set<String> = []
  @State private var submittedDraft: String?
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.colorScheme) private var scheme

  private var peer: DeviceIdentity? {
    peers.first { $0.peer.deviceId + ":" + $0.peer.fingerprint == peerKey }?.peer
  }
  private var destination: String { peer.map { model.destination($0, address: address) } ?? address }
  /// A picker only helps when more than one phone can serve the panel; a single connected phone is used directly.
  private var selectable: [PeerTrustRecord] {
    let connected = peers.filter { model.connected($0.peer) }
    return connected.count > 1 ? connected : (connected.isEmpty ? peers : connected)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if selectable.count > 1 {
        Picker("Phone", selection: $peerKey) {
          ForEach(selectable) { record in
            Text(record.peer.deviceName).tag(record.peer.deviceId + ":" + record.peer.fingerprint)
          }
        }.labelsHidden().frame(maxWidth: 260)
      }
      if !model.notificationStatus.isEmpty {
        Text(model.notificationStatus).font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
      }
      if let peer {
        if !model.supports(peer) {
          Text(model.connected(peer) ? "Waiting for your phone" : "Connect aniCe on your phone first")
            .font(.callout).foregroundStyle(AniCePalette.secondaryText(scheme))
        }
        if address.isEmpty { threads(peer) } else { conversation(peer) }
        // The subscription list is asked for once the phone is ready; without a second SIM nothing appears.
        Color.clear.frame(height: 0).task(id: peerKey + (model.supports(peer) ? "+ready" : "")) { model.requestSims(peer) }
      } else {
        Text("Pair a phone to relay messages.").foregroundStyle(AniCePalette.secondaryText(scheme))
      }
    }
    .onAppear { select() }
    .task { await model.refreshNotificationSettings() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { Task { await model.refreshNotificationSettings() } }
    }
    .onChange(of: peer.map { model.sending($0) } ?? false) { wasSending, isSending in
      if wasSending && !isSending, let peer, model.status(peer) == "Sent", draft == submittedDraft { draft = "" }
      if !isSending { submittedDraft = nil }
    }
    .onChange(of: peers.map { $0.peer.deviceId + ":" + $0.peer.fingerprint }) { _, _ in select() }
    .onChange(of: peers.map { model.connected($0.peer) }) { _, _ in select() }
  }

  private func select() {
    let options = selectable
    let next = options.first { model.connected($0.peer) } ?? options.first
    let key = next.map { $0.peer.deviceId + ":" + $0.peer.fingerprint } ?? ""
    guard key != peerKey else { return }
    peerKey = key
    address = ""
    draft = ""
    query = ""
    expanded.removeAll()
  }

  @ViewBuilder private func threads(_ peer: DeviceIdentity) -> some View {
    TextField("Search messages", text: $query)
      .textFieldStyle(.roundedBorder)
      .onChange(of: query) { _, _ in expanded.removeAll() }
      .task(id: query) {
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        model.search(peer, query: query)
      }
    if query.isEmpty {
      HStack {
        Text("Conversations").font(.subheadline.weight(.medium))
        Spacer()
        Button("Refresh") { model.requestThreads(peer) }
          .buttonStyle(.bordered).controlSize(.small)
          .disabled(!model.supports(peer) || model.busy(peer))
      }
      if model.status(peer) != "Ready" {
        Text(model.status(peer)).font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
      }
      if !model.diagnostics(peer).isEmpty {
        Text(model.diagnostics(peer)).font(.caption2).foregroundStyle(AniCePalette.secondaryText(scheme))
      }
      let cards = model.threads(peer)
      if cards.isEmpty {
        Text("No conversations yet").foregroundStyle(AniCePalette.secondaryText(scheme))
      } else {
        ForEach(cards) { card in
          Button {
            address = card.key
            draft = ""
            model.refreshMessages(peer, address: card.address)
          } label: {
            HStack(spacing: 12) {
              VStack(alignment: .leading, spacing: 4) {
                Text(card.address).font(.body)
                if !card.snippet.isEmpty {
                  Text(card.snippet).font(.caption).lineLimit(1)
                    .foregroundStyle(AniCePalette.secondaryText(scheme))
                }
              }
              Spacer(minLength: 8)
              VStack(alignment: .trailing, spacing: 4) {
                if card.dateMillis > 0 {
                  Text(date(card.dateMillis), format: .dateTime.month().day().hour().minute())
                    .font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
                }
                if card.unreadCount > 0 {
                  Text("\(card.unreadCount) unread").font(.caption).foregroundStyle(AniCePalette.accent(scheme))
                }
              }
              Image(systemName: "chevron.right").font(.caption)
                .foregroundStyle(AniCePalette.accent(scheme)).accessibilityHidden(true)
            }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle())
          }.buttonStyle(.plain)
          Divider()
        }
      }
    } else {
      results(peer)
    }
    Color.clear.frame(height: 0).task(id: peerKey) {
      if !model.busy(peer) { model.requestThreads(peer) }
    }
  }

  /// Search results replace the thread list; tapping a row only expands its text, it never jumps to a message.
  @ViewBuilder private func results(_ peer: DeviceIdentity) -> some View {
    Button { query = ""; model.clearSearch(peer); expanded.removeAll() } label: {
      Label("Conversations", systemImage: "chevron.backward")
    }.buttonStyle(.plain).foregroundStyle(AniCePalette.accent(scheme))
    Text("Results").font(.headline)
    if !model.searchStatus(peer).isEmpty {
      Text(model.searchStatus(peer)).font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
    }
    let rows = model.searchResults(peer)
    ForEach(rows) { row in
      Button {
        if expanded.contains(row.messageId) { expanded.remove(row.messageId) } else { expanded.insert(row.messageId) }
      } label: {
        VStack(alignment: .leading, spacing: 4) {
          Text(row.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
            .lineLimit(expanded.contains(row.messageId) ? nil : 2)
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { resultMetadata(row); Spacer() }
            VStack(alignment: .leading, spacing: 2) { resultMetadata(row) }
          }
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
      }.buttonStyle(.plain)
      Divider()
    }
    if model.moreResults(peer) {
      Button("Show more results") { model.searchMore(peer) }
        .buttonStyle(.bordered).controlSize(.small).disabled(model.searching(peer))
    } else if model.refineSearch(peer) {
      Text("Refine the search").font(.caption).foregroundStyle(AniCePalette.warning(scheme))
    }
  }

  @ViewBuilder private func resultMetadata(_ row: SmsSearchRow) -> some View {
    Text(row.address)
    Text(row.direction == 1 ? "Sent" : "Received")
    if row.dateMillis > 0 {
      Text(date(row.dateMillis), format: .dateTime.month().day().hour().minute())
    }
  }

  @ViewBuilder private func conversation(_ peer: DeviceIdentity) -> some View {
    let card = model.threads(peer).first { $0.key == address }
    HStack(spacing: 8) {
      Button { address = ""; draft = "" } label: { Label("Conversations", systemImage: "chevron.backward") }
        .buttonStyle(.plain).foregroundStyle(AniCePalette.accent(scheme))
      Text(card?.address ?? address).font(.headline)
      Spacer()
      // Messages sent from the phone's own apps arrive on the next provider read, so refreshing is one tap.
      Button("Refresh") { model.refreshMessages(peer, address: address) }
        .buttonStyle(.bordered).controlSize(.small)
        .disabled(!model.supports(peer))
    }
    if model.status(peer) != "Ready" {
      Text(model.status(peer)).font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
    }
    if !model.diagnostics(peer).isEmpty {
      Text(model.diagnostics(peer)).font(.caption2).foregroundStyle(AniCePalette.secondaryText(scheme))
    }
    // The reply box stays directly above the newest message, so sending a reply never needs a scroll.
    composer(peer)
    let rows = model.messages(peer, address: address)
    if rows.isEmpty {
      Text("No messages on this phone").foregroundStyle(AniCePalette.secondaryText(scheme))
    } else {
      ForEach(rows) { row in
        VStack(alignment: .leading, spacing: 4) {
          Text(row.body).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { metadata(row); Spacer() }
            VStack(alignment: .leading, spacing: 2) { metadata(row) }
          }
        }
        Divider()
      }
    }
    if model.more(peer, address: address) {
      Button("Show older messages") { model.requestMessages(peer, address: address) }
        .buttonStyle(.bordered).controlSize(.small).disabled(model.busy(peer))
    }
  }

  @ViewBuilder private func metadata(_ row: SmsMessageRow) -> some View {
    Text(row.direction == 1 ? "Sent" : "Received")
    Text(date(row.dateMillis), format: .dateTime.month().day().hour().minute())
    if row.unread { Text("Unread").foregroundStyle(AniCePalette.accent(scheme)) }
  }

  @ViewBuilder private func composer(_ peer: DeviceIdentity) -> some View {
    simPicker(peer)
    let bytes = draft.utf8.count
    let over = bytes > Int(SmsMessage.maxBodyBytes)
    TextField("Reply from this phone", text: $draft, axis: .vertical)
      .lineLimit(2...6).textFieldStyle(.roundedBorder)
    HStack(spacing: 12) {
      Text("\(bytes) / \(SmsMessage.maxBodyBytes) bytes").font(.caption)
        .foregroundStyle(over ? AniCePalette.error(scheme) : AniCePalette.secondaryText(scheme))
      Spacer(minLength: 8)
      Button {
        submittedDraft = draft
        model.send(peer, address: address, text: draft)
      } label: { Label("Send SMS", systemImage: "paperplane") }
        .buttonStyle(.bordered).controlSize(.small)
        .disabled(!model.supports(peer) || draft.isEmpty || over || model.sending(peer))
    }
    if draft.count > 1000 {
      Text("Very long messages may be rejected by the carrier; Unicode text reaches the limit sooner.")
        .font(.caption).foregroundStyle(AniCePalette.warning(scheme))
    }
    if !destination.isEmpty, destination != address {
      Text("Thread \(destination)").font(.caption2)
        .foregroundStyle(AniCePalette.secondaryText(scheme)).lineLimit(1)
    }
  }

  /// The phone's subscription list arrives quietly; a choice only appears when it really offers a second subscription.
  @ViewBuilder private func simPicker(_ peer: DeviceIdentity) -> some View {
    let sims = model.sims(peer)
    if sims.count >= 2 {
      Picker("Send from", selection: Binding(get: { model.simChoice(peer) }, set: { model.chooseSim(peer, $0) })) {
        Text("Phone default").tag(Int64(0))
        ForEach(sims) { entry in
          Text(simLabel(entry, of: sims)).tag(entry.subscriptionId)
        }
      }.labelsHidden().frame(maxWidth: 220)
    }
  }

  /// Two subscriptions can carry the same display name; the slot disambiguates them.
  private func simLabel(_ entry: SmsSimEntry, of sims: [SmsSimEntry]) -> String {
    let base = entry.label.isEmpty ? "SIM \(entry.slotIndex + 1)" : entry.label
    return !entry.label.isEmpty && sims.filter { $0.label == entry.label }.count > 1 ? "\(base) (SIM \(entry.slotIndex + 1))" : base
  }

  private func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }
}
