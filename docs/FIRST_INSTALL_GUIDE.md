<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Installation and permissions

Install aniCe on an Android 10+ phone and an Apple Silicon Mac running macOS 14+. Download `aniCe-android.apk` and `aniCe-mac.zip` from the [official releases](https://github.com/anisharyal09/aniCe/releases).

BLE/LAN feature data stays on the local peer connection and uses authenticated encrypted sessions. Mac-to-Android HID uses system Bluetooth instead. Update checks and downloads contact GitHub; aniCe has no account, relay or telemetry service.

## Android installation

1. Open the APK in your browser or file manager.
2. If Android blocks that source, open its **Settings** link and enable **Allow from this source**.
3. Return to the installer and choose **Install**.

For in-app updates, Android may separately request permission for aniCe to install packages. Enable **Allow from this source** for aniCe only if you want that update flow. Android still presents the installation confirmation.

### Google Play Protect warning

Play Protect may show **Blocked by Play Protect** or **Unrecognized app** for an independently distributed APK. Confirm that you downloaded aniCe from the official release before proceeding.

**Method A — Install anyway**

1. On the Play Protect dialog, tap **More details** or the downward arrow.
2. Tap **Install anyway**.

**Method B — If no Install anyway button is offered**

1. Open the **Google Play Store**.
2. Tap your **profile avatar → Play Protect**.
3. Tap the **Settings gear**.
4. Temporarily turn off **Scan apps with Play Protect**.
5. Return to the downloaded `aniCe-android.apk` and choose **Install**.
6. Return to Play Protect and turn scanning back on after installation.

Turning scanning off reduces protection device-wide while it is disabled. Manufacturer or managed-device policy may still block installation; these steps do not override an administrator's restrictions.

### Restricted settings

Some Android 13+ installers restrict sensitive access for sideloaded apps. If Notification Access or another permission is blocked:

1. Open **Settings → Apps → aniCe**.
2. Open the **⋮** menu and choose **Allow restricted settings**, if available.
3. Authenticate and return to the permission action in aniCe.

Installer policy can also restrict SMS and call-log permissions. Grant only the access needed for features you use. A restricted-settings prompt is not an assessment of the APK's safety.

### Background operation

Enable **Connect automatically** and complete companion setup on API 31+ devices. If the OS limits background operation, review **App info → Battery** and the manufacturer's battery policy. **Unrestricted** can reduce those limits but does not prevent process termination, force-stop, network loss or expired sessions.

Approved transfers use their own connected-device foreground service. See [Bluetooth background connections](BACKGROUND_CONNECTIONS.md) and [LAN connections](LAN_CONNECTIONS.md).

### Permissions

| Access | Purpose |
| --- | --- |
| `INTERNET` | Local TCP connections and GitHub update checks/downloads. Feature traffic stays peer-to-peer. |
| Nearby devices | BLE discovery and connection. API 29–30 uses fine-location permission for scanning, not location tracking. |
| Camera | QR pairing; optional when using the six-digit code. |
| Notifications | Transfer progress, Find Device alerts and update notices. Companion BLE ownership does not require a persistent status notification. |
| Notification Access | Relays selected active phone notifications to the paired Mac. |
| SMS | Reads/receives messages and sends replies for Messages. |
| Phone state / answer calls | Detects live SIM calls and permits Answer/Decline; audio stays on the phone. |
| Call log / contacts | Optional incoming-number and contact-name lookup. The displayed number/name can be shared with the paired Mac; aniCe keeps no call history. |
| Do Not Disturb access | Observes phone DND for the selected Mac Shortcuts. |
| Install packages | Hands verified in-app update downloads to Android's installer. |

Permissions are requested through the relevant feature. Denying an optional permission leaves unrelated features available.

## macOS installation

Install with Homebrew:

```sh
brew install anisharyal09/tap/anice
```

Or extract `aniCe-mac.zip` and move `aniCe.app` to `/Applications`.

### First open

Public releases use self-signed certificates without Apple notarization. If macOS blocks launch:

1. Try opening the app once.
2. Open **System Settings → Privacy & Security** and choose **Open Anyway** for that app.
3. Authenticate and confirm the launch.

On macOS 14, Control-click → **Open** is another first-launch path. Do not disable Gatekeeper globally. The Homebrew cask removes quarantine for its installed copy.

### Keychain access

Current Mac builds store identity signing keys in the login Keychain. If aniCe requests access, confirm the exact app copy and download source before approving. **Always Allow** remembers access for that code identity; a changed signature can prompt again. Denial leaves the committed identity intact.

### Input and system controls

Configure **Settings → Permissions** in aniCe for phone-to-Mac input and supported Mac lock controls. Enable the exact app copy in macOS **Accessibility**; newer systems may label the pane **Device Control and Data Access**. aniCe does not require Input Monitoring.

Playback scripting controls can require separate Automation permission from an explicit Mac action. Mac notification visibility follows notification and Focus settings.

## Pair the devices

1. Enable Bluetooth on both devices. Use a shared local network for LAN.
2. On Mac, choose **Add device** and show a QR invitation or six-digit code.
3. On Android, choose **Add device** and scan or enter that invitation.
4. Review the peer details and approve on both devices.

Pairing establishes trust. Automatic connection depends on the saved choices and Android companion setup; manual connection remains available. See [Getting started](GETTING_STARTED.md).
