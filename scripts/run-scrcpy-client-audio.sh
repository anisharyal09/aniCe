#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs the pinned scrcpy audio experiment with its matching local server and resources.
set -eu
experiment_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
experiment_source="$experiment_root/build/scrcpy-client-audio"
experiment_revision=0066c8425827682c4791232f0e248d20e53b7ee2
if [ ! -d "$experiment_source/.git" ]; then
    echo "Missing experimental checkout; see docs/features/CALL_AUDIO_ADB.md." >&2
    exit 2
fi
if [ "$(git -C "$experiment_source" rev-parse HEAD)" != "$experiment_revision" ]; then
    echo "Unexpected scrcpy revision; expected $experiment_revision." >&2
    exit 2
fi
if [ ! -x "$experiment_source/x/app/scrcpy" ] || [ ! -f "$experiment_source/x/server/scrcpy-server" ]; then
    echo "Build both the experimental client and server; see docs/features/CALL_AUDIO_ADB.md." >&2
    exit 2
fi
export SCRCPY_SERVER_PATH="$experiment_source/x/server/scrcpy-server"
export SCRCPY_ICON_DIR="$experiment_source/app/data"
exec "$experiment_source/x/app/scrcpy" "$@"
