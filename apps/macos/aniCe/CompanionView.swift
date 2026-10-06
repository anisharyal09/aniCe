// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

struct CompanionView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 24) {
            EmptyStateView()
            HStack(spacing: 12) {
                Button("Open aniCe") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(AniCePalette.onAccent(colorScheme))
                .frame(maxWidth: .infinity)

                Menu {
                    Button("Quit aniCe") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("More options")
            }
        }
        .padding(24)
        .frame(width: 350)
        .background(AniCePalette.surface(colorScheme))
        .tint(AniCePalette.accent(colorScheme))
    }
}
