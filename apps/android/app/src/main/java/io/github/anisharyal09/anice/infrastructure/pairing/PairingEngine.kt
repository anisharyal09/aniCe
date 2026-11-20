// SPDX-License-Identifier: GPL-3.0-or-later
// Authenticates Mac pairing invitations and exchanges mutual approval and trust receipts.
package io.github.anisharyal09.anice.infrastructure.pairing

import io.github.anisharyal09.anice.infrastructure.identity.*
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.spec.ECGenParameterSpec
import javax.crypto.KeyAgreement

/** Confined to the pairing worker. GATT/UI callbacks never perform expensive crypto. */
class PairingEngine(
    private val method: PairingMethod,
    private val qr: PairingQR?,
    private var pin: ByteArray,
    private val identity: IdentityService,
    private val store: PeerTrustStore,
    private val send: (ByteArray) -> Unit,
    private val event: (String, DeviceIdentity?) -> Unit,
    private val comparison: (String) -> Unit = {},
    private val isCurrent: () -> Boolean = { true },
) {
    private val local = identity.getOrCreateIdentity().identity
    private val localBytes = local.toJson().toString().toByteArray()
    private var stage = 0
    private var rendezvous = byteArrayOf()
    private var serverNonce = byteArrayOf()
    private var clientNonce = byteArrayOf()
    private var clientPublic = byteArrayOf()
    private var serverPublic = byteArrayOf()
    private var ephemeral: KeyPair? = null
    private var pake: ByteArray? = null
    private var channel: PairingChannel? = null
    private var peer: DeviceIdentity? = null
    private var peerBytes: ByteArray? = null
    private var proofVerified = false
    private var localApproved = false
    private var peerApproved = false
    private var prepared = false
    private var receiptSent = false
    private var receiptReceived = false
    private var clientCommitment = byteArrayOf()
    private var serverCommitment = byteArrayOf()
    private var serverComparisonNonce = byteArrayOf()
    private var localIdentitySalt = byteArrayOf()
    private var clientIdentityCommitment = byteArrayOf()
    private var serverIdentityCommitment = byteArrayOf()
    private var localCompared = false
    private var peerCompared = false
    private var identitySent = false
    private var comparisonCode: String? = null

    fun receive(data: ByteArray) {
        try { receiveMessage(data) } catch (error: Exception) {
            if (method == PairingMethod.SAS) close()
            throw error
        }
    }

    private fun receiveMessage(data: ByteArray) {
        check(stage >= 0 && (method != PairingMethod.SAS || isCurrent()))
        if (method == PairingMethod.SAS && stage != 3) {
            receiveSasBootstrap(data)
            return
        }
        when (stage) {
            0 -> {
                val f = PairingCodec.unpack(data, 2, 3)
                require(
                    f[0].contentEquals(byteArrayOf(method.wire.toByte())) &&
                        f[1].size == 16 &&
                        f[2].size == 32
                )
                if (qr != null) require(f[1].contentEquals(qr.rendezvous))
                rendezvous = f[1]
                serverNonce = f[2]
                clientNonce = PairingCodec.random(32)
                if (method == PairingMethod.QR) {
                    ephemeral =
                        KeyPairGenerator.getInstance("EC").run {
                            initialize(ECGenParameterSpec("secp256r1"))
                            generateKeyPair()
                        }
                    clientPublic = IdentityCrypto.exportPublicKey(ephemeral!!.public)
                } else {
                    val out = PairingCodec.parse(NativePake.invoke(2, pin))
                    require(out.size == 2)
                    pake = out[0]
                    clientPublic = out[1]
                }
                stage = 1
                event("authenticating", null)
                send(
                    PairingCodec.message(
                        3,
                        byteArrayOf(method.wire.toByte()),
                        rendezvous,
                        clientNonce,
                        clientPublic,
                    )
                )
            }
            1 -> {
                val f = PairingCodec.unpack(data, 4, 3)
                require(f[0].contentEquals(serverNonce))
                serverPublic = f[1]
                val t = transcript()
                val h = PairingCodec.hash(t)
                val key: ByteArray
                val finish: ByteArray
                if (method == PairingMethod.QR) {
                    require(serverPublic.size == 65)
                    val shared =
                        KeyAgreement.getInstance("ECDH").run {
                            init(ephemeral!!.private)
                            doPhase(IdentityCrypto.publicKey(serverPublic), true)
                            generateSecret()
                        }
                    key =
                        PairingCodec.hkdf(
                            shared,
                            qr!!.secret,
                            PairingCodec.fields("aniCe qr bootstrap v1".toByteArray(), h),
                        )
                    shared.fill(0)
                    ephemeral = null
                    require(
                        PairingCodec.equal(
                            f[2],
                            PairingCodec.mac(PairingCodec.derive(key, "server-auth", h), t),
                        )
                    )
                    finish = PairingCodec.mac(PairingCodec.derive(key, "client-auth", h), t)
                } else {
                    require(f[2].isEmpty())
                    val out = PairingCodec.parse(NativePake.invoke(4, pake!!, pin, f[1], context()))
                    pake = null
                    pin.fill(0)
                    require(out.size == 2)
                    finish = out[0]
                    key = PairingCodec.hkdf(out[1], h, "aniCe pin bootstrap v1".toByteArray())
                    out[1].fill(0)
                }
                channel = PairingChannel(key, t, false)
                stage = 2
                send(PairingCodec.message(5, finish))
            }
            2 -> {
                val f = PairingCodec.unpack(data, 6, 1)
                require(PairingCodec.equal(f[0], channel!!.confirm()))
                stage = 3
                send(channel!!.seal(PairingCodec.message(10, localBytes)))
            }
            else -> {
                val c = channel ?: throw PairingException()
                val plain = c.open(data)
                when (plain.firstOrNull()?.toInt()) {
                    10 -> {
                        require(peer == null)
                        if (method == PairingMethod.SAS) require(localCompared && peerCompared && identitySent)
                        val f = PairingCodec.unpack(plain, 10, if (method == PairingMethod.SAS) 2 else 1)
                        require(f[0].size <= 2048)
                        if (method == PairingMethod.SAS) {
                            require(PairingCodec.equal(
                                PairingSas.identityCommitment(2, f[1], f[0]), serverIdentityCommitment))
                        }
                        val record =
                            DeviceIdentity.fromJson(
                                org.json.JSONObject(String(f[0], Charsets.UTF_8))
                            )
                        require(record.platform == "macos" && record.deviceId != local.deviceId)
                        if (qr != null)
                            require(
                                PairingCodec.equal(
                                    PairingCodec.hash(
                                        IdentityCrypto.decodeBase64(record.publicKey)
                                    ),
                                    qr.fingerprint,
                                )
                            )
                        peer = record
                        peerBytes = f[0]
                        val signed = identity.sign(PairingCodec.proof(c.hash, localBytes, f[0], 1))
                        require(signed.snapshot.identity == local)
                        if (method == PairingMethod.SAS) check(isCurrent())
                        send(c.seal(PairingCodec.message(11, signed.signature)))
                    }
                    11 -> {
                        require(!proofVerified && peer != null)
                        val f = PairingCodec.unpack(plain, 11, 1)
                        require(
                            IdentityCrypto.verify(
                                IdentityCrypto.decodeBase64(peer!!.publicKey),
                                PairingCodec.proof(c.hash, localBytes, peerBytes!!, 2),
                                f[0],
                            )
                        )
                        proofVerified = true
                        if (method == PairingMethod.SAS) {
                            require(localCompared && peerCompared)
                            approve()
                        } else event("approval", peer)
                    }
                    12 -> {
                        PairingCodec.unpack(plain, 12, 0)
                        require(proofVerified && !peerApproved)
                        peerApproved = true
                        prepare()
                    }
                    13 -> {
                        val f = PairingCodec.unpack(plain, 13, 1)
                        require(prepared && !receiptReceived)
                        val hash = trustHash()
                        if (method == PairingMethod.SAS) check(isCurrent())
                        store.activate(peer!!.deviceId, hash, f[0])
                        receiptReceived = true
                        complete()
                    }
                    14 -> {
                        PairingCodec.unpack(plain, 14, 0)
                        close()
                        event("cancelled", null)
                    }
                    15 -> {
                        PairingCodec.unpack(plain, 15, 0)
                        require(method == PairingMethod.SAS && comparisonCode != null &&
                            !peerCompared && !identitySent)
                        peerCompared = true
                        discloseIdentity()
                    }
                    else -> throw PairingException()
                }
            }
        }
    }

    private fun receiveSasBootstrap(data: ByteArray) {
        when (stage) {
            0 -> {
                val fields = PairingCodec.unpack(data, 2, 3)
                require(fields[0].contentEquals(byteArrayOf(3)) &&
                    fields[1].size == 16 && fields[2].size == 32)
                rendezvous = fields[1]
                serverNonce = fields[2]
                localIdentitySalt = PairingCodec.random(32)
                clientIdentityCommitment = PairingSas.identityCommitment(1, localIdentitySalt, localBytes)
                clientNonce = PairingCodec.random(32)
                ephemeral = KeyPairGenerator.getInstance("EC").run {
                    initialize(ECGenParameterSpec("secp256r1")); generateKeyPair()
                }
                clientPublic = IdentityCrypto.exportPublicKey(ephemeral!!.public)
                clientCommitment = PairingSas.commitment(1, rendezvous, serverNonce,
                    clientPublic, clientNonce, clientIdentityCommitment)
                stage = 10
                event("authenticating", null)
                send(PairingCodec.message(3, byteArrayOf(3), rendezvous, clientCommitment))
            }
            10 -> {
                val fields = PairingCodec.unpack(data, 4, 2)
                require(fields[0].contentEquals(serverNonce) && fields[1].size == 32)
                serverCommitment = fields[1]
                stage = 11
                send(PairingCodec.message(8, clientPublic, clientNonce, clientIdentityCommitment))
            }
            11 -> {
                val fields = PairingCodec.unpack(data, 9, 3)
                serverPublic = fields[0]
                serverComparisonNonce = fields[1]
                serverIdentityCommitment = fields[2]
                val transcript = sasTranscript()
                val shared = KeyAgreement.getInstance("ECDH").run {
                    init(ephemeral!!.private)
                    doPhase(IdentityCrypto.publicKey(serverPublic), true)
                    generateSecret()
                }
                val key = try { PairingSas.bootstrap(shared, transcript) } finally { shared.fill(0) }
                ephemeral = null
                comparisonCode = PairingSas.digits(key, transcript)
                channel = PairingChannel(key, transcript, false)
                stage = 2
                send(PairingCodec.message(5, PairingCodec.mac(
                    PairingCodec.derive(key, "client-auth", PairingCodec.hash(transcript)), transcript)))
            }
            2 -> {
                val fields = PairingCodec.unpack(data, 6, 1)
                require(PairingCodec.equal(fields[0], channel!!.confirm()))
                stage = 3
                comparison(requireNotNull(comparisonCode))
                event("comparison", null)
            }
            else -> throw PairingException()
        }
    }

    private fun sasTranscript() = PairingSas.transcript(rendezvous, serverNonce,
        clientCommitment, serverCommitment, clientPublic, serverPublic, clientNonce,
        serverComparisonNonce, clientIdentityCommitment, serverIdentityCommitment)

    fun confirmComparison() {
        require(method == PairingMethod.SAS && isCurrent() && stage == 3 && comparisonCode != null && !localCompared)
        require(identity.getOrCreateIdentity().identity == local)
        check(isCurrent())
        localCompared = true
        send(channel!!.seal(PairingCodec.message(15)))
        discloseIdentity()
    }

    private fun discloseIdentity() {
        if (!localCompared || !peerCompared || identitySent) return
        require(identity.getOrCreateIdentity().identity == local)
        check(isCurrent())
        identitySent = true
        event("verifying", null)
        send(channel!!.seal(PairingCodec.message(10, localBytes, localIdentitySalt)))
    }

    fun decline() {
        cancellation()?.let(send)
    }

    /** Explicit rejection may be sealed after revocation, but cannot disclose identities or store trust. */
    fun cancellation(): ByteArray? {
        try {
            return channel?.seal(PairingCodec.message(14))
        } finally { close() }
    }

    fun approve() {
        require(proofVerified && !localApproved)
        localApproved = true
        send(channel!!.seal(PairingCodec.message(12)))
        prepare()
    }

    private fun prepare() {
        if (!localApproved || !peerApproved || prepared) return
        prepared = true
        event("saving", peer)
        if (method == PairingMethod.SAS) check(isCurrent())
        val hash = trustHash()
        // Persist pending trust before signing its receipt; only a verified peer receipt activates it.
        store.prepare(
            PeerTrustRecord(peer!!, local.fingerprint, method, System.currentTimeMillis(), hash)
        )
        val signed = identity.sign(PairingCodec.receipt(hash, 1))
        require(signed.snapshot.identity == local)
        if (method == PairingMethod.SAS) check(isCurrent())
        send(channel!!.seal(PairingCodec.message(13, signed.signature)))
        receiptSent = true
        complete()
    }

    private fun complete() {
        if (receiptSent && receiptReceived) event("paired", peer)
    }

    private fun trustHash() =
        PairingCodec.hash(PairingCodec.proof(channel!!.hash, localBytes, peerBytes!!))

    private fun context() =
        PairingCodec.fields(
            "aniCe pin bootstrap v1".toByteArray(),
            byteArrayOf(method.wire.toByte()),
            rendezvous,
            clientNonce,
            serverNonce,
        )

    private fun transcript() =
        PairingCodec.fields(
            "aniCe pairing v1".toByteArray(),
            byteArrayOf(method.wire.toByte()),
            rendezvous,
            clientNonce,
            serverNonce,
            clientPublic,
            serverPublic,
        )

    fun close() {
        stage = -1
        comparisonCode = null
        localCompared = false
        peerCompared = false
        localIdentitySalt.fill(0)
        serverComparisonNonce.fill(0)
        channel?.destroy()
        channel = null
        pin.fill(0)
        qr?.secret?.fill(0)
        pake?.let {
            try {
                NativePake.invoke(6, it)
            } catch (_: Exception) {}
        }
        pake = null
        ephemeral = null
        store.discardPending()
    }
}
