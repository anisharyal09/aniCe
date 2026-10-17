# Verification status

aniCe 0.2.0-dev (build 2) includes Now Playing, Local File Transfer, Find Device and the native UI overhaul following the 0.1.0 milestone. It remains an unreleased development build.

## Manual application testing

Manual testing on the current Android/Mac setup covers the three feature workflows and Home, Devices, Features, Favourites, Settings, About and menu-bar navigation. Playback and Phone→Mac transfer have also run together. These checks establish working application flows on that setup; they are separate from the remaining cross-version, permission, lifecycle and accessibility matrices below.

## Recorded device and native checks

| Area | Completed checks | Remaining scope |
| --- | --- | --- |
| Secure connections | API 36 authenticated BLE and native IPv4/scoped-IPv6 LAN interchange; encrypted directional checks; settings navigation, Pause/Resume, Recents removal with 190 seconds of quiet secured traffic; Mac-close retirement/recovery checks | Minimum-OS coverage, prolonged unplugged/locked operation, range/network-change recovery and the complete Release lifecycle matrix |
| Connected idle | Seventeen-minute physical BLE idle run; median single-core CPU 0.322% Android and 0.030% Mac, with zero storage reads during quiet deadline waits | Long-term battery drain, Release comparisons and active-feature workloads |
| Now Playing | Manual playback/control and player-selection use; packaged WebKit controls, native API checks and Mac output-volume writes | Full player/permission/output-device matrix, phone lock-screen/button lifecycle, sleep/wake and measured concurrent-control latency |
| File transfer | Real app transfers in both directions: 5 GHz external hotspot 7.0–10.5 MB/s Mac→Phone and 3.0–5.2 MB/s Phone→Mac; attenuated 2.4 GHz router approximately 1.0 MB/s each way; progress/rate presentation checked | Controlled 1-GiB runs, all document providers, phone-lock/process-death matrix and phone-hosted hotspot loopback |
| Find Device | Samsung SM-A346E audible native alarm in Vibrate mode; Stop/delete callbacks, unchanged sound mode/volume, startup/admission checks; all three native instrumentation tests, including uninterrupted sixty-second expiry | Complete BLE/LAN/direction/background matrix, repeated Mac requests after the replacement fix, DND/muted alarm and audio-routing combinations |
| Native UI | Iterative manual phone/Mac review; Mac fixture renders across light/dark and narrow/wide layouts; navigation and connection-preservation regressions | Interactive verification of the final phone Home/Devices/About refinement, large text, TalkBack/VoiceOver, keyboard focus and native picker return |

The Find Device timeout ran for 60.314 seconds in isolation and 64.796 seconds for the full three-test suite. These are device instrumentation measurements, not simulated ringing. File-transfer rates above are measured application rates, not codec benchmark results.

## Automated checks

- Android: 219 JVM tests, zero failures/errors/skips; offline lint reports zero errors, 19 warnings and one hint; Debug APK build passes. Instrumentation compilation was verified in an earlier run.
- Mac: 207 hosted tests total, 201 passed, six explicit skips and zero failures; Debug build passes. Permission-presentation policy and peer-layout smoke tests are separate. Earlier native window-fixture renders, universal Debug/Release builds and strict signature checks remain recorded with their respective runs.
- Native rendering covers six window sections and three feature panels at 720/1240-point widths in both themes, plus companion/player fixtures. These are hosted native renders, not live-device screenshots.
- Repository dependency direction, documentation links, Xcode source membership and whitespace checks pass.
- The normal offline Android Debug build includes freshly rebuilt pairing JNI libraries for arm64-v8a, armeabi-v7a and x86_64. Packaged ELF architecture and 16-KiB load-segment alignment checks pass. Persistent Cargo/Rustup and Android NDK r27d installations replace stale temporary paths; native PIN-pairing runtime acceptance remains separate.

Test totals describe the current development work; older counts in historical records describe their respective runs. Automated suites do not replace physical radio or OS-lifecycle checks.

## Platform and security coverage

Current testing includes Android API 36 and Apple Silicon macOS. Android API 29, macOS 14, Intel runtime, certificate-signed protected Mac storage and independent security review remain separate gaps. Existing development Keychain storage and ad-hoc signing are not hardware-isolated distribution acceptance.

Detailed records: [Background BLE](BACKGROUND_CONNECTIONS.md), [LAN](LAN_CONNECTIONS.md), [Now Playing](features/NOW_PLAYING.md), [File Transfer](features/FILE_TRANSFER.md), [Find Device](features/FIND_DEVICE.md) and [Performance](PERFORMANCE.md).
