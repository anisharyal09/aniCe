<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# First Installation & Permissions Guide

Feature data moves strictly peer-to-peer over local Bluetooth and your local network (Wi-Fi or Ethernet).
- **No accounts, relay servers, telemetry or analytics.**
- **No cloud storage**: your clipboard, notifications, media controls, and files never leave your local physical devices.
- **End-to-end encrypted**: all feature transport is secured locally using P-256 ECDSA authentication, an EDHOC handshake with ChaCha20-Poly1305, and AES-256-GCM record framing.

Update checks and downloads contact GitHub; no feature data is sent there.

Because aniCe is distributed directly via open-source GitHub Releases (independent of Google Play and the Mac App Store), modern operating systems (Android 13+ and macOS 14 Sonoma or newer) enforce several security verification gates.

This guide explains how to navigate each prompt and explains exactly why each permission is required.

---

## Table of Contents

- [📱 Android Installation & Setup](#-android-installation--setup)
  - [1. Allowing "Unknown Apps" (First Install)](#1-allowing-unknown-apps-first-install)
  - [2. Google Play Protect Warning ("Blocked by Play Protect")](#2-google-play-protect-warning-blocked-by-play-protect)
  - [3. Unlocking Android 13+ "Restricted Settings" (Crucial) ⚠️](#3-unlocking-android-13-restricted-settings-crucial-️)
  - [4. Background Battery Optimization (Keeping Connections Alive)](#4-background-battery-optimization-keeping-connections-alive)
  - [5. In-App Updates ("Allow aniCe to install apps")](#5-in-app-updates-allow-anice-to-install-apps)
  - [6. Android Permission Transparency: Why Each is Needed](#6-android-permission-transparency-why-each-is-needed)
- [💻 macOS Installation & Setup](#-macos-installation--setup)
  - [System Requirements](#system-requirements)
  - [1. Gatekeeper Approval (First Open)](#1-gatekeeper-approval-first-open)
  - [2. Login Keychain Prompt ("Always Allow")](#2-login-keychain-prompt-always-allow)
  - [3. Accessibility (Events) Access](#3-accessibility-events-access)
- [🔗 First Pairing Walkthrough](#-first-pairing-walkthrough)

---

## 📱 Android Installation & Setup

### 1. Allowing "Unknown Apps" (First Install)
When opening `aniCe-android.apk` from Chrome or your file manager, Android displays:
> *"For your security, your phone is not allowed to install unknown apps from this source."*

* **How to proceed**:
  1. Tap **Settings** on the prompt.
  2. Turn on the toggle for **Allow from this source**.
  3. Tap the back button and tap **Install**.

---

### 2. Google Play Protect Warning ("Blocked by Play Protect")
Google Play Protect may ask to scan a sideloaded APK, show an unfamiliar-app warning, or block installation. Read the exact warning; an independent release is not evidence that every warning is harmless.
> *"Blocked by Play Protect"* or *"Unrecognized app"*.

1. Download `aniCe-android.apk` only from the [official GitHub Releases](https://github.com/anisharyal09/aniCe/releases) page and confirm the selected version.
2. Keep Play Protect scanning enabled. If Android offers a scan, let it finish and review the result.
3. For an unfamiliar-app warning with **More details → Install anyway**, proceeding is an explicit decision to trust that release, not a guarantee of safety.
4. If the warning identifies harmful behavior, or no **Install anyway** option is offered, stop. Report the exact warning and release version through [GitHub Issues](https://github.com/anisharyal09/aniCe/issues); on a managed device, ask its administrator.

Do not disable Play Protect or bypass an organization’s installation policy. See [Google’s Play Protect guidance](https://support.google.com/googleplay/answer/2812853).

---

### 3. Unlocking Android 13+ "Restricted Settings" (Crucial) ⚠️
On modern Android versions (**Android 13 or newer**), Google automatically disables advanced permissions for sideloaded apps. If you try to enable **Notification Access**, **SMS or call permissions**, or another advanced access, Android shows:
> *"Restricted setting: For your security, this setting is currently unavailable."*

**This does NOT mean the app is blocked or unsafe.** It is a generic Android OS security barrier applied to every APK installed from outside the Play Store.

* **How to unlock it in 10 seconds**:
  1. Open Android **Settings → Apps → aniCe** (or long-press the `aniCe` app icon on your home screen and tap the **ℹ️ App info** icon).
  2. Tap the **three vertical dots (⋮)** in the top-right corner of the App Info screen.
  3. Tap **"Allow restricted settings"**.
  4. Authenticate using your fingerprint, face unlock, or device PIN.
  5. Return to aniCe and tap **Enable**—the permission screen will now let you toggle it ON without any block!

---

### 4. Background Battery Optimization (Keeping Connections Alive)
Modern Android aggressive battery savers (Samsung One UI, Google Pixel Adaptive Battery, Xiaomi MIUI) will aggressively kill background Bluetooth listeners if left on "Optimized":
1. Open **App Info → Battery** (or *Battery usage*).
2. Set it to **Unrestricted**.
3. This ensures aniCe stays armed in the background and automatically reconnects to your Mac when you sit down at your desk.

---

### 5. In-App Updates ("Allow aniCe to install apps")
When updating aniCe through its built-in update sheet:
1. When the download finishes, Android may ask once: *"Allow aniCe to install apps"*.
2. Tap **Settings** → toggle **Allow from this source** ON → return to aniCe.
3. aniCe will immediately hand off the verified APK to Android's system package installer.

---

### 6. Android Permission Transparency: Why Each is Needed

| Permission | Technical Name | Why aniCe Asks For It | Does it send data to the internet? |
| :--- | :--- | :--- | :--- |
| **Internet** | `INTERNET` | Checks GitHub Releases for updates and downloads release APKs. | **Only update traffic** to GitHub; feature data stays peer-to-peer. |
| **Nearby Devices** | `BLUETOOTH_CONNECT`, `BLUETOOTH_SCAN` | Discovers and connects to your Mac over Bluetooth LE. Android 10–11 also uses `ACCESS_FINE_LOCATION` for BLE scanning; aniCe does not use it for location. | **No.** Local radio only. |
| **Camera** | `CAMERA` | Scans the Mac's pairing QR code. Optional; the six-digit code works without it. | **No.** Local camera only. |
| **Notifications** | `POST_NOTIFICATIONS` | Displays the persistent foreground-service connection status and update notices. | **No.** Local device only. |
| **Notification Listener** | `BIND_NOTIFICATION_LISTENER_SERVICE` | Reads selected phone notifications so they can appear on your Mac. | **No.** Local encrypted peer stream only. |
| **SMS** | `READ_SMS`, `SEND_SMS`, `RECEIVE_SMS` | Mirrors SMS threads to your Mac and sends replies typed on your Mac. | **No.** Peer-to-peer over the local link only. |
| **Phone Calls** | `READ_PHONE_STATE`, `ANSWER_PHONE_CALLS` | Shows incoming SIM call alerts and lets you answer or decline from your Mac; call audio stays on the phone. | **No.** Peer-to-peer over the local link only. |
| **Caller ID** | `READ_CALL_LOG`, `READ_CONTACTS` | Matches incoming numbers against your contacts so your Mac can show a caller name. Optional. | **No.** Read locally; only the resulting name goes to your paired Mac. |
| **Do Not Disturb** | `ACCESS_NOTIFICATION_POLICY` | Observes phone DND changes so aniCe can run the Mac Shortcuts you chose. Optional. | **No.** Peer-to-peer over the local link only. |
| **Install Packages** | `REQUEST_INSTALL_PACKAGES` | Installs verified GitHub release APKs from the in-app update sheet. | **No.** The APK download comes from GitHub. |

---

## 💻 macOS Installation & Setup

### System Requirements
* **Architecture:** Apple Silicon (M1 or newer).
* **Operating System:** macOS 14 Sonoma or newer.

---

### 1. Gatekeeper Approval (First Open)
Because public GitHub release builds use a self-signed certificate rather than Apple notarization, macOS may block the first launch:
* **Option A (Homebrew - Recommended)**:
  ```bash
  brew install anisharyal09/tap/anice
  ```
  The Homebrew Cask removes the quarantine attribute after installation.
* **Option B (Manual ZIP download)**:
  1. Extract `aniCe-mac.zip` and drag `aniCe.app` into `/Applications`.
  2. Try to open `aniCe.app` once. If macOS says it cannot verify the app, click **Done**.
  3. Open **System Settings → Privacy & Security**, scroll to **Security**, and click **Open Anyway**. Authenticate, then confirm **Open Anyway** in the final dialog.
  4. On macOS 14 and earlier, you can instead Control-click `aniCe.app`, choose **Open**, then click **Open** in the confirmation dialog.

Do not disable Gatekeeper globally.

---

### 2. Login Keychain Prompt ("Always Allow")
On first launch, macOS may prompt:
> *"aniCe wants to access key '...' in your keychain. Enter your password."*

* **Why this happens**: aniCe creates a P-256 ECDSA key pair unique to your Mac so your paired phone can securely authenticate it without passwords. Current builds select the development Keychain backend with the `ANICE_DEVELOPMENT_KEYCHAIN` compile flag and store the key in your login Keychain under `io.github.anisharyal09.anice.identity.development`.
* **Important**: Enter your Mac user password and click **"Always Allow"** (do not click only "Allow").
  - "Always Allow" adds the app's code identity to the key's Keychain access control list. macOS remembers that choice for the same signed identity across launches and reboots.
  - A new build with a different signature can prompt once more. Confirm "Always Allow" again for that build.

---

### 3. Accessibility (Events) Access
Required only if you use the phone-to-Mac trackpad/keyboard or the Mac Desk Deck lock control:
* Open **System Settings → Privacy & Security → Accessibility** and toggle `aniCe` ON.
* On macOS 27 or newer, this pane is named **Device Control and Data Access**.
* aniCe does not request Input Monitoring access.

The app can request this access from its phone-input screen. If the prompt does not appear, open the pane manually.

---

## 🔗 First Pairing Walkthrough

Once installed on both devices:
1. Ensure **Bluetooth** is enabled on both devices and both are on the same local network if you use LAN features.
2. On your Mac, click **Add device** → select **Show QR code** (or **Show six-digit code**).
3. On your Android phone, tap **Add device** → scan the QR code with your camera (or enter the code).
4. Verify the device names on both screens and tap **Approve**.

Both devices now share cryptographic trust and will automatically discover and reconnect whenever they are nearby!
