// SPDX-License-Identifier: GPL-3.0-or-later
// Handles player and Mac output volume snapshots and commands.
package io.github.anisharyal09.anice.features.nowplaying

import io.github.anisharyal09.anice.infrastructure.session.*
import kotlinx.coroutines.*

internal fun MediaController.receiveVolume(kind: String, token: String, message: PlayerVolumeMessage): Boolean {
    if (message.scope == VolumeScope.OUTPUT) return receiveOutputVolume(kind, token, message)
    val link = links[kind] ?: return true
    if (link.token != token) return true
    if (message.kind == 1L) {
        if (!link.volumeCapable) {
            link.volumeCapable = true
            enqueue(kind, MediaSubmission.Volume(PlayerVolumeMessage(1, listOf(Cbor.Integer(1)))))
        }
        return true
    }
    if (kind != active || message.string(0) != subscription || !link.volumeCapable || !acknowledged) return true
    when (message.kind) {
        2L -> {
            val target = playback ?: return true
            if (message.string(1) != target.source || message.string(2) != target.revision) return true
            playerVolume = if ((message.fields[3] as Cbor.Bool).value) message.number(4).toInt() else null
            if (playerVolume == null && volumePreview != null) feedback = "Player volume became unavailable."
            if (playerVolume == null || playerVolume == volumePreview) {
                volumeTimeout?.cancel()
                volumeTimeout = null
                volumePreview = null
            }
            presentationChanged()
        }

        4L -> if (pendingVolume && !pendingOutput && pending == message.number(1)) {
            trace("volume_result command=${message.number(1)} result=${message.number(2)} transport=$active token=$token subscription=${message.string(0)}", clock())
            pending = null
            busy = false
            submitted = false
            pendingVolume = false
            timeout?.cancel()
            timeout = null
            val result = message.number(2)
            if (result != 0L) {
                clearSeek()
                volumeTimeout?.cancel()
                volumeTimeout = null
                volumePreview = null
            }
            feedback = when (result) {
                0L -> ""
                1L -> "Playback changed. Try again."
                2L -> "Player volume unavailable."
                3L, 4L -> "Allow player volume on your Mac."
                5L -> "Player unavailable."
                6L -> "Player busy. Try again."
                else -> "Player volume action failed."
            }
            finishIntents(result == 0L)
            presentationChanged()
            trace("settled command=${message.number(1)} token=$token subscription=${message.string(0)}", clock())
        }
    }
    return true
}


internal fun MediaController.sameOutput(target: RemoteOutputVolume) =
    outputVolume?.let { it.subscription == target.subscription && it.device == target.device && it.revision == target.revision } == true


internal fun MediaController.clearOutputVolume() {
    clearIntents()
    outputTimeout?.cancel()
    outputTimeout = null
    outputPreview = null
    outputVolume = null
    if (pendingOutput) {
        val id = pending
        active?.let { links[it]?.queue?.removeAll { work -> work.commandID == id } }
        pending = null
        pendingVolume = false
        pendingOutput = false
        busy = false
        submitted = false
        timeout?.cancel()
        timeout = null
    }
}


internal fun MediaController.receiveOutputVolume(kind: String, token: String, message: PlayerVolumeMessage): Boolean {
    val link = links[kind] ?: return true
    if (link.token != token) return true
    if (message.kind == 1L) {
        if (!link.outputCapable) {
            link.outputCapable = true
            enqueue(
                kind,
                MediaSubmission.Volume(PlayerVolumeMessage(1, listOf(Cbor.Integer(1)), VolumeScope.OUTPUT))
            )
        }
        return true
    }
    if (kind != active || message.string(0) != subscription || !link.outputCapable || !acknowledged) return true
    when (message.kind) {
        2L -> {
            if (!(message.fields[3] as Cbor.Bool).value) {
                if (outputPreview != null) feedback = "Mac output volume became unavailable."
                clearOutputVolume()
            } else {
                val next = RemoteOutputVolume(
                    message.string(0),
                    message.string(1),
                    message.string(2),
                    message.number(4).toInt()
                )
                if (outputVolume?.let { !sameOutput(next) } == true) {
                    if (outputPreview != null) feedback = "Mac audio output changed."
                    clearOutputVolume()
                }
                outputVolume = next
                if (next.level == outputPreview) {
                    outputTimeout?.cancel()
                    outputTimeout = null
                    outputPreview = null
                }
            }
            presentationChanged()
        }

        4L -> if (pendingOutput && pending == message.number(1)) {
            val result = message.number(2)
            trace("output_result command=${message.number(1)} result=$result token=$token subscription=${message.string(0)}", clock())
            pending = null
            pendingOutput = false
            pendingVolume = false
            busy = false
            submitted = false
            timeout?.cancel()
            timeout = null
            if (result != 0L) {
                outputPreview = null
                outputTimeout?.cancel()
                outputTimeout = null
            }
            feedback = when (result) {
                0L -> ""
                1L -> "Mac audio output changed. Try again."
                2L -> "This Mac output has no volume control."
                5L -> "Mac output unavailable."
                6L -> "Mac is busy. Try again."
                else -> "Mac output volume action failed."
            }
            finishIntents(result == 0L)
            presentationChanged()
            trace("settled command=${message.number(1)} token=$token subscription=${message.string(0)}", clock())
        }
    }
    return true
}


internal fun MediaController.acceptOutputVolume(value: Int, target: RemoteOutputVolume?, expires: Long) {
    val selected = target ?: return
    val kind = active ?: return
    if (!canControlOutputVolume || !sameOutput(selected) || value !in 0..100 || links[kind]?.outputCapable != true) return
    if (busy) {
        outputPreview = value
        retain(MediaController.IntentSlot.OUTPUT_VOLUME, value.toLong(), output = selected, expires = expires)
        return
    }
    if (counter == 4294967295L) {
        retire()
        choose()
        return
    }
    outputPreview = value
    outputTimeout?.cancel()
    val id = ++counter
    pending = id
    pendingOutput = true
    pendingVolume = true
    busy = true
    submitted = false
    feedback = "Processing…"
    trace("input command=$id transport=$kind token=${links[kind]?.token} subscription=$subscription accepted=${expires - 6000}", clock())
    outputTimeout = scope.launch {
        wait(6000)
        if (outputPreview != null && pending == null) feedback =
            "Mac volume was not confirmed. Showing the latest value."
        outputPreview = null
        outputTimeout = null
        presentationChanged()
    }
    timeout = scope.launch {
        wait((expires - clock()).coerceAtLeast(0))
        if (pending == id) {
            val outcomeUnknown = submitted
            pending = null
            pendingOutput = false
            pendingVolume = false
            busy = false
            submitted = false
            outputPreview = null
            clearIntents()
            feedback = if (outcomeUnknown) "Mac volume outcome unknown. It will not be retried."
                else "Mac volume was not sent. Connection is busy. Try again."
            links[kind]?.queue?.removeAll { it.commandID == id }
            presentationChanged()
        }
    }
    enqueue(
        kind,
        MediaSubmission.Volume(
            PlayerVolumeMessage(
                3,
                listOf(
                    Cbor.Text(selected.subscription),
                    Cbor.Integer(id),
                    Cbor.Text(selected.device),
                    Cbor.Text(selected.revision),
                    Cbor.Integer(value.toLong())
                ),
                VolumeScope.OUTPUT
            )
        )
    )
    presentationChanged()
}


internal fun MediaController.acceptVolume(value: Int, target: RemotePlayback?, expires: Long) {
    val snapshot = target ?: return
    val kind = active ?: return
    val sub = subscription ?: return
    if (!acknowledged || !sameTarget(snapshot) || playerVolume == null || links[kind]?.volumeCapable != true || value !in 0..100) return
    if (busy) {
        volumePreview = value
        retain(MediaController.IntentSlot.PLAYER_VOLUME, value.toLong(), target = snapshot, expires = expires)
        return
    }
    if (counter == 4294967295L) {
        retire()
        choose()
        return
    }
    clearSeek()
    volumeTimeout?.cancel()
    volumePreview = value
    val id = ++counter
    pending = id
    pendingVolume = true
    busy = true
    submitted = false
    feedback = "Processing…"
    trace("input command=$id transport=$kind token=${links[kind]?.token} subscription=$subscription accepted=${expires - 6000}", clock())
    volumeTimeout = scope.launch {
        wait(6000)
        if (volumePreview != null && pending == null) feedback =
            "Volume was not confirmed. Showing the player’s latest value."
        volumePreview = null
        volumeTimeout = null
        presentationChanged()
    }
    timeout = scope.launch {
        wait((expires - clock()).coerceAtLeast(0))
        if (pending == id) {
            val outcomeUnknown = submitted
            pending = null
            pendingVolume = false
            busy = false
            submitted = false
            clearSeek()
            volumePreview = null
            clearIntents()
            feedback = if (outcomeUnknown) "Volume outcome unknown. It will not be retried."
                else "Volume was not sent. Connection is busy. Try again."
            links[kind]?.queue?.removeAll { it.commandID == id }
            presentationChanged()
        }
    }
    enqueue(
        kind,
        MediaSubmission.Volume(
            PlayerVolumeMessage(
                3,
                listOf(
                    Cbor.Text(sub),
                    Cbor.Integer(id),
                    Cbor.Text(snapshot.source),
                    Cbor.Text(snapshot.revision),
                    Cbor.Integer(value.toLong())
                )
            )
        )
    )
    presentationChanged()
}
