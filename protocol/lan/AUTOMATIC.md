<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Defines authenticated BLE rendezvous for independent LAN admission on connection events and feature demand. -->
# Automatic LAN rendezvous v2

Automatic LAN uses authenticated BLE DATA to coordinate the existing TCP listener and Android Wi-Fi client. It does not transport LAN keys, resume a session, modify pairing, or accept endpoints as identities. LAN still performs fresh EDHOC against the full trusted peer credential and uses its own keys and counters. Existing LAN framing and record profiles are unchanged.

## Envelope

Deterministic CBOR, at most 64 bytes: `["aniCe LAN", 2, state, fields]`. The unsigned `state` is:

| State | Meaning |
| --- | --- |
| 0 | Automatic LAN disabled, paused, or locally ineligible |
| 1 | Eligible; requesting or preparing LAN |
| 2 | Mac TCP admission ready with a direct endpoint, or Bonjour registered for discovery |
| 3 | LAN secured |
| 4 | Explicit request to initiate one LAN attempt; does not change eligibility |

States 0, 1, 3 and 4 have empty fields `[]`. State 2 carries `[ip, port, profile]`, or `[]` when only Bonjour is ready. `ip` is canonical dotted-decimal IPv4 text, 7–15 ASCII bytes, with four minimal decimal octets in 0–255. Addresses in 0/8, 127/8 or 224/3 are rejected. `port` is 1–65535. `profile` is record profile 1, 3 or 4, not the rendezvous or Bonjour revision. Current Mac listeners use profile 4. Direct IPv6 exchange is excluded; Bonjour retains scoped IPv6 support.

Version 1 remains `["aniCe LAN", 1, state]`. Its canonical state-0 bytes are `83 69 61 6e 69 43 65 20 4c 41 4e 01 00`; states 1–4 replace the final byte. Each new BLE channel publishes one v2 eligibility/readiness probe before its ordinary v1 publication. Receipt of v2 confirms support for that channel; subsequent publications use v2. Without that confirmation, v1 coordination remains active. A delayed v1 state cannot replace v2 eligibility or a direct endpoint; a request already sent as v1 remains valid. Opcode 4 is never published in both versions. Capability confirmation does not create feature demand or replenish attempt budgets.

Unknown tags are unrecognized DATA. Invalid versions, lengths, field types, locators and state values are discarded. Only the live secured BLE channel instance can publish or change rendezvous state. LAN DATA cannot initiate rendezvous. Channel retirement clears remote state, endpoint, version support and pending publication; replacement requires a new advertisement. Receivers do not echo incoming state.

Each owner publishes its initial eligibility and later changes, coalescing unsent logical state and retrying capacity refusal before record sealing. Older peers that do not implement the tag never advertise readiness, so automatic LAN does not start; manual LAN remains available.

## Event-triggered admission

Both local and remote eligibility must permit automatic work. Mac pins each bounded Allow window to the authenticated BLE peer, preserving the one-peer reservation, anonymous Bonjour service, one admitted candidate, 120-second admission deadline and failure bound. A ready TCP listener with a bound port and usable Wi-Fi/Ethernet IPv4 address opens admission independently of Bonjour registration. The first usable admission path starts its original deadline; later registration or address callbacks never extend it. V1 readiness still requires Bonjour registration.

Android advertises eligibility only while a Wi-Fi interface has a usable local unicast address and waits for state 2. A supplied endpoint is checked against the selected Wi-Fi interface's directly connected routes and dialed through the existing network-bound transport. No NSD browse or multicast lock starts before that attempt fails. Absent/unsupported endpoints, v1 readiness and socket failures use the existing bounded Bonjour browse. Authentication or pinned-credential failure on an authenticated direct locator is terminal. Direct and discovered endpoints share the eight-endpoint bound, deduplication and original 90-second attempt deadline. Local identity/storage errors never authorize fallback.

Endpoints are channel-scoped locators, not authorization. Admission withdrawal, BLE retirement and listener/address changes invalidate or replace them. Endpoint updates cannot replace a secured LAN session, extend admission or replenish retries. Either device enabling its preference can trigger coordination. Without authenticated BLE, manual Bonjour discovery remains available; no new background scan policy is introduced.

Each new secured BLE channel, transition into local/remote eligibility, or explicit feature request permits one LAN attempt. Android also consumes a new listener-ready transition. An attempt gate consumes the event before opening admission or connecting, so local state updates, duplicate eligibility messages, admission expiry, socket loss and session expiry cannot restart LAN. A failed automatic attempt may retry twice, two and five seconds later, for at most three attempts per app-open/connection event. The same gate spends that budget, so duplicate callbacks and repeated failures cannot extend it; app activation, wake, timed-pause expiry, a new secured BLE channel, restored local/remote eligibility or restored Wi-Fi addressing rearms it. Retries stop on success, explicit Disconnect, disabled automation, background ineligibility or terminal trust/authentication failure. Explicit feature demand retains one later opportunity after the automatic budget is exhausted. BLE retains its existing separate reconnection ownership and 2/5/15/30/60/90-second retry chain. A fresh request received while LAN remains secured is retained until local channel retirement; it does not replace the healthy channel. An attempt already being established coalesces further requests.

Opcode 4 requests a new attempt over the secured BLE channel while retaining the last advertised eligibility. It never overrides a disabled preference, background eligibility, explicit Disconnect or the pinned peer. Requests coalesce while unsent and use normal transport capacity events before sealing; sealed requests are not replayed. Successful outbound feature DATA and successfully handled inbound feature DATA on the current secured BLE channel signal LAN demand when LAN is absent. LAN rendezvous messages, session keepalives/controls, discarded/unrecognized DATA, stale callbacks and refused sends do not signal demand. The first ordinary activity per secured BLE channel and local/remote eligibility interval signals this demand; subsequent records do not rearm a failed attempt. Explicit feature requests remain independent demand events. Existing Connect/Allow work coalesces further activity. Ordinary activity cannot resume a local Disconnect pause.

File-picker opening on either platform signals explicit demand. Android's existing disconnected-send connection request also signals demand. Mac file sending signals demand before choosing its current secured channel; a capable LAN upgrades a streaming BLE batch through the transfer resume handshake.

Wi-Fi address restoration, foreground eligibility and Mac wake are connection events that restore the bounded recovery budget rather than starting an endless timed loop. Android tracks address sets per Wi-Fi Network; adding an address while eligible requests one attempt through opcode 4, including IPv4 restoration while IPv6 survives. Duplicate link-property callbacks and address removal do not request another attempt. Explicit Disconnect, disabled preferences and unleased background eligibility remain authoritative. Each new attempt uses fresh authentication and native identity/trust validation. After the bounded budget is spent, failure waits for a new event, explicit demand or manual Connect/Allow. Mac sleep retires LAN; Quit never reopens admission.

Android initiates automatic LAN with a started presentation and an interactive screen, an existing bounded picker/approved-transfer lease, or active remote-playback demand under companion ownership. Background/lock withdraws new automatic admission when none of these leases remains; secured sessions retain the configured background timeout and picker/approved-transfer/media leases. Media demand covers playing state and the existing ninety-second paused-presentation grace, and ends when that presentation expires, playback stops/becomes unavailable or its subscription retires; it never overrides manual Disconnect or disabled automation. The Android background timeout defaults to Never (0 minutes); explicitly saved finite choices remain unchanged. Never disables only the app idle timer, not network loss, OS process retirement, session security limits or manual Disconnect. Foreground return reevaluates eligibility. This extension adds no background service or unrestricted locked-screen discovery.

Manual Disconnect/Cancel pauses local automation for the current app run; manual Connect/Allow or an explicit preference change resumes it earlier. Disabling automation cancels pending automatic setup while retaining an already-secured channel as manual work. Preferences are local installation settings and must be enabled on both devices. An absent preference defaults on; an explicitly saved off remains off; pairing presents a checked choice applied only after mutual trust activation.

Transfer routing and recovery remain feature-owned: a capable LAN upgrades a BLE stream, and reconnecting LAN resumes a retained transfer through kinds 10/11. Connection owners never replay commands, sealed records or session keys. [LAN renewal](RENEWAL.md) independently negotiates consecutive fresh sessions over a retained TCP socket.

## Verification

Native suites check the canonical bytes, malformed states, BLE-only dispatch, stale-channel rejection, retirement, no echo, coalesced capacity handling, explicit demand, one attempt per event and the bounded three-attempt recovery budget with its event rearm. Physical same-network discovery, Wi-Fi loss/return, Mac sleep/wake, phone lock/foreground, permissions and simultaneous transfer/media acceptance must be exercised with both packaged apps.
