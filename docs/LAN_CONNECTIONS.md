# Local-network connections

Already-paired Android and Mac devices can establish an independent encrypted TCP session on the same local network. Android uses Wi-Fi; Mac may use Wi-Fi or Ethernet. Bluetooth is not required for LAN discovery or authentication. BLE and LAN can remain connected to the same peer simultaneously.

## Explicit controls

Open Connection details on both devices. On Mac, select the trusted phone when several exist, then choose Allow local-network connections. The companion's Choose allowed phone action opens the main-window details for target selection. On Android, choose Connect local network for that trusted Mac. Availability expires after 120 seconds unless a candidate is admitted. Connection checks and received counters are separate for Bluetooth and local network inside collapsed Diagnostics.

The device summary reads Connected when either channel has completed encrypted readiness and names only ready transports. Pending/failed secondary-channel feedback remains separate. The primary Connect action starts Bluetooth; it never enables LAN automatically. Mac companion and Android details expand inline; the Mac window uses a native details sheet.

Disconnect Bluetooth and Disconnect local network affect their respective channel. Disconnect all closes both. Manual LAN does not reconnect automatically after network loss or expiry. Android closes LAN when its last presentation stops or the screen locks. Mac retains the channel through its companion until explicit disconnection, sleep or Quit. Trust removal and identity reset retire both channels.

If a different peer already owns either transport, end that relationship before selecting another. An unresolved Mac Any-phone Bluetooth admission must finish or stop before allowing LAN. LAN uses full pinned credentials; cached names and network endpoints do not authorize access.

With several Macs on the network, Android tries anonymous endpoints in discovery order and accepts only the selected trusted Mac's device ID, fingerprint and public key. A wrong trusted Mac is rejected without changing the selected peer. Sharing one router/public IP does not merge local endpoints. Different ports on the same address are distinct locators; duplicate identical address/scope/port locators are deduplicated. Two physical devices claiming the same private IP on one LAN constitute an address conflict; authentication prevents credential substitution but cannot repair routing.

## Platform boundaries

Discovery uses `_anice._tcp` with anonymous random service-instance names and protocol version only. The app does not advertise device identity, exchange LAN endpoints over BLE or provide synchronization features. Network multicast isolation, firewall policy or local-network permission denial can prevent discovery even when both devices use the same router. Connection details expose failure and Retry.

Android legacy resolution is serialized. After a native resolution timeout, another attempt remains blocked until its original callback arrives. API 34+ uses service-update subscriptions with bounded lifetime. TCP sockets bind to the selected Wi-Fi network before connect; IPv6 link-local addresses retain a matching interface scope.

Android targets SDK 36 and does not request ACCESS_LOCAL_NETWORK. The Mac packaged app declares Bonjour access and local-network purpose and includes client/server sandbox entitlements. Development Keychain signing policy remains unchanged.

Wi-Fi changes retire the Android owner, socket, network watcher and peer reservation. Reconnecting requires a new Mac Allow window. If discovery finds no service, confirm that Allow is open and both devices have directly connected routes; changing Wi-Fi does not imply that the new network can reach the old endpoint.

If the Mac still shows Secured after abrupt phone network loss, choose Disconnect local network before reopening Allow. Android reports foreground exit, screen lock and Wi-Fi changes separately from discovery failure.

Mac TCP requests keepalive probes after ten idle seconds, at five-second intervals, with three unanswered probes; retransmission timeout is twenty seconds. These OS probes detect an unreachable socket and do not extend authenticated session activity. Detection still depends on native TCP scheduling; abrupt peer network loss can leave controls visible briefly before failure is reported. [Network.framework options](https://developer.apple.com/documentation/network/nwprotocoltcp/options).

## Lifecycle and transfer feasibility

Returning to aniCe Home, opening automatic connection setup settings or closing connection details keeps a started Activity and LAN owner alive. Home and setup settings register independent presentation tokens; navigation in either direction releases only the activity that stopped. Pressing the Android Home button backgrounds the final Activity and closes manual LAN; screen lock also closes it. Opening Bluetooth discovery preserves both transports; starting Scan suspends/cancels only Bluetooth and leaves LAN active. Device-level Disconnect still closes both channels. Configuration recreation preserves the owner. No background-transfer lease exists in this increment.

A future user-started transfer can acquire a bounded feature lease backed by an appropriate foreground service, with a visible progress/cancel notification, and release it on completion or cancellation. Android's `connectedDevice` service type supports interactions with external devices over a network, subject to manifest/type prerequisites; start restrictions and minimum-OS behavior need native tests. This is feasible platform support, not implemented transfer acceptance. [Foreground service types](https://developer.android.com/develop/background-work/services/fgs/service-types).

Future transfer contracts must cover chunking beyond the 4,000-byte record bound, process death, resumable offsets, integrity, network loss, fresh authentication after reconnect and one-hour/record limits. A retained service cannot preserve an unusable old Wi-Fi socket or bypass same-peer reservations. BLE companion ownership remains independent. Manual IP entry, service leases and file-transfer protocols remain deferred.

## Automated verification

Run `python3 protocol/test-vectors/lan/generate_lan_vectors.py --check`, Android unit tests/lint/builds and Mac hosted tests/universal builds. Fixture inventory includes eight valid/ten invalid frames. Tests cover splits, coalescing, malformed lengths/versions, incomplete EOF, fixed deadlines, stale NSD completion, IPv6 scope and cross-transport peer exclusion.

With test APKs installed on a Wi-Fi-connected phone, run:

```sh
python3 scripts/verify-lan-interchange.py --serial PHONE_SERIAL --family ipv4 --output /tmp/anice-lan-native
python3 scripts/verify-lan-interchange.py --serial PHONE_SERIAL --family link-local --output /tmp/anice-lan-ipv6
```

The verifier compiles the Mac native interchange tool, creates isolated Keystore/Keychain identities, pins their public credentials, resolves its anonymous Bonjour advertisement through Android NSD, exchanges real TCP EDHOC/readiness/controls and 4,000-byte records each way, then checks cleanup. The address-family option requires IPv4 or scoped link-local IPv6 without fallback. Production identity/trust files remain unchanged.

Native Android owner regressions inject Wi-Fi loss and interface change, call Disconnect, and exercise overlapping presentation stops. All four cases verify worker cancellation, network-callback release and peer-reservation release; callbacks from the retired generation cannot close a new attempt. These automated injections do not measure physical Wi-Fi-switch detection latency. Mac hosted tests additionally assert bounded keepalive/retransmission settings; actual black-hole timeout latency remains unverified.

## Acceptance still required

Packaged-app Bonjour discovery and permission denial; simultaneous physical BLE/LAN and independent Disconnect; Bluetooth-disabled operation; locked/background Android retirement; Mac sleep/Quit; network/address changes; accessible native controls; API 29/macOS 14 runtime coverage; signed hardware identity protection; independent security review. Native socket interchange does not close those gates. Existing BLE Release acceptance gaps remain open.

References: [RFC 6763 — DNS-Based Service Discovery](https://www.rfc-editor.org/rfc/rfc6763.html), [Network.framework](https://developer.apple.com/documentation/network), [Android NsdManager](https://developer.android.com/reference/android/net/nsd/NsdManager), [LAN wire contract](../protocol/lan/README.md).

## Idle work

LAN session maintenance waits for the earliest authentication/readiness, compatibility, liveness, idle/lifetime or partial-frame deadline. Transport reads and queue-capacity callbacks reschedule that wait. Android blocks idle TCP reads and applies a read timeout only to an assembling frame. Ten-second write retirement remains independent of the wait. Every authenticated record retains native identity/protection and active trust validation; identity reset and journal revocation retire BLE and LAN through their shared services. LAN presentation, lock, network-loss and manual Retry behavior remain unchanged.
