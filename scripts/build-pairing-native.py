#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build pinned shared PAKE bridge. Tool paths can be supplied without changing global config."""
import argparse, os, pathlib, platform, shutil, subprocess
root = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(); p.add_argument('platform', choices=['macos','android']); args=p.parse_args()
env=os.environ.copy()
# Studio does not inherit shell-only tool paths; use its private project configuration as a fallback.
properties = root/'apps/android/local.properties'
local = {}
if properties.exists():
    for line in properties.read_text().splitlines():
        if '=' in line and not line.lstrip().startswith(('#', '!')):
            key, value = line.split('=', 1)
            local[key.strip()] = value.strip().replace('\\', '')
for name, key in [('CARGO_HOME', 'cargo.home'), ('RUSTUP_HOME', 'rustup.home')]:
    if name not in env and local.get(key): env[name] = local[key]
cargo_path = pathlib.Path(env.get('CARGO_HOME', str(pathlib.Path.home()/'.cargo')))/'bin/cargo'
cargo = str(cargo_path) if cargo_path.exists() else shutil.which('cargo')
if not cargo:
    raise SystemExit('Rust toolchain not found. Install the prerequisites in core/rust/pairing/README.md, or set cargo.home/rustup.home in apps/android/local.properties.')
manifest=root/'core/rust/pairing/Cargo.toml'; target=root/'core/rust/pairing/target'
def build(triple): subprocess.run([cargo,'build','--locked','--release','--manifest-path',str(manifest),'--target',triple],env=env,check=True)
if args.platform=='macos':
    # The Mac library contains both CPU architectures so the same build input links on either Mac.
    for t in ['aarch64-apple-darwin','x86_64-apple-darwin']: build(t)
    out=root/'apps/macos/build/native';out.mkdir(parents=True,exist_ok=True)
    subprocess.run(['lipo','-create',*[str(target/t/'release/libanice_pairing.a') for t in ['aarch64-apple-darwin','x86_64-apple-darwin']],'-output',str(out/'libanice_pairing.a')],check=True)
else:
    sdk = env.get('ANDROID_HOME') or env.get('ANDROID_SDK_ROOT')
    sdk = sdk or local.get('sdk.dir')
    sdk = sdk or str(pathlib.Path.home()/'Library/Android/sdk')
    ndk=pathlib.Path(env.get('ANICE_NDK') or env.get('ANDROID_NDK_HOME') or local.get('ndk.dir') or str(pathlib.Path(sdk)/'ndk/27.3.13750724'))
    host = platform.system()
    # This tag selects the compiler's host, independently of the Android CPU targets below.
    # NDK r27d uses darwin-x86_64 for its macOS tool directory on Apple Silicon too.
    host_tag = {'Darwin': 'darwin-x86_64', 'Linux': 'linux-x86_64'}.get(host)
    if host_tag is None or (host == 'Linux' and platform.machine() not in ('x86_64', 'AMD64')):
        raise SystemExit('Unsupported Android NDK host: ' + host + '/' + platform.machine())
    tool=ndk/'toolchains/llvm/prebuilt'/host_tag/'bin'
    if not tool.is_dir(): raise SystemExit('Android NDK tools not found at ' + str(tool) + '; set ANICE_NDK to Android NDK r27d (27.3.13750724).')
    compilers = ['aarch64-linux-android29-clang', 'armv7a-linux-androideabi29-clang', 'x86_64-linux-android29-clang', 'llvm-ar']
    # Validate every ABI's tools before producing any new native outputs.
    for compiler in compilers:
        if not os.access(tool/compiler, os.X_OK):
            raise SystemExit('Android NDK executable missing or not executable: ' + str(tool/compiler))
    # Android devices using 16-KiB pages require compatible ELF load-segment alignment.
    env['RUSTFLAGS']=env.get('RUSTFLAGS','')+' -C link-arg=-Wl,-z,max-page-size=16384'
    for triple,clang,abi in [('aarch64-linux-android','aarch64-linux-android29','arm64-v8a'),('armv7-linux-androideabi','armv7a-linux-androideabi29','armeabi-v7a'),('x86_64-linux-android','x86_64-linux-android29','x86_64')]:
        upper=triple.replace('-','_').upper();env['CARGO_TARGET_'+upper+'_LINKER']=str(tool/(clang+'-clang'));env['CC_'+triple.replace('-','_')]=str(tool/(clang+'-clang'));env['AR_'+triple.replace('-','_')]=str(tool/'llvm-ar')
        build(triple);out=root/'apps/android/app/build/native'/abi;out.mkdir(parents=True,exist_ok=True);shutil.copy2(target/triple/'release/libanice_pairing.so',out)
