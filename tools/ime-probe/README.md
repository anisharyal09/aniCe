<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Android IME diagnostic

Use the Debug-only `ImeProbeActivity` when investigating keyboard-specific composition, autocorrect, selection replacement or Backspace behavior. It reports callback names, ranges and text lengths, never text contents. It sends no aniCe input and saves no trace to app storage.

Build an isolated emulator preview from the repository root:

```sh
./scripts/dev.sh android --preview --serial emulator-5554
adb -s emulator-5554 shell am start \
  -n io.github.anisharyal09.anice.preview/io.github.anisharyal09.anice.spikes.ImeProbeActivity
```

External launch requires Android's system `DUMP` permission, available to the ADB shell. The activity is absent from Release builds. For a deliberately selected physical test phone, use the [transfer preview](../../apps/android/README.md#run-and-check) and its `.preview.transfer` package rather than replacing the normal installation.

Use disposable words. Exercise composing text, selecting suggestions, autocorrect on Space, selection/range replacement, one/many Backspaces and Backspace with an empty editor. Repeat with the affected keyboard and record its version/settings. **Seed U+200B marker** is an experiment, not a recommended product behavior.

The Mac event adapter's grapheme, pointer and ownership regressions live in the hosted suite; run `python3 scripts/verify-suite.py --only macos`. Those tests do not establish TCC permission or actual input delivery. Validate those explicitly in the signed app using [Control Mac](../../docs/features/PHONE_TO_MAC.md), not a separate feasibility implementation.
