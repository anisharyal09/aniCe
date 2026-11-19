// SPDX-License-Identifier: GPL-3.0-or-later
// Presents existing pairing approval and trust management within their explicit device flow.
import SwiftUI

struct MacPairingView: View {
  @Bindable var model: MacPairingModel
  var embedded = false
  var showTrustedDevices = true
  var showPairingControls = true
  var identityModel: IdentityViewModel?
  @State private var editingLocalName = false
  @State private var localName = ""
  @State private var resettingTrust = false
  @State private var forgetID: String?
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      if showPairingControls { pairingPanel }
      if showTrustedDevices && (!model.peers.isEmpty || model.trustRecoveryNeeded) {
        trustedDevicesPanel
      }
    }
    .alert("Edit this Mac's name", isPresented: $editingLocalName) {
      TextField("Mac name", text: $localName)
      Button("Cancel", role: .cancel) {}
      Button("Save") { Task { await identityModel?.rename(localName) } }
        .disabled(localName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
          localName.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count > 64)
    } message: { Text("This changes this Mac's own name, not a private nickname.") }
    .alert("Reset local trust?", isPresented: $resettingTrust) {
      Button("Cancel", role: .cancel) {}
      Button("Reset local trust", role: .destructive, action: model.recoverTrustStore)
    } message: {
      Text(
        "The unreadable trust file will be preserved separately. Local pairings will be removed and must be paired again. Your identity key stays the same."
      )
    }
    .confirmationDialog(
      "Forget this device?",
      isPresented: Binding(get: { forgetID != nil }, set: { if !$0 { forgetID = nil } })
    ) {
      Button("Forget device", role: .destructive) {
        if let id = forgetID { model.forget(id) }
        forgetID = nil
      }
    } message: {
      Text("This removes trust on this Mac. Pair again to reconnect.")
    }
  }

  // MARK: - Pairing Panel

  private var pairingPanel: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let identityModel, let local = identityModel.local {
        HStack {
          Text(local.identity.deviceName).font(.subheadline)
          Spacer()
          Button("Edit name") {
            if model.nearbyEnabled { model.cancel() }
            localName = local.identity.deviceName
            editingLocalName = true
          }
            .buttonStyle(AniCeButtonStyle())
            .disabled(identityModel.isWorking || (model.active && model.phase != "nearby"))
        }
        if identityModel.renameFailure { Text("Could not save this Mac's name. Try again.")
          .font(.caption).foregroundStyle(AniCePalette.error(scheme)) }
      }
      if !embedded {
      HStack {
        Text(model.active ? "Pairing invitation" : "Add device")
          .font(.headline)
        Spacer()
        if model.active && model.remaining > 0 {
          Label("\(model.remaining)s", systemImage: "clock")
            .font(.caption.monospacedDigit())
            .foregroundStyle(AniCePalette.secondaryText(scheme))
        }
      }

      }

      Text(model.status)
        .font(.subheadline)
        .foregroundStyle(AniCePalette.secondaryText(scheme))

      if model.active {
        activeInvitationContent
      } else {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 12) { pairingActions }
          VStack(alignment: .leading, spacing: 8) { pairingActions }
        }.padding(.top, 4)
      }
    }
    .padding(embedded ? 0 : 20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(embedded ? Color.clear : AniCePalette.surface(scheme), in: RoundedRectangle(cornerRadius: 12))
  }

  @ViewBuilder private var pairingActions: some View {
    Button { model.start(.qr) } label: { Label("Show QR code", systemImage: "qrcode") }
      .buttonStyle(AniCeButtonStyle(prominent: true))
    Button { model.start(.pin) } label: { Label("Show six-digit code", systemImage: "number") }
      .buttonStyle(AniCeButtonStyle())
  }

  @ViewBuilder
  private var activeInvitationContent: some View {
    if model.nearbyEnabled {
      if model.comparisonCode != nil && ["comparison", "waiting"].contains(model.phase) {
        MacComparisonCard(model: model)
      } else if model.phase == "nearby" || model.phase == "preparing" {
        Text("Bring your phone close with aniCe open, then compare the code on both screens.")
          .font(.callout).foregroundStyle(AniCePalette.secondaryText(scheme))
      }
      Button("Manual pair") { model.pauseNearby() }
        .buttonStyle(AniCeButtonStyle())
        .disabled(["saving", "paired"].contains(model.phase))
      if ["preparing", "connecting", "authenticating", "verifying", "saving"].contains(model.phase) {
        ProgressView().accessibilityLabel(model.status)
      }
    }
    if model.phase == "invitation", let image = model.qrImage {
      VStack(spacing: 12) {
        ZStack {
          RoundedRectangle(cornerRadius: 12)
            .fill(Color.white)
          Image(nsImage: image)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .padding(14)
        }
        .frame(width: 210, height: 210)
        .accessibilityLabel("Scan this pairing QR code with aniCe on Android")

        Text("Scan this QR code with aniCe on your Android phone.")
          .font(.caption)
          .foregroundStyle(AniCePalette.secondaryText(scheme))
      }
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.vertical, 8)
    }

    if model.phase == "invitation", let pin = model.pin {
      VStack(spacing: 12) {
        HStack(spacing: 8) {
          ForEach(Array(pin.enumerated()), id: \.offset) { index, char in
            Text(String(char))
              .font(.system(size: 26, weight: .semibold, design: .monospaced))
              .frame(width: 38, height: 46)
              .background(
                AniCePalette.secondarySurface(scheme), in: RoundedRectangle(cornerRadius: 8)
              )
              .overlay(
                RoundedRectangle(cornerRadius: 8).stroke(
                  AniCePalette.separator(scheme), lineWidth: 1))
            if index == 2 {
              Spacer().frame(width: 8)
            }
          }
        }
        .accessibilityLabel("Pairing code " + pin)

        Text("Enter this code in aniCe on your Android phone, then select this Mac.")
          .font(.caption)
          .foregroundStyle(AniCePalette.secondaryText(scheme))
      }
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.vertical, 8)
    }

    if let peer = model.peer {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
          Image(systemName: "phone")
            .font(.title2)
            .foregroundStyle(AniCePalette.accent(scheme))
          VStack(alignment: .leading, spacing: 2) {
            Text(peer.deviceName)
              .font(.headline)
            Text(peer.platform.capitalized)
              .font(.caption)
              .foregroundStyle(AniCePalette.secondaryText(scheme))
          }
        }

        Text("Fingerprint: " + peer.groupedFingerprint)
          .font(.caption.monospaced())
          .foregroundStyle(AniCePalette.secondaryText(scheme))
          .textSelection(.enabled)

        if model.phase == "approval" {
          HStack(spacing: 12) {
            Button("Pair with this device", action: model.approve)
              .buttonStyle(AniCeButtonStyle(prominent: true))
            Button("Decline", action: model.decline)
              .buttonStyle(AniCeButtonStyle())
          }
          .padding(.top, 4)
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(AniCePalette.secondarySurface(scheme), in: RoundedRectangle(cornerRadius: 10))
    }

    if model.phase == "preparing" || model.phase == "starting"
      || model.phase == "authenticating" || model.phase == "saving" || model.phase == "cancelling"
    {
      if !model.nearbyEnabled {
        ProgressView().accessibilityLabel(model.status).padding(.vertical, 4)
      }
    }

    if !model.nearbyEnabled && model.phase != "approval" && model.phase != "cancelling" {
      Button("Cancel invitation") { model.cancel() }
        .buttonStyle(AniCeButtonStyle())
        .controlSize(.small)
    }
  }

  // MARK: - Trusted Devices Panel

  private var trustedDevicesPanel: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Trusted devices")
          .font(.headline)
        Spacer()
        Button {
          Task { await model.refresh() }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless).aniCeControlFeedback()
        .font(.caption)
        .accessibilityLabel("Refresh trusted devices")
      }

      if model.peers.isEmpty {
        Text("No trusted devices on this Mac yet.")
          .font(.callout)
          .foregroundStyle(AniCePalette.secondaryText(scheme))
      } else {
        VStack(spacing: 8) {
          ForEach(model.peers) { record in
            HStack(spacing: 12) {
              Image(systemName: "phone")
                .foregroundStyle(AniCePalette.accent(scheme))
              DisclosureGroup {
                Text("Device name: " + record.peer.knownDeviceName).font(.caption)
                Text(record.peer.groupedFingerprint)
                  .font(.caption2.monospaced())
                  .foregroundStyle(AniCePalette.secondaryText(scheme))
                  .textSelection(.enabled)
                MacNicknameEditor(model: model, peer: record.peer)
              } label: {
                Text(model.displayedName(for: record.peer))
                  .font(.subheadline.weight(.medium))
                  .fixedSize(horizontal: false, vertical: true)
              }
              Spacer()
              Button("Forget…") {
                forgetID = record.id
              }
              .buttonStyle(AniCeButtonStyle())
              .controlSize(.small)
            }
            .padding(.vertical, 6)
          }
        }
      }

      if model.trustRecoveryNeeded {
        Button("Reset local trust…") {
          resettingTrust = true
        }
        .foregroundStyle(AniCePalette.error(scheme))
        .controlSize(.small)
      }
    }
    // The enclosing Devices disclosure supplies the group; peers remain flat rows.
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct MacNicknameEditor: View {
  @Bindable var model: MacPairingModel
  let peer: DeviceIdentity
  @State private var name = ""
  @State private var enabled = false
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("Private nickname", text: $name).textFieldStyle(.roundedBorder)
      Toggle("Use nickname", isOn: $enabled).toggleStyle(.checkbox)
      Text("Only on this Mac. Device name remains the default.").font(.caption)
      Button("Save nickname") { model.saveNickname(peer: peer, name: name, enabled: enabled) }
        .disabled(model.savingNickname || name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count > 64 ||
          (enabled && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
      if model.nicknameFailure { Text("Could not save nickname. Try again.").foregroundStyle(AniCePalette.error(scheme)) }
    }.onAppear {
      name = model.nickname(for: peer)?.name ?? ""
      enabled = model.nickname(for: peer)?.enabled ?? false
    }
    .onChange(of: model.nickname(for: peer)) { _, value in
      name = value?.name ?? ""
      enabled = value?.enabled ?? false
    }
  }
}
