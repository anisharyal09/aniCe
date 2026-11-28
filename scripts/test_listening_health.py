#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Checks redaction, read-only queries, missing data and process accounting without a device."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("listening_health", Path(__file__).with_name("check-listening-health.py"))
health = importlib.util.module_from_spec(spec)
spec.loader.exec_module(health)

UID = 10591
PID = 123
PACKAGE_ROW = "package:" + health.PACKAGE + " uid:10591\n"
FOCUS_ROW = "  source:binder -- pack: " + health.PACKAGE + " -- client: SECRET -- loss: none -- uid: 10591 -- sdk:36\n"
AUDIO_HEADER = "Audio Focus stack entries (last is top of stack):\n"
PLAYBACK_HEADER = "PlaybackActivityMonitor dump time: 00:00:00\n  players:\n"
NATIVE_HEADER = "    Type Id Active Client(pid/uid) Session Port Id S Flags Format Chn mask SRate ST Usg CT G db L dB R dB VS dB PortVol dB PortMuted Server FrmCnt FrmRdy F Underruns Flushed\n"
NATIVE_ROW = "  7 yes 123/ 10591 4 1502 A 0x001 00000001 00000003 48000 3 1 2 0 0 0 0 0 false 002CC079 1920 960 A 3 0\n"


def proc_stat(pid=PID, ticks=20, started=500, threads=8, state="S", name="private"):
    fields = [state] + ["0"] * 19
    fields[11], fields[12], fields[17], fields[19] = str(ticks), "0", str(threads), str(started)
    return f"{pid} ({name}) " + " ".join(fields)


def proc_snapshot(pid=PID, uid=UID, started=500):
    return proc_stat(pid=pid, started=started) + f"\nName:\tprivate\nPid:\t{pid}\nUid:\t{uid}\t{uid}\t{uid}\t{uid}\n"


def cpu_sample(ticks, started=500, pid=PID, observed=10):
    return {"pid": pid, "process": {"cpu_ticks": ticks, "start_time_ticks": started,
                                    "observed_seconds": observed}}


class ListeningHealthTests(unittest.TestCase):
    def test_audio_filters_uid_and_does_not_retain_metadata(self):
        text = (
            AUDIO_HEADER + FOCUS_ROW + "No external focus policy\n" + PLAYBACK_HEADER +
            "  AudioPlaybackConfiguration piid:1 u/pid:10591/123 state:started "
            "tags=SECRET_TITLE FormatInfo{sampleRate=48000}\n"
            "  AudioPlaybackConfiguration piid:2 u/pid:10592/13 state:started "
            "tags=OTHER_APP FormatInfo{sampleRate=44100}\n"
        )
        result = health.audio_metrics(text, UID, PID)
        self.assertTrue(result["has_audio_focus"])
        self.assertTrue(result["focus_request_present"])
        self.assertEqual(result["tracks"], [{"state": "started", "sample_rate": 48000}])
        self.assertNotIn("SECRET", str(result))
        self.assertNotIn("OTHER_APP", str(result))
        self.assertFalse(health.audio_metrics("", None)["available"])

    def test_focus_logs_and_lost_focus_do_not_look_like_granted_focus(self):
        logs = AUDIO_HEADER + "No external focus policy\nEvents log:\n" + FOCUS_ROW
        self.assertFalse(health.audio_metrics(logs, UID)["has_audio_focus"])
        for loss in ("LOSS", "LOSS_TRANSIENT", "LOSS_TRANSIENT_CAN_DUCK"):
            with self.subTest(loss=loss):
                result = health.audio_metrics(AUDIO_HEADER + FOCUS_ROW.replace("loss: none", "loss: " + loss), UID)
                self.assertTrue(result["focus_request_present"])
                self.assertFalse(result["has_audio_focus"])
        result = health.audio_metrics(AUDIO_HEADER + FOCUS_ROW.replace("loss: none", "loss: VENDOR_SECRET"), UID)
        self.assertIsNone(result["has_audio_focus"])
        self.assertNotIn("SECRET", json.dumps(result))
        self.assertIsNone(health.audio_metrics("vendor format", UID)["has_audio_focus"])
        self.assertFalse(health.audio_metrics(AUDIO_HEADER + FOCUS_ROW, UID + 1)["has_audio_focus"])

    def test_audio_state_is_allowlisted_and_matches_the_current_process(self):
        text = PLAYBACK_HEADER
        text += "  AudioPlaybackConfiguration u/pid:10591/123 state:secret_title sampleRate=0\n"
        text += "  AudioPlaybackConfiguration u/pid:10591/456 state:started sampleRate=48000\n"
        result = health.audio_metrics(text, UID, PID)
        self.assertEqual(result["tracks"], [{"state": "unknown", "sample_rate": None}])
        self.assertNotIn("secret_title", json.dumps(result))
        self.assertEqual(health.audio_metrics("Events log:\n" + text.split("  players:\n")[1], UID)["tracks"], [])
        self.assertFalse(health.audio_metrics("PlaybackActivityMonitor dump time:\nVENDOR FORMAT", UID)["tracks_available"])

    def test_wifi_retains_only_numeric_radio_fields(self):
        result = health.wifi_metrics("SSID: private-network BSSID: 01:23:45:67:89:ab "
                                     "Frequency: 5180 RSSI: -55 Tx Link speed: 866 Rx Link speed: 650")
        self.assertEqual(result["frequency_mhz"], 5180)
        self.assertEqual(result["rssi_dbm"], -55)
        self.assertEqual(result["tx_link_mbps"], 866)
        self.assertNotIn("private-network", str(result))
        self.assertNotIn("01:23", str(result))
        self.assertIsNone(health.wifi_metrics("")["rssi_dbm"])

    def test_wifi_does_not_claim_sentinel_duplicate_or_missing_metrics(self):
        result = health.wifi_metrics('SSID: "RSSI: -44 Frequency: 2412" RSSI: -127 Frequency: 5180')
        self.assertIsNone(result["rssi_dbm"])
        self.assertEqual(result["frequency_mhz"], 5180)
        self.assertIsNone(health.wifi_metrics("RSSI: -50 RSSI: -60")["rssi_dbm"])
        self.assertFalse(health.wifi_metrics("Permission denied")["available"])
        self.assertIsNone(health.wifi_metrics("Tx Link speed: " + "9" * 100)["tx_link_mbps"])

    def test_wifi_current_link_rates_do_not_include_max_supported_capabilities(self):
        text = ('SSID: "Tx Link speed: 999" Frequency: 5745 RSSI: -48 '
                'Link speed: 585Mbps Tx Link speed: 585Mbps Max Supported Tx Link speed: 866Mbps '
                'Rx Link speed: 390Mbps Max Supported Rx Link speed: 866Mbps')
        result = health.wifi_metrics(text)
        self.assertEqual(result["tx_link_mbps"], 585)
        self.assertEqual(result["rx_link_mbps"], 390)
        capabilities = health.wifi_metrics(
            "Max Supported Tx Link speed: 866Mbps Max Supported Rx Link speed: 866Mbps")
        self.assertIsNone(capabilities["tx_link_mbps"])
        self.assertIsNone(capabilities["rx_link_mbps"])
        self.assertFalse(capabilities["available"])
        self.assertIsNone(health.wifi_metrics(text + " Tx Link speed: 400Mbps")["tx_link_mbps"])

    def test_missing_process_data_and_pid_replacement_have_no_fake_delta(self):
        self.assertEqual(health.thread_metrics("Permission denied"), {"available": False})
        previous = cpu_sample(50)
        current = cpu_sample(65, observed=20)
        self.assertEqual(health.delta(previous, current), {"cpu_ticks": 15, "elapsed_seconds": 10, "native_tracks": []})
        for changed in (cpu_sample(100, pid=456, observed=20),
                        cpu_sample(100, started=600, observed=20),
                        cpu_sample(2, observed=20), cpu_sample(100, observed=10),
                        {"pid": PID, "process": {"cpu_ticks": 100}}):
            self.assertIsNone(health.delta(previous, changed))
        self.assertIsNone(health.delta(None, current))

    def test_native_deltas_only_compare_the_same_surviving_track_and_process(self):
        previous, current = cpu_sample(50), cpu_sample(65, observed=20)
        previous["native_tracks"] = {"tracks": [{"track_id": 7, "reported_underruns": 3},
                                               {"track_id": 8, "reported_underruns": 10}]}
        current["native_tracks"] = {"tracks": [{"track_id": 7, "reported_underruns": 5},
                                              {"track_id": 8, "reported_underruns": 2},
                                              {"track_id": 9, "reported_underruns": 100}]}
        self.assertEqual(health.delta(previous, current)["native_tracks"],
                         [{"track_id": 7, "reported_underruns": 2}])
        current["process"]["start_time_ticks"] += 1
        self.assertIsNone(health.delta(previous, current))

    def test_package_and_pid_are_exact(self):
        self.assertEqual(health.package_uid(PACKAGE_ROW), UID)
        self.assertIsNone(health.package_uid("package:io.github.anisharyal09.anice uid:1"))
        self.assertIsNone(health.package_uid(PACKAGE_ROW + PACKAGE_ROW))
        self.assertIsNone(health.package_uid(PACKAGE_ROW.replace(health.PACKAGE, health.PACKAGE + ".other")))
        self.assertEqual(health.process_id("123\n"), 123)
        for invalid in ("123 456", "", "0", "-1", "9" * 100, "１２３"):
            self.assertIsNone(health.process_id(invalid))

    def test_cli_requires_explicit_stage_and_bounds_sampling(self):
        args = health.parse_args(["--serial", "emulator-5580", "--stage", "screen-off", "--output", "new.json"])
        self.assertEqual(args.samples, 1)
        self.assertFalse(args.native_tracks)
        self.assertIsNone(args.mode)
        with contextlib.redirect_stderr(io.StringIO()):
            for serial in ("x;rm", "-s", ".phone", ""):
                with self.subTest(serial=serial), self.assertRaises(SystemExit):
                    health.parse_args(["--serial", serial, "--stage", "background", "--output", "new.json"])
            for options in (["--samples", "1000"], ["--samples", "0"], ["--interval", "nan"],
                            ["--interval", "inf"], ["--interval", "0"], ["--mode", "invalid"]):
                with self.subTest(options=options), self.assertRaises(SystemExit):
                    health.parse_args(["--serial", "phone", "--stage", "background", "--output", "new.json", *options])

    def test_native_track_filter_discards_other_apps_and_event_history(self):
        text = "  2 Tracks of which 2 are active\n" + NATIVE_HEADER + NATIVE_ROW
        text += NATIVE_ROW.replace("7 yes 123/ 10591", "8 yes 456/ 10592")
        text += "  Local log:\n" + NATIVE_HEADER + NATIVE_ROW
        text += "11-20 01:00:00 removeTrack 3 no 123/ 10591 4 960 2 40\n"
        result = health.native_track_metrics(text, UID, PID)
        self.assertEqual(result["tracks"], [{"track_id": 7, "active": True, "sample_rate": 48000,
                                             "buffer_frames": 1920, "ready_frames": 960,
                                             "reported_underruns": 3, "flushed_frames": 0}])
        self.assertNotIn("123", str(result))

    def test_native_layout_changes_never_guess_counter_columns(self):
        text = "1 Tracks of which 1 are active\n" + NATIVE_HEADER + "F1 " + NATIVE_ROW
        self.assertEqual(health.native_track_metrics(text, UID)["tracks"][0]["reported_underruns"], 3)
        changed = text.replace("Server FrmCnt", "VendorColumn Server FrmCnt").replace("false 002CC079", "false 777 002CC079")
        result = health.native_track_metrics(changed, UID)["tracks"][0]
        self.assertTrue(result["active"])
        self.assertIsNone(result["buffer_frames"])
        self.assertIsNone(result["reported_underruns"])
        self.assertFalse(health.native_track_metrics("Local log:\n" + NATIVE_HEADER + NATIVE_ROW, UID)["available"])
        self.assertEqual(health.native_track_metrics(text, UID, PID + 1)["tracks"], [])

    def test_native_static_patch_and_fast_static_rows_keep_current_table_accounting(self):
        foreign = NATIVE_ROW.replace("7 yes 123/ 10591", "8 no 456/ 10592")
        for prefix in ("S ", "P ", "F1 S ", "F2 P "):
            with self.subTest(prefix=prefix):
                text = "2 Tracks of which 1 are active\n" + NATIVE_HEADER
                text += prefix + foreign + NATIVE_ROW
                result = health.native_track_metrics(text, UID, PID)
                self.assertTrue(result["available"])
                self.assertEqual([track["track_id"] for track in result["tracks"]], [7])
                self.assertEqual(result["tracks"][0]["buffer_frames"], 1920)
                own = health.native_track_metrics(
                    "1 Tracks of which 1 are active\n" + NATIVE_HEADER + prefix + NATIVE_ROW, UID, PID)
                self.assertTrue(own["available"])
                self.assertEqual(own["tracks"][0]["reported_underruns"], 3)
        self.assertFalse(health.native_track_metrics(
            "1 Tracks of which 1 are active\n" + NATIVE_HEADER + "VENDOR " + NATIVE_ROW, UID, PID
        )["available"])

    def test_native_samsung_trailing_columns_and_known_counter_markers_are_redacted(self):
        header = NATIVE_HEADER.rstrip() + " BitPerfect InternalMute L Vol R Vol Drain State CType Latency\n"
        for marker in ("", "*", "<", "?"):
            with self.subTest(marker=marker):
                row = NATIVE_ROW.replace("1920 960 A 3 0", "1920r 960 A 3" + marker + " 0")
                row = row.rstrip() + " false false 0 0 SECRET_DRAIN SECRET_SOURCE SECRET_LATENCY\n"
                result = health.native_track_metrics(
                    "1 Tracks of which 1 are active\n" + header + row, UID, PID)
                self.assertTrue(result["available"])
                track = result["tracks"][0]
                self.assertEqual(track["buffer_frames"], 1920)
                self.assertEqual(track["reported_underruns"], 3)
                self.assertEqual(track["flushed_frames"], 0)
                self.assertNotIn("SECRET", json.dumps(result))
        for buffer, underruns in (("1920e", "3"), ("1920secret", "3secret"), ("1920", "3r")):
            with self.subTest(buffer=buffer, underruns=underruns):
                row = NATIVE_ROW.replace("1920 960 A 3 0", buffer + " 960 A " + underruns + " 0")
                track = health.native_track_metrics(
                    "1 Tracks of which 1 are active\n" + NATIVE_HEADER + row, UID, PID)["tracks"][0]
                if buffer != "1920":
                    self.assertIsNone(track["buffer_frames"])
                if underruns != "3":
                    self.assertIsNone(track["reported_underruns"])

    def test_malformed_current_track_table_is_not_reported_as_an_empty_available_table(self):
        text = "1 Tracks of which 1 are active\n" + NATIVE_HEADER + "VENDOR_FORMAT private metadata\n"
        result = health.native_track_metrics(text, UID)
        self.assertFalse(result["available"])
        self.assertEqual(result["tracks"], [])
        self.assertFalse(health.native_track_metrics(
            "1 Tracks of which 1 are active\n" + NATIVE_HEADER.replace("FrmRdy", "VendorReady") + NATIVE_ROW, UID
        )["available"])
        self.assertFalse(health.native_track_metrics(
            "1 Tracks of which 1 are active\n" + NATIVE_HEADER, UID
        )["available"])

    def test_snapshot_uses_only_read_only_queries_and_never_retains_raw_content(self):
        called = []

        def query(adb, serial, arguments):
            called.append(arguments)
            if arguments == health.PACKAGE_QUERY:
                return health.Query("ok", PACKAGE_ROW)
            if arguments == health.PID_QUERY:
                return health.Query("ok", "123\n")
            return health.Query("unavailable")

        with patch.object(health, "command", query):
            result = health.snapshot("adb", "phone", UID, "background", native_tracks=True)
        self.assertEqual(result["pid"], 123)
        self.assertTrue(result["preview_running"])
        self.assertEqual(called, [
            health.PACKAGE_QUERY, health.PID_QUERY,
            ["shell", "cat", "/proc/123/stat", "/proc/123/status"],
            ["shell", "dumpsys", "power"],
            ["shell", "dumpsys", "audio"],
            ["shell", "cmd", "wifi", "status"],
            ["shell", "dumpsys", "media.audio_flinger"],
        ])

    def test_heavy_native_query_is_opt_in_and_pid_failure_is_unknown(self):
        responses = {
            tuple(health.PACKAGE_QUERY): health.Query("ok", PACKAGE_ROW),
            tuple(health.PID_QUERY): health.Query("failed"),
        }
        with patch.object(health, "command", side_effect=lambda _adb, _serial, arguments:
                          responses.get(tuple(arguments), health.Query("unavailable"))) as query:
            result = health.snapshot("adb", "phone", UID, "foreground")
        self.assertIsNone(result["preview_running"])
        self.assertIsNone(result["pid"])
        self.assertNotIn("native_tracks", result["queries"])
        self.assertFalse(any("media.audio_flinger" in call.args[2] for call in query.call_args_list))

    def test_snapshot_stops_on_uid_change_and_fences_process_replacement_during_queries(self):
        with patch.object(health, "command", return_value=health.Query("ok", PACKAGE_ROW.replace("10591", "10592"))) as query:
            result = health.snapshot("adb", "phone", UID, "transfer")
        self.assertFalse(result["preview_verified"])
        self.assertEqual(query.call_count, 1)
        process_rows = iter((proc_snapshot(), proc_snapshot(started=600)))

        def query(adb, serial, arguments):
            if arguments == health.PACKAGE_QUERY:
                return health.Query("ok", PACKAGE_ROW)
            if arguments == health.PID_QUERY:
                return health.Query("ok", "123\n")
            if arguments == ["shell", "cat", "/proc/123/stat", "/proc/123/status"]:
                return health.Query("ok", next(process_rows))
            return health.Query("ok", "")

        with patch.object(health, "command", query):
            result = health.snapshot("adb", "phone", UID, "foreground")
        self.assertFalse(result["process"]["available"])
        self.assertFalse(result["audio"]["available"])
        self.assertEqual(result["queries"]["process_check"], "process_changed")

    def test_existing_output_is_not_overwritten_or_followed(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "existing.json"
            output.write_text("user content")
            linked = Path(directory) / "linked.json"
            linked.symlink_to(output)
            dangling = Path(directory) / "dangling.json"
            dangling.symlink_to(Path(directory) / "missing")
            for path in (output, linked, dangling):
                with patch.object(health, "find_adb") as find, patch.object(health, "command") as query:
                    with self.assertRaises(SystemExit):
                        health.main(["--serial", "phone", "--stage", "background", "--output", str(path)])
                    query.assert_not_called()
                    find.assert_not_called()
            self.assertEqual(output.read_text(), "user content")

    def test_interrupted_run_keeps_partial_report_without_claiming_completion(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "new.json"
            with patch.object(health, "find_adb", return_value="adb"), \
                    patch.object(health, "command", return_value=health.Query("ok", PACKAGE_ROW)), \
                    patch.object(health, "snapshot", side_effect=[
                        {"pid": 1, "process": {"available": False}, "query_seconds": 0},
                        KeyboardInterrupt(),
                    ]), patch.object(health.time, "sleep"):
                with self.assertRaises(KeyboardInterrupt):
                    health.main(["--serial", "phone", "--stage", "background", "--samples", "2",
                                 "--output", str(output)])
            report = json.loads(output.read_text())
            self.assertFalse(report["complete"])
            self.assertEqual(len(report["samples"]), 1)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)

    def test_completed_run_has_safe_query_rest_and_user_label_without_device_identifiers(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "new.json"
            sample = {"pid": PID, "process": {"available": False}, "query_seconds": 90}
            with patch.object(health, "find_adb", return_value="adb"), \
                    patch.object(health, "command", return_value=health.Query("ok", PACKAGE_ROW)), \
                    patch.object(health, "snapshot", side_effect=[dict(sample), dict(sample)]) as snapshot, \
                    patch.object(health.time, "sleep") as sleep, contextlib.redirect_stdout(io.StringIO()):
                health.main(["--serial", "secret-serial", "--stage", "background", "--samples", "2",
                             "--mode", "lower-delay", "--output", str(output)])
            sleep.assert_called_once_with(5)
            report = json.loads(output.read_text())
            self.assertTrue(report["complete"])
            self.assertEqual(report["buffering_mode"], "lower-delay")
            self.assertFalse(report["native_tracks_requested"])
            self.assertNotIn("secret-serial", output.read_text())
            self.assertFalse(snapshot.call_args.args[-1])

    def test_missing_preview_does_not_create_report_or_query_production(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "new.json"
            with patch.object(health, "find_adb", return_value="adb"), \
                    patch.object(health, "command", return_value=health.Query("unavailable")) as query:
                with self.assertRaises(SystemExit):
                    health.main(["--serial", "phone", "--stage", "foreground", "--output", str(output)])
            self.assertFalse(output.exists())
            query.assert_called_once_with("adb", "phone", health.PACKAGE_QUERY)

    def test_lost_preview_verification_saves_an_incomplete_report_and_stops_sampling(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "new.json"
            with patch.object(health, "find_adb", return_value="adb"), \
                    patch.object(health, "command", return_value=health.Query("ok", PACKAGE_ROW)), \
                    patch.object(health, "snapshot", return_value={
                        "preview_verified": False, "pid": None, "process": {"available": False},
                        "query_seconds": 0,
                    }) as snapshot, patch.object(health.time, "sleep") as sleep:
                with self.assertRaises(SystemExit):
                    health.main(["--serial", "phone", "--stage", "foreground", "--samples", "2", "--output", str(output)])
            self.assertEqual(snapshot.call_count, 1)
            sleep.assert_not_called()
            report = json.loads(output.read_text())
            self.assertFalse(report["complete"])
            self.assertEqual(len(report["samples"]), 1)

    def test_proc_stat_uses_numeric_offsets_after_the_last_parenthesis(self):
        result = health.thread_metrics(proc_stat(name="name ) SECRET"))
        self.assertEqual(result, {"available": True, "cpu_ticks": 20, "threads": 8,
                                  "start_time_ticks": 500, "state": "S"})
        self.assertNotIn("SECRET", str(result))
        self.assertFalse(health.thread_metrics(proc_stat(pid=456), PID)["available"])
        self.assertFalse(health.thread_metrics(proc_stat(threads=0))["available"])
        self.assertFalse(health.thread_metrics(proc_stat(ticks=-1))["available"])
        self.assertEqual(health.thread_metrics(proc_stat(state="SECRET"))["state"], "unknown")

    def test_process_uid_is_checked_before_any_cpu_accounting(self):
        self.assertTrue(health.process_metrics(proc_snapshot(), PID, UID)["available"])
        for value in (proc_snapshot(uid=UID + 1), proc_snapshot(pid=PID + 1),
                      proc_stat(), proc_snapshot().replace(f"\t{UID}\t{UID}", f"\t{UID}\t{UID + 1}", 1)):
            with self.subTest(snapshot=value):
                self.assertFalse(health.process_metrics(value, PID, UID)["available"])

    def test_output_race_does_not_overwrite_a_late_user_file(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "new.json"

            def query(adb, serial, arguments):
                output.write_text("created concurrently")
                return health.Query("ok", PACKAGE_ROW)

            with patch.object(health, "find_adb", return_value="adb"), patch.object(health, "command", query):
                with self.assertRaises(FileExistsError):
                    health.main(["--serial", "phone", "--stage", "foreground", "--output", str(output)])
            self.assertEqual(output.read_text(), "created concurrently")

    def test_adb_discovery_uses_existing_sdk_without_installing(self):
        with tempfile.TemporaryDirectory() as directory:
            sdk = Path(directory) / "sdk"
            adb = sdk / "platform-tools/adb"
            adb.parent.mkdir(parents=True)
            adb.write_text("fixture")
            adb.chmod(0o700)
            with patch.object(health.shutil, "which", return_value=None), \
                    patch.dict(os.environ, {"ANDROID_HOME": str(sdk)}, clear=True):
                self.assertEqual(health.find_adb(), str(adb))

    def test_command_reports_nonzero_errors_without_saving_stderr_or_partial_text(self):
        # These mock adb executables run on the host. They never contact a phone.
        with tempfile.TemporaryDirectory() as directory:
            adb = Path(directory) / "adb-fixture"
            adb.write_text("#!/bin/sh\nprintf 'PRIVATE STDERR' >&2\nexit 1\n")
            adb.chmod(0o700)
            self.assertEqual(health.command(str(adb), "phone", health.PID_QUERY), health.Query("failed"))
            adb.write_text("#!/bin/sh\nprintf 'Permission Denial: PRIVATE CONTENT\\n'\n")
            self.assertEqual(health.command(str(adb), "phone", health.PID_QUERY), health.Query("unavailable"))
            adb.write_text("#!/bin/sh\nprintf '123\\n'\n")
            self.assertEqual(health.command(str(adb), "phone", health.PID_QUERY), health.Query("ok", "123\n"))

    def test_command_memory_and_runtime_bounds_discard_partial_output(self):
        with tempfile.TemporaryDirectory() as directory:
            adb = Path(directory) / "adb-fixture"
            adb.write_text("#!/bin/sh\nprintf '1234567890\\n'\n")
            adb.chmod(0o700)
            with patch.object(health, "MAX_QUERY_BYTES", 5):
                self.assertEqual(health.command(str(adb), "phone", health.PID_QUERY), health.Query("output_limit"))
            # A shell builtin blocks without creating a descendant that survives kill().
            adb.write_text("#!/bin/sh\nwhile :; do :; done\n")
            with patch.object(health, "QUERY_TIMEOUT", 0.05):
                self.assertEqual(health.command(str(adb), "phone", health.PID_QUERY), health.Query("timeout"))

    def test_command_keeps_explicit_target_as_separate_arguments(self):
        with patch.object(health.subprocess, "Popen", side_effect=OSError("secret path")) as child:
            result = health.command("/adb with spaces", "phone", health.PID_QUERY)
        self.assertEqual(result, health.Query("unavailable"))
        child.assert_called_once_with(
            ["/adb with spaces", "-s", "phone", *health.PID_QUERY],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )


if __name__ == "__main__":
    unittest.main()
