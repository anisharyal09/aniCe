#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build pinned shared PAKE bridge. Tool paths can be supplied without changing global config."""
import argparse, os, pathlib, shutil, subprocess
root = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(); p.add_argument('platform', choices=['macos','android']); args=p.parse_args()
env=os.environ.copy()
cargo_path = pathlib.Path(env.get('CARGO_HOME', str(pathlib.Path.home()/'.cargo')))/'bin/cargo'
cargo = str(cargo_path) if cargo_path.exists() else shutil.which('cargo')
if not cargo:
    raise SystemExit('Rust toolchain not found. Install Rust >=1.90 and the targets in core/rust/pairing/README.md, or set CARGO_HOME/RUSTUP_HOME explicitly.')
manifest=root/'core/rust/pairing/Cargo.toml'; target=root/'core/rust/pairing/target'
def build(triple): subprocess.run([cargo,'build','--locked','--release','--manifest-path',str(manifest),'--target',triple],env=env,check=True)
if args.platform=='macos':
    for t in ['aarch64-apple-darwin','x86_64-apple-darwin']: build(t)
    out=root/'apps/macos/build/native';out.mkdir(parents=True,exist_ok=True)
    subprocess.run(['lipo','-create',*[str(target/t/'release/libanice_pairing.a') for t in ['aarch64-apple-darwin','x86_64-apple-darwin']],'-output',str(out/'libanice_pairing.a')],check=True)
else:
    sdk = env.get('ANDROID_HOME') or env.get('ANDROID_SDK_ROOT')
    if not sdk:
        properties = root/'apps/android/local.properties'
        if properties.exists():
            for line in properties.read_text().splitlines():
                if line.startswith('sdk.dir='): sdk = line.split('=', 1)[1].replace('\\', '')
    sdk = sdk or str(pathlib.Path.home()/'Library/Android/sdk')
    ndk=pathlib.Path(env.get('ANICE_NDK') or env.get('ANDROID_NDK_HOME') or str(pathlib.Path(sdk)/'ndk/27.3.13750724'))
    tool=ndk/'toolchains/llvm/prebuilt/darwin-x86_64/bin'
    if not tool.exists(): raise SystemExit('Set ANICE_NDK to an installed Android NDK r27d (27.3.13750724).')
    env['RUSTFLAGS']=env.get('RUSTFLAGS','')+' -C link-arg=-Wl,-z,max-page-size=16384'
    for triple,clang,abi in [('aarch64-linux-android','aarch64-linux-android29','arm64-v8a'),('armv7-linux-androideabi','armv7a-linux-androideabi29','armeabi-v7a'),('x86_64-linux-android','x86_64-linux-android29','x86_64')]:
        upper=triple.replace('-','_').upper();env['CARGO_TARGET_'+upper+'_LINKER']=str(tool/(clang+'-clang'));env['CC_'+triple.replace('-','_')]=str(tool/(clang+'-clang'));env['AR_'+triple.replace('-','_')]=str(tool/'llvm-ar')
        build(triple);out=root/'apps/android/app/build/native'/abi;out.mkdir(parents=True,exist_ok=True);shutil.copy2(target/triple/'release/libanice_pairing.so',out)
