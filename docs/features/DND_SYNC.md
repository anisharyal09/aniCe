<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Do Not Disturb sync

DND sync sends explicit phone changes to the Mac over an existing trusted connection. It does not poll, queue changes offline or replay them after reconnecting. Mac-to-phone sync is not supported.

## Set up once on the Mac

In aniCe → Settings → Do Not Disturb, choose separate Shortcuts for **When phone DND turns on** and **When phone DND turns off**. Expand **Set up once** for the prompts and steps. Create each Shortcut with Set Focus: the On Shortcut turns Do Not Disturb on until turned off; the Off Shortcut turns it off. Test both before selecting them. aniCe can report that a Shortcut ran, but cannot read back the resulting Focus state.

## Turn on phone sync

On Android, open aniCe → Settings → Do Not Disturb, enable **Sync phone DND to Mac**, and allow aniCe DND access. Keep both apps connected when changing DND. Android requires Notification Policy access to observe phone-side DND changes.

The Desk Deck **DND mode** button runs a separate Mac-local toggle Shortcut. It does not sync to the phone.

See the [DND sync v1 contract](../../protocol/dnd-sync/README.md).
