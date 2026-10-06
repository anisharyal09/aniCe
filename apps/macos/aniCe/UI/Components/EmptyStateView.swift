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
            Text("Device pairing will be added in a later phase.")
                .font(.body)
                .foregroundStyle(AniCePalette.secondaryText(colorScheme))
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
}
