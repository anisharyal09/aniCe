<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Describes native text clipboard sharing and its platform lifecycle limits. -->
# Clipboard

Clipboard shares one plain-text item or link with a selected trusted device. Open Features → Clipboard → Share and choose Send clipboard. Workspace send actions use compact neutral outlined controls with icons and visible labels; the Mac companion uses quiet send and tray actions for its ready targets. Automatic sharing remains a separate toggle. More options contains inspection, metadata-only preview, explicit Reveal and manual paste. An explicit Paste field provides a native manual route when programmatic clipboard reading is unavailable. Sensitive-marked content requires confirmation of the exact captured item. Receiving writes directly to the system clipboard; use ordinary Paste in another application.

Automatic clipboard sharing defaults off and is stored locally per device ID and fingerprint. The same preference appears in Settings and the feature panel. It controls both outgoing automatic observation and acceptance of automatic input; enable it on both devices for automatic exchange. Manual incoming items are accepted from a trusted compatible peer even with automatic off. Turning automatic sharing off cancels pending automatic preparation immediately. Already captured manual sends continue while a compatible secured channel survives; automatic copy events do not replace them. Incoming content replaces the native clipboard without a separate approval dialog.

Android 10+ reads require actual input focus under Android's [clipboard privacy restrictions](https://developer.android.com/about/versions/10/privacy/changes#clipboard-data). Copy in another app, focus aniCe, then paste on the Mac. Automatic sharing observes only while aniCe has focus and a compatible peer is connected; optional local history can observe while focused without a peer. If capability negotiation or peer receiving consent arrives after focus, the one focus-triggered sharing sample waits for readiness. Losing focus cancels that sample; reconnection after a completed sample does not replay clipboard content. No foreground-service exemption, IME or background clipboard reader is installed. Background incoming items use an existing live connection and write immediately: aniCe cannot detect an intervening local copy while unfocused. Focused Android and Mac preserve newer local copies when they change during incoming assembly.

On Mac, enabled local history or an eligible opted-in connection enables one 500-ms changeCount observer; content is read only after a change. Supported OS versions expose pasteboard access behavior; automatic reading requires Always Allow. Inspect clipboard provides an explicit read/setup action, and the native Paste field remains available without automatic access. Access denial stops automatic reading without repeated prompts. Sleep stops observation; disconnecting or disabling automatic sharing stops it unless local history still needs it. Collection and pause controls remain in Clipboard preferences; the companion provides direct Send clipboard and Open tray actions.

## Delivery

A send requires an already-secured clipboard-capable peer. LAN is preferred; BLE is used immediately when LAN is unavailable. Normal BLE feature activity may request LAN through existing automation without delaying delivery or clearing a manual Disconnect pause. No additional connection retry timer exists.

Items are limited to 65,536 UTF-8 bytes with fragments of at most 3,072 bytes. Oversized items are rejected rather than truncated. An item has a fixed 30-second submission deadline. On channel loss or a missing result two seconds after commit, one retry can use the other already-secured transport. Shared UUID results and sender revisions prevent duplicate application and stale overwrites. Delivery unconfirmed means no conclusive native-write acknowledgement was received; it does not mean the clipboard was unchanged. Cancel cannot undo an already-applied write.

Native writes are acknowledged after the platform reports success; Android success means the call returned without throwing. No acknowledgement proves a later Paste. Deduplication is in memory, with 32 terminal results per peer retained for 60 seconds. Process death provides no durable delivery guarantee. Full session loss abandons outgoing and incomplete work; reconnection does not replay clipboard history.

## Privacy

Only literal text is read: content/file URIs are never resolved. Clipboard delivery never fetches links; Open in Mac passes a URL to the default browser. Automatic observation skips recognized sensitive, transient, generated and remote markers. Received clipboard items carry remote/generated markers to prevent echoes and preserve sensitivity. Unmarked secrets cannot be detected reliably. Content stays out of notifications, logs, saved UI state and ordinary preferences. Optional local history stores eligible text separately.

The [wire contract](../../protocol/clipboard/README.md) defines exact bounds and terminal results. Images, rich text and continuous Android background reading are excluded.

## Send to Mac on Android

In applications that expose Android text-processing actions, select plain text and choose **Send to Mac**. A compact sending panel receives the selection directly without reading or changing the phone clipboard. The single connected Mac must already have a secured channel; capability negotiation may finish within the action's 30-second deadline. The panel closes after the Mac acknowledges applying the item. Failures remain visible; Back or Cancel stops pending submissions without recalling text already applied. The selection and Share-sheet routes do not read the phone clipboard or require a background clipboard permission.

The integration uses Android's official [`ACTION_PROCESS_TEXT`](https://developer.android.com/reference/android/content/Intent#ACTION_PROCESS_TEXT) Activity contract and [`EXTRA_PROCESS_TEXT`](https://developer.android.com/reference/android/content/Intent#EXTRA_PROCESS_TEXT) selection payload. It does not add an action to every text field: availability depends on the originating application's selection menu, and the action may appear under **More** or **⋮**. Custom search fields and selection menus may omit third-party actions.

Android also filters discovery of other applications through [package visibility](https://developer.android.com/training/package-visibility/automatic). Applications querying compatible handlers can [declare visibility by intent signature](https://developer.android.com/training/package-visibility/declaring#intent-filter-signature). Those declarations belong to the application performing the query; adding a query declaration to aniCe cannot force another application's selection menu to discover or display aniCe. Registration alone therefore does not guarantee visibility in a particular menu.

When a single HTTP(S) link is shared or selected through **Send to Mac**, Android offers **Open in Mac** and **Send as clipboard**. Open in Mac reuses the existing secured delivery, acknowledgements and duplicate prevention. The Mac validates the URL and opens it in the default browser without another click, leaving the clipboard and its history/activity unchanged. The option is enabled only when the connected Mac advertises support; older Macs retain the clipboard-send choice. Success means macOS accepted the request, not that the page loaded.

When the selection menu omits the action, use **Share → Send to Mac**. Android's official [receiving shared text](https://developer.android.com/training/sharing/receive) contract supplies literal text or a browser-shared URL through `ACTION_SEND`, `text/plain` and `EXTRA_TEXT`. Both entry points use the same compact sending panel and existing connection, without opening the full workspace or reading the phone clipboard. Image shares, HTML-only payloads, multi-item shares and attachment-only shares are not accepted; attachment URIs are never opened and URLs are never fetched.

## Quick Settings and recent activity

Add **Send to Mac** from Clipboard → Share → More options → **Add Send to Mac tile** on Android 13+, or use the Quick Settings panel's Edit control on older supported versions. Placement uses Android's [native tile setup](https://developer.android.com/develop/ui/views/quicksettings-tiles); aniCe never adds the tile without consent.

Remove or rearrange the tile through Quick Settings → Edit. Tile placement is managed by Android's system panel, separately from automatic clipboard sharing and local history.

Copy text, open Quick Settings and tap the tile. Unlock the phone if requested. The tile opens a small focused panel, reads the clipboard once and shows only byte count and sensitivity. Tap **Send to Mac**; sensitive-marked text requires confirmation of that captured sample. The tile's service never reads the clipboard, starts a connection or runs a foreground service. The panel uses the existing secured sender and does not activate automatic sharing or clipboard-history observation. Share-sheet and selection payloads keep their existing direct-send behavior without a clipboard read. **Open aniCe** provides a connection/setup route when needed; it does not retry a send or carry the captured text into the full workspace.

Android Home and the Mac overview/menu-bar companion show the latest successful clipboard activity for five minutes. The heading opens Clipboard; the activity shows **From Mac** or **From phone**, direction and time, a two-line preview of up to 240 characters for eligible text, a labeled Copy action and Dismiss. Copy uses the full item, independently of preview length. Failed or unconfirmed sends do not create a successful activity, and duplicate incoming delivery does not refresh it.

The recent activity is independent of saved history: one eligible text item can remain in process memory for five minutes even with history off. Sensitive or excluded/generated samples retain metadata only and offer no Copy action. Copy writes locally with own-write suppression and never automatically sends or creates history. Expiry, dismissal, identity reset and trust removal clear the corresponding activity content. Process exit discards it; no activity is restored from disk or saved UI state.

## Local history

**History** is a separate view within Clipboard on both platforms. **Keep clipboard history** defaults off on each device, independently of automatic sharing and peer preferences. Enabling it saves eligible plain-text items across restarts in private local storage. Both platforms offer 20 (default), 50, or 100 recent items. On Mac, this limit applies to unpinned items; pins are retained in addition, with an absolute total of 100. Adding new items or reducing capacity removes the oldest unpinned items when needed. Entries are grouped by local calendar date, newest first. A compact toolbar shows the saved count and Clear options; each row shows a two-line preview, time, a Mac pin indicator where applicable, and **From Mac** or **From phone**, with labeled Copy, Send and Delete actions, plus Pin/Unpin on Mac. Both automatic sharing and local-history consent use the compact native checkbox style from local-network settings. These labels describe the device supplying the item, not the source application. Sending an existing entry preserves its label in the local history; the recipient records the sending device. Mac clearing offers **Clear unpinned** (retaining pinned items) and **Clear all**; Android offers **Clear all**. Turning history off pauses collection and keeps saved items available for browsing, copying, sending, or explicit deletion; storage failures remain visible.

Eligible sources are local native copies, explicit selection/manual-paste input and successfully applied incoming items. Android captures local text on actual focus gain and while focused, including without a connected peer or automatic sharing. Copies made elsewhere can be captured when aniCe regains focus; background incoming items enter history directly after application. Mac reuses its permission-aware change-count observer for history even when sharing is off. No unavailable past clipboard contents are recovered.

Recognized sensitive, confidential, transient and generated clips are excluded. Sensitive manual sends do not enter history. Consecutive identical text from the same device coalesces; duplicate delivery and aniCe's own clipboard writes do not add rows. Copying a history row changes only the local clipboard and does not automatically send it. History databases are never transmitted. Resending a row is an explicit manual send through the existing channel.

History uses a bounded versioned file in Android no-backup storage or a dedicated private Mac application-support directory excluded from backup. History and its collection preference survive app restarts, identity reset, and forgetting devices. Reset and Forget still retire sessions and clear the corresponding sharing consent and transient recent activity. Retention is count-based; entries otherwise remain until explicitly deleted or cleared. The saved envelope records the collection preference separately from its entries, including when collection is paused. Unmarked secrets cannot be detected reliably.

## Quick Paste Tray on macOS

On macOS, aniCe includes a floating **Quick Paste Tray** that can be invoked from anywhere via global hotkey (`⌥⌘V`), the small tray icon beside **Send clipboard** in the menu-bar companion, or the in-app Clipboard panel. The tray icon remains available without a connected phone. Opening the tray closes the companion and starts a fresh search.

- **Floating presentation**: The tray opens as a lightweight, non-activating panel floating above other applications. Clicking outside dismisses it. Escape first exits search or full-text preview, then closes the tray.
- **Instant search & filtering**: Type to filter history in real time. Switch between All, Pinned, Mac, and Phone filters.
- **Smart preview cards**:
  - Hex color values (`#RGB`, `#RRGGBB`, etc.) display live color swatch tiles alongside their hex codes.
  - URLs display link icons and structured URL summaries.
  - Code snippets render with monospace formatting.
  - Phone and Mac origin badges show where text was copied.
- **Keyboard navigation & quick copy**:
  - Opening focuses the selected card immediately. Arrow keys select items; Return copies and closes for ordinary `⌘V` pasting.
  - Space expands full text inside the tray. Space or Escape collapses it. Left/Right switch previewed items; Up/Down scroll the full text.
  - Typing enters search, and Command-F focuses it. Search keeps normal spaces and Left/Right cursor editing. Up/Down return to card selection; Escape exits search before closing the tray.
  - Quick action buttons on each card allow toggling pins or deleting entries.

Search and filters occupy separate rows above fully visible cards. Pin and Delete are always available. Copy closes the tray only after a successful native write; a failed write leaves it open for retry. Enabling local history from the tray requires consent to persistent local text storage. Existing saved items remain available while collection is paused. The full History panel also offers text search and All/Pinned/Mac/Phone filters.
