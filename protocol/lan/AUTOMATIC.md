<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Defines authenticated BLE rendezvous for independent LAN admission on connection events and feature demand. -->
# Automatic LAN rendezvous v1

Automatic LAN uses authenticated BLE DATA to coordinate the existing Bonjour listener and Android Wi-Fi client. It does not transport LAN keys, resume a session, modify pairing, or accept unauthenticated endpoints as identities. LAN still performs fresh EDHOC against the full trusted peer credential and uses its own keys and counters. Existing LAN framing and record profiles are unchanged.

## Envelope

Deterministic CBOR, at most 64 bytes: `["aniCe LAN", 1, state]`. The unsigned `state` is:

| State | Meaning |
| --- | --- |
| 0 | Automatic LAN disabled, paused, or locally ineligible |
| 1 | Eligible; requesting or preparing LAN |
| 2 | Mac Bonjour listener registered and ready for discovery |
| 3 | LAN secured |
| 4 | Explicit request to initiate one LAN attempt; does not change eligibility |

The canonical state-0 bytes are `83 69 61 6e 69 43 65 20 4c 41 4e 01 00`; states 1–4 replace the final byte. Unknown tags are unrecognized DATA. Invalid versions, lengths, field types and state values are discarded. Only the live secured BLE channel instance can publish or change rendezvous state. LAN DATA cannot initiate rendezvous. Channel retirement clears the remote state and pending publication; replacement requires a new advertisement. Receivers do not echo incoming state.

Each owner publishes its initial eligibility and later changes, coalescing unsent logical state and retrying capacity refusal before record sealing. Older peers that do not implement the tag never advertise readiness, so automatic LAN does not start; manual LAN remains available.

## Event-triggered admission

Both local and remote eligibility must permit automatic work. Mac pins each bounded Allow window to the authenticated BLE peer, preserving the one-peer reservation, anonymous Bonjour service, one admitted candidate, 120-second admission deadline and failure bound. Android advertises eligibility only while a Wi-Fi network is available, waits for state 2, then invokes the existing bounded Wi-Fi discovery/connect path for that exact peer. Either device enabling its preference can trigger this exchange. No IP address or port is trusted or exchanged over BLE.

Each new secured BLE channel, transition into local/remote eligibility, or explicit feature request permits one LAN attempt. Android also consumes a new listener-ready transition. An attempt gate consumes the event before opening admission or connecting, so local state updates, duplicate eligibility messages, admission expiry, socket loss and session expiry cannot restart LAN. LAN has no retry timer, backoff or independent recovery loop. BLE retains its existing reconnection ownership.

Opcode 4 requests a new attempt over the secured BLE channel while retaining the last advertised eligibility. It never overrides a disabled preference, background eligibility, explicit Disconnect or the pinned peer. Requests coalesce while unsent and use normal transport capacity events before sealing; sealed requests are not replayed. Successful outbound feature DATA and successfully handled inbound feature DATA on the current secured BLE channel signal LAN demand when LAN is absent. LAN rendezvous messages, session keepalives/controls, discarded/unrecognized DATA, stale callbacks and refused sends do not signal demand. The first ordinary activity per secured BLE channel and local/remote eligibility interval signals this demand; subsequent records do not rearm a failed attempt. Explicit feature requests remain independent demand events. Existing Connect/Allow work coalesces further activity. Ordinary activity cannot resume a local Disconnect pause.

File-picker opening on either platform signals explicit demand. Android's existing disconnected-send connection request also signals demand. Mac file sending signals demand before choosing its current secured channel; an active batch never moves to a later LAN channel.

Wi-Fi availability, foreground eligibility and Mac wake are connection events rather than timed retries. Each new attempt uses fresh authentication and native identity/trust validation. Failure waits for a new event, explicit demand or manual Connect/Allow. Mac sleep retires LAN; Quit never reopens admission.

Android initiates automatic LAN with a started presentation and an interactive screen, or an existing bounded picker/approved-transfer lease. Background/lock withdraws new automatic admission; secured sessions retain the configured background timeout and picker/approved-transfer leases. The Android background timeout defaults to Never (0 minutes); explicitly saved finite choices remain unchanged. Never disables only the app idle timer, not network loss, OS process retirement, session security limits or manual Disconnect. Foreground return reevaluates eligibility. This extension adds no background service or unrestricted locked-screen discovery.

Manual Disconnect/Cancel pauses local automation for the current app run; manual Connect/Allow or an explicit preference change resumes it earlier. Disabling automation cancels pending automatic setup while retaining an already-secured channel as manual work. Preferences are local installation settings and must be enabled on both devices. Existing installations default off; pairing presents a checked choice applied only after mutual trust activation.

Active file transfers remain bound to their current channel. A new connection does not resume interrupted transfers or replay commands. Durable transfer resume and coordinated renewal during active batches remain separate work.

## Verification

Native suites check the canonical bytes, malformed states, BLE-only dispatch, stale-channel rejection, retirement, no echo, coalesced capacity handling, explicit demand and one attempt per event. Physical same-network discovery, Wi-Fi loss/return, Mac sleep/wake, phone lock/foreground, permissions and simultaneous transfer/media acceptance must be exercised with both packaged apps.
