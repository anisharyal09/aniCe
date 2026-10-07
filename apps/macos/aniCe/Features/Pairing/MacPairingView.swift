// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct MacPairingView: View {
  @Bindable var model: MacPairingModel
  @State private var resettingTrust = false
  @State private var forgetID: String?
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      pairingPanel
      trustedDevicesPanel
    }
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
      Text("This removes trust on this Mac. Pair again to reconnect in a future secure session.")
    }
  }

  // MARK: - Pairing Panel

  private var pairingPanel: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text(model.active ? "Pairing invitation" : "Pair a device")
          .font(.headline)
        Spacer()
        if model.active && model.remaining > 0 {
          Label("\(model.remaining)s", systemImage: "clock")
            .font(.caption.monospacedDigit())
            .foregroundStyle(AniCePalette.secondaryText(scheme))
        }
      }

      Text(model.status)
        .font(.subheadline)
        .foregroundStyle(AniCePalette.secondaryText(scheme))

      if model.active {
        activeInvitationContent
      } else {
        HStack(spacing: 12) {
          Button {
            model.start(.qr)
          } label: {
            Label("Show QR code", systemImage: "qrcode")
          }
          .buttonStyle(.borderedProminent)

          Button {
            model.start(.pin)
          } label: {
            Label("Show six-digit code", systemImage: "number")
          }
          .buttonStyle(.bordered)
        }
        .padding(.top, 4)
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(AniCePalette.surface(scheme), in: RoundedRectangle(cornerRadius: 12))
  }

  @ViewBuilder
  private var activeInvitationContent: some View {
    if model.phase == "invitation", let image = model.qrImage {
      VStack(spacing: 12) {
        ZStack {
          RoundedRectangle(cornerRadius: 12)
            .fill(Color.white)
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
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
              .background(AniCePalette.secondarySurface(scheme), in: RoundedRectangle(cornerRadius: 8))
              .overlay(RoundedRectangle(cornerRadius: 8).stroke(AniCePalette.separator(scheme), lineWidth: 1))
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
              .buttonStyle(.borderedProminent)
            Button("Decline", action: model.decline)
              .buttonStyle(.bordered)
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
      ProgressView().accessibilityLabel(model.status)
        .padding(.vertical, 4)
    }

    if model.phase != "approval" && model.phase != "cancelling" {
      Button("Cancel invitation") { model.cancel() }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
  }

  // MARK: - Trusted Devices Panel

  private var trustedDevicesPanel: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Trusted devices")
          .font(.headline)
        Spacer()
        Button {
          Task { await model.refresh() }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
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
              VStack(alignment: .leading, spacing: 2) {
                Text(record.peer.deviceName)
                  .font(.subheadline.weight(.medium))
                Text(record.peer.groupedFingerprint)
                  .font(.caption2.monospaced())
                  .foregroundStyle(AniCePalette.secondaryText(scheme))
                  .textSelection(.enabled)
              }
              Spacer()
              Button("Forget…") {
                forgetID = record.id
              }
              .buttonStyle(.bordered)
              .controlSize(.small)
            }
            .padding(12)
            .background(AniCePalette.secondarySurface(scheme), in: RoundedRectangle(cornerRadius: 8))
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
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(AniCePalette.surface(scheme), in: RoundedRectangle(cornerRadius: 12))
  }
}
