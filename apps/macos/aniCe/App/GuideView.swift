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
      summary: "Auto-pairing confirmation, QR scan, manual code entry, and device nicknames.",
      symbol: "laptopcomputer.and.iphone",
      body: "Confirm the 6-digit auto-pairing comparison code on both screens, scan the Mac QR code on your phone, or enter the pairing code manually on your phone. Trusted peers reconnect over Bluetooth Low Energy and switch heavier transfers, Desk Deck stats, or artwork onto local Wi-Fi when Settings → Connection → Use local network automatically is enabled on both devices (your phone adds Idle LAN in background timeouts). In Devices, rename any paired peer, set a local-only nickname with display override, pause auto-connect, or unpair without resetting your cryptographic identity."
    ),
    GuideTopicEntry(
      topic: .permissions,
      title: "Permissions & access",
      summary: "Capabilities stay inactive until their matching Mac or phone permission is granted.",
      symbol: "checkmark.shield",
      body: "Mac Settings → Permissions covers Event Posting (Privacy & Security → Accessibility or Device Control, required for Control Mac and Lock Mac fallback), Notifications (alerts, Messages, Find Device, transfers, and updates), and Automatic pasteboard reading. Phone Settings → Permissions covers Nearby devices, SMS (Receive/Read/Send), Phone state (optional dual-SIM list), Find Phone notifications, Notification Access, Answer phone calls, Call log, Contacts (optional caller ID), and Do Not Disturb access."
    ),
    GuideTopicEntry(
      topic: .openLinkInMac,
      title: "Open Link in Mac",
      summary: "Launch http or https links from your phone straight into your Mac browser.",
      symbol: "safari",
      body: "Highlight an http or https link on your phone and choose Send to Mac, or share from Chrome via Share → Send to Mac. Tapping Open in Mac launches it directly in your Mac’s default browser without overwriting your Mac clipboard (or tap Send as clipboard to copy it instead)."
    ),
    GuideTopicEntry(
      topic: .filesAndEdgeDrop,
      title: "Send files & Edge Drop",
      summary: "Encrypted batches up to 128 files, phone Share sheet, and Mac Edge Drop.",
      symbol: "arrow.up.doc",
      body: "Send up to 128 files per batch from Send files, your phone’s Share → Send to Mac menu, or by dragging Finder items onto the Left, Right, or Top screen edge with Edge Drop (Settings → File transfer). Transfers use local Wi-Fi when available, retain 15-minute resume checkpoints across interruptions, and support custom receive folders, trusted auto-receive, and background notifications."
    ),
    GuideTopicEntry(
      topic: .clipboardAndQuickSend,
      title: "Clipboard & Quick Settings tile",
      summary: "Manual or auto text sync, phone selection menu, and Send to Mac Quick Settings tile.",
      symbol: "doc.on.clipboard",
      body: "Share text manually via Clipboard → Send clipboard / Paste text here, or enable automatic sync on both devices in Settings → Clipboard. On your phone, add the Send to Mac Quick Settings tile (prompt in Clipboard → More options or Quick Settings → Edit) to push your current phone clipboard—or open an http/https link on Mac—with one notification-shade tap without opening aniCe. Text selection → Send to Mac and Share → Send to Mac also work in any app; marked sensitive items ask before sending."
    ),
    GuideTopicEntry(
      topic: .pasteTrayAndPins,
      title: "Clipboard history & Quick Paste Tray",
      summary: "Device-local history filters, Mac pinned snippets, and tray shortcut.",
      symbol: "tray.full",
      body: "Local-only clipboard history stays off synced storage on each device (All, Pinned, Mac, and Phone filters with 20, 50, or 100 item capacity). On Mac, press \(tray) or click the menu-bar icon (Settings → Shortcuts) to search history, pin reusable snippets, pause collection, or Undo/Redo edits without needing an active peer connection."
    ),
    GuideTopicEntry(
      topic: .controlMac,
      title: "Control Mac (from phone)",
      summary: "Use your phone screen and keyboard as a wireless Mac trackpad and keyboard.",
      symbol: "keyboard.badge.ellipsis",
      body: "While connected, open Features → Control Mac on your phone and tap Start. Use one-finger drag to move, tap or two-finger tap to left/right click, long-press drag to select, two-finger drag to scroll, or expand fullscreen trackpad. Type using your mobile keyboard (with autocorrect, Live typing, and Clear box without deleting Mac text). Requires Mac Event Posting access (Settings → Permissions)."
    ),
    GuideTopicEntry(
      topic: .controlAndroidAndFloatingKey,
      title: "Control Android & Floating Key",
      summary: "Classic Bluetooth HID keyboard/trackpad from Mac and the \(floatingKey) Floating Key panel.",
      symbol: "keyboard",
      body: "Pair your Mac and phone once in system Bluetooth Settings, then link that pairing inside Mac Features → Control Android (Home, Back, and Recents controls included). Toggle the compact Floating Key overlay from any Mac app via \(floatingKey) (Settings → Shortcuts) or the menu bar, resize the trackpad, adjust pointer/scroll speed, and stop input anytime with ⌘⇧Esc."
    ),
    GuideTopicEntry(
      topic: .macDeskDeck,
      title: "Mac Desk Deck (from phone)",
      summary: "Live Mac CPU/memory/thermal meters, quick actions, audio output, and approved apps.",
      symbol: "slider.horizontal.3",
      body: "View live CPU history, memory breakdown (Used, App, Wired, Compressed, Cached, Swap), thermal state, and Mac/phone power status (plus last cached snapshot offline). Trigger Mic mute, Lock Mac, Screenshot, Keep awake while charging (under Details), Ping Mac, playback controls, Output device + volume slider, up to 32 approved Mac app shortcuts (Mac Settings → Desk Deck), and a Mac-local DND Shortcut."
    ),
    GuideTopicEntry(
      topic: .nowPlayingAndAudio,
      title: "Now Playing & audio output",
      summary: "Track metadata, album art, timeline scrubbing, player switcher, and volume sync.",
      symbol: "music.note",
      body: "Control Mac playback and volume from Home/Overview, Features → Now Playing, Desk Deck, or the Mac menu bar (plus notification/lock-screen media controls when phone background ownership is active). Configure Mac companion visibility and output-volume permissions in Playback setup and Settings → Now Playing."
    ),
    GuideTopicEntry(
      topic: .messagesAndSms,
      title: "Messages & SMS relay",
      summary: "Read SMS conversations on Mac and reply directly through your phone’s SIM.",
      symbol: "message",
      body: "Browse recent SMS threads, unread counts, search results, dual-SIM Send from selection, and delivery status over your encrypted direct link (no cloud server). On Mac, the gear beside Search messages toggles per-phone notifications, sound, text previews, and Connection details inline (mirrored in Settings → Messages). Requires phone SMS access and Phone state permission for SIM selection."
    ),
    GuideTopicEntry(
      topic: .notificationsAndCalls,
      title: "Mirrored notifications & call controls",
      summary: "Forward chosen phone app alerts to Mac with inline reply, dismissal, and Answer/Decline.",
      symbol: "bell.badge",
      body: "In phone Settings → Notification sync, grant Notification Access and choose apps under Select apps. Native Mac alerts mirror inline replies, app actions, and dismissals. Enable Mirror incoming calls (Answer phone calls plus optional Call log & Contacts for caller ID) to Answer or Decline ringing SIM calls from Mac while audio stays on your phone."
    ),
    GuideTopicEntry(
      topic: .dndSync,
      title: "Do Not Disturb sync",
      summary: "Sync phone Do Not Disturb changes to macOS Focus using Apple Shortcuts.",
      symbol: "moon",
      body: "Allow Do Not Disturb access and enable Sync phone DND to Mac in phone Settings → Do Not Disturb, then configure “Turn Do Not Disturb On” and “Turn Do Not Disturb Off” Shortcuts in Mac Settings → Do Not Disturb. Connected phone DND changes run the matching Mac Shortcut automatically (Desk Deck’s DND toggle stays Mac-local)."
    ),
    GuideTopicEntry(
      topic: .findDeviceAndPing,
      title: "Find Device & Ping Mac",
      summary: "Ring your misplaced phone loudly from Mac or Ping Mac from Desk Deck.",
      symbol: "iphone.radiowaves.left.and.right",
      body: "Use Mac Features → Find Device (or the menu bar) to sound a continuous alarm ring on your paired phone until dismissed (configured under phone Settings → Permissions → Find Phone notifications). Tap Ping Mac inside Desk Deck → Find Mac to post an immediate macOS alert notification even when Desk Deck meters are stale."
    ),
    GuideTopicEntry(
      topic: .companionAndShortcuts,
      title: "Menu bar, Favourites & Settings",
      summary: "Sidebar/menu-bar pins, Favourites reordering, global shortcuts, Glass, and updates.",
      symbol: "star",
      body: "Star tools into Favourites or reorder them (right-click on Mac, long-press on phone); Mac right-click menus also pin tools independently to the sidebar and menu-bar companion. Customize Quick Paste Tray (\(tray)) and Floating Key (\(floatingKey)) in Settings → Shortcuts, System/Light/Dark appearance, Native Glass styling, 80%–120% text scaling, device identity safety checks, and signed updates in Settings."
    ),
  ]
  }
}

private struct GuideFilterMinYKey: PreferenceKey {
  nonisolated(unsafe) static var defaultValue: CGFloat = .infinity
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct GuideView: View {
  let initialTopic: GuideTopic?
  @State private var selectedCategory: GuideCategory = .all
  @State private var forceExpandAll: Bool? = nil
  @State private var filterPinned = false
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
            .opacity(filterPinned ? 0 : 1)
            .background {
              GeometryReader { geo in
                Color.clear.preference(key: GuideFilterMinYKey.self, value: geo.frame(in: .named("guideScroll")).minY)
              }
            }
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
      .coordinateSpace(name: "guideScroll")
      .onPreferenceChange(GuideFilterMinYKey.self) { minY in
        let pinned = minY < 8
        if pinned != filterPinned { filterPinned = pinned }
      }
      .overlay(alignment: .top) {
        if filterPinned {
          VStack(alignment: .leading, spacing: 8) {
            filterBar
              .padding(.horizontal, 24)
            AniCePalette.separator(scheme).opacity(0.45).frame(height: 0.5)
          }
          .padding(.top, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(AniCePalette.background(scheme))
        }
      }
      .onAppear {
        if let initialTopic {
          selectedCategory = .all
          DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
              proxy.scrollTo(initialTopic, anchor: .center)
            }
          }
        }
      }
      .onChange(of: initialTopic) { _, updated in
        forceExpandAll = nil
        if let updated {
          selectedCategory = .all
          withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(updated, anchor: .center)
          }
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
    let highlighted = initialTopic == entry.topic
    let shouldExpand = forceExpandAll ?? highlighted
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
