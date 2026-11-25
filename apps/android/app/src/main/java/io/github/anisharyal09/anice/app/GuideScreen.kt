// SPDX-License-Identifier: GPL-3.0-or-later
// Renders one offline, categorized guide covering built-in capabilities across Mac and Android.
package io.github.anisharyal09.anice.app

import androidx.annotation.DrawableRes
import androidx.compose.foundation.background
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
import androidx.compose.ui.graphics.Color
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
            summary = "End-to-end encrypted Bluetooth Low Energy and local Wi-Fi.",
            iconRes = R.drawable.ic_devices,
            body = "Verify the 6-digit comparison code (or scan QR on Android) once when pairing. Paired devices reconnect automatically over Bluetooth Low Energy and upgrade heavier work such as file transfers or Desk Deck onto local Wi-Fi when Settings → Connection → Use local network automatically is on in both apps (Android also offers Idle LAN in background timeouts). Pause or unpair a peer anytime from Devices without resetting this device's identity.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.Permissions,
            title = "Permissions & Mac Access",
            summary = "Capabilities stay dormant until the matching Android or Mac access is allowed.",
            iconRes = R.drawable.ic_settings,
            body = "Android Settings → Permissions covers Nearby devices, Receive/Read/Send SMS, SIM selection, Find Phone notifications, Notification Access, Answer phone calls, Call log, Contacts (optional caller ID), and Do Not Disturb access. Mac Settings → Permissions (Access) tracks Event Posting (Privacy & Security → Accessibility or Device Control, used for Control Mac and Lock Mac fallback), Notifications, and Automatic pasteboard reading.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.OpenLinkInMac,
            title = "Open Link in Mac",
            summary = "Launch any http or https link from Android straight into your Mac's browser.",
            iconRes = R.drawable.ic_external_link,
            body = "Highlight a web URL in any Android app and choose Send to Mac, or share a URL from Chrome or another app via Android's Share sheet → Send to Mac. When the link is an http or https URL and your connected Mac supports Open Link, tapping Open in Mac launches it directly in your Mac's default browser without overwriting your Mac clipboard (or tap Send as clipboard to send it to Mac clipboard instead).",
        ),
        GuideTopicEntry(
            topic = GuideTopic.FilesAndEdgeDrop,
            title = "Send files & Edge Drop",
            summary = "Encrypted batch transfers up to 128 files plus Android Share & Mac Edge Drop.",
            iconRes = R.drawable.ic_file_send,
            body = "Pick files in Send files, share directly from any Android app with Share → Send to Mac, or drag from Finder toward your chosen Left, Right, or Top screen edge with Mac Edge Drop. Transfers switch automatically to local Wi-Fi when paired and reachable, track progress per file with retry or cancel, and support Save received files to custom folders, background transfer notifications, and trusted auto-receive in Settings → File transfer.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.ClipboardAndQuickSend,
            title = "Clipboard & Send to Mac",
            summary = "Manual or automatic text sync, Android selection menu, and Quick Settings tile.",
            iconRes = R.drawable.ic_clipboard,
            body = "Send text manually from Clipboard → Send clipboard, paste text under More options → Paste text here, or enable automatic sharing on both devices in Settings → Clipboard. Anywhere on Android, highlight text and pick Send to Mac, share text into Send to Mac, or add the Send to Mac Quick Settings tile (prompt inside Clipboard → More options or Quick Settings → Edit). Marked sensitive items ask before sending.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.PasteTrayAndPins,
            title = "History & Quick Paste Tray",
            summary = "Offline local clipboard history by device, Mac snippet pins, and tray hotkey.",
            iconRes = R.drawable.ic_clipboard_tile,
            body = "Android Clipboard → History keeps local-only clips filtered by All, Mac, and Phone tabs with selectable 20, 50, or 100 item capacity. Mac Clipboard → History and the floating Quick Paste Tray (⌥⌘V or menu-bar icon; Mac Settings → Shortcuts) keep local-only history under All, Pinned, Mac, and Phone filters with search, pinned snippets, Pause history, and Undo/Redo.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.ControlMac,
            title = "Control Mac (from Android)",
            summary = "Turn your phone screen and keyboard into a wireless trackpad and keyboard for Mac.",
            iconRes = R.drawable.ic_laptop,
            body = "Open Features → Control Mac while connected and tap Start. Drag for cursor movement, tap or two-finger tap to click, two-finger drag to scroll, and type with your regular Android keyboard (with autocorrect and IME support) or the fullscreen trackpad bar. Requires Event Posting / Accessibility access on Mac (Mac Settings → Permissions); closing the screen keeps the live session ready without forcing the keyboard open.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.ControlAndroidAndFloatingKey,
            title = "Control Android & Floating Key",
            summary = "Bluetooth HID keyboard and trackpad from Mac plus the anywhere Floating Key.",
            iconRes = R.drawable.ic_keyboard,
            body = "Pair your phone and Mac in system Bluetooth Settings once, then link that Bluetooth pairing in Mac Features → Control Android. On Mac, press ⌥⌘K (customizable in Mac Settings → Shortcuts) or use the menu bar to toggle the Floating Key panel anywhere, use keyboard and trackpad together or separately, resize the pad, and stop input anytime with ⌘⇧Esc.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.MacDeskDeck,
            title = "Mac Desk Deck (from Android)",
            summary = "Monitor Mac vitals and trigger quick actions, audio output switching, volume, and apps.",
            iconRes = R.drawable.ic_features,
            body = "Open Features → Mac Desk Deck to view live CPU history, memory breakdown (Used, App, Wired, Compressed, Cached, Swap), thermal pressure, and Mac/Phone power status plus a cached last snapshot when offline. Trigger Mute input / Mic mute, Lock Mac, Screenshot, Keep awake while charging (under Details), Ping Mac, Now Playing controls, Output device + Output volume slider, up to 32 approved Mac app shortcuts (Mac Settings → Desk Deck, arranged under Apps), and a Mac-local DND mode Shortcut (does not sync back to your phone).",
        ),
        GuideTopicEntry(
            topic = GuideTopic.NowPlayingAndAudio,
            title = "Now Playing & Output control",
            summary = "Shared track artwork, scrubbing, playback buttons, and volume synchronization.",
            iconRes = R.drawable.ic_media_note,
            body = "Control playback and volume from Home, Features → Now Playing, Mac Desk Deck, or Mac's menu-bar companion. View track title, artist, album art, timeline scrubber, play/pause/skip buttons, and output volume synchronization across connected peers. Configure Mac visibility and player volume in Playback setup and Settings → Now Playing.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.MessagesAndSms,
            title = "Messages & SMS relay",
            summary = "Read phone SMS threads on Mac and send replies straight through your SIM.",
            iconRes = R.drawable.ic_sms,
            body = "Browse recent SMS conversations, unread counts, search results, dual-SIM Send from selection, and sent/delivery status in Mac Features → Messages over your encrypted direct connection (zero cloud server). On Mac, the gear beside Search messages toggles per-phone notifications and Connection details right inline (Settings → Messages shows the same controls). Requires Android SMS permissions and Phone access for SIM selection.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.NotificationsAndCalls,
            title = "Mirrored Notifications & Call controls",
            summary = "Mirror Android app alerts to Mac, inline reply or dismiss, and handle SIM calls.",
            iconRes = R.drawable.ic_phone,
            body = "Configure under Settings → Notification sync: grant Notification Access, pick installed apps under Select apps, and turn on Mirror incoming calls (Answer phone calls plus optional Call log & Contacts for caller ID) to show caller alerts on Mac with Answer or Decline actions while call audio stays on your phone. Supported inline replies and dismissals mirror back to Android.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.DndSync,
            title = "Do Not Disturb sync",
            summary = "Sync Android Do Not Disturb changes onto macOS Focus using Apple Shortcuts.",
            iconRes = R.drawable.ic_settings,
            body = "Turn on Sync phone DND to Mac in Settings → Do Not Disturb (after allowing Do Not Disturb access), and choose the two Apple Shortcuts (“Turn Do Not Disturb On” and “Turn Do Not Disturb Off”) guided inside Mac Settings → Do Not Disturb (copyable prompts or manual Set Focus setup). When phone DND changes while connected, your Mac runs the matching Shortcut locally.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.FindDeviceAndPing,
            title = "Find Device & Ping Mac",
            summary = "Ring your misplaced phone from Mac or send Ping Mac from Android Desk Deck.",
            iconRes = R.drawable.ic_phone,
            body = "Open Mac Features → Find Device (or the menu-bar companion) to trigger a continuous audible alarm ring on your paired phone until dismissed; Android incoming-ring permissions live in Settings → Permissions → Find Phone notifications. On Android, open Features → Mac Desk Deck → Find Mac and tap Ping Mac to send a macOS alert notification whose banner and sound follow Mac Notification settings, even when Desk Deck telemetry is stale.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.CompanionAndShortcuts,
            title = "Menu bar, Favourites & Customization",
            summary = "Pinned quick actions, feature reordering, themes, scaled text, and signed updates.",
            iconRes = R.drawable.ic_star,
            body = "Star any tool into Favourites or reorder features (long-press on Android, right-click on Mac); Mac right-click menus also customize menu-bar and sidebar pins alongside Quick Paste Tray (⌥⌘V) and Floating Key (⌥⌘K) in Mac Settings → Shortcuts. Both apps support System/Light/Dark themes, 80%–120% text scaling, device safety checks, and signed GitHub updates in Settings.",
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
                listState.animateScrollToItem(targetIndex + 1)
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
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 16.dp),
        ) {
            item(key = "guide-header") {
                Column(
                    Modifier.fillMaxWidth().padding(bottom = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Row(
                        Modifier.fillMaxWidth(),
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

                    Text(
                        "Offline reference for everything built into aniCe across your Android and Mac—including system tools outside the Features list—plus shortcuts and Settings paths.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )

                    @OptIn(ExperimentalLayoutApi::class)
                    FlowRow(
                        Modifier.fillMaxWidth().selectableGroup(),
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
                }
            }
            items(rows, key = { it.key }) { row ->
                    when (row) {
                        is GuideRow.Heading -> Text(
                            row.category.label,
                            style = MaterialTheme.typography.titleSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier
                                .padding(top = if (row.first) 4.dp else 18.dp, bottom = 6.dp, start = 2.dp)
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
                                modifier = Modifier.fillMaxWidth(),
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

