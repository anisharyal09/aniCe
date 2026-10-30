// SPDX-License-Identifier: GPL-3.0-or-later
// Presents nearby discovery status and native start, stop and permission actions.
import SwiftUI

struct MacDiscoveryView: View {
    let model: MacDiscoveryModel
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nearby discovery").font(.headline)
            Text(model.session.message).foregroundStyle(AniCePalette.secondaryText(colorScheme))
            if model.session.remainingSeconds > 0 {
                Text("Discoverable for \(model.session.remainingSeconds / 60):\(String(format: "%02d", model.session.remainingSeconds % 60))")
                    .monospacedDigit()
            }
            HStack {
                if model.session.active {
                    Button("Stop", action: model.stop)
                } else if model.session.recovery != .unsupported {
                    Button("Make this Mac discoverable", action: model.start).buttonStyle(.borderedProminent).aniCeControlFeedback(prominent: true)
                        .foregroundStyle(AniCePalette.onAccent(colorScheme))
                    if model.session.state == .bluetoothOff || model.session.state == .permissionNeeded {
                        Button("Open System Settings", action: model.openSettings)
                    }
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(AniCePalette.surface(colorScheme), in: RoundedRectangle(cornerRadius: 12))
    }
}
