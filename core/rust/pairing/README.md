# aniCe Ephemeral PAKE Bridge

This crate provides a narrow C/JNI bridge around the pinned [`opaque-ke 4.0.1`](https://github.com/facebook/opaque-ke/tree/v4.0.1) Rust library. It enables cross-platform Password-Authenticated Key Exchange (PAKE) for 6-digit PIN pairing between Android and macOS.

## Security & Architecture

- **Scope:** Ephemeral in-memory manual invitation setup and OPAQUE login only.
- **Isolation:** Has zero access to disk, persistent identity keys, Bluetooth radios, or network sockets.
- **Memory Hygiene:** PIN buffers and temporary exported secrets are wiped via the `zeroize` crate upon completion.
- **Resource Bounds:** Process-local handles are capped at 64 concurrent sessions and expire after 300 seconds of inactivity.
- **Error Handling:** All C ABI and JNI calls catch Rust panics (`std::panic::catch_unwind`) and fail closed (returning `-1` or throwing an exception).

## C ABI Reference (`anice_pake`)

```c
intptr_t anice_pake(uint32_t op, const uint8_t *input, size_t len, uint8_t *out, size_t capacity);
```

Every `input` payload consists of `uint32` big-endian length-prefixed fields: `fields(x1, x2, ...)`.

| Op | Name | Inputs | Outputs | Description |
| :---: | :--- | :--- | :--- | :--- |
| `1` | `ServerRegister` | `PIN` (6B), `rendezvous` (16B) | `serverHandle` (8B) | Registers local in-memory OPAQUE record on macOS |
| `2` | `ClientLoginStart` | `PIN` (6B) | `clientHandle` (8B), `request` | Initiates OPAQUE client login on Android |
| `3` | `ServerLoginStart` | `serverHandle` (8B), `request`, `context` | `response` | Evaluates login request; bounded to 5 attempts |
| `4` | `ClientLoginFinish`| `clientHandle` (8B), `PIN` (6B), `response`, `context` | `finalization`, `sessionKey` (32B) | Completes client login; consumes client handle |
| `5` | `ServerLoginFinish`| `serverHandle` (8B), `finalization` | `sessionKey` (32B) | Verifies client finalization; outputs session key |
| `6` | `ReleaseHandle` | `handle` (8B) | `[1]` | Explicitly drops session state from memory |

## Prerequisites & Building

- **Rust:** `>= 1.85`
- **macOS Target:** `aarch64-apple-darwin` / `x86_64-apple-darwin`
- **Android NDK:** `r27d` (`27.3.13750724`)
- **Android Targets:** `aarch64-linux-android`, `armv7-linux-androideabi`, `x86_64-linux-android`

The native builder resolves Cargo from `CARGO_HOME/bin/cargo`, then `PATH`; the default Cargo home is `~/.cargo`. Android NDK lookup uses `ANICE_NDK`, `ANDROID_NDK_HOME`, private `ndk.dir`, then the SDK's `ndk/27.3.13750724`. The SDK comes from `ANDROID_HOME`, `ANDROID_SDK_ROOT` or private `sdk.dir`.

For IDE builds with tools installed outside those defaults, configure `apps/android/local.properties` with `cargo.home`, `rustup.home` and `ndk.dir`. Environment variables take precedence; this file is ignored and contains only machine-local paths. `rustup.home` must point to the installed toolchain/targets, not the Cargo executable directory. Keep these installations in persistent directories: `~/.cargo`, `~/.rustup` and the Android SDK’s `ndk/27.3.13750724`. Do not point IDE builds at temporary tool installations; cached native outputs may hide missing tools until the next rebuild.

### Build Commands

```bash
# Build native static library for macOS (links into Xcode)
python3 scripts/build-pairing-native.py macos

# Build JNI shared libraries for Android (bundled into APK)
python3 scripts/build-pairing-native.py android

# Run unit tests
cargo test --locked --manifest-path core/rust/pairing/Cargo.toml
```
