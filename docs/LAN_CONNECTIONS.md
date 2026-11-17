# Local-network connections

Paired Android and Mac devices can establish an independent encrypted TCP session on a shared local network. Android uses Wi-Fi; Mac can use Wi-Fi or Ethernet. Bluetooth is not required for manual LAN connections, and both transports can remain connected to the same trusted peer.

## Manual connection

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
- Eligible BLE feature traffic, file selection and companion-owned playback can request LAN.
- A failed automatic attempt retries twice, after 2 and 5 seconds. Further work waits for a new event, explicit demand or manual connection.
- Duplicate callbacks and an expired Allow window do not restart discovery.

Disconnect pauses local LAN automation for the current app run. Manual Connect/Allow or an explicit preference change resumes it. Turning automation off cancels pending setup but leaves an already-secured channel available manually.

A timed **Pause** closes both transports and gates automatic work until its saved deadline or an early Resume. It does not preserve an active connection.

## Background work and renewal

Android's **background LAN timeout** defaults to **Never**. A saved finite timeout applies after the final activity stops or the screen locks. Never removes the app's idle timer; it does not prevent network loss, OS process retirement or explicit disconnection.

Bounded file pickers, approved transfer-service work and companion-owned playing/paused-grace media demand retain eligible LAN work. An approved paused transfer keeps its service until it resumes, is cancelled or its 15-minute retention expires. Losing the native owner releases that work; a job tag alone grants no background execution.

Opening connection setup or another aniCe activity does not release an activity that is still started. Configuration recreation preserves the owner. Opening Bluetooth discovery leaves LAN unchanged; starting Scan affects only Bluetooth.

Mutually capable LAN peers renew through fresh EDHOC before the session lifetime or record limit. Renewal retains the TCP socket, feature channel, subscriptions and active transfer batch while new DATA briefly waits. Keys, counters and handshake material are replaced, never resumed. Legacy peers retain hard expiry. Manual recovery after network loss or failed renewal requires a new Allow/Connect attempt.

Mac window and menu-bar companion share the LAN owner. Closing the window retains the connection; sleep and Quit retire it. Wake reevaluates enabled automatic choices. Trust removal and identity reset retire both transports.

## Network and security limits

- Both devices need reachable local routes. Router client isolation, firewall rules and denied local-network access can prevent connection.
- DNS-SD advertisements and numeric endpoints are locators, not credentials. Every initial or renewed session authenticates the full pinned identity.
- Android binds TCP to the selected Wi-Fi network. IPv6 discovery retains its interface scope; direct BLE hints use IPv4.
- Wi-Fi/interface loss retires the affected socket. An unchanged address in another family cannot conceal loss of the socket's bound address.
- TCP keepalive detects an unreachable peer according to OS scheduling; Secured may remain visible briefly after abrupt network loss.
- Standard and bulk transfer profiles have separate record limits. Transfer recovery remains feature-owned and does not replay encrypted records.

For setup failures, check the shared network, the Mac's Allow window, permissions and firewall rules before retrying. With several Macs, discovery can encounter another locator first; only the selected full credential is accepted.

## Technical references

- [LAN framing and admission](../protocol/lan/README.md)
- [Automatic rendezvous](../protocol/lan/AUTOMATIC.md)
- [Retained-socket renewal](../protocol/lan/RENEWAL.md)
- [File-transfer behavior](features/FILE_TRANSFER.md)
- [Architecture](../ARCHITECTURE.md) and [performance](PERFORMANCE.md)
