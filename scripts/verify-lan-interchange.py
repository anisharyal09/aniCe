#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs protected-key native TCP interchange and checks disposable identity cleanup.
import argparse
import json
import math
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


def require_deadline_failure(log):
    assert re.findall(r'^INSTRUMENTATION_STATUS_CODE: (-?\d+)$', log, re.M) == ['1', '-2']
    expected = 'java.lang.AssertionError: Production DATA benchmark exceeded its completion budget'
    assert re.findall(r'^INSTRUMENTATION_STATUS: stack=(.*)$', log, re.M) == [expected]
    assert 'Caused by: kotlinx.coroutines.TimeoutCancellationException:' in log
    normalized = log.replace('INSTRUMENTATION_STATUS_CODE: -2', 'INSTRUMENTATION_STATUS_CODE: 0')
    normalized = normalized.replace('FAILURES!!!', '').replace('Tests run: 1,  Failures: 1', 'OK (1 test)')
    require_test(normalized)


def benchmark_result(android, mac, total, window):
    assert total in (4 * 1048576, 16 * 1048576, 100 * 1048576, 1024 * 1048576) and window in (4, 8, 32, 64)
    for metrics in (android, mac):
        assert isinstance(metrics, dict)
        assert metrics['bytes'] == total and metrics['window'] == window
    names = ('androidSendMiBs', 'androidReceiveMiBs', 'macSendMiBs', 'macReceiveMiBs')
    measurements = {key: value for metrics in (android, mac)
                    for key, value in metrics.items() if key not in ('bytes', 'window')}
    rates = [measurements[name] for name in names]
    assert all(isinstance(value, (int, float)) and not isinstance(value, bool)
               and math.isfinite(value) and value > 0 for value in rates)
    return dict(bytes=total, window=window, **measurements,
                throughputPassed=all(value >= 8 for value in rates),
                responsiveness='pending', macAllocation='pending')


def benchmark_deadline_result(progress, total, window):
    assert isinstance(progress, dict)
    assert progress['completed'] is False and progress['throughputPassed'] is False
    assert progress['bytes'] == total and progress['window'] == window
    assert progress['reason'] == 'completion-deadline'
    elapsed = progress['elapsedSeconds']
    assert isinstance(elapsed, (int, float)) and math.isfinite(elapsed)
    assert elapsed >= max(60, total / 1048576 * 0.5) - 1
    for name in ('androidReceivedBytes', 'androidAcknowledgedBytes'):
        assert isinstance(progress[name], int) and 0 <= progress[name] <= total
    assert progress['androidCpuMs'] >= 0
    return progress


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--serial', required=True)
    parser.add_argument('--family', choices=('ipv4', 'link-local'), default='ipv4')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--mac-binary', type=Path, help='Use an already-built native interchange helper')
    parser.add_argument('--benchmark-mib', type=int, choices=(4, 16, 100, 1024))
    parser.add_argument('--window', type=int, choices=(4, 8, 32, 64))
    parser.add_argument('--profile', choices=('standard', 'bulk-probe', 'lan-transfer'), default='standard')
    args = parser.parse_args()
    args.window = args.window or (32 if args.profile == 'standard' else 4)
    if args.window not in ((32, 64) if args.profile == 'standard' else (4, 8)):
        parser.error('window does not belong to the selected profile')
    if args.profile != 'standard' and not args.benchmark_mib:
        parser.error('bulk-probe requires --benchmark-mib')
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
    if args.mac_binary:
        binary = args.mac_binary.resolve(strict=True)
        assert binary.is_file() and os.access(binary, os.X_OK)
    else:
        binary = output / 'tcp-interchange'
        environment = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
        with (output / 'build.log').open('w') as log:
            subprocess.run(['xcrun', 'swiftc', *(['-O'] if args.benchmark_mib else []), '-swift-version', '6', '-D', 'ANICE_DEVELOPMENT_KEYCHAIN',
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
            mac = subprocess.Popen([str(binary), '--tcp', *(['--' + args.profile] if args.profile != 'standard' else [])], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=mac_log, text=True)
            server = read_event(mac)
            server['family'] = args.family
            if args.benchmark_mib:
                server.update(benchmarkMiB=args.benchmark_mib, window=args.window, profile=args.profile)
            (output / 'server.json').write_text(json.dumps(server))
            command('shell', 'run-as', package, 'mkdir', '-p', remote)
            command('push', output / 'server.json', bootstrap)
            command('shell', 'run-as', package, 'cp', bootstrap, remote + '/server.json')
            instrumentation = subprocess.Popen([*adb, 'shell', 'am', 'instrument', '-w', '-r',
                '-e', 'class', f'{TEST}#protectedTcpInterchange', '-e', 'aniceLanRun', run,
                'io.github.anisharyal09.anice.test/androidx.test.runner.AndroidJUnitRunner'],
                stdout=instrument_log, stderr=subprocess.STDOUT)
            def wait_file(name):
                deadline = time.monotonic() + (1200 if args.benchmark_mib else 90)
                while time.monotonic() < deadline:
                    if args.benchmark_mib:
                        failure = subprocess.run([*adb, 'shell', 'run-as', package, 'cat',
                                                  remote + '/benchmark-failure.json'], capture_output=True,
                                                 text=True, timeout=10)
                        if failure.returncode == 0:
                            progress = benchmark_deadline_result(json.loads(failure.stdout),
                                                                 args.benchmark_mib * 1048576, args.window)
                            progress['macOptimization'] = 'O'
                            progress['profile'] = args.profile
                            (output / 'benchmark.json').write_text(json.dumps(progress, indent=2) + '\n')
                            command('shell', 'run-as', package, 'touch', remote + '/ack')
                            instrumentation.wait(timeout=40)
                            require_deadline_failure((output / 'instrumentation.log').read_text())
                            raise RuntimeError('Production DATA completion deadline failed; see benchmark.json')
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
            android_metrics = result.pop('benchmark', None)
            assert result == dict(tcp=True, controls=True, bidirectionalBytes=4000, family=args.family)
            benchmark = None
            if args.benchmark_mib:
                mac_metrics = read_event(mac, timeout=1200)['benchmark']
                benchmark = benchmark_result(android_metrics, mac_metrics,
                                             args.benchmark_mib * 1048576, args.window)
                benchmark['macOptimization'] = 'O'
                benchmark['profile'] = args.profile
                (output / 'benchmark.json').write_text(json.dumps(benchmark, indent=2) + '\n')
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
        if benchmark:
            print(json.dumps(benchmark))
            if not benchmark['throughputPassed']:
                raise RuntimeError('Production DATA throughput gate failed; feature integration remains blocked')
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
