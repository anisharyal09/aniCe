<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Phone-to-Mac input spike

Phase 0 tools only. They do not implement a product feature.

## Android IME trace

Build and install the Debug app, then launch the probe from a connected phone:

```sh
cd apps/android
./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n io.github.anisharyal09.anice/.spikes.ImeProbeActivity
```

The activity is present only in the Debug manifest and requires Android's `DUMP` permission to launch externally. It records InputConnection operation names, ranges, selection offsets, and text lengths in the screen and Logcat; this includes modern surrounding-text queries and suggested-text replacement callbacks. It never records text contents, sends input over aniCe, or writes the trace to app storage. Use disposable test words. Test once with an empty editor and once after **Seed U+200B marker**. Exercise ordinary composition, suggestion selection, autocorrect on space, selection, one/many Backspaces, and Backspace after the editor is empty. Save the trace before changing IMEs, then repeat with Gboard and Samsung Keyboard.

The marker is only an experiment; this activity does not automatically restore it or recommend shipping it.

### Observed device run

On the Samsung SM-A346E (API 36.1) with Samsung Keyboard selected, ordinary typing called `setComposingText` repeatedly as the composing length grew. Selecting a correction committed the replacement with `commitText`; this run did not call `deleteSurroundingText` or `replaceText`. Backspace arrived as `sendKeyEvent` down/up pairs for `KEYCODE_DEL`, including after the field was empty and after the local U+200B marker was removed. This run therefore did not reproduce an empty-buffer Backspace loss for Samsung Keyboard; it does not establish behavior for other keyboard versions or settings. The tested misspelling committed on space without a correction.

Gboard was enabled on the same device. It opened in its compact toolbar mode; choosing **On-screen keyboard** exposed the keys. Typing `Teh` committed one character at a time. Selecting the visible `The` suggestion called `replaceText(start=1, end=3, length=3)` inside a batch edit and changed the field to `The`. Typing the disposable typo `Helllo` and pressing Space corrected it to `Hello`; Gboard called `setComposingRegion(0, 6)` followed by `commitText(length=6)` in this run. Neither correction path called `deleteSurroundingText`.

Gboard Backspace arrived as `sendKeyEvent` down/up pairs for `KEYCODE_DEL` with text present, after the field was empty, and after deleting the U+200B marker; repeated Backspace on the empty field still delivered key events. Together with the Samsung run above, this A34 session did not reproduce the empty-buffer trap. These observations are specific to the installed keyboard versions and settings. The probe field was cleared, Samsung Keyboard restored, and the phone returned to its launcher.

Phase 0 consequence: the adapter must preserve range replacement and composing-region semantics before emitting a Mac commit; treating every callback as append-only would duplicate corrected text. This device run does not justify a sentinel, while other keyboard and version combinations remain open.

## macOS event construction

Run from the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift -module-cache-path /tmp/aniCe-phase0-swift-module-cache \
  tools/phone-control-spike/macos/main.swift
```

This checks grapheme-boundary chunking, constructs Unicode key-down/up events and a mouse event with negative global coordinates and integer deltas, and reports the current event-posting permission state. It does **not** call `post`, request permission, move the cursor, or type into the active app. Passing proves event construction only; it does not prove that target apps accept the Unicode override.

The real delivery check is opt-in and targets TextEdit only. First create a blank TextEdit document and leave its insertion point in the document. The CLI request mode calls `CGRequestPostEventAccess`; it posts no events:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift -module-cache-path /tmp/aniCe-phase0-swift-module-cache \
  tools/phone-control-spike/macos/main.swift --request-post-access
```

If access is granted, get TextEdit's process ID with `pgrep -x TextEdit`, then pass it to the fixed-sample mode:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift -module-cache-path /tmp/aniCe-phase0-swift-module-cache \
  tools/phone-control-spike/macos/main.swift --post-textedit-sample <pid>
```

The request mode only asks macOS for permission; it posts no events. The sample mode checks that the PID belongs to Apple TextEdit and that posting access is already granted, then sends one fixed multilingual sample directly to that PID. It cannot post arbitrary text or target another app. Apple documents [`CGRequestPostEventAccess`](https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess%28%29) and [`CGEvent.postToPid`](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid%28_%3A%29).

For an app-attributed request, build and open the small GUI wrapper:

```sh
probe=/tmp/aniCe-Phase0EventProbe.app
mkdir -p "$probe/Contents/MacOS"
cp tools/phone-control-spike/macos/Phase0EventProbe-Info.plist "$probe/Contents/Info.plist"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swiftc -parse-as-library \
  -module-cache-path /tmp/aniCe-phase0-swift-module-cache \
  -framework AppKit -framework CoreGraphics -framework SwiftUI \
  -o "$probe/Contents/MacOS/Phase0EventProbe" \
  tools/phone-control-spike/macos/Phase0EventProbe.swift
codesign --force --sign - --identifier io.github.anisharyal09.anice.phase0eventprobe "$probe"
open "$probe"
```

The GUI wrapper has separate **Request event access** and **Send sample to TextEdit** buttons. Sending still requires a blank TextEdit document, a TextEdit PID, and an already-granted event-posting permission. In the Phase 0 run on macOS 27.0.1, the request returned `false` without displaying an approval prompt, so no sample was sent. System Settings labels the broader permission pane **Device Control and Data Access**; do not grant that broader access just to complete this narrow event-posting check without reviewing its scope first.

### Current Mac validation status

Event construction and fixed-sample delivery to TextEdit passed. Outside the restricted tool environment, the construction probe reported `CGPreflightPostEventAccess() == true`. With a new TextEdit test document focused, the approved CLI mode sent its fixed 36-UTF-16-unit sample in three chunks to the verified TextEdit process. The accessibility view then showed the complete sample `aniCe Phase 0: café — नमस्ते 👩🏽‍💻` in the document. An unrelated prefix was also present at verification and was left untouched. This proves delivery through the test host's existing permission; it does not establish permission for a standalone aniCe build or validate every target app, shortcut, drag, or display configuration.

The successful CLI sample used a separate test process with its own existing Event Posting grant. It does not establish permission for the aniCe application. The previous aniCe Xcode target explicitly used ad-hoc signing; `codesign -d -r-` showed a designated requirement pinned to that build's `cdhash`, so rebuilding could leave a visible Settings entry that no longer matched the running app. Apple describes how code-signing requirements identify code in [TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

The shared aniCe app target defaults to ad-hoc signing so contributors can build without an Apple account. For permission-persistence checks, use a stable Apple Development identity locally; signing alone does not grant Event Posting. After switching from an ad-hoc build, remove the old aniCe entry from **Device Control and Data Access** and add the current signed app once. Automated unit tests use ad-hoc signing and do not validate TCC permissions. The Phase 0 CLI result remains limited to the fixed TextEdit sample above.
