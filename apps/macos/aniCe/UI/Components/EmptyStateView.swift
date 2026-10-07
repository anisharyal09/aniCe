// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct EmptyStateView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 12) {
            Text("No devices paired")
                .font(.title2)
                .fontWeight(.medium)
                .foregroundStyle(AniCePalette.primaryText(colorScheme))
            Text("Pair a nearby Android device using a QR code or six-digit code.")
                .font(.body)
                .foregroundStyle(AniCePalette.secondaryText(colorScheme))
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
}
