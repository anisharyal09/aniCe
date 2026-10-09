#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs protected-key native TCP interchange and checks disposable identity cleanup.
import argparse
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
TEST = 'io.github.anisharyal09.anice.infrastructure.session.LanNativeTest'


def read_event(process, timeout=45):
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        if not selector.select(timeout):
            raise TimeoutError('Mac TCP interchange timed out')
        line = process.stdout.readline()
        if not line:
            raise RuntimeError('Mac TCP interchange exited before its result')
        return json.loads(line)


def require_test(log):
    codes = re.findall(r'^INSTRUMENTATION_STATUS_CODE: (-?\d+)$', log, re.M)
    assert codes == ['1', '0'], 'Instrumentation did not run and pass exactly one test'
    assert re.findall(r'^INSTRUMENTATION_CODE: (-?\d+)$', log, re.M) == ['-1']
    assert re.search(r'^OK \(1 test\)\s*$', log, re.M)
    assert log.count('INSTRUMENTATION_STATUS: test=protectedTcpInterchange') == 2
    assert log.count('INSTRUMENTATION_STATUS: class=' + TEST) == 2
    assert re.findall(r'^INSTRUMENTATION_STATUS: numtests=(\d+)$', log, re.M) == ['1', '1']
    assert re.findall(r'^INSTRUMENTATION_STATUS: current=(\d+)$', log, re.M) == ['1', '1']
    assert not any(token in log for token in ('FAILURES', 'INSTRUMENTATION_FAILED', 'shortMsg='))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--serial', required=True)
    parser.add_argument('--family', choices=('ipv4', 'link-local'), default='ipv4')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    output = args.output or Path(tempfile.mkdtemp(prefix='anice-lan-native-'))
    output.mkdir(parents=True, exist_ok=True)
    adb = ['adb', '-s', args.serial]
    def command(*parts):
        return subprocess.run([*adb, *map(str, parts)], check=True, capture_output=True, text=True, timeout=20).stdout
    sources = [ROOT / 'apps/macos/aniCe/Infrastructure/Identity' / name for name in
               ('DeviceIdentity.swift', 'IdentityService.swift', 'MacIdentityStorage.swift')]
    sources += [ROOT / 'apps/macos/aniCe/Infrastructure/Pairing' / name for name in ('PeerTrustStore.swift', 'PairingCodec.swift')]
    sources += [ROOT / 'apps/macos/aniCe/Infrastructure/Bluetooth/GattFraming.swift']
    sources += sorted((ROOT / 'apps/macos/aniCe/Infrastructure/Session').glob('*.swift'))
    sources += [ROOT / 'apps/macos/aniCe/Infrastructure/LAN/LanFraming.swift',
                ROOT / 'apps/macos/aniCe/Infrastructure/LAN/LanTcpTransport.swift',
                ROOT / 'apps/macos/SessionInterchange/TcpInterchange.swift', ROOT / 'apps/macos/SessionInterchange/main.swift']
    binary = output / 'tcp-interchange'
    environment = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    with (output / 'build.log').open('w') as log:
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-D', 'ANICE_DEVELOPMENT_KEYCHAIN',
                        '-module-cache-path', str(output / 'module-cache'), '-framework', 'Foundation',
                        '-framework', 'CryptoKit', '-framework', 'Security', '-framework', 'Network',
                        *map(str, sources), '-o', str(binary)], env=environment, stdout=log,
                       stderr=subprocess.STDOUT, check=True, timeout=180)
    run = str(uuid.uuid4())
    remote = f'files/lan-interchange-{run}'
    bootstrap = f'/data/local/tmp/anice-lan-{run}.json'
    package = 'io.github.anisharyal09.anice'
    mac = None
    instrumentation = None
    server = None
    cleaned = False
    try:
        with (output / 'mac.log').open('w') as mac_log, (output / 'instrumentation.log').open('w') as instrument_log:
            mac = subprocess.Popen([str(binary), '--tcp'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=mac_log, text=True)
            server = read_event(mac)
            server['family'] = args.family
            (output / 'server.json').write_text(json.dumps(server))
            command('shell', 'run-as', package, 'mkdir', '-p', remote)
            command('push', output / 'server.json', bootstrap)
            command('shell', 'run-as', package, 'cp', bootstrap, remote + '/server.json')
            instrumentation = subprocess.Popen([*adb, 'shell', 'am', 'instrument', '-w', '-r',
                '-e', 'class', TEST, '-e', 'aniceLanRun', run,
                'io.github.anisharyal09.anice.test/androidx.test.runner.AndroidJUnitRunner'],
                stdout=instrument_log, stderr=subprocess.STDOUT)
            def wait_file(name):
                deadline = time.monotonic() + 90
                while time.monotonic() < deadline:
                    result = subprocess.run([*adb, 'shell', 'run-as', package, 'cat', remote + '/' + name], capture_output=True,
                                            text=True, timeout=10)
                    if result.returncode == 0:
                        return json.loads(result.stdout)
                    if instrumentation.poll() is not None:
                        raise RuntimeError('Android TCP instrumentation ended before its result')
                    time.sleep(0.1)
                raise TimeoutError('Android TCP interchange timed out: ' + name)
            client = wait_file('client.json')
            mac.stdin.write(json.dumps(client) + '\n'); mac.stdin.flush()
            command('shell', 'run-as', package, 'touch', remote + '/go')
            result = wait_file('result.json')
            assert result == dict(tcp=True, controls=True, bidirectionalBytes=4000, family=args.family)
            cleanup = read_event(mac)
            assert cleanup == dict(cleanup=True, tcp=True, bidirectionalBytes=4000)
            cleaned = True
            command('shell', 'run-as', package, 'touch', remote + '/ack')
            instrumentation.wait(timeout=40)
            mac.wait(timeout=10)
        require_test((output / 'instrumentation.log').read_text())
        assert instrumentation.returncode == 0 and mac.returncode == 0
        (output / 'result.json').write_text(json.dumps(dict(result, isolatedCleanup=True), indent=2) + '\n')
        print(f'Native LAN ({args.family}): NSD, protected identities, readiness, controls, 4,000 bytes each direction and cleanup passed.')
        print(output)
    finally:
        for process in (instrumentation, mac):
            if process and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        if server and not cleaned:
            subprocess.run([str(binary), '--cleanup', server['cleanupNamespace']], check=True, timeout=20, capture_output=True)
        command('shell', 'rm', '-f', bootstrap)


if __name__ == '__main__':
    main()
