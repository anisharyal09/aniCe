// SPDX-License-Identifier: GPL-3.0-or-later
// Renders one offline, categorized guide covering built-in capabilities across Mac and Android.
import SwiftUI

struct GuideTopicEntry: Identifiable {
  let topic: GuideTopic
  let title: String
  let summary: String
  let symbol: String
  let body: String
  var id: GuideTopic { topic }

  @MainActor static var allEntries: [GuideTopicEntry] {
    let tray = GlobalShortcutPreferences.shared.binding(.tray).label
    let floatingKey = GlobalShortcutPreferences.shared.binding(.floatingKey).label
    return [
    GuideTopicEntry(
      topic: .pairingAndConnection,
      title: "Pairing & Connections",
      summary: "End-to-end encrypted Bluetooth Low Energy and local Wi-Fi.",
      symbol: "laptopcomputer.and.iphone",
      body: "Verify the 6-digit comparison code (or scan QR on Android) once when pairing. Paired devices reconnect automatically over Bluetooth Low Energy and upgrade heavier work such as file transfers or Desk Deck onto local Wi-Fi when Settings → Connection → Use local network automatically is on in both apps (Android also offers Idle LAN in background timeouts). Pause or unpair a peer anytime from Devices without resetting this device’s identity."
    ),
    GuideTopicEntry(
      topic: .permissions,
      title: "Permissions & Mac Access",
      summary: "Capabilities stay dormant until the matching Mac or Android access is granted.",
      symbol: "checkmark.shield",
      body: "Mac Settings → Permissions (Access) tracks Event Posting (Privacy & Security → Accessibility or Device Control, used for Control Mac and Lock Mac fallback), Notifications (alerts, Messages, Find Device, transfers, and updates), and Automatic pasteboard reading (Privacy & Security). Android Settings → Permissions covers Nearby devices, Receive/Read/Send SMS, SIM selection, Find Phone notifications, Notification Access, Answer phone calls, Call log, Contacts (optional caller ID), and Do Not Disturb access."
    ),
    GuideTopicEntry(
      topic: .openLinkInMac,
      title: "Open Link in Mac",
      summary: "Launch any http or https link from Android straight into your Mac’s default browser.",
      symbol: "safari",
      body: "Highlight a web URL in any Android app and choose Send to Mac, or share a URL from Chrome or another app via Android’s Share sheet → Send to Mac. When the link is an http or https URL and your connected Mac supports Open Link, tapping Open in Mac launches it directly in your Mac’s browser without overwriting your Mac clipboard (or tap Send as clipboard to copy it to Mac instead)."
    ),
    GuideTopicEntry(
      topic: .filesAndEdgeDrop,
      title: "Send files & Edge Drop",
      summary: "Encrypted batch transfers up to 128 files plus Finder screen-edge drops.",
      symbol: "arrow.up.doc",
      body: "Drop files onto Send files, drag from Finder toward your chosen Left, Right, or Top screen edge with Edge Drop, or use Android’s Share sheet → Send to Mac. Transfers switch dynamically to local Wi-Fi when paired and reachable, show per-file progress with retry or cancel, and support Save received files to custom folders, background transfer notifications, and trusted auto-receive in Settings → File transfer."
    ),
    GuideTopicEntry(
      topic: .clipboardAndQuickSend,
      title: "Clipboard & Send to Mac",
      summary: "Manual or automatic text sync, Android selection menu, and Quick Settings tile.",
      symbol: "doc.on.clipboard",
      body: "Send text manually from Clipboard → Send clipboard, paste under More options → Paste text here, or enable automatic sharing on both devices in Settings → Clipboard. On Android, select text in any app and pick Send to Mac, share text via Share → Send to Mac, or add the Send to Mac Quick Settings tile (prompt inside Android Clipboard → More options or Quick Settings → Edit). Marked sensitive items ask before sending."
    ),
    GuideTopicEntry(
      topic: .pasteTrayAndPins,
      title: "History & Quick Paste Tray",
      summary: "Offline local clipboard history by device, Mac snippet pins, and tray shortcut.",
      symbol: "tray.full",
      body: "Mac Clipboard → History and the floating Quick Paste Tray (\(tray) or menu-bar icon; Settings → Shortcuts) organize local-only history under All, Pinned, Mac, and Phone filters with search, pinned snippets, Pause history, Undo/Redo, and 20/50/100 item capacity. Android Clipboard → History keeps local-only clips filtered by All, Mac, and Phone with configurable capacity."
    ),
    GuideTopicEntry(
      topic: .controlMac,
      title: "Control Mac (from Android)",
      summary: "Turn your Android screen and keyboard into a wireless touchpad and keyboard for Mac.",
      symbol: "keyboard.badge.ellipsis",
      body: "Open Features → Control Mac on Android while connected and tap Start. Drag for relative cursor movement, tap or two-finger tap to click, two-finger drag to scroll, and type with your normal mobile keyboard (with autocorrect and IME support) or the fullscreen trackpad bar. Requires Event Posting / Accessibility access on Mac (Settings → Permissions); closing the screen keeps the live session ready without forcing the keyboard open."
    ),
    GuideTopicEntry(
      topic: .controlAndroidAndFloatingKey,
      title: "Control Android & Floating Key",
      summary: "Bluetooth HID keyboard and trackpad from Mac plus the anywhere Floating Key.",
      symbol: "keyboard",
      body: "Pair your phone and Mac in system Bluetooth Settings once, then link that Bluetooth pairing in Features → Control Android. Toggle the compact Floating Key panel from any Mac app using \(floatingKey) (Settings → Shortcuts) or the menu bar. Use keyboard and trackpad together or separately, drag the handle to resize the pad, tune pointer/scroll speed, and stop input anytime with ⌘⇧Esc."
    ),
    GuideTopicEntry(
      topic: .macDeskDeck,
      title: "Mac Desk Deck (from Android)",
      summary: "Monitor Mac vitals and trigger quick actions, audio output switching, volume, and shortcuts.",
      symbol: "slider.horizontal.3",
      body: "Open Features → Mac Desk Deck on Android to view live CPU history, memory breakdown (Used, App, Wired, Compressed, Cached, Swap), thermal pressure, and Mac/Phone power status alongside a cached last snapshot when offline. Trigger Mute input / Mic mute, Lock Mac, Screenshot, Keep awake while charging (under Details), Ping Mac, playback controls, Output device + Output volume slider, up to 32 approved Mac app shortcuts (Settings → Desk Deck, arranged under Apps), and a Mac-local DND mode Shortcut (which does not sync back to your phone)."
    ),
    GuideTopicEntry(
      topic: .nowPlayingAndAudio,
      title: "Now Playing & Output control",
      summary: "Shared media artwork, scrubbing, playback buttons, and volume synchronization.",
      symbol: "music.note",
      body: "Control playback and volume from Overview, Features → Now Playing, Mac’s menu-bar companion, or Android’s Desk Deck. View track title, artist, album art, timeline scrubber, play/pause/skip controls, and output volume synchronization across connected peers. Configure visibility and output-volume access in Playback setup and Settings → Now Playing."
    ),
    GuideTopicEntry(
      topic: .messagesAndSms,
      title: "Messages & SMS relay",
      summary: "Browse phone SMS threads on Mac and send replies through your Android’s SIM.",
      symbol: "message",
      body: "Read recent SMS conversations, unread counts, search results, dual-SIM Send from selection, and sent/delivery tracking directly in Mac Features → Messages over your encrypted direct connection (zero cloud server). Tap the gear beside Search messages on Mac to adjust per-phone alerts and Connection details inline without leaving your thread (Settings → Messages shows the same controls). Requires Android SMS permissions and Phone access for SIM selection."
    ),
    GuideTopicEntry(
      topic: .notificationsAndCalls,
      title: "Mirrored Notifications & Call controls",
      summary: "Mirror Android app alerts to Mac, inline reply or dismiss, and handle SIM calls.",
      symbol: "bell.badge",
      body: "Configure on Android in Settings → Notification sync: enable Notification Access, choose apps under Select apps, and turn on Mirror incoming calls (Answer phone calls plus optional Call log & Contacts for caller ID) to show caller alerts on Mac with Answer or Decline actions while call audio stays on your phone. Inline notification replies and dismissals mirror back to Android automatically."
    ),
    GuideTopicEntry(
      topic: .dndSync,
      title: "Do Not Disturb sync",
      summary: "Sync Android Do Not Disturb changes onto macOS Focus using Apple Shortcuts.",
      symbol: "moon",
      body: "Enable Sync phone DND to Mac in Android Settings → Do Not Disturb (with Do Not Disturb access granted), and set up the two Apple Shortcuts (“Turn Do Not Disturb On” and “Turn Do Not Disturb Off”) guided in Mac Settings → Do Not Disturb (copyable prompts for Shortcuts or manual Set Focus setup). When phone DND changes, your Mac runs the matching Shortcut locally."
    ),
    GuideTopicEntry(
      topic: .findDeviceAndPing,
      title: "Find Device & Ping Mac",
      summary: "Ring your misplaced phone from Mac or send Ping Mac from Android Desk Deck.",
      symbol: "iphone.radiowaves.left.and.right",
      body: "Open Features → Find Device on Mac (or the menu-bar companion) to ring your paired Android with a continuous audible alert until dismissed; Android incoming-ring settings live in Settings → Permissions → Find Phone notifications. From Android’s Mac Desk Deck → Find Mac, tap Ping Mac to send an immediate macOS alert notification whose banner and sound follow Mac Notification settings, even when Desk Deck telemetry is stale."
    ),
    GuideTopicEntry(
      topic: .companionAndShortcuts,
      title: "Menu bar, Favourites & Customization",
      summary: "Pinned quick actions, feature reordering, Native Glass, scaled text, and signed updates.",
      symbol: "star",
      body: "Star any tool into Favourites or reorder features on both Mac and Android; Mac right-click menus also pin tools independently to the menu-bar companion and sidebar alongside Quick Paste Tray (\(tray)) and Floating Key (\(floatingKey)) in Settings → Shortcuts. Both apps include System/Light/Dark themes, Mac Native Glass window styling, 80%–120% text scaling, device identity checks, and signed updates in Settings."
    ),
  ]
  }
}

struct GuideView: View {
  let initialTopic: GuideTopic?
  @State private var selectedCategory: GuideCategory = .all
  @State private var forceExpandAll: Bool? = nil
  @State private var scrollTarget: GuideTopic?
  @Environment(\.colorScheme) private var scheme
  @AppStorage("ui.fontScale") private var fontScale = 1.0

  private var visibleCategories: [GuideCategory] {
    selectedCategory == .all ? GuideCategory.allCases.filter { $0 != .all } : [selectedCategory]
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          header
          filterBar
          ForEach(visibleCategories) { category in
            let entries = GuideTopicEntry.allEntries.filter { $0.topic.category == category }
            if !entries.isEmpty {
              VStack(alignment: .leading, spacing: 6) {
                Text(category.rawValue)
                  .font(.system(size: 12.5 * fontScale, weight: .semibold))
                  .foregroundStyle(AniCePalette.secondaryText(scheme))
                  .padding(.leading, 2)
                VStack(spacing: 0) {
                  ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    topicRow(entry)
                      .id(entry.topic)
                    if index < entries.count - 1 {
                      AniCePalette.separator(scheme)
                        .opacity(0.6)
                        .frame(height: 0.5)
                        .padding(.leading, 56)
                        .padding(.trailing, 14)
                    }
                  }
                }
                .background(AniCePalette.surface(scheme), in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
              }
            }
          }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .onAppear {
        if let initialTopic {
          selectedCategory = .all
          scrollTarget = initialTopic
          DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
              proxy.scrollTo(initialTopic, anchor: .top)
            }
          }
        }
      }
      .onChange(of: initialTopic) { _, updated in
        forceExpandAll = nil
        if let updated {
          selectedCategory = .all
          scrollTarget = updated
          withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(updated, anchor: .top)
          }
        } else {
          scrollTarget = nil
        }
      }
    }
  }

  private var header: some View {
    let allExpanded = forceExpandAll == true
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Image(systemName: "questionmark.circle")
          .font(.system(size: 18 * fontScale, weight: .semibold))
          .foregroundStyle(AniCePalette.accent(scheme))
        Text("aniCe Guide")
          .font(.system(size: 20 * fontScale, weight: .semibold))
          .foregroundStyle(AniCePalette.primaryText(scheme))
        Spacer()
        Button(allExpanded ? "Collapse all" : "Expand all") {
          forceExpandAll = allExpanded ? false : true
        }
        .buttonStyle(AniCeHoverButtonStyle(feedbackPadding: 4))
        .font(.system(size: 12.5 * fontScale, weight: .medium))
        .foregroundStyle(AniCePalette.accent(scheme))
        .accessibilityLabel(allExpanded ? "Collapse all" : "Expand all")
        .help(allExpanded ? "Collapse all Guide sections" : "Expand all Guide sections")
      }
      Text("Offline reference for everything built into aniCe across your Mac and Android—including tools outside the 6-item Features list—plus shortcuts and Settings paths.")
        .font(.system(size: 12.5 * fontScale))
        .foregroundStyle(AniCePalette.secondaryText(scheme))
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var filterBar: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 6) {
        ForEach(GuideCategory.allCases, id: \.self) { category in
          categoryChip(category)
        }
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 110 * fontScale))], alignment: .leading, spacing: 6) {
        ForEach(GuideCategory.allCases, id: \.self) { category in
          categoryChip(category)
        }
      }
    }
  }

  private func categoryChip(_ category: GuideCategory) -> some View {
    let selected = selectedCategory == category
    return Button {
      selectedCategory = category
    } label: {
      Text(category.rawValue)
        .font(.system(size: 12 * fontScale, weight: selected ? .semibold : .regular))
        .foregroundStyle(selected ? AniCePalette.primaryText(scheme) : AniCePalette.secondaryText(scheme))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(selected ? AniCePalette.subtleAccent(scheme) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(AniCeHoverButtonStyle())
    .accessibilityLabel(category.rawValue)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func topicRow(_ entry: GuideTopicEntry) -> some View {
    let highlighted = scrollTarget == entry.topic || initialTopic == entry.topic
    let shouldExpand = forceExpandAll ?? (initialTopic == entry.topic)
    return AniCeHelpDisclosure(
      title: entry.title,
      bodyText: entry.body,
      summary: entry.summary,
      symbol: entry.symbol,
      highlighted: highlighted,
      initiallyExpanded: shouldExpand
    )
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(highlighted ? AniCePalette.subtleAccent(scheme).opacity(0.6) : .clear)
    .overlay(alignment: .leading) {
      if highlighted {
        AniCePalette.accent(scheme)
          .frame(width: 2.5)
      }
    }
  }
}
