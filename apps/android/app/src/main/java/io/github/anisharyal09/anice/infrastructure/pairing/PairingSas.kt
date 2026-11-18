// SPDX-License-Identifier: GPL-3.0-or-later
// Defines method-3 commitments and uniform numeric comparison using the shared pairing primitives.
package io.github.anisharyal09.anice.infrastructure.pairing

import io.github.anisharyal09.anice.infrastructure.identity.IdentityCrypto

internal object PairingSas {
    const val DISCOVERY_FLAG = 1

    fun identityCommitment(role: Int, salt: ByteArray, identity: ByteArray): ByteArray {
        require(role in 1..2 && salt.size == 32 && identity.size in 1..2048)
        return PairingCodec.hash(PairingCodec.fields(
            "aniCe sas identity v1".toByteArray(), byteArrayOf(role.toByte()), salt, identity))
    }

    fun commitment(role: Int, rendezvous: ByteArray, serverNonce: ByteArray,
        publicKey: ByteArray, nonce: ByteArray, identityCommitment: ByteArray): ByteArray {
        require(role in 1..2 && rendezvous.size == 16 && serverNonce.size == 32 &&
            publicKey.size == 65 && nonce.size == 32 && identityCommitment.size == 32)
        IdentityCrypto.publicKey(publicKey)
        return PairingCodec.hash(PairingCodec.fields(
            "aniCe sas commitment v1".toByteArray(), byteArrayOf(3), rendezvous, serverNonce,
            byteArrayOf(role.toByte()), publicKey, nonce, identityCommitment))
    }

    fun transcript(rendezvous: ByteArray, serverNonce: ByteArray,
        clientCommitment: ByteArray, serverCommitment: ByteArray,
        clientPublic: ByteArray, serverPublic: ByteArray, clientNonce: ByteArray,
        serverComparisonNonce: ByteArray, clientIdentityCommitment: ByteArray,
        serverIdentityCommitment: ByteArray): ByteArray {
        require(clientCommitment.size == 32 && serverCommitment.size == 32 &&
            !clientPublic.contentEquals(serverPublic))
        require(PairingCodec.equal(clientCommitment, commitment(1, rendezvous, serverNonce,
            clientPublic, clientNonce, clientIdentityCommitment)))
        require(PairingCodec.equal(serverCommitment, commitment(2, rendezvous, serverNonce,
            serverPublic, serverComparisonNonce, serverIdentityCommitment)))
        return PairingCodec.fields(
            "aniCe pairing sas v1".toByteArray(), byteArrayOf(3), rendezvous, serverNonce,
            clientCommitment, serverCommitment, clientPublic, serverPublic, clientNonce,
            serverComparisonNonce, clientIdentityCommitment, serverIdentityCommitment)
    }

    fun bootstrap(shared: ByteArray, transcript: ByteArray): ByteArray {
        val hash = PairingCodec.hash(transcript)
        return PairingCodec.hkdf(shared, hash,
            PairingCodec.fields("aniCe sas bootstrap v1".toByteArray(), hash))
    }

    fun digits(key: ByteArray, transcript: ByteArray): String {
        val hash = PairingCodec.hash(transcript)
        val digitsKey = PairingCodec.derive(key, "sas-digits", hash)
        try {
            for (counter in 0L..0xffff_ffffL) {
                val bytes = PairingCodec.mac(digitsKey, PairingCodec.fields(
                    "aniCe sas digits v1".toByteArray(), hash, PairingCodec.number(counter, 4)))
                decimal(bytes.copyOfRange(0, 4))?.let { return it }
            }
            throw PairingException()
        } finally { digitsKey.fill(0) }
    }

    fun decimal(bytes: ByteArray): String? {
        require(bytes.size == 4)
        val value = PairingCodec.integer(bytes)
        return if (value < 4_294_000_000L) (value % 1_000_000).toString().padStart(6, '0') else null
    }
}
