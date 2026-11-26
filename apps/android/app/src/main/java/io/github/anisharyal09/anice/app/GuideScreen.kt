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
            body = "Pair in Devices. For nearby pairing, compare all six digits on both screens and confirm on both. With Manual pair, scan the Mac’s QR code or enter its PIN on the phone.\n\nIf you’re already paired, check Bluetooth and Local network separately in Devices. Resume if paused, or reconnect without pairing again. Bluetooth reconnect in the background needs Android’s native approval. To set up Wi-Fi automatically, enable Use local network automatically in Settings → Connection on both devices.\n\nEdit This device to share a new name, or set a private nickname for a paired device.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.Permissions,
            title = "Permissions & access",
            summary = "Capabilities stay inactive until their matching phone or Mac permission is granted.",
            iconRes = R.drawable.ic_settings,
            body = "Open Settings → Permissions in aniCe on the device that needs access. On the phone, this covers SMS, SIM selection, Find Phone notifications, Notification Access, SIM-call controls, optional caller ID and Do Not Disturb. Bluetooth and camera access are requested during setup when needed.\n\nOn Mac, Event Posting is used by Control Mac and Lock Mac. Notifications and automatic pasteboard reading are separate. Return to aniCe after changing access so the status can refresh.",
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
            body = "Open Features → Send files to send a batch of 1–128 files. On your phone, you can also use Share → Send to Mac. On Mac, drag local Finder files to the Edge Drop edge chosen in Settings → File transfer. Edge Drop accepts files, not folders.\n\nChoose Automatically receive files per sender and set the save folder in Mac Settings → File transfer or in the phone’s Send files panel. Without auto-receive, the receiver reviews the offer.\n\nLocal network is faster than Bluetooth. Interrupted transfers keep resume checkpoints for up to 15 minutes. Reconnect to the same peer; after local-network loss, continuing over Bluetooth needs your approval.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.ClipboardAndQuickSend,
            title = "Clipboard & Quick Settings tile",
            summary = "Manual or auto text sync, phone selection menu, and Send to Mac Quick Settings tile.",
            iconRes = R.drawable.ic_clipboard,
            body = "Use Clipboard → Send clipboard or paste text manually. For automatic sharing, turn it on for the peer on both devices. Android can read the clipboard only while aniCe has input focus.\n\nAdd the Send to Mac tile from Clipboard → Share → More options (Android 13+) or Quick Settings → Edit. The tile opens a panel showing size and sensitivity, then waits for Send to Mac. Sensitive items marked by the phone ask for confirmation. To open a link in the Mac browser, use the phone’s text selection or Share menu instead.",
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
            body = "Connect over Bluetooth, open phone Features → Control Mac and tap Start control. If access is blocked, open Settings → Permissions → Event Posting in aniCe on Mac.\n\nMove with one finger, tap to click, long-press and move to drag, or scroll with two fingers. Type with the phone keyboard; Live typing also sends text as you compose it. Clear only resets the phone editor. If you move the text cursor on Mac or change documents, stop and start control before typing again.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.ControlAndroidAndFloatingKey,
            title = "Control Android & Floating Key",
            summary = "Use your Mac keyboard and trackpad on the phone, with a floating shortcut.",
            iconRes = R.drawable.ic_keyboard,
            body = "Pair in aniCe and in system Bluetooth Settings, then choose Link device in Mac Features → Control Android. Click the trackpad to start pointer and keyboard control. Turn off Use keyboard and trackpad together for separate input areas.\n\nOn Mac, ⌥⌘K shows or hides Floating Key; ⌃⌘K starts or stops typing through it. Those are defaults; see Mac Settings → Shortcuts for current bindings. When the controls have focus, ⌘⇧Esc stops input.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.MacDeskDeck,
            title = "Mac Desk Deck (from phone)",
            summary = "Live Mac CPU/memory/thermal meters, quick actions, audio output, and approved apps.",
            iconRes = R.drawable.ic_features,
            body = "Open phone Features → Mac Desk Deck for CPU, memory, thermal pressure and battery. If readings are stale, open Details and tap Refresh readings. Ping Mac can work independently of the readings.\n\nInput mute, Lock Mac and audio controls depend on hardware and permissions. Screenshot opens capture controls on Mac; the image stays there. Allow app shortcuts in Mac Settings → Desk Deck. Choose the DND mode Shortcut in Mac Settings → Do Not Disturb.\n\nDetails → Keep awake while charging applies only while Desk Deck is visible and the phone has external power.",
        ),
        GuideTopicEntry(
            topic = GuideTopic.NowPlayingAndAudio,
            title = "Now Playing & audio output",
            summary = "Track details, artwork, player selection and supported playback and volume controls.",
            iconRes = R.drawable.ic_media_note,
            body = "Open Features → Now Playing to control Mac playback. Home and the Mac menu bar also offer playback controls when available. Check Mac Playback setup if your player needs access. Artwork needs a local-network connection; audio stays on the Mac.\n\nOutput volume changes the Mac’s audio output; player volume changes only the selected player. Phone volume buttons can adjust supported Mac output while the playback panel is active. Phone notification and lock-screen controls need Android background connection setup.",
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
            summary = "Choose which alerts appear on Mac and what to do when a call action fails.",
            iconRes = R.drawable.ic_phone,
            body = "On your phone, open Settings → Notification sync. Allow Notification Access and use Select apps for regular alerts. Mirror incoming calls adds supported call alerts from apps outside that list. Turning it off still allows alerts from selected apps.\n\nPhone state and Answer phone calls are for SIM-call controls. Call log and Contacts add optional SIM caller ID. With apps like WhatsApp, Android and the source app decide whether Answer or Decline works.\n\nRequest sent to phone confirms dispatch only. If the call is still ringing or aniCe can’t confirm the action, use the phone. Call audio stays on the phone. If no alerts arrive, check the connection in Devices, Notification sync on the phone, and notification and Focus settings on Mac.",
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
            body = "Star tools to add them to Favourites. To reorder, right-click on Mac or long-press on the phone. Mac feature menus also pin tools separately to the sidebar or menu bar. Closing the Mac window leaves its menu-bar companion running.\n\nMac Settings → Shortcuts shows the current bindings for Paste tray, Floating Key and Floating Key typing. Use Settings → Appearance for theme and text size. In Settings → Updates, you can check manually, choose automatic checks or opt into betas. Review release notes before installing.",
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
