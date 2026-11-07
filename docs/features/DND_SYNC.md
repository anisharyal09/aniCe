<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Do Not Disturb sync

Settings → Do Not Disturb contains **Sync Do Not Disturb** on each device. It is off by default and controls changes sent **from that device**:

| Mac switch | Android switch | Changes sent |
| --- | --- | --- |
| Off | Off | Neither direction |
| On | Off | Mac → Android |
| Off | On | Android → Mac |
| On | On | Both directions |

Reception requires local setup, independently of the outgoing switch. Only connected, trusted, compatible devices participate. Opening Desk Deck is unnecessary. DND sync adds no feature page, connection lease, continuous Focus polling, or offline replay. Enabling sync or reconnecting does not overwrite either device; only a later native transition is sent. Android can receive in the background only while its existing connection policy keeps the secured channel alive.

## Mac setup

Use a macOS version whose Shortcuts app offers native Do Not Disturb automation triggers. Create these two automations in Shortcuts → Automation; the aniCe setting does not create them:

1. **Do Not Disturb → Turned On**, run immediately. Add **aniCe → Report Mac Do Not Disturb**, with **Do Not Disturb is on** enabled.
2. **Do Not Disturb → Turned Off**, run immediately. Add the same aniCe action with **Do Not Disturb is on** disabled.
3. Enable **Sync Do Not Disturb** in aniCe Settings to send those transitions to connected phones.

The App Intent reports the exact DND transition; it does not infer DND from generic Focus status or inspect private preferences. It waits for channel submission, but that does not confirm Android applied the state. If Mac sync is off, no ready phone is connected, or submission fails, the automation reports an error. Reports without a connected channel are dropped and never replayed later.

Initial setup still requires Shortcuts. Apple's documented URL scheme opens the shortcut editor, and importing a `.shortcut` file is done through Shortcuts, so aniCe cannot silently install these automations. The Mac settings section provides copyable setup steps. See [Apple's URL-scheme guide](https://support.apple.com/guide/shortcuts-mac/apda283236d7/mac) and [shortcut import guide](https://support.apple.com/guide/shortcuts-mac/import-shortcuts-apd02bffbaac/mac).

To receive phone changes, create two dedicated Shortcuts with **Set Focus**: one turns **Do Not Disturb On until turned off**, and one turns **Do Not Disturb Off**. They must be different Shortcuts; the Desk Deck toggle cannot be reused. Select them under aniCe Settings → Do Not Disturb. Both must use explicit On/Off actions and ask for no input. Settings provides separate copyable prompts and manual setup guidance. Test each Shortcut, then select it in the matching row. aniCe reports whether the command finished; it cannot read back Focus state. Selecting both allows phone → Mac changes even when Mac outgoing sync is off. **Remove selections** revokes reception. The Mac runs only locally selected Shortcut identifiers; a phone cannot supply executable content or select another Shortcut.

The optional Desk Deck button is configured separately in the same settings section. It runs the existing Do Not Disturb toggle Shortcut. On Macs where Apple Intelligence shortcut creation is available, use **Copy toggle prompt** and paste it into a new Shortcut description:

> Create a macOS shortcut named “Toggle Do Not Disturb” using built-in Shortcuts actions. Get Current Focus. If the current Focus is Do Not Disturb, use Set Focus to turn Do Not Disturb off. Otherwise, use Set Focus to turn Do Not Disturb on until it is turned off. Run immediately without asking for input, showing menus or notifications, or changing any other Focus. Do not use AppleScript, shell commands, or URLs.

Review the generated actions and run the Shortcut manually to confirm both directions before selecting it. If generation is unavailable, add **Get Current Focus**, **If**, and **Set Focus** manually. An empty Shortcut can finish without changing anything. aniCe reports command completion, not whether Focus changed. Automatic sync uses the native automations above, not this toggle. See [Apple's Mac shortcut creation guide](https://support.apple.com/guide/shortcuts-mac/create-a-custom-shortcut-apd84c576f8c/mac).

## Android setup

Open aniCe Settings → Do Not Disturb → **Allow Do Not Disturb access**, then allow aniCe in Android's system settings. This grants reception without requiring the phone's outgoing sync switch. Enable **Sync Do Not Disturb** to send local phone DND changes to connected Macs. No incoming event opens a permission prompt.

Android reports changes to its notification interruption filter, including Priority, Alarms only and Total silence as DND on. Incoming On uses the existing user policy's Priority interruption filter; incoming Off removes aniCe's contribution. On Android 15 and newer with this app's target SDK, this may be an aniCe-owned automatic DND rule. Another active user or system mode can keep phone DND enabled after aniCe turns its rule off; aniCe does not override other rules or edit their policy. Permission revocation stops native writes and withdraws reception capability.

## Feedback and limits

Settings distinguishes command completion from the resulting Focus state. The native Mac automation reports the actual outgoing transition. Android submission similarly does not prove every active DND rule is off. Different OS policy semantics mean both devices need not end up with identical global notification rules.

Only one latest incoming Mac action waits behind the currently running On/Off Shortcut. Old events, retired channels and duplicate transport delivery cannot replay an action. Matching remote effects are suppressed from outgoing reports; explicit setters and duplicate native-state checks avoid toggle loops. Native callbacks have a fifteen-second echo window: an unusually delayed automation can be interpreted as a new local event. Simultaneous opposing local edits are not a distributed transaction; check either device's native DND controls after an unconfirmed result.

The Mac Shortcuts helper must be available. Create and run each selected Shortcut locally once to resolve native permission prompts. The app limits each command to five seconds and never retries an uncertain action. Timers bound command feedback and process termination; they do not poll DND.

The wire contract is [DND sync v1](../../protocol/dnd-sync/README.md).
