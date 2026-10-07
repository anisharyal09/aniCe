// SPDX-License-Identifier: GPL-3.0-or-later
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

    fun receive(data: ByteArray) {
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
                        val f = PairingCodec.unpack(plain, 10, 1)
                        require(f[0].size <= 2048)
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
                        event("approval", peer)
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
                        store.activate(peer!!.deviceId, hash, f[0])
                        receiptReceived = true
                        complete()
                    }
                    14 -> {
                        PairingCodec.unpack(plain, 14, 0)
                        close()
                        event("cancelled", null)
                    }
                    else -> throw PairingException()
                }
            }
        }
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
        val hash = trustHash()
        store.prepare(
            PeerTrustRecord(peer!!, local.fingerprint, method, System.currentTimeMillis(), hash)
        )
        val signed = identity.sign(PairingCodec.receipt(hash, 1))
        require(signed.snapshot.identity == local)
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
