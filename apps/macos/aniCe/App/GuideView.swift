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
        body: "Pair in Devices. For nearby pairing, compare all six digits on both screens and confirm on both. With Manual pair, scan the Mac’s QR code or enter its PIN on the phone.\n\nIf you’re already paired, check Bluetooth and Local network separately in Devices. Resume if paused, or reconnect without pairing again. Bluetooth reconnect in the background needs Android’s native approval. To set up Wi-Fi automatically, enable Use local network automatically in Settings → Connection on both devices.\n\nEdit This device to share a new name, or set a private nickname for a paired device."
      ),
      GuideTopicEntry(
        topic: .permissions,
        title: "Permissions & access",
        summary: "Capabilities stay inactive until their matching Mac or phone permission is granted.",
        symbol: "checkmark.shield",
        body: "Open Settings → Permissions in aniCe on the device that needs access. On Mac, Event Posting is used by Control Mac and Lock Mac. Notifications and automatic pasteboard reading are separate.\n\nOn the phone, Permissions covers SMS, SIM selection, Find Phone notifications, Notification Access, SIM-call controls, optional caller ID and Do Not Disturb. Bluetooth and camera access are requested during setup when needed. Return to aniCe after changing access so the status can refresh."
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
        body: "Open Features → Send files to send a batch of 1–128 files. On your phone, you can also use Share → Send to Mac. On Mac, drag local Finder files to the Edge Drop edge chosen in Settings → File transfer. Edge Drop accepts files, not folders.\n\nChoose Automatically receive files per sender and set the save folder in Mac Settings → File transfer or in the phone’s Send files panel. Without auto-receive, the receiver reviews the offer.\n\nLocal network is faster than Bluetooth. Interrupted transfers keep resume checkpoints for up to 15 minutes. Reconnect to the same peer; after local-network loss, continuing over Bluetooth needs your approval."
      ),
      GuideTopicEntry(
        topic: .clipboardAndQuickSend,
        title: "Clipboard & Quick Settings tile",
        summary: "Manual or auto text sync, phone selection menu, and Send to Mac Quick Settings tile.",
        symbol: "doc.on.clipboard",
        body: "Use Clipboard → Send clipboard or paste text manually. For automatic sharing, turn it on for the peer on both devices. Android can read the clipboard only while aniCe has input focus.\n\nAdd the Send to Mac tile from Clipboard → Share → More options (Android 13+) or Quick Settings → Edit. The tile opens a panel showing size and sensitivity, then waits for Send to Mac. Sensitive items marked by the phone ask for confirmation. To open a link in the Mac browser, use the phone’s text selection or Share menu instead."
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
        body: "Connect over Bluetooth, open phone Features → Control Mac and tap Start control. If access is blocked, open Settings → Permissions → Event Posting in aniCe on Mac.\n\nMove with one finger, tap to click, long-press and move to drag, or scroll with two fingers. Type with the phone keyboard; Live typing also sends text as you compose it. Clear only resets the phone editor. If you move the text cursor on Mac or change documents, stop and start control before typing again."
      ),
      GuideTopicEntry(
        topic: .controlAndroidAndFloatingKey,
        title: "Control Android & Floating Key",
        summary: "Use your Mac keyboard and trackpad on the phone, with a floating shortcut.",
        symbol: "keyboard",
        body: "Pair in aniCe and in system Bluetooth Settings, then choose Link device in Mac Features → Control Android. Click the trackpad to start pointer and keyboard control. Turn off Use keyboard and trackpad together for separate input areas.\n\nUse \(floatingKey) to show or hide Floating Key and \(floatingKeyInput) to start or stop typing through it. You can change both in Mac Settings → Shortcuts. When the controls have focus, ⌘⇧Esc stops input."
      ),
      GuideTopicEntry(
        topic: .macDeskDeck,
        title: "Mac Desk Deck (from phone)",
        summary: "Live Mac CPU/memory/thermal meters, quick actions, audio output, and approved apps.",
        symbol: "slider.horizontal.3",
        body: "Open phone Features → Mac Desk Deck for CPU, memory, thermal pressure and battery. If readings are stale, open Details and tap Refresh readings. Ping Mac can work independently of the readings.\n\nInput mute, Lock Mac and audio controls depend on hardware and permissions. Screenshot opens capture controls on Mac; the image stays there. Allow app shortcuts in Mac Settings → Desk Deck. Choose the DND mode Shortcut in Mac Settings → Do Not Disturb.\n\nDetails → Keep awake while charging applies only while Desk Deck is visible and the phone has external power."
      ),
      GuideTopicEntry(
        topic: .nowPlayingAndAudio,
        title: "Now Playing & audio output",
        summary: "Track details, artwork, player selection and supported playback and volume controls.",
        symbol: "music.note",
        body: "Open Features → Now Playing to control Mac playback. Home and the Mac menu bar also offer playback controls when available. Check Mac Playback setup if your player needs access. Artwork needs a local-network connection; audio stays on the Mac.\n\nOutput volume changes the Mac’s audio output; player volume changes only the selected player. Phone volume buttons can adjust supported Mac output while the playback panel is active. Phone notification and lock-screen controls need Android background connection setup."
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
        summary: "Choose which alerts appear on Mac and what to do when a call action fails.",
        symbol: "bell.badge",
        body: "On your phone, open Settings → Notification sync. Allow Notification Access and use Select apps for regular alerts. Mirror incoming calls adds supported call alerts from apps outside that list. Turning it off still allows alerts from selected apps.\n\nPhone state and Answer phone calls are for SIM-call controls. Call log and Contacts add optional SIM caller ID. With apps like WhatsApp, Android and the source app decide whether Answer or Decline works.\n\nRequest sent to phone confirms dispatch only. If the call is still ringing or aniCe can’t confirm the action, use the phone. Call audio stays on the phone. If no alerts arrive, check the connection in Devices, Notification sync on the phone, and notification and Focus settings on Mac."
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
        body: "Star tools to add them to Favourites. To reorder, right-click on Mac or long-press on the phone. Mac feature menus also pin tools separately to the sidebar or menu bar. Closing the Mac window leaves its menu-bar companion running.\n\nMac Settings → Shortcuts shows Clipboard tray (\(tray)), Floating Key (\(floatingKey)) and \(GlobalShortcutAction.floatingKeyInput.title) (\(floatingKeyInput)). Use Settings → Appearance for theme and text size. In Settings → Updates, you can check manually, choose automatic checks or opt into betas. Review release notes before installing."
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
