<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Install and connect

## Install

Download published builds from [GitHub Releases](https://github.com/anisharyal09/aniCe/releases). Until the first beta is published, use the [development setup](../CONTRIBUTING.md).

- **Mac:** Apple Silicon and macOS 14 or newer. Extract `aniCe-mac.zip`, move `aniCe.app` to Applications and open it. The current release pipeline uses a self-signed certificate, without Apple notarization; macOS may require explicit approval in System Settings → Privacy & Security. Do not disable Gatekeeper globally.
- **Android:** Android 10 or newer. Open `aniCe-android.apk` and approve installation from the app used to download it. Development builds use a different signer; Android cannot update them in place with a production APK. Preserve anything needed before deliberately removing a development installation, since uninstalling removes app data and trust.

## Pair your devices

1. On the Mac, choose **Add device**, then **Show QR code** or **Show six-digit code**.
2. On Android, choose **Add device**, then scan the QR code or enter the six-digit code.
3. Check the device name and approve pairing on both screens.

Keep Bluetooth enabled. If an invitation expires or pairing is declined, start a new invitation from the Mac. Approving pairing saves trust locally on each device. Forgetting a device is also local.

After pairing, Home shows the device and current activity. Devices contains Bluetooth/LAN controls and connection diagnostics. Automatic LAN setup coordinates through authenticated Bluetooth; manual LAN remains independent. See [background Bluetooth](BACKGROUND_CONNECTIONS.md) and [LAN connections](LAN_CONNECTIONS.md) for lifecycle limits.

## Manage connections

**Devices** keeps the trusted-device list, Bluetooth and local-network controls, and collapsed diagnostics for connection checks. A failed secondary transport does not mean the other secured channel has stopped. Manual LAN is independent; automatic LAN setup coordinates through authenticated Bluetooth.

For a manual Bluetooth connection, select the trusted Android on the Mac and choose **Connect**, then choose **Connect** for that Mac on Android. For manual LAN, keep the devices on the same local network, open the Mac's **Allow** window and connect from Android. Connection status becomes ready only after authentication completes.

Use **Pause/Resume** to stop automatic connection work for 1, 3 or 6 hours, a custom interval, or until manually resumed. A timed pause closes current Bluetooth/LAN sessions and saves its resume deadline; it does not keep active work connected. Disconnect local network and Disconnect Bluetooth affect their respective channels. Android's background LAN timeout defaults to Never; this removes the idle timeout, not network loss, process loss or session security limits.

Enable **Connect automatically** on both devices for their supported native background setup. Android first enable or association repair can require the companion association dialog. Closing the Mac window leaves the menu-bar companion running; Command-Q quits. Phone force-stop and reboot have no automatic-recovery promise. See [Bluetooth lifecycle](BACKGROUND_CONNECTIONS.md) and [LAN policy](LAN_CONNECTIONS.md) for the full ownership rules.

In **Settings → This device → Edit name**, save a trimmed name of 1–64 Unicode code points. Renaming keeps the same device ID, key and trust. **Forget device** removes local trust; **Reset identity** replaces the local identity and requires pairing again. Neither action clears optional saved clipboard history; delete or clear that history explicitly in Clipboard.

## Permissions

Grant feature permissions when you use the feature. Notification mirroring needs Android Notification Access; SMS needs the phone's SMS permissions; Mac input needs Event Posting access. DND sync needs configured Mac Shortcuts. Setup and platform limits are described in the [feature guides](../README.md#features).

Automatic receiving is enabled for new pairings. Review each sender's file-transfer preference and save location if you want approval before receiving files.

## Updates

aniCe checks GitHub Releases while open and also offers **Settings → Updates → Check for updates**. Stable releases are selected by default, including on beta installations. Enable **Include beta releases** to receive subsequent betas. Skip version hides that release; Later leaves it available.

Android verifies the downloaded APK's package, version and signing lineage before handing it to the system installer. Installation requires confirmation, and Android may ask you to allow aniCe to install apps. Updates retain app data when Android accepts the signing identity.

Mac verifies the archive and app signature before a detached helper replaces the bundle. The previous bundle is retained until the new build reaches its main window; failed launch triggers a restore attempt. Automatic replacement needs a writable app folder and a volume supporting atomic exchange. Move the app out of its downloaded/translocated location first. If installation is unavailable or fails, open the release on GitHub and install manually.

An update changes the application, not the permissions granted by another computer. Signing changes can require privacy or Keychain approval again. Older experimental universal Mac updaters may require a manual installation of the first arm64-only build.
