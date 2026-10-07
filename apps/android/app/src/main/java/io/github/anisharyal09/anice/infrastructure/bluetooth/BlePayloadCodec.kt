// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.infrastructure.bluetooth

object BlePayloadCodec {
    const val SERVICE_UUID = "414E4953-4853-4149-4A49-4C4365090901"
    const val CHARACTERISTIC_UUID = "414E4953-4853-4149-4A49-4C4365090902"
    data class Payload(val flags: Int, val nonce: ByteArray)
    fun decode(bytes: ByteArray): Payload {
        require(bytes.size == 20) { "length" }
        require(bytes[0] == 0.toByte() && bytes[1] == 1.toByte()) { "version" }
        return Payload(((bytes[2].toInt() and 255) shl 8) or (bytes[3].toInt() and 255), bytes.copyOfRange(4, 20))
    }
    fun encode(nonce: ByteArray, flags: Int = 0): ByteArray {
        require(nonce.size == 16 && flags in 0..65535)
        return byteArrayOf(0, 1, (flags shr 8).toByte(), flags.toByte()) + nonce
    }
}

enum class DiscoveryState { idle, permissionNeeded, bluetoothOff, discovering, found, connecting, ready, failed }
enum class RecoveryReason { none, permission, permanentDenial, bluetoothDisabled, locationServicesDisabled, unsupported, retry }
enum class ConnectionStage { none, connecting, services, reading, disconnecting }
data class DiscoveryCandidate(val rowId: Long, val number: Int)
data class DiscoverySnapshot(
    val state: DiscoveryState = DiscoveryState.idle,
    val message: String = "Start discovery on your Mac, then scan here. Nearby devices are not trusted.",
    val recovery: RecoveryReason = RecoveryReason.none,
    val candidates: List<DiscoveryCandidate> = emptyList(),
    val scanning: Boolean = false,
    val busy: Boolean = false,
    val remainingSeconds: Int = 0,
    val stage: ConnectionStage = ConnectionStage.none,
)
