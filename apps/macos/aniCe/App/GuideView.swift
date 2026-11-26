// SPDX-License-Identifier: GPL-3.0-or-later
// Renders one offline, categorized guide covering built-in capabilities across Mac and Android.
import SwiftUI

private struct GuideTopicEntry: Identifiable {
  let topic: GuideTopic
  let title: String
  let summary: String
  let symbol: String
  let body: String
  var id: GuideTopic { topic }

  @MainActor static var allEntries: [GuideTopicEntry] {
    let tray = GlobalShortcutPreferences.shared.binding(.tray).label
    let floatingKey = GlobalShortcutPreferences.shared.binding(.floatingKey).label
    let floatingKeyInput = GlobalShortcutPreferences.shared.binding(.floatingKeyInput).label
    return [
      GuideTopicEntry(
        topic: .pairingAndConnection,
        title: "Pairing & Connections",
        summary: "Nearby confirmation, QR scan, manual code entry, and device nicknames.",
        symbol: "laptopcomputer.and.iphone",
        body: "In Devices, pair by comparing the six digits on both screens, scanning the Mac QR code on your phone, or entering its pairing code. Bluetooth reconnect follows the saved automatic preference; background reconnect also needs supported phone setup. Local-network setup follows Use local network automatically in Settings → Connection. Devices also lets you edit device names, choose private nicknames, pause connections or unpair."
      ),
      GuideTopicEntry(
        topic: .permissions,
        title: "Permissions & access",
        summary: "Capabilities stay inactive until their matching Mac or phone permission is granted.",
        symbol: "checkmark.shield",
        body: "Grant access on the device that needs it. Phone Settings → Permissions shows SMS, SIM selection, Find Phone notifications, Notification Access, call controls, caller ID and Do Not Disturb access. Pairing requests Bluetooth or camera access when needed. Mac Settings → Permissions shows Event Posting for Control Mac and Lock Mac, notifications and automatic pasteboard reading. Return to aniCe after changing system access."
      ),
      GuideTopicEntry(
        topic: .openLinkInMac,
        title: "Open Link in Mac",
        summary: "Launch http or https links from your phone straight into your Mac browser.",
        symbol: "safari",
        body: "Connect a trusted Mac, then select a single http or https link on your phone and choose Send to Mac, or use Share → Send to Mac. Tapping Open in Mac launches it directly in your Mac’s default browser without overwriting your Mac clipboard; Send as clipboard copies it instead. Open in Mac requires support on the connected Mac. A successful request confirms the browser handoff, not that the page loaded."
      ),
      GuideTopicEntry(
        topic: .filesAndEdgeDrop,
        title: "Send files & Edge Drop",
        summary: "Encrypted batches up to 128 files, phone Share sheet, and Mac Edge Drop.",
        symbol: "arrow.up.doc",
        body: "Send 1–128 files from Send files, the phone Share → Send to Mac menu, or a Finder drop on Mac. Edge Drop uses the screen edge selected in Mac Settings → File transfer and accepts saved local files, not folders. Ready local-network connections are preferred; Bluetooth is slower. The receiver approves unless auto-receive is enabled for that sender. Interrupted transfers keep resume checkpoints for up to 15 minutes."
      ),
      GuideTopicEntry(
        topic: .clipboardAndQuickSend,
        title: "Clipboard & Quick Settings tile",
        summary: "Manual or auto text sync, phone selection menu, and Send to Mac Quick Settings tile.",
        symbol: "doc.on.clipboard",
        body: "Use Clipboard → Send clipboard or paste text manually. Automatic sharing is off by default; enable it for the peer on both devices. Android reads the clipboard only while aniCe has input focus. Add Send to Mac from Clipboard → Share → More options or Quick Settings → Edit. Tapping the tile opens a focused panel: review the captured item, then tap Send to Mac. Sensitive-marked clipboard items ask for confirmation. To open a link on Mac, use the phone selection or Share menu."
      ),
      GuideTopicEntry(
        topic: .pasteTrayAndPins,
        title: "Clipboard history & Quick Paste Tray",
        summary: "Device-local history filters, Mac pinned snippets, and tray shortcut.",
        symbol: "tray.full",
        body: "Enable Keep clipboard history separately on each device to save eligible text locally. History capacity is 20, 50 or 100 items; Mac pins are kept separately within 100 clips overall. Android has All/Mac/Phone filters; Mac also has Pinned. Open the Mac Paste tray from the menu bar or \(tray) to search, pin and copy saved clips. On Mac, Clipboard → History also provides Undo/Redo and a collection pause; pausing history does not pause sharing."
      ),
      GuideTopicEntry(
        topic: .controlMac,
        title: "Control Mac (from phone)",
        summary: "Use your phone screen and keyboard as a wireless Mac trackpad and keyboard.",
        symbol: "keyboard.badge.ellipsis",
        body: "Connect over Bluetooth, open phone Features → Control Mac and tap Start control. Move with one finger, tap to click, long-press to drag, or use two fingers for right-click and scrolling. Type with the phone keyboard; Live typing includes composing text. Clear resets only the phone editor. Input goes to the focused Mac app and needs Mac Event Posting access. After moving the Mac caret or changing documents, stop and start control before typing again."
      ),
      GuideTopicEntry(
        topic: .controlAndroidAndFloatingKey,
        title: "Control Android & Floating Key",
        summary: "Classic Bluetooth HID keyboard/trackpad from Mac and the \(floatingKey) Floating Key panel.",
        symbol: "keyboard",
        body: "Trust the phone in aniCe, pair it separately in system Bluetooth Settings, then link that pairing in Mac Features → Control Android. Click the trackpad to arm pointer and keyboard input; turn off Use keyboard and trackpad together for separate areas. Toggle Floating Key from the menu bar or \(floatingKey), and press \(floatingKeyInput) to start or stop typing directly (showing Floating Key if hidden), configurable in Mac Settings → Shortcuts. Press ⌘⇧Esc while an input surface has focus to stop. Bluetooth HID input stays separate from aniCe’s BLE and local-network connections."
      ),
      GuideTopicEntry(
        topic: .macDeskDeck,
        title: "Mac Desk Deck (from phone)",
        summary: "Live Mac CPU/memory/thermal meters, quick actions, audio output, and approved apps.",
        symbol: "slider.horizontal.3",
        body: "Open phone Features → Mac Desk Deck for CPU, memory, thermal pressure and device power readings. Stale readings keep their timestamp. Available Mac controls include input mute, Lock Mac, Screenshot, audio output and volume, approved apps and a Mac-local DND Shortcut; support and permissions determine which work. Ping Mac has separate readiness. Details → Keep awake while charging keeps the phone screen awake only while Desk Deck is visible and the phone has external power."
      ),
      GuideTopicEntry(
        topic: .nowPlayingAndAudio,
        title: "Now Playing & audio output",
        summary: "Track details, artwork, player selection and supported playback and volume controls.",
        symbol: "music.note",
        body: "Use Home, Features → Now Playing or the Mac menu bar for playback. Player selection, seeking, artwork and volume depend on the source and connection; artwork needs the local network. Audio stays on the Mac. Mac output volume and selected-player volume are separate controls, and phone volume keys adjust supported Mac output while playback is active. Grant player-control access in Mac Playback setup. Background phone media controls require existing companion ownership."
      ),
      GuideTopicEntry(
        topic: .messagesAndSms,
        title: "Messages & SMS relay",
        summary: "Read SMS conversations on Mac and reply directly through your phone’s SIM.",
        symbol: "message",
        body: "Grant SMS access in the phone Messages panel, then browse conversations, search and send replies over an existing connection. Choose SIM requests an optional active-SIM list; missing Phone state access is recovered in phone Settings → Permissions → SIM selection. Default-SIM sending does not need that list. The Mac Messages gear opens per-phone notification settings and Connection details inline. Radio acceptance is not recipient delivery; an unconfirmed reply may have been sent and is not retried automatically."
      ),
      GuideTopicEntry(
        topic: .notificationsAndCalls,
        title: "Mirrored notifications & call controls",
        summary: "Forward chosen phone app alerts to Mac with inline reply, dismissal, and Answer/Decline.",
        symbol: "bell.badge",
        body: "In phone Settings → Notification sync, enable Notification Access and choose apps under Select apps. Mac alerts expose replies, actions and dismissal only when the phone’s source notification supports them. Mirror incoming calls also uses Phone state and Answer phone calls access for SIM controls; Call log and Contacts add optional caller ID. Audio stays on the phone. Both devices need a live connection, and macOS notification and Focus settings control presentation."
      ),
      GuideTopicEntry(
        topic: .dndSync,
        title: "Do Not Disturb sync",
        summary: "Sync phone Do Not Disturb changes to macOS Focus using Apple Shortcuts.",
        symbol: "moon",
        body: "On the phone, allow Do Not Disturb access and enable Sync phone DND to Mac in Settings → Do Not Disturb. Create and choose separate On and Off Shortcuts in Mac Settings → Do Not Disturb. Connected phone DND changes run the matching Shortcut; disconnected changes are not replayed. Desk Deck’s DND button uses a separate Mac-local toggle Shortcut. Mac Focus changes are not synced back to the phone."
      ),
      GuideTopicEntry(
        topic: .findDeviceAndPing,
        title: "Find Device & Ping Mac",
        summary: "Ring a connected phone or request a Mac notification from Desk Deck.",
        symbol: "iphone.radiowaves.left.and.right",
        body: "With a live connection, Mac Features → Find Device rings the phone for up to 60 seconds or until stopped. Phone Settings → Permissions → Find Phone notifications controls incoming alert access. Ping Mac in phone Desk Deck requests a native Mac notification even when telemetry is stale. Alarm volume, Do Not Disturb and macOS Focus can limit alerts. Find Device does not track location, wake a sleeping Mac or start a stopped app."
      ),
      GuideTopicEntry(
        topic: .companionAndShortcuts,
        title: "Menu bar, Favourites & Settings",
        summary: "Sidebar/menu-bar pins, Favourites reordering, global shortcuts, Glass, and updates.",
        symbol: "star",
        body: "Add tools to Favourites or reorder them with right-click on Mac and long-press on phone. Mac feature menus also pin tools independently to the sidebar and menu bar. Mac Settings → Shortcuts configures Paste tray (\(tray)), Floating Key (\(floatingKey)) and Floating Key typing (\(floatingKeyInput)). Settings also holds appearance, 80%–120% text size, connection preferences and updates. New releases are reviewed before installation; automatic checking and beta inclusion are separate choices."
      ),
    ]
  }
}

private struct GuideFilterMinYKey: PreferenceKey {
  static let defaultValue: CGFloat = .infinity
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct GuideView: View {
  let initialTopic: GuideTopic?
  @State private var selectedCategory: GuideCategory = .all
  @State private var expandedTopics: Set<GuideTopic>
  @State private var filterPinned = false
  @Environment(\.colorScheme) private var scheme
  @AppStorage("ui.fontScale") private var fontScale = 1.0

  init(initialTopic: GuideTopic?) {
    self.initialTopic = initialTopic
    _expandedTopics = State(initialValue: Set([initialTopic].compactMap { $0 }))
  }

  private var visibleCategories: [GuideCategory] {
    selectedCategory == .all ? GuideCategory.allCases.filter { $0 != .all } : [selectedCategory]
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        let entries = GuideTopicEntry.allEntries
        VStack(alignment: .leading, spacing: 18) {
          header
          filterBar
            .opacity(filterPinned ? 0 : 1)
            .accessibilityHidden(filterPinned)
            .allowsHitTesting(!filterPinned)
            .background {
              GeometryReader { geo in
                Color.clear.preference(key: GuideFilterMinYKey.self, value: geo.frame(in: .named("guideScroll")).minY)
              }
            }
          ForEach(visibleCategories) { category in
            let categoryEntries = entries.filter { $0.topic.category == category }
            if !categoryEntries.isEmpty {
              VStack(alignment: .leading, spacing: 6) {
                Text(category.rawValue)
                  .font(.system(size: 12.5 * fontScale, weight: .semibold))
                  .foregroundStyle(AniCePalette.secondaryText(scheme))
                  .padding(.leading, 2)
                VStack(spacing: 0) {
                  ForEach(Array(categoryEntries.enumerated()), id: \.element.id) { index, entry in
                    topicRow(entry)
                      .id(entry.topic)
                    if index < categoryEntries.count - 1 {
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
      .task {
        guard let initialTopic, initialTopic != .pairingAndConnection else { return }
        await Task.yield()
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.2)) {
          proxy.scrollTo(initialTopic, anchor: .center)
        }
      }
    }
  }

  private var header: some View {
    let allExpanded = expandedTopics.count == GuideTopic.allCases.count
    return HStack(spacing: 10) {
      Image(systemName: "questionmark.circle")
        .font(.system(size: 18 * fontScale, weight: .semibold))
        .foregroundStyle(AniCePalette.accent(scheme))
      Text("aniCe Guide")
        .font(.system(size: 20 * fontScale, weight: .semibold))
        .foregroundStyle(AniCePalette.primaryText(scheme))
      Spacer()
      Button(allExpanded ? "Collapse all" : "Expand all") {
        expandedTopics = allExpanded ? [] : Set(GuideTopic.allCases)
      }
      .buttonStyle(AniCeHoverButtonStyle(feedbackPadding: 4))
      .font(.system(size: 12.5 * fontScale, weight: .medium))
      .foregroundStyle(AniCePalette.accent(scheme))
      .help(allExpanded ? "Collapse all Guide sections" : "Expand all Guide sections")
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
    return DisclosureGroup(isExpanded: Binding(get: { expandedTopics.contains(entry.topic) }, set: { expanded in
      if expanded { expandedTopics.insert(entry.topic) }
      else { expandedTopics.remove(entry.topic) }
    })) {
      Text(entry.body)
        .font(.system(size: 12 * fontScale))
        .foregroundStyle(AniCePalette.secondaryText(scheme))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 48)
        .padding(.trailing, 8)
        .padding(.top, 4)
        .padding(.bottom, 2)
    } label: {
      HStack(spacing: 10) {
        Image(systemName: entry.symbol)
          .font(.system(size: 14 * fontScale))
          .foregroundStyle(highlighted ? AniCePalette.accent(scheme) : AniCePalette.secondaryText(scheme))
          .frame(width: 20)
        VStack(alignment: .leading, spacing: 2) {
          Text(entry.title)
            .font(.system(size: 13 * fontScale, weight: .medium))
            .foregroundStyle(AniCePalette.primaryText(scheme))
          Text(entry.summary)
            .font(.system(size: 12 * fontScale))
            .foregroundStyle(AniCePalette.secondaryText(scheme))
        }
        .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 4)
      }
      .padding(.vertical, 2)
      .contentShape(Rectangle())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
