#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Checks diagnostic allowlists, bounded parsing and local-window attribution without device access."""
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("phone_audio_diagnostics",
                                             Path(__file__).with_name("summarize-phone-audio.py"))
diagnostics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostics)


def row(side="android", elapsed=1000, **values):
    base = {"version": 1, "side": side, "run": 1, "elapsed_ms": elapsed,
            "window_start_elapsed_ms": 0, "state": 2, "terminal": False, "maintenance": False}
    base.update(values)
    return base


def line(value):
    return b"untrusted wrapper " + diagnostics.PREFIX.encode() + json.dumps(value).encode() + b"\n"


class PhoneAudioDiagnosticTests(unittest.TestCase):
    def test_unknown_strings_and_other_logs_are_never_saved(self):
        text = b"SECRET source title and network address\n"
        text += line(row(peer="SECRET", pcm="SECRET", stream="SECRET", address="SECRET",
                         submitted_packets=3, capture_interval_window_max_us=20_000))
        rows, rejected = diagnostics.parse_lines(io.BytesIO(text))
        result = diagnostics.summarize(rows, rejected)
        self.assertNotIn("SECRET", json.dumps(result))
        self.assertEqual(result["accepted_rows"], 1)
        self.assertEqual(rows[0]["submitted_packets"], 3)

    def test_malformed_duplicate_bool_integer_and_excess_queue_are_rejected(self):
        bad = [
            row(run=True), row(version=True), row(state=6), row(elapsed_ms=-1),
            row(queued_packets=4), row(read_calls="PRIVATE"),
            row("macos", output_queued_frames=5761),
            row(activity_started=1), row(window_start_elapsed_ms=2000),
            row(side=[]), row(side={}), row(side=None),
        ]
        raw = b"".join(line(value) for value in bad)
        raw += diagnostics.PREFIX.encode() + b'{"version":1,"version":1}\n'
        rows, rejected = diagnostics.parse_lines(io.BytesIO(raw))
        self.assertEqual(rows, [])
        self.assertEqual(rejected, len(bad) + 1)

    def test_optional_missing_metrics_and_immediate_terminal_are_preserved(self):
        first = diagnostics.sanitized_row(row(elapsed=1000, queued_packets=None,
                                              maximum_queued_packets=None, read_calls=5))
        terminal = diagnostics.sanitized_row(row(elapsed=1000, terminal=True, read_calls=5))
        report = diagnostics.summarize([first, terminal], 0)
        self.assertEqual(len(report["segments"]), 1)
        self.assertEqual(report["segments"][0]["samples"][1]["counter_delta"]["read_calls"], 0)
        self.assertIsNone(first["queued_packets"])

    def test_maximum_input_line_and_row_budgets(self):
        with self.assertRaises(diagnostics.DiagnosticError):
            diagnostics.parse_lines(io.BytesIO(b"x" * (diagnostics.MAX_LINE_BYTES + 1)))
        with patch.object(diagnostics, "MAX_INPUT_BYTES", 10):
            with self.assertRaises(diagnostics.DiagnosticError):
                diagnostics.parse_lines(io.BytesIO(b"ordinary log\n"))
        with patch.object(diagnostics, "MAX_ROWS", 1):
            with self.assertRaises(diagnostics.DiagnosticError):
                diagnostics.parse_lines(io.BytesIO(line(row()) + line(row(elapsed=2000))))

    def test_local_deltas_and_windows_do_not_imply_clock_synchronization(self):
        first = diagnostics.sanitized_row(row(elapsed=1000, captured_packets=50,
            queue_replaced_packets=0, capture_interval_window_max_us=20_000,
            presentation_wait_window_max_us=0))
        second = diagnostics.sanitized_row(row(elapsed=2000, window_start_elapsed_ms=1000,
            captured_packets=100, queue_replaced_packets=7, capture_interval_window_max_us=20_000,
            presentation_wait_window_max_us=100_000))
        result = diagnostics.summarize([first, second], 0)
        sample = result["segments"][0]["samples"][1]
        self.assertEqual(sample["counter_delta"]["captured_packets"], 50)
        self.assertIn("presentation_wait_window_over_40ms", sample["observations"])
        self.assertIn("queue_replaced_packets_increased", sample["observations"])
        self.assertNotIn("capture_interval_window_over_40ms", sample["observations"])
        self.assertFalse(any("latency" in key for key in sample["metrics"]))

    def test_process_local_run_reset_and_terminal_start_new_segments(self):
        rows = [row(elapsed=1000), row(elapsed=2000, terminal=True), row(elapsed=10),
                row(elapsed=5), row("macos", elapsed=5)]
        report = diagnostics.summarize(rows, 0)
        self.assertEqual(len(report["segments"]), 4)
        with patch.object(diagnostics, "MAX_RUNS", 1):
            with self.assertRaises(diagnostics.DiagnosticError):
                diagnostics.summarize(rows, 0)

    def test_missing_or_reset_counters_are_unavailable_not_zero(self):
        self.assertIsNone(diagnostics.counter_delta(None, row(), "android"))
        delta = diagnostics.counter_delta(row(read_calls=5), row(read_calls=2), "android")
        self.assertIsNone(delta["read_calls"])
        self.assertIsNone(delta["queue_replaced_packets"])

    def test_symlink_and_nonregular_inputs_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            log = path / "input.log"
            log.write_bytes(line(row()))
            link = path / "link.log"
            link.symlink_to(log)
            with self.assertRaises(OSError):
                diagnostics.read_log(link)
            fifo = path / "fifo"
            os.mkfifo(fifo)
            with self.assertRaises(diagnostics.DiagnosticError):
                diagnostics.read_log(fifo)

    def test_summary_file_is_exclusive_private_and_wrong_side_rows_are_discarded(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            source = path / "input.log"
            source.write_bytes(line(row(peer="SECRET")) + line(row("macos")))
            output = path / "result.json"
            diagnostics.main(["--android-log", str(source), "--output", str(output)])
            report = json.loads(output.read_text())
            self.assertEqual(report["accepted_rows"], 1)
            self.assertEqual(report["rejected_diagnostic_rows"], 1)
            self.assertNotIn("SECRET", output.read_text())
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            before = output.read_bytes()
            with self.assertRaises(SystemExit):
                diagnostics.main(["--android-log", str(source), "--output", str(output)])
            self.assertEqual(output.read_bytes(), before)

    def test_combined_inputs_cannot_expand_the_summary_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            android = path / "android.log"
            mac = path / "mac.log"
            android.write_bytes(line(row()))
            mac.write_bytes(line(row("macos")))
            output = path / "output.json"
            with patch.object(diagnostics, "MAX_ROWS", 1):
                with self.assertRaises(SystemExit):
                    diagnostics.main(["--android-log", str(android), "--mac-log", str(mac),
                                      "--output", str(output)])
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
