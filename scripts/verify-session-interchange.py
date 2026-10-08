#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fresh Android Keystore / Mac Keychain EDHOC exchange, without BLE or persisted session secrets."""
import argparse
import json
import re
from pathlib import Path
import selectors
import subprocess
import tempfile
import time
import uuid

TEST_CLASS = "io.github.anisharyal09.anice.infrastructure.session.SessionNativeTest"

def require_instrumentation_pass(log):
    """Require both named tests to finish; am's exit code and summary also occur on skips."""
    events = []
    fields = {}
    for line in log.splitlines():
        field = re.fullmatch(r"INSTRUMENTATION_STATUS: (class|test|current|numtests)=(.*)", line)
        if field:
            fields[field[1]] = field[2]
        code = re.fullmatch(r"INSTRUMENTATION_STATUS_CODE: (-?\d+)", line)
        if code:
            events.append((fields, int(code[1])))
            fields = {}
    result_codes = re.findall(r"^INSTRUMENTATION_CODE: (-?\d+)\s*$", log, re.MULTILINE)
    valid = (
        len(events) == 4 and [code for _, code in events] == [1, 0, 1, 0]
        and result_codes == ["-1"]
        and re.search(r"^OK \(2 tests\)\s*$", log, re.MULTILINE)
        and not any(token in log for token in ["FAILURES", "INSTRUMENTATION_FAILED", "shortMsg="])
    )
    if valid:
        names = [field.get("test") for field, _ in events]
        valid = (
            names[0] == names[1] and names[2] == names[3]
            and set(names) == {"nativeProviderConformance", "protectedKeyInterchange"}
            and all(field.get("class") == TEST_CLASS and field.get("numtests") == "2"
                    and field.get("current") == str(index // 2 + 1)
                    for index, (field, _) in enumerate(events))
        )
    if not valid:
        raise RuntimeError("Native instrumentation did not complete both required tests:\n" + log)


def command(adb, *parts):
    return subprocess.run([*adb, *parts], check=True, capture_output=True, text=True, timeout=20).stdout

def receive(process):
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    try:
        if not selector.select(40):
            raise TimeoutError("Mac handshake reply timed out")
        line = process.stdout.readline()
        if not line:
            raise RuntimeError("Mac interchange process exited before reply")
        return json.loads(line)
    finally:
        selector.close()

def wait_file(adb, remote, name):
    deadline = time.monotonic() + 40
    while time.monotonic() < deadline:
        result = subprocess.run([*adb, "shell", "cat", f"{remote}/{name}"], capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            return json.loads(result.stdout)
        time.sleep(0.1)
    raise TimeoutError(f"Android reply timed out: {name}")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--serial", required=True)
    parser.add_argument("--mac-binary", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    run = str(uuid.uuid4())
    remote = f"/sdcard/Android/data/io.github.anisharyal09.anice/files/session-interchange-{run}"
    adb = ["adb", "-s", args.serial]
    if args.output:
        args.output.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix="anice-session-interchange-", dir=args.output))
    logs = Path(tmp) / "instrumentation.log"
    mac_log = (tmp / "mac.log").open("w")
    mac = subprocess.Popen([str(args.mac_binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                           stderr=mac_log, text=True, bufsize=1)
    instrumentation = None
    try:
        server = receive(mac)
        def publish(name, row):
            file = Path(tmp) / name
            file.write_text(json.dumps(row))
            command(adb, "push", str(file), f"{remote}/{name}.tmp")
            command(adb, "shell", "mv", f"{remote}/{name}.tmp", f"{remote}/{name}")
        with logs.open("w") as log:
            instrumentation = subprocess.Popen([*adb, "shell", "am", "instrument", "-w", "-r",
                "-e", "class", TEST_CLASS,
                "-e", "aniceSessionRun", run,
                "io.github.anisharyal09.anice.test/androidx.test.runner.AndroidJUnitRunner"], stdout=log, stderr=log)
            bootstrap = wait_file(adb, remote, "bootstrap.json")
            if bootstrap["directory"].replace("/storage/emulated/0", "/sdcard") != remote:
                raise AssertionError("Unexpected isolated exchange directory")
            publish("server.json", server)
            client = wait_file(adb, remote, "client.json")
            mac.stdin.write(json.dumps(client) + "\n"); mac.stdin.flush()
            publish("message2.json", receive(mac))
            m3 = wait_file(adb, remote, "message3.json")
            mac.stdin.write(json.dumps(m3) + "\n"); mac.stdin.flush()
            final = receive(mac)
            publish("message4.json", {"message4Hex": final["message4Hex"]})
            for inbound, outbound in [("ready", "readyAck"), ("clientData", "serverData")]:
                mac.stdin.write(json.dumps(wait_file(adb, remote, inbound + ".json")) + "\n"); mac.stdin.flush()
                publish(outbound + ".json", receive(mac))
            mac.stdin.write(json.dumps(wait_file(adb, remote, "close.json")) + "\n"); mac.stdin.flush()
            result = wait_file(adb, remote, "result.json")
            if result.get("recordAgreement") is not True or result.get("bidirectionalBytes") != 4000:
                raise AssertionError("Native record/readiness agreement failed")
            if result["exportDigestHex"] != final["exportDigestHex"] or result["stage"] != "COMPLETE":
                raise AssertionError("Native EDHOC exporter agreement failed")
            publish("ack.json", {"received": True})
            cleanup = receive(mac)
            if cleanup != {"cleanup": True}:
                raise AssertionError("Mac isolated-key cleanup failed")
            instrumentation.wait(timeout=30)
            mac.wait(timeout=10)
        output = logs.read_text()
        if instrumentation.returncode != 0 or mac.returncode != 0:
            raise AssertionError("Native instrumentation failed:\n" + output)
        require_instrumentation_pass(output)
        sdk = command(adb, "shell", "getprop", "ro.build.version.sdk").strip()
        report = {"nativeProviderTests": 2, "exporterAgreement": True, "isolatedCleanup": True,
                  "androidApi": sdk, "bleVerified": False, "run": run,
                  "recordAgreement": True, "readinessVerified": True, "bidirectionalBytes": 4000,
                  "evidenceKind": "automated-native-interchange",
                  "manualAcceptance": "pending", "macStorageBackend": "developmentKeychain"}
    finally:
        if instrumentation is not None and instrumentation.poll() is None:
            # Let the test's bounded wait/finally clean its isolated Keystore namespace.
            instrumentation.wait(timeout=100)
        if mac.poll() is None:
            mac.stdin.close()
            try:
                mac.wait(timeout=10)
            except subprocess.TimeoutExpired:
                mac.terminate(); mac.wait(timeout=5)
        command(adb, "shell", "rm", "-rf", remote)
        mac_log.close()
        print("Native interchange logs: " + str(tmp), flush=True)
    # A cleanup exception must never leave a success report for this fresh run.
    (tmp / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({**report, "evidence": str(tmp)}, indent=2))


if __name__ == "__main__":
    main()
