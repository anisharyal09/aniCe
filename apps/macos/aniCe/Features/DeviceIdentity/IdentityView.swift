// SPDX-License-Identifier: GPL-3.0-or-later
// Presents editable identity metadata and confirmed recovery using the shared native identity owner.
import AppKit
import SwiftUI

struct IdentityView: View {
    @Bindable var model: IdentityViewModel
    var embedded = false
    var onBack: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmingReset = false
    @State private var copyFeedback = ""
    @State private var deviceName = ""
    @State private var editingName = false
    @State private var advanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                if let onBack {
                    Button(action: onBack) { Image(systemName: "chevron.left") }
                        .buttonStyle(.plain).accessibilityLabel("Back to Settings")
                }
                Text("This device").font(.title2).fontWeight(.medium)
                Spacer()
                if !embedded { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let local = model.local {
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: "desktopcomputer")
                                .font(.system(size: 28, weight: .regular))
                                .foregroundStyle(AniCePalette.secondaryText(colorScheme))
                                .frame(width: 48, height: 48)
                                .background(AniCePalette.surface(colorScheme), in: RoundedRectangle(cornerRadius: 12))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(local.identity.deviceName).font(.title3).fontWeight(.medium)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("macOS").foregroundStyle(AniCePalette.secondaryText(colorScheme))
                            }
                        }
                        Button("Edit name…") {
                            deviceName = local.identity.deviceName
                            editingName = true
                        }.buttonStyle(.bordered)
                        Text("Your local identity stays the same until you reset it.")
                            .foregroundStyle(AniCePalette.secondaryText(colorScheme))
                        VStack(alignment: .leading, spacing: 16) {
                            copyRow("Device ID", value: local.identity.deviceId)
                            Divider()
                            copyRow("Fingerprint", value: local.identity.fingerprint,
                                    displayedValue: local.identity.groupedFingerprint)
                            Text("A public fingerprint of this device’s signing key.")
                                .font(.callout).foregroundStyle(AniCePalette.secondaryText(colorScheme))
                            Divider()
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Key protection", systemImage: "key")
                                    .font(.headline)
                                Text(local.protection.label)
                                    .foregroundStyle(AniCePalette.secondaryText(colorScheme))
                                if local.protection == .developmentKeychain {
                                    Text("This development build uses the login Keychain. Its identity is not hardware protected.")
                                        .font(.callout).foregroundStyle(AniCePalette.secondaryText(colorScheme))
                                }
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AniCePalette.surface(colorScheme), in: RoundedRectangle(cornerRadius: 12))
                        if local.cleanupPending {
                            Text("The new identity is ready. Removing an older key will be retried when identity storage is available.")
                        }
                    }
                    if model.isWorking { ProgressView("Updating identity…") }
                    if let recovery = model.recovery {
                        recoveryPanel(recovery)
                    }
                    if !copyFeedback.isEmpty {
                        Text(copyFeedback).foregroundStyle(AniCePalette.secondaryText(colorScheme))
                    }
                    if model.local != nil {
                        Divider()
                        Button { advanced.toggle() } label: {
                            HStack(spacing: 6) {
                                Image(systemName: advanced ? "chevron.down" : "chevron.right")
                                Text("Advanced")
                                Spacer()
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityValue(advanced ? "Expanded" : "Collapsed")
                        if advanced {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Resetting creates a new identity. Existing pairings become invalid; you will need to pair your devices again.")
                                    .foregroundStyle(AniCePalette.secondaryText(colorScheme))
                                Button("Reset device identity", role: .destructive) { confirmingReset = true }
                                    .disabled(model.isWorking || !model.canReset)
                            }.padding(.top, 8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(minWidth: embedded ? 0 : 460, idealWidth: 540, minHeight: embedded ? 0 : 460, idealHeight: 620)
        .foregroundStyle(AniCePalette.primaryText(colorScheme))
        .background(AniCePalette.background(colorScheme))
        .tint(AniCePalette.primaryText(colorScheme))
        .alert("Edit device name", isPresented: $editingName) {
            TextField("Mac name", text: $deviceName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { Task { await model.rename(deviceName) } }
                .disabled(model.isWorking || deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || deviceName.unicodeScalars.count > 64 || deviceName == model.local?.identity.deviceName)
        } message: {
            Text("Shown to your phone after authentication.")
        }
        .alert("Reset this device’s identity?", isPresented: $confirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset identity", role: .destructive) { copyFeedback = ""; Task { await model.reset() } }
        } message: {
            Text("A new device ID and signing key will replace this identity. Existing pairings become invalid; you will need to pair your devices again.")
        }
        .task { if !Self.isTesting { await model.load() } }
        .onChange(of: model.local?.identity.deviceId) { copyFeedback = "" }
        .onChange(of: model.local?.identity.deviceName) { _, name in deviceName = name ?? "" }
        .onAppear { deviceName = model.local?.identity.deviceName ?? "" }
    }

    static var isTesting: Bool { ProcessInfo.processInfo.environment["ANICE_IDENTITY_TESTING"] == "1" }

    private func recoveryPanel(_ recovery: IdentityRecovery) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(recovery.title, systemImage: "key")
                .font(.headline)
            Text(recovery.message)
                .foregroundStyle(AniCePalette.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            if recovery.canReset && !recovery.canRetry {
                Text("This creates a new device ID and fingerprint. Existing pairings become invalid; you will need to pair your devices again.")
                    .font(.callout).foregroundStyle(AniCePalette.secondaryText(colorScheme))
            }
            ViewThatFits(in: .horizontal) {
                recoveryActions(recovery, vertical: false)
                recoveryActions(recovery, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AniCePalette.surface(colorScheme), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func recoveryActions(_ recovery: IdentityRecovery, vertical: Bool) -> some View {
        if vertical {
            VStack(alignment: .leading, spacing: 8) { recoveryButtons(recovery) }
        } else {
            HStack(spacing: 12) { recoveryButtons(recovery) }
        }
    }

    @ViewBuilder
    private func recoveryButtons(_ recovery: IdentityRecovery) -> some View {
        if recovery.canRetry {
            Button("Try again") { Task { await model.load(force: true) } }
                .disabled(model.isWorking)
        }
        if recovery.canReset {
            Button(recovery.resetLabel) { confirmingReset = true }
                .disabled(model.isWorking)
        }
    }

    private func copyRow(_ label: String, value: String, displayedValue: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label).font(.headline).foregroundStyle(AniCePalette.secondaryText(colorScheme))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(value, forType: .string) { copyFeedback = "\(label) copied." }
                    else { copyFeedback = "Could not copy \(label.lowercased()). Try again." }
                }
                label: { Label("Copy", systemImage: "doc.on.doc") }
                .accessibilityLabel("Copy \(label.lowercased())")
                .disabled(model.isWorking)
            }
            Text(displayedValue ?? value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
