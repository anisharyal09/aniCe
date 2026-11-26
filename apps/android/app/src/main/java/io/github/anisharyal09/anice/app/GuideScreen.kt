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
import androidx.compose.runtime.saveable.Saver
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

private data class GuideTopicEntry(
    val topic: GuideTopic,
    val title: String,
    val summary: String,
    @DrawableRes val iconRes: Int,
    val body: String,
)

private object GuideCatalog {
    val entries: List<GuideTopicEntry> = listOf(
        GuideTopicEntry(
            topic = GuideTopic.PairingAndConnection,
            title = "Pairing & Connections",
            summary = "Nearby confirmation, QR scan, manual code entry, and device nicknames.",
            iconRes = R.drawable.ic_devices,
            body = "In Devices, pair by comparing the six digits on both screens, scanning the Mac QR code on your phone, or entering its pairing code. Bluetooth reconnect follows the saved automatic preference; background reconnect also needs supported phone setup. Local-network setup follows Use local network automatically in Settings → Connection. Devices also lets you edit device names, choose private nicknames, pause connections or unpair.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.Permissions,
            title = "Permissions & access",
            summary = "Capabilities stay inactive until their matching phone or Mac permission is granted.",
            iconRes = R.drawable.ic_settings,
            body = "Grant access on the device that needs it. Phone Settings → Permissions shows SMS, SIM selection, Find Phone notifications, Notification Access, call controls, caller ID and Do Not Disturb access. Pairing requests Bluetooth or camera access when needed. Mac Settings → Permissions shows Event Posting for Control Mac and Lock Mac, notifications and automatic pasteboard reading. Return to aniCe after changing system access.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.OpenLinkInMac,
            title = "Open Link in Mac",
            summary = "Launch http or https links from your phone straight into your Mac browser.",
            iconRes = R.drawable.ic_external_link,
            body = "Connect a trusted Mac, then select a single http or https link on your phone and choose Send to Mac, or use Share → Send to Mac. Tapping Open in Mac launches it directly in your Mac’s default browser without overwriting your Mac clipboard; Send as clipboard copies it instead. Open in Mac requires support on the connected Mac. A successful request confirms the browser handoff, not that the page loaded.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.FilesAndEdgeDrop,
            title = "Send files & Edge Drop",
            summary = "Encrypted batches up to 128 files, phone Share sheet, and Mac Edge Drop.",
            iconRes = R.drawable.ic_file_send,
            body = "Send 1–128 files from Send files, the phone Share → Send to Mac menu, or a Finder drop on Mac. Edge Drop uses the screen edge selected in Mac Settings → File transfer and accepts saved local files, not folders. Ready local-network connections are preferred; Bluetooth is slower. The receiver approves unless auto-receive is enabled for that sender. Interrupted transfers keep resume checkpoints for up to 15 minutes.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.ClipboardAndQuickSend,
            title = "Clipboard & Quick Settings tile",
            summary = "Manual or auto text sync, phone selection menu, and Send to Mac Quick Settings tile.",
            iconRes = R.drawable.ic_clipboard,
            body = "Use Clipboard → Send clipboard or paste text manually. Automatic sharing is off by default; enable it for the peer on both devices. Android reads the clipboard only while aniCe has input focus. Add Send to Mac from Clipboard → Share → More options or Quick Settings → Edit. Tapping the tile opens a focused panel: review the captured item, then tap Send to Mac. Sensitive-marked clipboard items ask for confirmation. To open a link on Mac, use the phone selection or Share menu.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.PasteTrayAndPins,
            title = "Clipboard history & Quick Paste Tray",
            summary = "Device-local history filters, Mac pinned snippets, and tray shortcut.",
            iconRes = R.drawable.ic_clipboard_tile,
            body = "Enable Keep clipboard history separately on each device to save eligible text locally. History capacity is 20, 50 or 100 items; Mac pins are kept separately within 100 clips overall. Android has All/Mac/Phone filters; Mac also has Pinned. Open the Mac Paste tray from the menu bar or ⌥⌘V to search, pin and copy saved clips. On Mac, Clipboard → History also provides Undo/Redo and a collection pause; pausing history does not pause sharing.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.ControlMac,
            title = "Control Mac (from phone)",
            summary = "Use your phone screen and keyboard as a wireless Mac trackpad and keyboard.",
            iconRes = R.drawable.ic_laptop,
            body = "Connect over Bluetooth, open phone Features → Control Mac and tap Start control. Move with one finger, tap to click, long-press to drag, or use two fingers for right-click and scrolling. Type with the phone keyboard; Live typing includes composing text. Clear resets only the phone editor. Input goes to the focused Mac app and needs Mac Event Posting access. After moving the Mac caret or changing documents, stop and start control before typing again.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.ControlAndroidAndFloatingKey,
            title = "Control Android & Floating Key",
            summary = "Classic Bluetooth HID keyboard/trackpad from Mac and the Floating Key panel.",
            iconRes = R.drawable.ic_keyboard,
            body = "Trust the phone in aniCe, pair it separately in system Bluetooth Settings, then link that pairing in Mac Features → Control Android. Click the trackpad to arm pointer and keyboard input; turn off Use keyboard and trackpad together for separate areas. Toggle Floating Key from the menu bar or ⌥⌘K, configurable in Mac Settings → Shortcuts. Press ⌘⇧Esc while an input surface has focus to stop. Bluetooth HID input stays separate from aniCe’s BLE and local-network connections.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.MacDeskDeck,
            title = "Mac Desk Deck (from phone)",
            summary = "Live Mac CPU/memory/thermal meters, quick actions, audio output, and approved apps.",
            iconRes = R.drawable.ic_features,
            body = "Open phone Features → Mac Desk Deck for CPU, memory, thermal pressure and device power readings. Stale readings keep their timestamp. Available Mac controls include input mute, Lock Mac, Screenshot, audio output and volume, approved apps and a Mac-local DND Shortcut; support and permissions determine which work. Ping Mac has separate readiness. Details → Keep awake while charging keeps the phone screen awake only while Desk Deck is visible and the phone has external power.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.NowPlayingAndAudio,
            title = "Now Playing & audio output",
            summary = "Track details, artwork, player selection and supported playback and volume controls.",
            iconRes = R.drawable.ic_media_note,
            body = "Use Home, Features → Now Playing or the Mac menu bar for playback. Player selection, seeking, artwork and volume depend on the source and connection; artwork needs the local network. Audio stays on the Mac. Mac output volume and selected-player volume are separate controls, and phone volume keys adjust supported Mac output while playback is active. Grant player-control access in Mac Playback setup. Background phone media controls require existing companion ownership.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.MessagesAndSms,
            title = "Messages & SMS relay",
            summary = "Read SMS conversations on Mac and reply directly through your phone's SIM.",
            iconRes = R.drawable.ic_sms,
            body = "Grant SMS access in the phone Messages panel, then browse conversations, search and send replies over an existing connection. Choose SIM requests an optional active-SIM list; missing Phone state access is recovered in phone Settings → Permissions → SIM selection. Default-SIM sending does not need that list. The Mac Messages gear opens per-phone notification settings and Connection details inline. Radio acceptance is not recipient delivery; an unconfirmed reply may have been sent and is not retried automatically.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.NotificationsAndCalls,
            title = "Mirrored notifications & call controls",
            summary = "Forward chosen phone app alerts to Mac with inline reply, dismissal, and Answer/Decline.",
            iconRes = R.drawable.ic_phone,
            body = "In phone Settings → Notification sync, enable Notification Access and choose apps under Select apps. Mac alerts expose replies, actions and dismissal only when the phone’s source notification supports them. Mirror incoming calls also uses Phone state and Answer phone calls access for SIM controls; Call log and Contacts add optional caller ID. Audio stays on the phone. Both devices need a live connection, and macOS notification and Focus settings control presentation.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.DndSync,
            title = "Do Not Disturb sync",
            summary = "Sync phone Do Not Disturb changes to macOS Focus using Apple Shortcuts.",
            iconRes = R.drawable.ic_settings,
            body = "On the phone, allow Do Not Disturb access and enable Sync phone DND to Mac in Settings → Do Not Disturb. Create and choose separate On and Off Shortcuts in Mac Settings → Do Not Disturb. Connected phone DND changes run the matching Shortcut; disconnected changes are not replayed. Desk Deck’s DND button uses a separate Mac-local toggle Shortcut. Mac Focus changes are not synced back to the phone.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.FindDeviceAndPing,
            title = "Find Device & Ping Mac",
            summary = "Ring a connected phone or request a Mac notification from Desk Deck.",
            iconRes = R.drawable.ic_phone,
            body = "With a live connection, Mac Features → Find Device rings the phone for up to 60 seconds or until stopped. Phone Settings → Permissions → Find Phone notifications controls incoming alert access. Ping Mac in phone Desk Deck requests a native Mac notification even when telemetry is stale. Alarm volume, Do Not Disturb and macOS Focus can limit alerts. Find Device does not track location, wake a sleeping Mac or start a stopped app.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.CompanionAndShortcuts,
            title = "Menu bar, Favourites & Settings",
            summary = "Sidebar/menu-bar pins, Favourites reordering, global shortcuts, themes, and updates.",
            iconRes = R.drawable.ic_star,
            body = "Add tools to Favourites or reorder them with right-click on Mac and long-press on phone. Mac feature menus also pin tools independently to the sidebar and menu bar. Mac Settings → Shortcuts configures Paste tray (default ⌥⌘V) and Floating Key (default ⌥⌘K); check there for custom bindings. Settings also holds appearance, 80%–120% text size, connection preferences and updates. New releases are reviewed before installation; automatic checking and beta inclusion are separate choices.",
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

private val expandedTopicsSaver = Saver<Set<GuideTopic>, ArrayList<String>>(
    save = { topics -> topics.mapTo(ArrayList()) { it.name } },
    restore = { names -> GuideTopic.entries.filter { it.name in names }.toSet() },
)

@Composable
internal fun GuideScreen(initialTopic: GuideTopic?) = key(initialTopic) {
    var selectedCategory by rememberSaveable { mutableStateOf(GuideCategory.All) }
    var expandedTopics by rememberSaveable(stateSaver = expandedTopicsSaver) {
        mutableStateOf(setOfNotNull(initialTopic))
    }
    var revealTopic by rememberSaveable { mutableStateOf(initialTopic != null) }
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

    LaunchedEffect(revealTopic) {
        if (revealTopic && initialTopic != null) {
            val targetIndex = rows.indexOfFirst { it is GuideRow.Topic && it.entry.topic == initialTopic }
            if (targetIndex >= 0) {
                withFrameNanos { }
                val targetKey = rows[targetIndex].key
                val layoutInfo = listState.layoutInfo
                val visible = layoutInfo.visibleItemsInfo.firstOrNull { it.key == targetKey }
                if (visible == null) {
                    // Account for guide-header (0), sticky guide-filter (1), and show the topic heading above it.
                    listState.animateScrollToItem(targetIndex + 1)
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
            revealTopic = false
        }
    }

    val allExpanded = expandedTopics.size == GuideTopic.entries.size

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
                        onClick = {
                            expandedTopics = if (allExpanded) emptySet() else GuideTopic.entries.toSet()
                        },
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
                                        if (selectedCategory != category) {
                                            revealTopic = false
                                            selectedCategory = category
                                            listState.requestScrollToItem(0)
                                        }
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
                            val topic = row.entry.topic
                            val highlighted = initialTopic == topic
                            val expanded = topic in expandedTopics
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
                                            expanded = expanded,
                                            onToggle = {
                                                expandedTopics = if (topic in expandedTopics) expandedTopics - topic
                                                else expandedTopics + topic
                                            },
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
