#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Summarize bounded local Phone Audio diagnostic logs; never reads a device or activates audio."""
import argparse
import json
import os
from pathlib import Path
import stat

PREFIX = "phone_audio_diag "
MAX_INPUT_BYTES = 8 * 1024 * 1024
MAX_LINE_BYTES = 8192
MAX_ROWS = 4096
MAX_RUNS = 32
MAX_INTEGER = (1 << 63) - 1

TIMINGS = {
    "android": ("read", "capture_interval", "presentation_wait", "queue_age", "encode", "submission"),
    "macos": ("arrival_interval", "receiver_admission"),
}
COMMON_INTEGERS = frozenset(("version", "run", "elapsed_ms", "window_start_elapsed_ms", "state"))
SIDE_INTEGERS = {
    "android": frozenset((
        "queued_packets", "capture_requested_frames", "capture_effective_frames",
        "read_calls", "read_frames", "empty_reads", "read_errors", "captured_packets",
        "emission_failures", "submitted_packets", "queue_replaced_packets",
        "maintenance_dropped_packets", "backpressure_dropped_packets", "cancelled_send_attempts",
        "maximum_queued_packets",
    )),
    "macos": frozenset((
        "arriving_packets", "accepted_packets", "discarded_packets", "sequence_gap_events",
        "sequence_missing_packets", "output_queued_frames", "output_resyncs",
        "output_unavailable_drops", "output_scheduled_packets", "output_rendered_callbacks", "output_played_back_callbacks",
        "output_empty_pending_transitions", "output_completion_max_us", "output_snapshot_age_us",
    )),
}
BOOLEANS = frozenset((
    "terminal", "maintenance", "in_flight", "capture_available", "activity_started",
    "activity_resumed", "screen_interactive",
))
COUNTERS = {
    "android": frozenset((
        "read_calls", "read_frames", "empty_reads", "read_errors", "captured_packets",
        "emission_failures", "submitted_packets", "queue_replaced_packets", "maintenance_dropped_packets",
        "backpressure_dropped_packets", "cancelled_send_attempts",
    )),
    "macos": frozenset((
        "arriving_packets", "accepted_packets", "discarded_packets", "sequence_gap_events",
        "sequence_missing_packets", "output_resyncs", "output_unavailable_drops",
        "output_scheduled_packets", "output_rendered_callbacks", "output_played_back_callbacks",
        "output_empty_pending_transitions",
    )),
}


class DiagnosticError(ValueError):
    """Fixed errors contain no log content or potentially private identifiers."""


def integer(value):
    return type(value) is int and 0 <= value <= MAX_INTEGER


def timing_keys(side):
    return {prefix + "_" + suffix for prefix in TIMINGS[side] for suffix in (
        "samples", "max_us", "window_max_us", "over_40ms", "under_5ms")}


def sanitized_row(value):
    if not isinstance(value, dict) or type(value.get("side")) is not str or (
            value["side"] not in TIMINGS) or value.get("version") != 1:
        return None
    side = value["side"]
    required = ("version", "run", "elapsed_ms", "window_start_elapsed_ms", "state")
    if not all(integer(value.get(key)) for key in required):
        return None
    if value["run"] < 1 or value["state"] > 5 or value["window_start_elapsed_ms"] > value["elapsed_ms"]:
        return None
    if type(value.get("terminal")) is not bool or type(value.get("maintenance")) is not bool:
        return None
    result = {"side": side}
    for key in COMMON_INTEGERS | SIDE_INTEGERS[side] | timing_keys(side):
        if key in value:
            item = value[key]
            if item is not None and not integer(item):
                return None
            result[key] = item
    for key in BOOLEANS:
        if key in value:
            item = value[key]
            if item is not None and type(item) is not bool:
                return None
            result[key] = item
    if side == "android":
        for key in ("queued_packets", "maximum_queued_packets"):
            if result.get(key) is not None and result[key] > 3:
                return None
    if side == "macos" and result.get("output_queued_frames") is not None and result["output_queued_frames"] > 5760:
        return None
    return result


def no_duplicate_keys(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise DiagnosticError("Malformed diagnostic row")
        value[key] = item
    return value


def parse_lines(stream):
    rows = []
    rejected = 0
    total = 0
    while True:
        line = stream.readline(MAX_LINE_BYTES + 1)
        if not line:
            break
        total += len(line)
        if total > MAX_INPUT_BYTES:
            raise DiagnosticError("Input exceeds the diagnostic size limit")
        if len(line) > MAX_LINE_BYTES:
            raise DiagnosticError("Input line exceeds the diagnostic size limit")
        marker = line.find(PREFIX.encode())
        if marker < 0:
            continue
        try:
            value = json.loads(line[marker + len(PREFIX):].decode("utf-8"),
                               object_pairs_hook=no_duplicate_keys)
            row = sanitized_row(value)
        except (ValueError, UnicodeDecodeError, RecursionError):
            row = None
        if row is None:
            rejected += 1
            continue
        if len(rows) >= MAX_ROWS:
            raise DiagnosticError("Input exceeds the diagnostic row limit")
        rows.append(row)
    return rows, rejected


def read_log(path):
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_INPUT_BYTES:
            raise DiagnosticError("Input must be a bounded regular diagnostic log")
        return parse_lines(stream)


def counter_delta(previous, current, side):
    if previous is None:
        return None
    result = {}
    keys = COUNTERS[side] | {
        prefix + "_" + suffix for prefix in TIMINGS[side] for suffix in ("samples", "over_40ms", "under_5ms")
    }
    for key in keys:
        before, after = previous.get(key), current.get(key)
        result[key] = after - before if integer(before) and integer(after) and after >= before else None
    return result


def findings(row, delta):
    """Describe observed local timing, not a causal diagnosis or audible-gap count."""
    observations = []
    side = row["side"]
    for prefix in TIMINGS[side]:
        duration = row.get(prefix + "_window_max_us")
        if integer(duration) and duration > 40_000:
            observations.append(prefix + "_window_over_40ms")
    if delta:
        for key in ("queue_replaced_packets", "backpressure_dropped_packets", "sequence_missing_packets",
                    "output_resyncs", "empty_reads", "read_errors"):
            if integer(delta.get(key)) and delta[key] > 0:
                observations.append(key + "_increased")
    return observations


def summarize(rows, rejected):
    groups = []
    current = None
    counts = {"android": 0, "macos": 0}
    # Input-file boundaries start a segment: process-local run counters are not global stream identifiers.
    for row in rows:
        side = row["side"]
        replace = (current is None or current["side"] != side or current["run"] != row["run"] or
                   current["samples"][-1]["metrics"]["terminal"] or
                   row["elapsed_ms"] < current["samples"][-1]["metrics"]["elapsed_ms"] or
                   (row["elapsed_ms"] == current["samples"][-1]["metrics"]["elapsed_ms"] and not row["terminal"]))
        if replace:
            if len(groups) >= MAX_RUNS:
                raise DiagnosticError("Input exceeds the diagnostic segment limit")
            counts[side] += 1
            current = {"side": side, "run": row["run"], "segment": counts[side], "samples": []}
            groups.append(current)
        previous = current["samples"][-1]["metrics"] if current["samples"] else None
        delta = counter_delta(previous, row, side)
        current["samples"].append({
            "metrics": row, "counter_delta": delta, "observations": findings(row, delta),
        })
    return {"schema": 1, "scope": "payload-free local Phone Audio diagnostic summary",
            "accepted_rows": len(rows), "rejected_diagnostic_rows": rejected, "segments": groups,
            "limitations": [
                "Phone and Mac clocks are not synchronized; run counters are process-local.",
                "No stream or peer identities, source names, addresses or raw log lines are retained.",
                "Timing windows are local elapsed intervals; phase labels must come from manual run notes.",
                "Submission completion is not authenticated remote delivery or measured output latency.",
                "Empty native queue transitions and resyncs are not measured audible gaps or native underruns.",
                "Diagnostics can perturb scheduling and are limited to ten minutes per operation.",
                "Observations identify timing pressure, not its physical root cause or acceptance.",
            ]}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--android-log", type=Path)
    parser.add_argument("--mac-log", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    if not args.android_log and not args.mac_log:
        parser.error("Provide at least one diagnostic log")
    if args.output.exists() or args.output.is_symlink():
        raise SystemExit("Output already exists; choose a new file")
    segments = []
    accepted = rejected = 0
    try:
        for side, path in (("android", args.android_log), ("macos", args.mac_log)):
            if path is None:
                continue
            rows, invalid = read_log(path)
            invalid += sum(row["side"] != side for row in rows)
            rows = [row for row in rows if row["side"] == side]
            result = summarize(rows, invalid)
            segments.extend(result["segments"])
            accepted += result["accepted_rows"]
            rejected += result["rejected_diagnostic_rows"]
            if accepted > MAX_ROWS or len(segments) > MAX_RUNS:
                raise DiagnosticError("Combined inputs exceed the diagnostic summary limit")
        if not accepted:
            raise DiagnosticError("No valid Phone Audio diagnostic rows found")
        report = summarize([], rejected)
        report["accepted_rows"] = accepted
        report["segments"] = segments
        args.output.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(report, stream, indent=2)
            stream.write("\n")
    except (OSError, DiagnosticError):
        raise SystemExit("Could not read bounded diagnostics or create a new summary; no raw content copied")
    print(f"Saved {accepted} payload-free diagnostic rows: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
