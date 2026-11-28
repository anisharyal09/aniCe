# Local-network connections

Paired Android and Mac devices can establish an independent encrypted TCP session on a shared local network. Android uses Wi-Fi; Mac can use Wi-Fi or Ethernet. Bluetooth is not required for manual LAN connections, and both transports can remain connected to the same trusted peer.

## Manual connection

The device-level **Connect** action starts both BLE and LAN. The individual transport controls below remain independent.

1. Open the trusted device's connection details on both devices.
2. On Mac, select the phone and choose **Allow local-network connections**.
3. On Android, choose **Connect local network** for that Mac.

The Mac's Allow window lasts 120 seconds. A connection becomes ready only after pinned authentication and encrypted readiness complete. A failed secondary transport does not disconnect the other secured channel.

Android first uses a usable endpoint from the selected peer's live authenticated BLE channel. Without that hint—including with Bluetooth disconnected—it uses bounded mDNS discovery. A retired BLE channel's hint cannot be reused. Connection details report connection state, not the discovery source. Manual IP entry is not provided.

**Disconnect Bluetooth** and **Disconnect local network** affect their respective channels; **Disconnect all** closes both. A different peer cannot take either transport while the existing peer owns a connection attempt or session.

## Automatic connection

Enable **Use local network automatically** on both devices and establish secured Bluetooth. The choice defaults on when no preference has been stored; a saved off choice remains off.

The Mac publishes its numeric IPv4 endpoint when its listener is ready, without waiting for Bonjour registration. Android tries that endpoint before starting discovery. Missing endpoints and retryable socket failures use bounded mDNS fallback; an authenticated direct-peer credential failure stops the attempt.

Automatic setup runs on connection events and feature demand:

- A new secured BLE channel, restored eligibility, app return or usable Wi-Fi address restoration can start an attempt.
- Eligible BLE feature traffic, file selection, Audio Sharing views or actions, and companion-owned playback can request LAN.
- A failed automatic attempt retries twice, after 2 and 5 seconds. Further work waits for a new event, explicit demand or manual connection.
- Duplicate callbacks and an expired Allow window do not restart discovery.

Disconnect pauses local LAN automation for the current app run. Manual Connect/Allow, an explicit preference change or a new file-selection/send action from either updated peer with automatic LAN enabled resumes it. Ordinary traffic and recovery of an existing batch do not undo Disconnect. Turning automation off cancels pending setup but leaves an already-secured channel available manually.

On Android, Disconnect retires pending discovery/authentication, its worker and reservation synchronously. Only an already-secured channel receives the bounded best-effort encrypted close before teardown.

All features use these shared owners and eligibility checks. Only a new file action (including **Connect LAN for speed**) has the Disconnect exception; clipboard, messages, playback and other feature traffic cannot override it. No feature demand overrides connection Pause, disabled automation or trust/native ownership restrictions.

**Cancel** stops only the current attempt and its retries, not the automatic preference. Duplicate readiness callbacks cannot restart that cancelled attempt; a new connection/eligibility event or explicit demand can authorize another.

A timed **Pause** closes both transports and gates automatic work until its saved deadline or an early Resume. It does not preserve an active connection.

## Background work and renewal

Android's **background LAN timeout** defaults to **Never**. A saved finite timeout applies after the final activity stops or the screen locks. Never removes the app's idle timer; it does not prevent network loss, OS process retirement or explicit disconnection.

**Idle LAN in background** closes only the idle LAN session, not Bluetooth or the app. Pressing Home, opening another app or locking counts as background; leaving aniCe visible does not. Duplicate callbacks and socket replacement do not restart the idle clock. A setting change uses elapsed idle time, and app return enforces an overdue deadline before resetting it. Deep sleep can defer execution until a lifecycle event or app return; aniCe does not wake the phone with periodic alarms.

Bounded file pickers, approved transfer-service work and companion-owned playing/paused-grace media demand retain eligible LAN work. Up to 128 job-scoped leases can be active; releasing one cannot end a replacement job. An approved paused transfer keeps its service until it resumes, is cancelled or its 15-minute retention expires. Losing the native owner releases that work; a job tag alone grants no background execution.

Settings identifies any transfer, picker, listening or playback work retaining LAN. When that final work ends, one fresh idle interval starts. An approved Bluetooth transfer can also request/retain eligible LAN for an upgrade, without forcing a Bluetooth disconnect.

Opening connection setup or another aniCe activity does not release an activity that is still started. Configuration recreation preserves the owner. Opening Bluetooth discovery leaves LAN unchanged; starting Scan affects only Bluetooth.

Mutually capable LAN peers renew through fresh EDHOC before the session lifetime or record limit. Renewal retains the TCP socket, feature channel, subscriptions and active transfer batch while new DATA briefly waits. Keys, counters and handshake material are replaced, never resumed. Legacy peers retain hard expiry. After network loss or failed renewal, eligible automatic recovery follows the bounded event/demand budget above; manual recovery starts a fresh Allow/Connect attempt.

Mac window and menu-bar companion share the LAN owner. Closing the window retains the connection; sleep and Quit retire it. Wake reevaluates enabled automatic choices. Trust removal and identity reset retire both transports.

## Network and security limits

- Both devices need reachable local routes. Router client isolation, firewall rules and denied local-network access can prevent connection.
- Android targets SDK 36 and does not declare `ACCESS_LOCAL_NETWORK`; the Mac app declares Bonjour access and a local-network purpose. OS network policy still governs reachability.
- DNS-SD advertisements and numeric endpoints are locators, not credentials. Every initial or renewed session authenticates the full pinned identity.
- Android binds TCP to the selected Wi-Fi network. IPv6 discovery retains its interface scope; direct BLE hints use IPv4.
- Wi-Fi/interface loss retires the affected socket. An unchanged address in another family cannot conceal loss of the socket's bound address.
- Mac retains a connection while its path is satisfied, uses a Wi-Fi/Ethernet interface and overlaps an original local interface; unrelated interface changes do not retire it.
- Mac TCP probes an idle peer after five seconds with two-second spacing and three probes, and requests a ten-second connection-drop budget. Android requests a ten-second TCP user timeout when supported. Authenticated LAN PING starts after ten seconds without activity with a ten-second matching-reply budget; BLE retains its separate sixty/twenty-second policy.
- A matching peer's BLE announcement that LAN is no longer secured starts one bounded check of the current LAN socket. Presentation shows **Checking LAN** rather than a confirmed Wi-Fi indicator. A valid LAN response preserves it; failed verification retires it without disconnecting BLE. Silent network loss cannot be detected instantaneously, and OS suspension can delay visible status until execution resumes.
- Standard and bulk transfer profiles have separate record limits. Transfer recovery remains feature-owned and does not replay encrypted records.

For setup failures, check the shared network, the Mac's Allow window, permissions and firewall rules before retrying. With several Macs, discovery can encounter another locator first; only the selected full credential is accepted.

## Technical references

- [LAN framing and admission](../protocol/lan/README.md)
- [Automatic rendezvous](../protocol/lan/AUTOMATIC.md)
- [Retained-socket renewal](../protocol/lan/RENEWAL.md)
- [File-transfer behavior](features/FILE_TRANSFER.md)
- [Architecture](../ARCHITECTURE.md) and [performance](PERFORMANCE.md)
