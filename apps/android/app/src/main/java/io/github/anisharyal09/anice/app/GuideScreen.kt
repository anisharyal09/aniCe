// SPDX-License-Identifier: GPL-3.0-or-later
// Renders one offline, categorized guide covering built-in capabilities across Mac and Android.
package io.github.anisharyal09.anice.app

import androidx.annotation.DrawableRes
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import io.github.anisharyal09.anice.R
import io.github.anisharyal09.anice.ui.ExpandableHelpNote

internal data class GuideTopicEntry(
    val topic: GuideTopic,
    val title: String,
    val summary: String,
    @DrawableRes val iconRes: Int,
    val body: String,
)

internal object GuideCatalog {
    val entries: List<GuideTopicEntry> = listOf(
        GuideTopicEntry(
            topic = GuideTopic.PairingAndConnection,
            title = "Pairing & Connections",
            summary = "Auto-pairing confirmation, QR scan, manual code entry, and device nicknames.",
            iconRes = R.drawable.ic_devices,
            body = "Pair by confirming the 6-digit auto-pairing comparison code, scanning the Mac QR code on your phone, or entering the pairing code manually on your phone. Paired devices reconnect over Bluetooth Low Energy and upgrade file transfers or Desk Deck onto local Wi-Fi when Settings → Connection → Use local network automatically is on in both apps. Rename or set a custom nickname for any paired device, pause connections, or unpair from Devices.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.Permissions,
            title = "Permissions & access",
            summary = "Capabilities stay inactive until their matching phone or Mac permission is granted.",
            iconRes = R.drawable.ic_settings,
            body = "Phone Settings → Permissions covers Nearby devices, SMS (Receive/Read/Send), Phone state (optional dual-SIM list), Find Phone notifications, Notification Access, Answer phone calls, Call log, Contacts (optional caller ID), and Do Not Disturb access. Mac Settings → Permissions covers Event Posting (Privacy & Security → Accessibility or Device Control, required for Control Mac and Lock Mac fallback), Notifications, and Automatic pasteboard reading.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.OpenLinkInMac,
            title = "Open Link in Mac",
            summary = "Launch http or https links from your phone straight into your Mac browser.",
            iconRes = R.drawable.ic_external_link,
            body = "Highlight an http or https link on your phone and choose Send to Mac, or share from Chrome via Share → Send to Mac. Tapping Open in Mac launches it directly in your Mac's default browser without overwriting your Mac clipboard (or tap Send as clipboard to copy it instead).",
        ),
        GuideTopicEntry(
            topic = GuideTopic.FilesAndEdgeDrop,
            title = "Send files & Edge Drop",
            summary = "Encrypted batches up to 128 files, phone Share sheet, and Mac Edge Drop.",
            iconRes = R.drawable.ic_file_send,
            body = "Send up to 128 files per batch from Send files, your phone's Share → Send to Mac menu, or by dragging Finder items onto the Left, Right, or Top screen edge with Mac Edge Drop (Settings → File transfer). Transfers use local Wi-Fi when available, retain 15-minute resume checkpoints across interruptions, and support custom receive folders, trusted auto-receive, and background notifications.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.ClipboardAndQuickSend,
            title = "Clipboard & Quick Settings tile",
            summary = "Manual or auto text sync, phone selection menu, and Send to Mac Quick Settings tile.",
            iconRes = R.drawable.ic_clipboard,
            body = "Share text manually via Clipboard → Send clipboard / Paste text here, or enable automatic sync on both devices in Settings → Clipboard. Add the Send to Mac Quick Settings tile (prompt in Clipboard → More options or Quick Settings → Edit) to push your current phone clipboard—or open an http/https link on Mac—with one notification-shade tap without opening aniCe. Text selection → Send to Mac and Share → Send to Mac also work in any app; marked sensitive items ask before sending.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.PasteTrayAndPins,
            title = "Clipboard history & Quick Paste Tray",
            summary = "Device-local history filters, Mac pinned snippets, and tray shortcut.",
            iconRes = R.drawable.ic_clipboard_tile,
            body = "Local-only clipboard history stays off synced storage on each device (All, Mac, and Phone filters on your phone with 20, 50, or 100 item capacity). On Mac, press ⌥⌘V or click the menu-bar icon (Mac Settings → Shortcuts) to search history, pin snippets, pause collection, or Undo/Redo edits offline.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.ControlMac,
            title = "Control Mac (from phone)",
            summary = "Use your phone screen and keyboard as a wireless Mac trackpad and keyboard.",
            iconRes = R.drawable.ic_laptop,
            body = "While connected, open Features → Control Mac and tap Start. Use one-finger drag to move, tap or two-finger tap to left/right click, long-press drag to select, two-finger drag to scroll, or expand fullscreen trackpad. Type using your mobile keyboard (with autocorrect, Live typing, Clear box without deleting Mac text, and cursor-preserving middle edits). Requires Mac Event Posting access (Mac Settings → Permissions).",
        ),
        GuideTopicEntry(
            topic = GuideTopic.ControlAndroidAndFloatingKey,
            title = "Control Android & Floating Key",
            summary = "Classic Bluetooth HID keyboard/trackpad from Mac and the Floating Key panel.",
            iconRes = R.drawable.ic_keyboard,
            body = "Pair your Mac and phone once in system Bluetooth Settings, then link that pairing inside Mac Features → Control Android (Home, Back, and Recents controls included). Toggle the compact Floating Key overlay from any Mac app via ⌥⌘K (Mac Settings → Shortcuts) or the menu bar, resize the trackpad, adjust pointer/scroll speed, and stop input anytime with ⌘⇧Esc.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.MacDeskDeck,
            title = "Mac Desk Deck (from phone)",
            summary = "Live Mac CPU/memory/thermal meters, quick actions, audio output, and approved apps.",
            iconRes = R.drawable.ic_features,
            body = "View live CPU history, memory breakdown (Used, App, Wired, Compressed, Cached, Swap), thermal state, and Mac/phone power status (plus last cached snapshot offline). Trigger Mic mute, Lock Mac, Screenshot, Keep awake while charging (under Details), Ping Mac, playback controls, Output device + volume slider, up to 32 approved Mac app shortcuts (Mac Settings → Desk Deck), and a Mac-local DND Shortcut.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.NowPlayingAndAudio,
            title = "Now Playing & audio output",
            summary = "Track metadata, album art, timeline scrubbing, player switcher, and volume sync.",
            iconRes = R.drawable.ic_media_note,
            body = "Control Mac playback and volume from Home, Features → Now Playing, Desk Deck, or the Mac menu bar (plus notification/lock-screen media controls when phone background ownership is active). Phone volume keys can adjust supported Mac output. Configure Mac visibility and volume access in Playback setup and Settings → Now Playing.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.MessagesAndSms,
            title = "Messages & SMS relay",
            summary = "Read SMS conversations on Mac and reply directly through your phone's SIM.",
            iconRes = R.drawable.ic_sms,
            body = "Browse recent SMS threads, unread counts, search results, dual-SIM Send from selection, and delivery status over your encrypted direct link (no cloud server). On Mac, the gear beside Search messages toggles per-phone notifications, sound, text previews, and Connection details inline (mirrored in Settings → Messages). Requires SMS access and Phone permission for SIM selection.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.NotificationsAndCalls,
            title = "Mirrored notifications & call controls",
            summary = "Forward chosen phone app alerts to Mac with inline reply, dismissal, and Answer/Decline.",
            iconRes = R.drawable.ic_phone,
            body = "In phone Settings → Notification sync, grant Notification Access and choose apps under Select apps. Native Mac alerts mirror inline replies, app actions, and dismissals. Enable Mirror incoming calls (Answer phone calls plus optional Call log & Contacts for caller ID) to Answer or Decline ringing SIM calls from Mac while audio stays on your phone.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.DndSync,
            title = "Do Not Disturb sync",
            summary = "Sync phone Do Not Disturb changes to macOS Focus using Apple Shortcuts.",
            iconRes = R.drawable.ic_settings,
            body = "Allow Do Not Disturb access and enable Sync phone DND to Mac in Settings → Do Not Disturb, then configure “Turn Do Not Disturb On” and “Turn Do Not Disturb Off” Shortcuts in Mac Settings → Do Not Disturb. Connected phone DND changes run the matching Mac Shortcut automatically (Desk Deck's DND toggle stays Mac-local).",
        ),
        GuideTopicEntry(
            topic = GuideTopic.FindDeviceAndPing,
            title = "Find Device & Ping Mac",
            summary = "Ring your misplaced phone loudly from Mac or Ping Mac from Desk Deck.",
            iconRes = R.drawable.ic_phone,
            body = "Use Mac Features → Find Device (or the menu bar) to sound a continuous alarm ring on your paired phone until dismissed (configured under phone Settings → Permissions → Find Phone notifications). Tap Ping Mac inside Desk Deck → Find Mac to post an immediate macOS alert notification even when Desk Deck meters are stale.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.CompanionAndShortcuts,
            title = "Menu bar, Favourites & Settings",
            summary = "Sidebar/menu-bar pins, Favourites reordering, global shortcuts, themes, and updates.",
            iconRes = R.drawable.ic_star,
            body = "Star tools into Favourites or reorder features (long-press on phone, right-click on Mac); Mac right-click menus also pin tools to the sidebar and menu bar alongside Quick Paste Tray (⌥⌘V) and Floating Key (⌥⌘K) in Mac Settings → Shortcuts. Both apps support System/Light/Dark themes, 80%–120% text scaling, identity safety checks, and signed GitHub updates in Settings.",
        ),
    )
}

private sealed interface GuideRow {
    val key: String
    data class Heading(val category: GuideCategory, val first: Boolean) : GuideRow {
        override val key: String = "heading-${category.name}"
    }
    data class Topic(val entry: GuideTopicEntry, val isFirst: Boolean, val isLast: Boolean) : GuideRow {
        override val key: String = "topic-${entry.topic.name}"
    }
}

@Composable
internal fun GuideScreen(initialTopic: GuideTopic?) {
    var selectedCategory by rememberSaveable(initialTopic) { mutableStateOf(GuideCategory.All) }
    var forceExpandAll by rememberSaveable(initialTopic) { mutableStateOf<Boolean?>(null) }
    var categoryChangedByUser by rememberSaveable(initialTopic) { mutableStateOf(false) }
    val listState = rememberLazyListState()

    val visibleCategories = remember(selectedCategory) {
        if (selectedCategory == GuideCategory.All) GuideCategory.entries.filter { it != GuideCategory.All }
        else listOf(selectedCategory)
    }

    val rows = remember(visibleCategories) {
        buildList {
            visibleCategories.forEachIndexed { catIndex, category ->
                val categoryEntries = GuideCatalog.entries.filter { it.topic.category == category }
                if (categoryEntries.isNotEmpty()) {
                    add(GuideRow.Heading(category, first = catIndex == 0))
                    categoryEntries.forEachIndexed { index, entry ->
                        add(GuideRow.Topic(entry, isFirst = index == 0, isLast = index == categoryEntries.lastIndex))
                    }
                }
            }
        }
    }

    LaunchedEffect(initialTopic) {
        forceExpandAll = null
        categoryChangedByUser = false
        selectedCategory = GuideCategory.All
        if (initialTopic != null) {
            val targetIndex = rows.indexOfFirst { it is GuideRow.Topic && it.entry.topic == initialTopic }
            if (targetIndex >= 0) {
                withFrameNanos { }
                val targetKey = "topic-${initialTopic.name}"
                val layoutInfo = listState.layoutInfo
                val visible = layoutInfo.visibleItemsInfo.firstOrNull { it.key == targetKey }
                if (visible == null) {
                    // Account for guide-header (0), sticky guide-filter (1), and show the topic heading above it.
                    listState.animateScrollToItem((targetIndex + 1).coerceAtLeast(1))
                } else {
                    val stickyBottom = layoutInfo.visibleItemsInfo
                        .firstOrNull { it.key == "guide-filter" }
                        ?.let { it.offset + it.size } ?: 0
                    val overflow = (visible.offset + visible.size) - layoutInfo.viewportEndOffset
                    val maxKeepingRoom = (visible.offset - stickyBottom).coerceAtLeast(0)
                    if (overflow > 0 && maxKeepingRoom > 0) {
                        listState.animateScrollBy(minOf(overflow, maxKeepingRoom).toFloat())
                    }
                }
            }
        }
    }

    LaunchedEffect(selectedCategory) {
        if (categoryChangedByUser) {
            listState.scrollToItem(0)
        }
    }

    val allExpanded = forceExpandAll == true

    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
        LazyColumn(
            state = listState,
            modifier = Modifier.widthIn(max = 680.dp).fillMaxSize(),
            verticalArrangement = Arrangement.spacedBy(0.dp),
            contentPadding = PaddingValues(top = 12.dp, bottom = 16.dp),
        ) {
            item(key = "guide-header") {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Icon(
                        painter = painterResource(R.drawable.ic_help),
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(20.dp),
                    )
                    Text(
                        "aniCe Guide",
                        style = MaterialTheme.typography.titleMedium,
                        modifier = Modifier.weight(1f).semantics { heading() },
                    )
                    TextButton(
                        onClick = { forceExpandAll = !allExpanded },
                        modifier = Modifier.heightIn(min = 48.dp),
                    ) {
                        Text(if (allExpanded) "Collapse all" else "Expand all")
                    }
                }
            }
            @OptIn(ExperimentalFoundationApi::class)
            stickyHeader(key = "guide-filter") {
                Surface(
                    color = MaterialTheme.colorScheme.background,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column(Modifier.fillMaxWidth()) {
                        @OptIn(ExperimentalLayoutApi::class)
                        FlowRow(
                            Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 16.dp, vertical = 6.dp)
                                .selectableGroup(),
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                            verticalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            GuideCategory.entries.forEach { category ->
                                FilterChip(
                                    selected = selectedCategory == category,
                                    onClick = {
                                        categoryChangedByUser = true
                                        selectedCategory = category
                                    },
                                    label = { Text(category.label) },
                                    modifier = Modifier.defaultMinSize(minHeight = 32.dp),
                                )
                            }
                        }
                        HorizontalDivider(
                            thickness = 0.5.dp,
                            color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.45f),
                        )
                    }
                }
            }
            items(rows, key = { it.key }) { row ->
                    when (row) {
                        is GuideRow.Heading -> Text(
                            row.category.label,
                            style = MaterialTheme.typography.titleSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier
                                .padding(
                                    start = 18.dp,
                                    end = 16.dp,
                                    top = if (row.first) 12.dp else 18.dp,
                                    bottom = 6.dp,
                                )
                                .semantics { heading() },
                        )
                        is GuideRow.Topic -> {
                            val highlighted = initialTopic == row.entry.topic
                            val expandedByDefault = forceExpandAll ?: highlighted
                            val groupShape = when {
                                row.isFirst && row.isLast -> RoundedCornerShape(12.dp)
                                row.isFirst -> RoundedCornerShape(topStart = 12.dp, topEnd = 12.dp)
                                row.isLast -> RoundedCornerShape(bottomStart = 12.dp, bottomEnd = 12.dp)
                                else -> RectangleShape
                            }
                            Surface(
                                shape = groupShape,
                                color = if (highlighted) MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.55f)
                                else MaterialTheme.colorScheme.surfaceContainer,
                                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                            ) {
                                Column(Modifier.fillMaxWidth()) {
                                    Box(Modifier.fillMaxWidth()) {
                                        if (highlighted) {
                                            Box(
                                                Modifier
                                                    .matchParentSize()
                                                    .padding(vertical = 8.dp),
                                            ) {
                                                Box(
                                                    Modifier
                                                        .width(2.5.dp)
                                                        .fillMaxHeight()
                                                        .background(MaterialTheme.colorScheme.primary),
                                                )
                                            }
                                        }
                                        ExpandableHelpNote(
                                            title = row.entry.title,
                                            summary = row.entry.summary,
                                            body = row.entry.body,
                                            iconRes = row.entry.iconRes,
                                            highlighted = highlighted,
                                            expandedByDefault = expandedByDefault,
                                            modifier = Modifier.padding(horizontal = 12.dp, vertical = 2.dp),
                                        )
                                    }
                                    if (!row.isLast) {
                                        HorizontalDivider(
                                            modifier = Modifier.padding(start = 46.dp, end = 14.dp),
                                            thickness = 0.5.dp,
                                            color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.55f),
                                        )
                                    }
                                }
                            }
                    }
                }
            }
        }
    }
}

