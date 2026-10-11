# Now Playing

## Usage and supported behavior

Home displays genuine playback and all advertised controls, including the Auto/player picker on Android. The phone controls playback on the originating Mac. Mac Features → Phone controls describes this capability, shows its active subscription and exposes explicit Automation permission. Android Features → Mac controls → Now Playing retains the full artwork/detail workspace. Mac Settings → Show Now Playing on this Mac enables compact local playback on Home and the companion, off by default; companion detail opens Phone controls. The saved display preference does not disable phone subscriptions or controls. Android subscribes automatically while foregrounded and connected; no sharing toggle or extra connection owner exists.

Auto ranks playing above paused, retains the current source among equals, then prefers system current, then stable PID order. Manual selection overrides Auto, survives temporary metadata gaps with controls unavailable and resets on player exit or observation stop. A track replacement cancels a scrub; one seek is sent when dragging finishes. Android retains the requested position locally after release until a matching source/revision sample agrees with its position within one second, preventing a jump back to the previous sample. The preview advances locally while playing and clears on failure, source/revision replacement, subscription retirement or a six-second deadline; an applied command result alone does not confirm position. Unknown duration/live streams omit seeking. Progress advances locally from monotonic position/rate samples; there is no per-second network progress timer. Mac progress uses a four-Hz periodic timeline rather than an animation/display-link schedule; hidden, paused or missing-position playback schedules only its initial presentation.

Missing title/artist remain absent; a native recording identifier can establish a genuine session without a title. Player support depends on registered MediaRemote metadata and reliable directed controls. Native controls use the selected player path/recording. Players with an installed playback scripting dictionary may use PID-addressed Apple Events after an explicit Mac **Allow playback control…** action. Remote actions cannot trigger permission prompts. Unsupported controls stay disabled; metadata can remain available. The implementation does not establish universal browser/player support.

Home keeps trusted-device summaries above playback on both platforms; the companion uses the same order. Playback controls use accessible icons whose action labels convey Playing/Paused without repeating it in metadata. Compact Android Home relies on the device summary above for origin; the full workspace names the Mac.

## Architecture and transport

One application-scoped `MacPlayback` owns a packaged event-driven adapter and all local/remote consumers. The adapter observes only while an enabled Mac Home/companion media card, Phone controls feature information or an Android subscription needs it. Hiding local playback releases those local display leases; remote subscriptions remain active. Window hide/minimize/close and companion dismissal release presentation leases. Android final background stop clears its subscribed state while preserving existing background BLE ownership and foreground-only LAN policy.

Reference: Vorssaint revision `b0599423cbf38dd0e28415ccd3f9874a2548668f`. Reviewed reused files and preserved notices are listed in [attribution](../../apps/macos/NowPlayingAdapter/THIRD_PARTY_NOTICES.md). No notch, radial menu, queue, shuffle or lyrics code is incorporated.

The fixed `/usr/bin/perl` loader loads a signed universal `libaniCeNowPlaying.dylib`. Packaging replaces the signed dylib by rename rather than overwriting a potentially loaded image. Bounded JSON lines carry native metadata and recording-targeted requests between app and helper. Native requests identify PID/recording revision and request UUID; the helper checks recording/process identity before directed execution. Recording-targeted validation/delivery uses a serial command queue independent of full player scans; source selection stays serialized with scans. Notifications coalesce into one pending scan after 30 ms and at most one follow-up scan; new notifications do not postpone the current scan. Oversized input lines discard through newline. A successful playback command triggers one recording-bound position/state sample on the command queue, avoiding the full source scan; stale samples are ignored and never change another recording. EOF ends the watcher. Observation failure clears playback and uses at most three bounded startup retries. No global playback-command fallback exists.

Debug/Release disable App Sandbox; hardened-runtime target settings and existing signing defaults remain. Xcode disables effective runtime for its ad-hoc Debug app; Release and helper signatures carry runtime flags. Certificate-signed Debug/runtime acceptance remains pending. Journals retain their original container paths, identity backend/tags/ACLs and trust credentials. [Process boundary decision](../decisions/0007-macos-unsandboxed-playback-prototype.md) records the access change and pending signing/platform acceptance.

The authoritative [media contract](../../protocol/media/README.md) and [CDDL](../../protocol/media/media.cddl) define deterministic CBOR within existing authenticated DATA. One compatible secured LAN subscription is preferred; BLE otherwise carries metadata and controls, including supported seek. Media never activates LAN. A channel change requires a fresh subscription/snapshot; pending commands are not replayed. Legacy peers remain connected without media.

Artwork is LAN-only, in-memory, ≤256 pixels, ≤64 KiB, sequential binary chunks ≤2 KiB, with one ten-second fixed-deadline assembly and SHA-256/dimension validation. The Mac coalesces unsent snapshots; existing liveness has priority over commands/results/snapshots, then artwork. No disk cache or URL fetching exists.

## Verification matrix

Packaged read-only target validation completed five consecutive requests in 7–24 ms on Apple Silicon/current macOS. After signed-image replacement by rename, three consecutive helper startups and nine recording-bound state/position samples passed; sample round trips measured 1 ms. These measurements exclude radio transfer and player command execution. Dispatch checks hold a player scan open, verify validation still executes and verify source selection waits for the scan. Playback response and phone round-trip latency remain physical acceptance checks.

CPU investigation on the Debug app under Xcode captured predominantly waiting threads in ten- and fifteen-second process samples; the sampled helper was idle. A separate fifteen-second observation of the restarted app showed mostly 0–3% CPU with brief 11–12% readings. Its process sample included connection setup and authenticated media sends through existing native identity checks. Sustained 19% usage and 55% peaks were not reproduced. These observations precede the periodic-progress change and do not establish a measured improvement or playback/endurance acceptance.


| Acceptance area | Evidence |
| --- | --- |
| Packaged helper, Apple Silicon/macOS 27.0.1, ad-hoc Debug | Hosted startup, initial metadata, invalid/stale input, bounds, EOF cleanup and packaged license checks |
| YT Audio Air / `anish.creations.yt-audio-air`, WebKit helper | Native metadata and directed pause/resume observed; Firefox stayed paused |
| Non-current Firefox | Metadata/manual selection observed; unavailable native targeting rejected, controls disabled |
| Apple Music / Spotify | Native or installed scripting-dictionary support implemented; full packaged playback/Automation denial matrix pending |
| Safari / Chrome | Registered native metadata/control path implemented; physical playback/targeting matrix pending |
| Source ties/manual gaps/PID/pipe input | Pure adversarial adapter checks |
| Wire malformed/oversized/version/inventory/revisions | Independent positive/negative fixtures tested in both native codecs |
| Android foreground overlap, legacy capability absence, channel replacement, fresh subscriptions/no replay, stale scrub, seek preview confirmation/failure/timeout, saturation | JVM behavioral tests |
| Artwork offsets, lengths, hash mismatch, supersession and fixed timeout | JVM assembly tests; physical decoding/rendering and transfer latency pending |
| Mac subscription retirement/dedup/stale commands and local progress | Hosted tests |
| Keychain/identity/trust/session regression | Isolated hosted regressions; production journal paths preserved |
| macOS 14 / Intel runtime | Pending; universal arm64/x86_64 compilation is separate evidence |
| Certificate-signed hardened runtime | Pending; local builds use existing ad-hoc signing defaults |
| Physical phone/Mac UI, foreground/background, sleep/wake, denial, CPU/endurance | Pending on integrated build; automated suites do not establish these results |

Automated checks: the latest Mac suite executes 109 tests with zero failures and one manually started-player test skipped; isolated Keychain and inactive/cadence progress checks pass. The preceding 108-test run also verified the packaged playback owner reading a manually playing source. 122 Android JVM tests pass; lint reports zero errors/twelve warnings; Debug/test/Release APK builds pass. Both data-preserving APK replacements retain identical identity/trust journal hashes. Universal Debug/Release compilation, strict resource/signature checks and unchanged Mac production journal hashes are verified; effective Debug/runtime limitations remain as recorded above. Physical radio/UI acceptance, minimum OS and player-specific support remain distinct release gates.

## Feature log and exclusions

The current increment adds shared local/remote playback, source selection, bounded thumbnails, revision-bound controls and Home/Features/companion presentation. UI appearance reuses existing semantic palettes and native accessible controls; slider activities have no swipe gesture. Compact activities have no history or placeholder track.

Audio streaming, Android media notifications/lock-screen controls/background media service, automatic LAN activation, volume, shuffle, lyrics, queues, ADB/scrcpy and clipboard work are deferred. Discovery-disconnect recovery remains separate.
