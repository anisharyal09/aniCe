// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

struct MainWindowView: View {
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                EmptyStateView()
                    .padding(32)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .background(AniCePalette.background(colorScheme))
        .tint(AniCePalette.accent(colorScheme))
        .onAppear {
            let action = openWindow
            delegate.reopenMainWindow = {
                action(id: "main")
                NSApp.activate()
            }
        }
    }
}
