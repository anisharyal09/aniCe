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
  @Environment(\.colorScheme) private var scheme

  private var peer: DeviceIdentity? {
    peers.first { $0.peer.deviceId + ":" + $0.peer.fingerprint == peerKey }?.peer
  }
  private var destination: String { peer.map { model.destination($0, address: address) } ?? address }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if peers.count > 1 {
        Picker("Phone", selection: $peerKey) {
          ForEach(peers) { record in
            Text(record.peer.deviceName).tag(record.peer.deviceId + ":" + record.peer.fingerprint)
          }
        }.labelsHidden().frame(maxWidth: 260)
      }
      if let peer {
        if !model.supports(peer) {
          Text(model.connected(peer) ? "Waiting for your phone" : "Connect aniCe on your phone first")
            .font(.callout).foregroundStyle(AniCePalette.secondaryText(scheme))
        }
        if address.isEmpty { threads(peer) } else { conversation(peer) }
      } else {
        Text("Pair a phone to relay messages.").foregroundStyle(AniCePalette.secondaryText(scheme))
      }
    }
    .onAppear { select() }
    .onChange(of: peers.map { $0.peer.deviceId + ":" + $0.peer.fingerprint }) { _, _ in select() }
  }

  private func select() {
    if !peers.contains(where: { $0.peer.deviceId + ":" + $0.peer.fingerprint == peerKey }) {
      peerKey = (peers.first { model.connected($0.peer) } ?? peers.first)
        .map { $0.peer.deviceId + ":" + $0.peer.fingerprint } ?? ""
    }
    address = ""
    draft = ""
  }

  @ViewBuilder private func threads(_ peer: DeviceIdentity) -> some View {
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
    let cards = model.threads(peer)
    if cards.isEmpty {
      Text("No conversations yet").foregroundStyle(AniCePalette.secondaryText(scheme))
    } else {
      ForEach(cards) { card in
        Button {
          address = card.key
          draft = ""
          model.requestMessages(peer, address: card.address)
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
    Color.clear.frame(height: 0).task(id: peerKey) {
      if model.supports(peer), !model.busy(peer) { model.requestThreads(peer) }
    }
  }

  @ViewBuilder private func conversation(_ peer: DeviceIdentity) -> some View {
    let card = model.threads(peer).first { $0.key == address }
    Button { address = ""; draft = "" } label: { Label("Conversations", systemImage: "chevron.backward") }
      .buttonStyle(.plain).foregroundStyle(AniCePalette.accent(scheme))
    Text(card?.address ?? address).font(.headline)
    if model.status(peer) != "Ready" {
      Text(model.status(peer)).font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
    }
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
      Button("Load older messages") { model.requestMessages(peer, address: address) }
        .buttonStyle(.bordered).controlSize(.small).disabled(model.busy(peer))
    }
    composer(peer)
  }

  @ViewBuilder private func metadata(_ row: SmsMessageRow) -> some View {
    Text(row.direction == 1 ? "Sent" : "Received")
    Text(date(row.dateMillis), format: .dateTime.month().day().hour().minute())
    if row.unread { Text("Unread").foregroundStyle(AniCePalette.accent(scheme)) }
  }

  @ViewBuilder private func composer(_ peer: DeviceIdentity) -> some View {
    let bytes = draft.utf8.count
    let over = bytes > Int(SmsMessage.maxBodyBytes)
    TextField("Reply from this phone", text: $draft, axis: .vertical)
      .lineLimit(2...6).textFieldStyle(.roundedBorder)
    HStack(spacing: 12) {
      Text("\(bytes) / \(SmsMessage.maxBodyBytes) bytes").font(.caption)
        .foregroundStyle(over ? AniCePalette.error(scheme) : AniCePalette.secondaryText(scheme))
      Spacer(minLength: 8)
      Button {
        model.send(peer, address: address, text: draft)
        draft = ""
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

  private func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }
}
