#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Read-only, payload-free snapshots for an explicitly selected listening preview."""
import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import subprocess
import time

PACKAGE = "io.github.anisharyal09.anice.preview.transfer"
PACKAGE_QUERY = ["shell", "pm", "list", "packages", "-U", "--user", "0", PACKAGE]
PID_QUERY = ["shell", "pidof", PACKAGE]
QUERY_TIMEOUT = 15
MAX_QUERY_BYTES = 4 * 1024 * 1024
MAX_TRACKS = 32
AUDIO_STATES = frozenset(("idle", "started", "paused", "stopped", "released"))
PROCESS_STATES = frozenset("RSDZTtIXKWPN")


@dataclass(frozen=True)
class Query:
    status: str
    text: str = ""


def bounded_integer(value, minimum=0, maximum=(1 << 63) - 1):
    if not re.fullmatch(r"[0-9]{1,19}", value):
        return None
    number = int(value)
    return number if minimum <= number <= maximum else None


def package_uid(text):
    matches = re.findall(r"^package:" + re.escape(PACKAGE) + r" uid:([0-9]+)[ \t]*$", text, re.M)
    return bounded_integer(matches[0], 1, (1 << 31) - 1) if len(matches) == 1 else None


def process_id(text):
    return bounded_integer(text.strip(), 1, (1 << 31) - 1)


def audio_metrics(text, uid, pid=None):
    """Keep only this app's native playback state; never retain source metadata."""
    focus_seen = False
    focus_section = False
    playback_seen = False
    players_section = False
    players_seen = False
    focus_losses = []
    tracks = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("Audio Focus stack entries"):
            focus_seen = focus_section = True
        elif stripped.startswith(("Events log:", "No external focus policy", "Focus policy:")):
            focus_section = False
        if stripped.startswith("PlaybackActivityMonitor dump time:"):
            playback_seen = True
            players_section = False
        elif playback_seen and stripped == "players:":
            players_section = True
            players_seen = True
        elif players_section and stripped.startswith(("ducked players:", "muted players:", "Events log:")):
            players_section = False
        if uid is None:
            continue
        # Historical request/abandon logs contain the same package. They are not current focus.
        if focus_section and stripped.startswith("source:") and re.search(
                r"-- pack: " + re.escape(PACKAGE) + r" --", line) and re.search(
                r"-- uid: " + str(uid) + r"(?:[ \t]|$)", line):
            loss = re.search(r"-- loss: (none|LOSS|LOSS_TRANSIENT|LOSS_TRANSIENT_CAN_DUCK)(?:[ \t]|$)", line)
            focus_losses.append(loss.group(1) if loss else None)
        if not players_section:
            continue
        if not line.lstrip().startswith("AudioPlaybackConfiguration "):
            continue
        owner = re.search(r"\bu/pid:([0-9]{1,10})/([0-9]{1,10})\b", line)
        if owner is None or bounded_integer(owner.group(1)) != uid or (
                pid is not None and bounded_integer(owner.group(2)) != pid):
            continue
        state = re.search(r"\bstate:([a-z_]+)", line)
        rate = re.search(r"\bsampleRate=([0-9]+)", line)
        tracks.append({
            "state": state.group(1) if state and state.group(1) in AUDIO_STATES else "unknown",
            "sample_rate": bounded_integer(rate.group(1), 1, 768000) if rate else None,
        })
        if len(tracks) >= MAX_TRACKS:
            break
    focus = None
    if focus_seen and uid is not None:
        focus = "none" in focus_losses if all(loss is not None for loss in focus_losses) else None
    return {
        "available": uid is not None and (focus_seen or playback_seen),
        "focus_request_present": bool(focus_losses) if focus_seen and uid is not None else None,
        "has_audio_focus": focus,
        "tracks_available": players_seen and uid is not None,
        "tracks": tracks,
    }


def wifi_metrics(text):
    # cmd wifi status contains SSID, BSSID, MAC/IP: discard all raw content and identifiers.
    # Ignore quoted SSIDs before looking for numeric fields. Unknown layouts are not usable data.
    text = re.sub(r'"(?:\\.|[^"\\])*"', '""', text)
    # Android reports both current PHY rates and "Max Supported" capabilities.
    # Capability limits must not become duplicate current-rate matches or throughput.
    text = re.sub(r"\bMax\s+Supported\s+(?:Tx|Rx)\s+Link\s+speed:\s*[0-9]+", "", text, flags=re.I)
    result = {}
    patterns = {
        "frequency_mhz": (r"\bFrequency:\s*([0-9]+)", 1000, 100000),
        "rssi_dbm": (r"\bRSSI:\s*(-?[0-9]+)", -126, -1),
        "tx_link_mbps": (r"\bTx Link speed:\s*([0-9]+)", 0, 100000),
        "rx_link_mbps": (r"\bRx Link speed:\s*([0-9]+)", 0, 100000),
    }
    for key, (pattern, minimum, maximum) in patterns.items():
        matches = re.findall(pattern, text, re.I)
        value = int(matches[0]) if len(matches) == 1 and len(matches[0]) <= 7 else None
        result[key] = value if value is not None and minimum <= value <= maximum else None
    result["available"] = any(value is not None for value in result.values())
    return result


def native_track_metrics(text, uid, pid=None):
    """Read current tables only. Named columns must match a recognized layout, not guessed offsets."""
    tracks = []
    if uid is None:
        return {"available": False, "tracks": tracks}
    header = None
    remaining = None
    available = False
    incomplete = False
    # These labels contain spaces but represent one column in the supported AudioFlinger tables.
    labels = ("Port Id", "Chn mask", "G db", "L dB", "R dB", "VS dB", "PortVol dB",
              "L Vol", "R Vol")
    allowed = frozenset((
        "Type", "Id", "Active", "Client(pid/uid)", "Session", "Port_Id", "S", "Flags",
        "Format", "Chn_mask", "SRate", "ST", "Usg", "CT", "G_db", "L_dB", "R_dB",
        "VS_dB", "PortVol_dB", "PortMuted", "Server", "FrmCnt", "FrmRdy", "F",
        "Underruns", "Flushed",
    ))
    for line in text.splitlines():
        count = re.fullmatch(r"\s*([0-9]+) Tracks of which [0-9]+ are active\s*", line)
        if count:
            incomplete = incomplete or bool(remaining)
            remaining = bounded_integer(count.group(1), 0, 4096)
            header = None
            continue
        if line.strip().startswith("Local log:"):
            incomplete = incomplete or bool(remaining)
            header = None
            remaining = None
            continue
        if "Client(pid/uid)" in line and "FrmCnt" in line:
            if remaining is None:
                continue
            normalized = line
            for label in sorted(labels, key=len, reverse=True):
                normalized = re.sub(r"\b" + re.escape(label) + r"\b", label.replace(" ", "_"), normalized)
            columns = normalized.split()
            required = ("Id", "Active", "Client(pid/uid)", "SRate", "FrmCnt", "FrmRdy", "Underruns")
            if all(columns.count(column) == 1 for column in required):
                owner = columns.index("Client(pid/uid)")
                if owner >= 2 and columns[owner - 2:owner] == ["Id", "Active"]:
                    header = (columns, owner)
                    available = True
            if header is None and remaining:
                incomplete = True
            continue
        if header is None or not remaining:
            continue
        # Native Type is blank, S (static) or P (patch), optionally after F<n>.
        # Recognize these explicitly: an unrelated static track must not make a
        # supported current table look malformed, but unknown prefixes still fail.
        row = re.fullmatch(r"\s*(?:F[0-9]{1,10}\s+)?(?:[SP]\s+)?([0-9]{1,19})\s+(yes|no)\s+"
                           r"([0-9]{1,10})/\s*([0-9]{1,10})\s+(.+)", line)
        if row is None:
            incomplete = True
            header = None
            remaining = None
            continue
        remaining -= 1
        if int(row.group(4)) != uid or (pid is not None and int(row.group(3)) != pid):
            continue
        columns, owner = header
        values = [row.group(1), row.group(2), row.group(3) + "/" + row.group(4)] + row.group(5).split()
        counters = {}
        for column, key in (("SRate", "sample_rate"), ("FrmCnt", "buffer_frames"),
                            ("FrmRdy", "ready_frames"), ("Underruns", "reported_underruns"),
                            ("Flushed", "flushed_frames")):
            index = columns.index(column) if column in columns else None
            offset = index - owner + 2 if index is not None else None
            supported = index is not None and all(label in allowed for label in columns[:index + 1])
            value = values[offset] if supported and 0 <= offset < len(values) else ""
            # Android decorates reduced buffer sizes and current starvation state.
            # Remove only known suffixes, never guess numeric positions or units.
            suffix = r"r?" if column == "FrmCnt" else r"[*<?]?" if column == "Underruns" else ""
            number = re.fullmatch(r"([0-9]{1,19})" + suffix, value)
            value = number.group(1) if number else ""
            counters[key] = bounded_integer(value, 1 if column == "SRate" else 0,
                                            768000 if column == "SRate" else (1 << 63) - 1)
        tracks.append({"track_id": bounded_integer(row.group(1)), "active": row.group(2) == "yes", **counters})
        if len(tracks) >= MAX_TRACKS:
            break
    return {"available": available and not incomplete and not remaining, "tracks": tracks}


def thread_metrics(text, pid=None):
    """Linux /proc/PID/stat fields; absence on restricted Android is not an invented zero."""
    opening = re.match(r"([0-9]{1,10}) \(", text)
    if opening is None or ")" not in text or (pid is not None and int(opening.group(1)) != pid):
        return {"available": False}
    fields = text.rsplit(")", 1)[1].split()
    try:
        user = bounded_integer(fields[11])
        system = bounded_integer(fields[12])
        threads = bounded_integer(fields[17], 1, 65536)
        started = bounded_integer(fields[19])
        if None in (user, system, threads, started):
            return {"available": False}
        return {"available": True, "cpu_ticks": user + system, "threads": threads,
                "start_time_ticks": started, "state": fields[0] if fields[0] in PROCESS_STATES else "unknown"}
    except IndexError:
        return {"available": False}


def process_metrics(text, pid, uid):
    """The PID may be recycled between pidof and cat; verify both process identity and owner UID."""
    stats, separator, status = text.partition("\nName:")
    if not separator:
        return {"available": False}
    owner = re.search(r"(?m)^Uid:[ \t]+([0-9]{1,10})[ \t]+([0-9]{1,10})"
                      r"[ \t]+([0-9]{1,10})[ \t]+([0-9]{1,10})[ \t]*$", status)
    selected = re.search(r"(?m)^Pid:[ \t]+([0-9]{1,10})[ \t]*$", status)
    if owner is None or selected is None or int(selected.group(1)) != pid or any(
            int(value) != uid for value in owner.groups()):
        return {"available": False}
    return thread_metrics(stats, pid)


def delta(previous, current):
    if previous is None or previous.get("pid") != current.get("pid") or current.get("pid") is None:
        return None
    before = previous.get("process", {})
    after = current.get("process", {})
    if before.get("start_time_ticks") is None or before["start_time_ticks"] != after.get("start_time_ticks"):
        return None
    ticks_before, ticks_after = before.get("cpu_ticks"), after.get("cpu_ticks")
    at_before, at_after = before.get("observed_seconds"), after.get("observed_seconds")
    if (ticks_before is None or ticks_after is None or ticks_after < ticks_before or
            at_before is None or at_after is None or at_after <= at_before):
        return None
    native = []
    earlier = {track["track_id"]: track for track in previous.get("native_tracks", {}).get("tracks", [])
               if track.get("track_id") is not None}
    for track in current.get("native_tracks", {}).get("tracks", []):
        if track.get("track_id") is None:
            continue
        prior = earlier.get(track["track_id"], {})
        count_before, count_after = prior.get("reported_underruns"), track.get("reported_underruns")
        if count_before is not None and count_after is not None and count_after >= count_before:
            native.append({"track_id": track["track_id"], "reported_underruns": count_after - count_before})
    return {"cpu_ticks": ticks_after - ticks_before, "elapsed_seconds": at_after - at_before,
            "native_tracks": native}


def find_adb():
    candidate = shutil.which("adb")
    if candidate:
        return candidate
    roots = [os.environ.get("ANDROID_HOME"), os.environ.get("ANDROID_SDK_ROOT"),
             Path.home() / "Library/Android/sdk", Path.home() / "Android/Sdk"]
    for root in roots:
        if root:
            path = Path(root) / "platform-tools/adb"
            if path.is_file() and os.access(path, os.X_OK):
                return str(path)
    raise SystemExit("adb unavailable; no tool installation attempted")


def command(adb, serial, arguments):
    # Every call below is a read-only query. No shell interpolation, grants, installs or recording.
    deadline = time.monotonic() + QUERY_TIMEOUT
    try:
        with subprocess.Popen([adb, "-s", serial, *arguments], stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL) as process:
            try:
                output = bytearray()
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    while True:
                        remaining = deadline - time.monotonic()
                        if remaining <= 0 or not selector.select(remaining):
                            process.kill()
                            return Query("timeout")
                        block = os.read(process.stdout.fileno(), 65536)
                        if not block:
                            break
                        output.extend(block)
                        if len(output) > MAX_QUERY_BYTES:
                            process.kill()
                            return Query("output_limit")
                code = process.wait(timeout=max(0, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                process.kill()
                return Query("timeout")
            except BaseException:
                process.kill()
                raise
        if code != 0:
            # pidof exit 1 also occurs on device/permission failure; absence is not proven.
            return Query("failed")
        try:
            text = output.decode("utf-8")
        except UnicodeDecodeError:
            return Query("unrecognized")
        if re.search(r"(?mi)^\s*(?:permission denial|permission denied|error:|can't find service)", text):
            return Query("unavailable")
        return Query("ok", text)
    except OSError:
        return Query("unavailable")


def snapshot(adb, serial, uid, stage, native_tracks=False):
    at = time.monotonic()
    queries = {}

    def read(name, arguments):
        result = command(adb, serial, arguments)
        queries[name] = result.status
        return result.text

    current_uid = package_uid(read("package", PACKAGE_QUERY))
    if current_uid != uid:
        return {"stage": stage, "monotonic_seconds": at, "query_seconds": time.monotonic() - at,
                "pid": None, "preview_running": None, "process": {"available": False},
                "queries": queries, "preview_verified": False}
    raw_pid = read("pid", PID_QUERY)
    pid = process_id(raw_pid)
    running = True if pid is not None else False if queries["pid"] == "ok" and not raw_pid.strip() else None
    process_query = ["shell", "cat", f"/proc/{pid}/stat", f"/proc/{pid}/status"] if pid else None
    process = process_metrics(read("process", process_query), pid, uid) if pid else {"available": False}
    if process["available"]:
        process["observed_seconds"] = time.monotonic()
    interactive = read("power", ["shell", "dumpsys", "power"])
    wakefulness = re.search(r"^\s*mWakefulness=(Awake|Asleep|Dozing|Dreaming)\s*$", interactive, re.M)
    audio = audio_metrics(read("audio", ["shell", "dumpsys", "audio"]), uid, pid)
    wifi = wifi_metrics(read("wifi", ["shell", "cmd", "wifi", "status"]))
    native = (native_track_metrics(read("native_tracks", ["shell", "dumpsys", "media.audio_flinger"]), uid, pid)
              if native_tracks else {"available": False, "tracks": []})
    if process["available"]:
        final = process_metrics(read("process_check", process_query), pid, uid)
        if not final["available"] or final["start_time_ticks"] != process["start_time_ticks"]:
            process = {"available": False}
            audio = audio_metrics("", None)
            native = {"available": False, "tracks": []}
            queries["process_check"] = "process_changed" if final["available"] else queries["process_check"]
    return {
        "stage": stage, "monotonic_seconds": at, "query_seconds": time.monotonic() - at,
        "pid": pid, "preview_running": running, "preview_verified": True,
        "process": process, "queries": queries,
        "wakefulness": wakefulness.group(1) if wakefulness else "unavailable",
        "audio": audio, "native_tracks": native, "wifi": wifi,
    }


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True, help="Explicit adb target; never selects a phone automatically")
    parser.add_argument("--stage", choices=("foreground", "background", "screen-off", "transfer"), required=True)
    parser.add_argument("--samples", type=int, default=1, help="1–120 read-only snapshots; default is one")
    parser.add_argument("--interval", type=float, default=10,
                        help="5–60 seconds; slow queries also get at least 5 seconds of rest")
    parser.add_argument("--mode", choices=("balanced", "lower-delay"), help="Optional user-labelled buffering mode, never inferred")
    parser.add_argument("--native-tracks", action="store_true", help="Opt into the heavier, layout-checked AudioFlinger query")
    parser.add_argument("--output", type=Path, required=True, help="New JSON file; existing files are never overwritten")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,99}", args.serial):
        parser.error("Invalid device serial")
    if not 1 <= args.samples <= 120 or not 5 <= args.interval <= 60:
        parser.error("Use samples 1–120 and interval 5–60 seconds")
    return args


def main(argv=None):
    args = parse_args(argv)
    if args.output.exists() or args.output.is_symlink():
        raise SystemExit("Output already exists; choose a new file")
    adb = find_adb()
    uid = package_uid(command(adb, args.serial, PACKAGE_QUERY).text)
    if uid is None:
        raise SystemExit("Selected device has no identifiable Transfer Preview; no production app queried")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive creation also closes the race between the existence check and writing.
    descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        report = {
            "schema": 1, "scope": "read-only Transfer Preview diagnostics",
            "complete": False, "buffering_mode": args.mode,
            "native_tracks_requested": args.native_tracks,
            "limitations": [
                "Stage is user-labelled, not inferred.",
                "Queries can perturb timing; this is not an audio latency benchmark.",
                "Link rates are Wi-Fi PHY rates, not file throughput.",
                "No audio, keys, peer credentials, addresses, SSIDs or playback titles are saved.",
                "Missing restricted diagnostics are unavailable, not zero.",
                "Native table counters have vendor semantics; compare only a surviving track in one process.",
                "App-owned tracks can include other preview sounds; no stream attribution is inferred.",
                "CPU ticks are not CPU percentage; per-process start time fences PID reuse.",
            ], "samples": [],
        }
        try:
            for index in range(args.samples):
                sample = snapshot(adb, args.serial, uid, args.stage, args.native_tracks)
                sample["delta"] = delta(report["samples"][-1] if report["samples"] else None, sample)
                report["samples"].append(sample)
                if sample.get("preview_verified") is False:
                    raise SystemExit("Selected preview UID changed or became unavailable; partial report saved")
                if index + 1 < args.samples:
                    time.sleep(max(5, args.interval - sample["query_seconds"]))
            report["complete"] = True
        finally:
            json.dump(report, output, indent=2)
            output.write("\n")
    print(f"Saved {len(report['samples'])} read-only snapshots: {args.output}")


if __name__ == "__main__":
    main()
