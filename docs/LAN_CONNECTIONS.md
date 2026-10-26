# Local-network connections

Already-paired Android and Mac devices can establish an independent encrypted TCP session on the same local network. Android uses Wi-Fi; Mac may use Wi-Fi or Ethernet. Bluetooth is not required for LAN discovery or authentication. BLE and LAN can remain connected to the same peer simultaneously.

## Explicit controls

Open Connection details on both devices. On Mac, select the trusted phone when several exist, then choose Allow local-network connections. The companion's Choose allowed phone action opens the main-window details for target selection. On Android, choose Connect local network for that trusted Mac. Availability expires after 120 seconds unless a candidate is admitted. Connection checks and received counters are separate for Bluetooth and local network inside collapsed Diagnostics.

The device summary reads Connected when either channel has completed encrypted readiness and names only ready transports. Pending/failed secondary-channel feedback remains separate. The primary Connect action starts Bluetooth; when automatic LAN is enabled on both devices, secured Bluetooth coordinates LAN separately. Mac companion and Android details expand inline; the Mac window uses a native details sheet.

Disconnect Bluetooth and Disconnect local network affect their respective channel. Disconnect all closes both. Manual LAN does not reconnect automatically after network loss or expiry. Android idle LAN follows its configured background timeout after its last presentation stops or the screen locks; bounded picker and approved transfer-service ownership preserve the channel. Mac retains the channel through its companion until explicit disconnection, sleep or Quit. Trust removal and identity reset retire both channels.

If a different peer already owns either transport, end that relationship before selecting another. An unresolved Mac Any-phone Bluetooth admission must finish or stop before allowing LAN. LAN uses full pinned credentials; cached names and network endpoints do not authorize access.

With several Macs on the network, Android tries anonymous endpoints in discovery order and accepts only the selected trusted Mac's device ID, fingerprint and public key. A wrong trusted Mac is rejected without changing the selected peer. Sharing one router/public IP does not merge local endpoints. Different ports on the same address are distinct locators; duplicate identical address/scope/port locators are deduplicated. Two physical devices claiming the same private IP on one LAN constitute an address conflict; authentication prevents credential substitution but cannot repair routing.

## Platform boundaries

Discovery uses `_anice._tcp` with anonymous random service-instance names and protocol version only. The app does not advertise device identity, exchange LAN endpoints over BLE or provide synchronization features. Network multicast isolation, firewall policy or local-network permission denial can prevent discovery even when both devices use the same router. Connection details expose failure and Retry.

Android legacy resolution is serialized. After a native resolution timeout, another attempt remains blocked until its original callback arrives. API 34+ uses service-update subscriptions with bounded lifetime. TCP sockets bind to the selected Wi-Fi network before connect; IPv6 link-local addresses retain a matching interface scope.

Android targets SDK 36 and does not request ACCESS_LOCAL_NETWORK. The Mac packaged app declares Bonjour access and local-network purpose and includes client/server sandbox entitlements. Development Keychain signing policy remains unchanged.

Wi-Fi changes retire the Android owner, socket, network watcher and peer reservation. Reconnecting requires a new Mac Allow window. If discovery finds no service, confirm that Allow is open and both devices have directly connected routes; changing Wi-Fi does not imply that the new network can reach the old endpoint.

If the Mac still shows Secured after abrupt phone network loss, choose Disconnect local network before reopening Allow. Android reports foreground exit, screen lock and Wi-Fi changes separately from discovery failure.

Mac TCP requests keepalive probes after ten idle seconds, at five-second intervals, with three unanswered probes; retransmission timeout is twenty seconds. These OS probes detect an unreachable socket and do not extend authenticated session activity. Detection still depends on native TCP scheduling; abrupt peer network loss can leave controls visible briefly before failure is reported. [Network.framework options](https://developer.apple.com/documentation/network/nwprotocoltcp/options).

The Mac transport logs Network.framework `waiting` and `failed` transitions separately with their native error before retiring the channel. Both remain terminal in the current owner; no waiting-state recovery window extends the connection or its write deadlines.

## Lifecycle and transfer feasibility

Both TCP readers stop at the remaining frame header or body boundary before handing complete frames to the bounded ingress queue. Queue backpressure therefore waits between frames rather than consuming a later frame's assembly budget. Before secured readiness, partial frames expire after ten seconds absolute. Established encrypted-record frames may continue while bytes arrive within ten seconds of each other, bounded to sixty seconds total; partial headers and handshake envelopes retain ten seconds absolute. Byte progress does not count as authenticated activity. LAN rendezvous also retains capacity notifications received during a pending submission, so a pre-seal refusal cannot lose that wakeup.

Returning to aniCe Home, opening automatic connection setup settings or closing connection details keeps a started Activity and LAN owner alive. Home and setup settings register independent presentation tokens; navigation in either direction releases only the activity that stopped. Pressing the Android Home button backgrounds the final Activity; idle LAN follows the timeout saved in Settings. Screen lock applies the same policy. A bounded picker lease and an approved connected-device transfer service preserve the channel through connection establishment, source hashing, destination preflight and streaming. A paused batch keeps the approved transfer service and its LAN eligibility until it resumes, is cancelled or the 15-minute pause expires. Service loss releases approved ownership; expiry, trust invalidation, network loss and explicit Disconnect still retire the transport. Foreground-service ownership does not require notification-drawer permission. [File-transfer ownership](features/FILE_TRANSFER.md) records lifecycle and recovery limits.

Opening Bluetooth discovery preserves both transports; starting Scan suspends/cancels only Bluetooth and leaves LAN active. Configuration recreation preserves the owner. A retained service cannot preserve an unusable Wi-Fi socket or bypass same-peer reservations. BLE companion ownership remains independent of the user-approved transfer lease.

Transfer profiles negotiate larger LAN records independently of BLE. Feature-owned checkpoints retain prepared jobs across process death for 15 minutes; resumed connections authenticate afresh and verify retained prefixes. A retained service cannot preserve an unusable old Wi-Fi socket or bypass same-peer reservations. BLE companion ownership remains independent. Manual IP entry and coordinated renewal remain deferred.

Mac path updates retain a connection while the path is satisfied, uses Wi-Fi/Ethernet and retains an original local interface; unrelated interface inventory changes do not retire TCP. Write deadlines and cancellation callbacks retire only their outstanding submission, never a completed one. Native socket failures and actual local path loss still retire the channel.

## Automated verification

Run `python3 protocol/test-vectors/lan/generate_lan_vectors.py --check`, Android unit tests/lint/builds and Mac hosted tests/universal builds. Fixture inventory includes eight valid/ten invalid frames. Tests cover splits, coalescing, malformed lengths/versions, incomplete EOF, fixed deadlines, stale NSD completion, IPv6 scope and cross-transport peer exclusion.

With test APKs installed on a Wi-Fi-connected phone, run:

```sh
python3 scripts/verify-lan-interchange.py --serial PHONE_SERIAL --family ipv4 --output /tmp/anice-lan-native
python3 scripts/verify-lan-interchange.py --serial PHONE_SERIAL --family link-local --output /tmp/anice-lan-ipv6
```

The verifier compiles the Mac native interchange tool, creates isolated Keystore/Keychain identities, pins their public credentials, resolves its anonymous Bonjour advertisement through Android NSD, exchanges real TCP EDHOC/readiness/controls and 4,000-byte records each way, then checks cleanup. The address-family option requires IPv4 or scoped link-local IPv6 without fallback. Production identity/trust files remain unchanged.

Native Android owner regressions inject Wi-Fi loss and interface change, call Disconnect, and exercise overlapping presentation stops. All four cases verify worker cancellation, network-callback release and peer-reservation release; callbacks from the retired generation cannot close a new attempt. These automated injections do not measure physical Wi-Fi-switch detection latency. Mac hosted tests additionally assert bounded keepalive/retransmission settings; actual black-hole timeout latency remains unverified.

## Recorded application checks and remaining matrix

Real packaged-app transfers over an external 5 GHz hotspot and a 2.4 GHz router verify authenticated application traffic in both directions. Native IPv4/scoped-IPv6 interchange and owner cleanup regressions provide additional coverage.

The remaining matrix includes permission denial; simultaneous physical BLE/LAN and independent Disconnect; Bluetooth-disabled operation; locked/background Android retirement; Mac sleep/Quit; network/address changes; accessible native controls; API 29/macOS 14 runtime coverage; signed hardware identity protection; independent security review. These combinations are distinct from the completed app transfers and isolated native interchange checks. Existing BLE Release coverage gaps remain open.

References: [RFC 6763 — DNS-Based Service Discovery](https://www.rfc-editor.org/rfc/rfc6763.html), [Network.framework](https://developer.apple.com/documentation/network), [Android NsdManager](https://developer.android.com/reference/android/net/nsd/NsdManager), [LAN wire contract](../protocol/lan/README.md).

## Idle work

LAN session maintenance waits for the earliest authentication/readiness, compatibility, liveness, idle/lifetime or partial-frame deadline. Transport reads and queue-capacity callbacks reschedule that wait. Android blocks idle TCP reads and applies a read timeout only to an assembling frame. Ten-second write retirement remains independent of the wait. Every authenticated record retains native identity/protection and active trust validation; identity reset and journal revocation retire BLE and LAN through their shared services. LAN presentation and lock obey picker/approved-work leases and the configured idle timeout; network-loss and manual Retry behavior retain independent teardown.

## Automatic connection on events and demand

The Mac may retain its listening socket after a session retires while automatic ownership permits it. Retention does not reopen admission: Bonjour readiness is withdrawn, new sockets are rejected and the original window/failure budget is not extended. A newly authorized attempt revalidates the pinned peer and reservation and publishes a fresh anonymous service. Native local-path unavailable-to-available transitions rearm automation; duplicate path and listener-registration callbacks do not. Confirmed socket/network failure and fatal authenticated submissions retire the owning channel before feature fallback. TCP keepalive supplements detection; local write completion does not confirm remote receipt.

Settings and pairing on both platforms expose **Use local network automatically**. The preference is on when no choice has been stored; an explicitly stored off still wins, and the single pairing toggle sets both the Bluetooth and LAN choices. Enable it on both devices and establish secured Bluetooth. The Mac automatically opens bounded Bonjour admission for that BLE peer; Android discovers and freshly authenticates the LAN session. Either preference change can initiate coordination. See the [rendezvous contract](../protocol/lan/AUTOMATIC.md).

A new secured BLE channel, transition into eligibility, or explicit feature demand permits one bounded LAN attempt. Successful feature DATA sent or handled over secured BLE signals demand while LAN is missing; connection-control traffic is excluded. File selection on either device also signals demand through secured BLE. Android also holds a bounded media lease while companion-owned playback is playing or inside its paused grace, so background Now Playing can request and keep LAN (and therefore receive artwork); the lease ends when playback stops, the paused grace expires, or companion ownership is lost. Admission expiry, LAN failure and duplicate state messages do not initiate another attempt; BLE owns reconnection and LAN has no independent retry timer. Disconnect pauses local automation for the current app run; feature traffic, file selection and playback demand do not clear that pause. Manual Connect/Allow or a preference change resumes it earlier. Turning the preference off stops pending setup; an already-secured session remains available manually. Mac sleep retires LAN and wake reevaluates it. Android starts automatic LAN while the app is visible and the screen interactive, or while an existing bounded picker/approved-transfer/media lease owns work; returning to the app reevaluates it. The Android background timeout defaults to Never; saved finite choices remain in force. This removes the app idle timer while preserving network/process loss, session security limits, explicit Disconnect and approved transfer/picker/media ownership. A channel loss mid-stream pauses the batch and retains its partial with a private checkpoint for 15 minutes; a reconnected LAN to the same peer resumes automatically, while Bluetooth continuation after a LAN pause requires an explicit action on either device (the receiving device then sends the resume request). Transfer recovery owns its journal and expiry; event-triggered LAN initiation adds no discovery retry loop.

Selecting files or starting a send never retires the secured BLE channel: the picker lease follows the transports that are actually secured, not the transfer's transiently selected channel, and an active or paused batch keeps a bounded BLE work lease as its continuation fallback. A LAN attempt preserves existing transfer leases. A send with an already-secured compatible channel proceeds on it without waiting for LAN; when no secured channel can accept it, a failed LAN demand fails the pending send immediately instead of waiting for the connect timeout. The active batch stays on its original channel unless that channel is lost, or unless a capable LAN becomes available while Bluetooth is streaming: the sender then upgrades in place through the resume handshake.

Automated rendezvous checks cover canonical bytes, malformed input, channel retirement, stale traffic, no echo and capacity coalescing.
