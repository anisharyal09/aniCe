// SPDX-License-Identifier: GPL-3.0-or-later
// Captures selected Android notifications and routes them over current secured Mac channels.
package io.github.anisharyal09.anice.features.notifications

import android.app.ActivityOptions
import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.os.Build
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.provider.Telephony
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.os.BundleCompat
import androidx.core.graphics.drawable.toBitmap
import io.github.anisharyal09.anice.infrastructure.connections.DataHandling
import io.github.anisharyal09.anice.infrastructure.connections.FeatureHandler
import io.github.anisharyal09.anice.infrastructure.connections.SecuredChannel
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.session.Cbor
import io.github.anisharyal09.anice.infrastructure.session.SessionException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.UUID

class NotificationMirrorPreferences(context: Context) {
    private val storage = context.getSharedPreferences("notification_mirror", Context.MODE_PRIVATE)
    fun selectedPackages(): Set<String> = storage.getStringSet("selected_packages", emptySet())?.toSet().orEmpty()
    fun isSelected(packageName: String) = packageName in selectedPackages()
    fun mirrorIncomingCalls(): Boolean = storage.getBoolean("mirror_incoming_calls", true)
    fun setSelected(packageName: String, selected: Boolean) {
        val values = selectedPackages().toMutableSet()
        if (selected) values.add(packageName) else values.remove(packageName)
        storage.edit().putStringSet("selected_packages", values).apply()
    }
    fun setMirrorIncomingCalls(enabled: Boolean) {
        storage.edit().putBoolean("mirror_incoming_calls", enabled).apply()
    }
}

private data class NotificationEntry(
    val key: String,
    val id: String,
    val epoch: String,
    val sequence: Long,
    val statusBar: StatusBarNotification,
    val appPackage: String,
    val appName: String,
    val title: String,
    val body: String,
    val sourceIcon: ByteArray?,
    val actions: Map<Int, NotificationActionTarget>,
    val wireActions: List<MirroredAction>,
)

internal data class NotificationActionTarget(
    val pendingIntent: PendingIntent,
    val remoteInput: RemoteInput?,
)

private data class DeliveredRevision(val epoch: String, val sequence: Long)

// Public CallStyle extra keys, kept as strings so the Android 29–33 code path has no newer field references.
private const val EXTRA_CALL_TYPE = "android.callType"
private const val EXTRA_ANSWER_INTENT = "android.answerIntent"
private const val EXTRA_DECLINE_INTENT = "android.declineIntent"

internal fun notificationPackageEligible(
    packageName: String,
    ownPackage: String,
    defaultSmsPackage: String?,
    selectedPackages: Set<String>,
    incomingCall: Boolean = false,
    mirrorIncomingCalls: Boolean = false,
): Boolean = packageName != ownPackage && packageName != defaultSmsPackage &&
    (packageName in selectedPackages || (incomingCall && mirrorIncomingCalls))

internal fun isIncomingCallStyle(template: String?, callType: Int?): Boolean =
    callType == 1 && (template == "android.app.Notification\$CallStyle" ||
        template == "androidx.core.app.NotificationCompat\$CallStyle")

internal fun notificationActions(
    notification: Notification,
    incomingCall: Boolean,
): Pair<Map<Int, NotificationActionTarget>, List<MirroredAction>> {
    val sourceActions = notification.actions.orEmpty()
    val extras = notification.extras
    if (incomingCall && extras != null) {
        val answer = BundleCompat.getParcelable(extras, EXTRA_ANSWER_INTENT, PendingIntent::class.java)
        val decline = BundleCompat.getParcelable(extras, EXTRA_DECLINE_INTENT, PendingIntent::class.java)
        if (answer != null && decline != null) {
            val targets = linkedMapOf<Int, NotificationActionTarget>()
            val mirrored = mutableListOf<MirroredAction>()
            // CallStyle's extra intents are authoritative; order Answer then Decline for the Mac banner.
            listOf(answer to "Answer", decline to "Decline").forEach { (pending, fallbackTitle) ->
                val source = sourceActions.firstOrNull { it.actionIntent == pending }
                val title = notificationText(source?.title?.toString().orEmpty(), 48).ifEmpty { fallbackTitle }
                val index = mirrored.size
                targets[index] = NotificationActionTarget(pending, null)
                mirrored += MirroredAction(index.toLong(), title, "")
            }
            return targets to mirrored
        }
    }

    val targets = linkedMapOf<Int, NotificationActionTarget>()
    val mirrored = mutableListOf<MirroredAction>()
    sourceActions.forEach { action ->
        if (mirrored.size >= NotificationWireMessage.MAX_ACTIONS || action.actionIntent == null) return@forEach
        val remote = action.remoteInputs.orEmpty().firstOrNull { it.allowFreeFormInput && !it.isDataOnly }
        val title = notificationText(action.title?.toString().orEmpty(), 48)
        if (title.isEmpty()) return@forEach
        val index = mirrored.size
        targets[index] = NotificationActionTarget(action.actionIntent, remote)
        val placeholder = remote?.label?.toString()?.let { notificationText(it, 48) }.orEmpty()
        mirrored += MirroredAction(index.toLong(), title, if (remote == null) "" else placeholder.ifEmpty { "Reply" })
    }
    return targets to mirrored
}

class NotificationMirrorController(context: Context) : FeatureHandler {
    private data class Link(
        val channel: SecuredChannel,
        var remoteCapability: Boolean = false,
        val sendLock: Mutex = Mutex(),
        val sentIconPackages: LinkedHashSet<String> = linkedSetOf(),
    )
    private data class Completed(val result: Long, val expiry: Long)
    private val app = context.applicationContext
    val preferences = NotificationMirrorPreferences(app)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val links = mutableMapOf<String, Link>()
    private val active = LinkedHashMap<String, NotificationEntry>()
    private val completed = LinkedHashMap<String, Completed>()
    private val inFlight = mutableSetOf<String>()
    private val deliveredRevisions = mutableMapOf<String, MutableMap<String, DeliveredRevision>>()
    private val sourceIcons = object : LinkedHashMap<String, ByteArray>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, ByteArray>?) = size > MAX_ICON_CACHE_ENTRIES
    }
    private var listener: NotificationMirrorService? = null
    private var accessEnabled = false
    private var epoch = UUID.randomUUID().toString()
    private var sequence = 0L
    private val now get() = android.os.SystemClock.elapsedRealtime()

    override fun available(channel: SecuredChannel) {
        if (channel.descriptor.peer.platform != "macos") return
        val transport = channel.descriptor.transport
        links[transport]?.let { retired(it.channel.descriptor) }
        val link = Link(channel)
        links[transport] = link
        send(link, NotificationWireMessage.of(1, number(NotificationWireMessage.MAX_ACTIONS)))
    }

    override fun retired(descriptor: io.github.anisharyal09.anice.infrastructure.connections.ChannelDescriptor) {
        val link = links[descriptor.transport] ?: return
        if (link.channel.descriptor != descriptor) return
        links.remove(descriptor.transport)
        if (links.values.none { peerKey(it.channel.descriptor.peer) == peerKey(descriptor.peer) }) {
            clearPeerState(peerKey(descriptor.peer))
        }
    }

    override fun capacityAvailable(descriptor: io.github.anisharyal09.anice.infrastructure.connections.ChannelDescriptor) = Unit

    override suspend fun handle(
        descriptor: io.github.anisharyal09.anice.infrastructure.connections.ChannelDescriptor,
        bytes: ByteArray,
    ): DataHandling {
        val message = try { NotificationWireMessage.decode(bytes) ?: return DataHandling.UNRECOGNIZED }
        catch (_: NotificationWireException) { return DataHandling.DISCARDED }
        catch (_: SessionException) { return DataHandling.DISCARDED }
        val link = links[descriptor.transport]?.takeIf { it.channel.descriptor == descriptor } ?: return DataHandling.DISCARDED
        if (message.kind == 1L) {
            val first = !link.remoteCapability
            link.remoteCapability = true
            if (first) {
                send(link, NotificationWireMessage.of(1, number(NotificationWireMessage.MAX_ACTIONS)))
                sendSnapshot(link)
            }
            return DataHandling.HANDLED
        }
        if (!link.remoteCapability) return DataHandling.DISCARDED
        when (message.kind) {
            6L -> executeAction(link, message)
            8L -> executeDismiss(link, message)
            else -> return DataHandling.DISCARDED
        }
        return DataHandling.HANDLED
    }

    fun accessChanged(enabled: Boolean) {
        if (accessEnabled == enabled) return
        accessEnabled = enabled
        if (!enabled) {
            listener = null
            active.values.toList().forEach(::sendRemoval)
            active.clear()
            deliveredRevisions.clear()
            completed.clear()
            inFlight.clear()
        }
    }

    fun listenerConnected(service: NotificationMirrorService) {
        listener = service
        accessEnabled = true
        refreshFromSystem()
    }

    fun listenerDisconnected(service: NotificationMirrorService) {
        if (listener !== service) return
        listener = null
        accessChanged(false)
    }

    fun selectionChanged() { refreshFromSystem() }
    fun securityInvalidated() {
        completed.clear()
        inFlight.clear()
        deliveredRevisions.clear()
    }

    fun notificationPosted(sbn: StatusBarNotification) {
        if (!accessEnabled) return
        val id = notificationId(sbn.key)
        val packageName = sbn.packageName
        val notification = sbn.notification
        val extras = notification.extras
        val incomingCall = isIncomingCallStyle(
            extras?.getString(Notification.EXTRA_TEMPLATE),
            extras?.getInt(EXTRA_CALL_TYPE),
        )
        if (!eligible(packageName, incomingCall)) {
            active.remove(id)?.let { sendRemoval(it) }
            return
        }
        val appName = runCatching {
            app.packageManager.getApplicationLabel(app.packageManager.getApplicationInfo(packageName, 0)).toString()
        }.getOrDefault(packageName)
        val title = notificationText(extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty(), 512)
        val body = notificationText(
            (extras?.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: extras?.getCharSequence(Notification.EXTRA_TEXT))?.toString().orEmpty(),
            1024,
        )
        val (actions, wireActions) = notificationActions(notification, incomingCall)
        val old = active[id]
        if (sequence >= NotificationWireMessage.MAX_SEQUENCE) {
            epoch = UUID.randomUUID().toString()
            sequence = 0
            active.clear()
            links.values.filter { it.remoteCapability }.forEach(::sendSnapshot)
        }
        val entry = NotificationEntry(
            sbn.key, id, epoch, ++sequence, sbn, packageName,
            notificationText(appName, 128).ifEmpty { packageName }, title, body,
            sourceIconFor(packageName), actions, wireActions,
        )
        if (old == null && active.size >= MAX_ACTIVE) {
            val evicted = active.values.minByOrNull { it.sequence }
            if (evicted != null) { active.remove(evicted.id); sendRemoval(evicted) }
        }
        active[id] = entry
        sendUpsert(entry)
    }

    fun notificationRemoved(sbn: StatusBarNotification) {
        val id = notificationId(sbn.key)
        active.remove(id)?.let { sendRemoval(it) }
    }

    private fun refreshFromSystem() {
        if (!accessEnabled) return
        val service = listener ?: return
        val rows = runCatching { service.activeNotifications.orEmpty().toList() }.getOrDefault(emptyList())
        active.clear()
        rows.forEach(::notificationPosted)
        links.values.filter { it.remoteCapability }.forEach(::sendSnapshot)
    }

    private fun eligible(packageName: String, incomingCall: Boolean): Boolean {
        val smsPackage = runCatching { Telephony.Sms.getDefaultSmsPackage(app) }.getOrNull()
        return notificationPackageEligible(
            packageName, app.packageName, smsPackage, preferences.selectedPackages(),
            incomingCall = incomingCall, mirrorIncomingCalls = preferences.mirrorIncomingCalls(),
        )
    }

    private fun sourceIconFor(packageName: String): ByteArray? {
        sourceIcons[packageName]?.let { return it }
        val drawable = runCatching { app.packageManager.getApplicationIcon(packageName) }.getOrNull() ?: return null
        for (size in SOURCE_ICON_SIZES) {
            val png = runCatching {
                val bitmap = drawable.toBitmap(size, size, Bitmap.Config.ARGB_8888)
                ByteArrayOutputStream().use { output ->
                    if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) return@runCatching null
                    output.toByteArray()
                }
            }.getOrNull() ?: continue
            if (png.size <= NotificationWireMessage.MAX_SOURCE_ICON_BYTES) {
                sourceIcons[packageName] = png
                return png
            }
        }
        return null
    }

    private fun sendSnapshot(link: Link) {
        val snapshotEpoch = epoch
        val highWater = sequence
        val rows = active.values.filter { it.sequence <= highWater }.toList()
        val token = UUID.randomUUID().toString()
        scope.launch {
            sendNow(link, NotificationWireMessage.of(4, text(token), text(snapshotEpoch), number(highWater)))
            for (entry in rows) {
                sendEntry(link, entry, token)
            }
            sendNow(link, NotificationWireMessage.of(5, text(token)))
        }
    }

    private fun sendUpsert(entry: NotificationEntry) {
        links.values.filter { it.remoteCapability }.forEach { link -> scope.launch { sendEntry(link, entry, "") } }
    }

    private suspend fun sendEntry(link: Link, entry: NotificationEntry, snapshotToken: String) {
        link.sendLock.withLock {
            if (active[entry.id]?.let { it.epoch == entry.epoch && it.sequence == entry.sequence } != true) return
            if (entry.sourceIcon != null && entry.appPackage !in link.sentIconPackages) {
                val icon = NotificationWireMessage.of(9, text(entry.appPackage), Cbor.Bytes(entry.sourceIcon))
                if (sendNow(link, icon)) {
                    link.sentIconPackages += entry.appPackage
                    if (link.sentIconPackages.size > MAX_ICON_CACHE_ENTRIES) {
                        link.sentIconPackages.remove(link.sentIconPackages.first())
                    }
                }
            }
            if (active[entry.id]?.let { it.epoch == entry.epoch && it.sequence == entry.sequence } != true) return
            sendNow(link, notificationRecord(entry, snapshotToken))
        }
    }

    private fun notificationRecord(entry: NotificationEntry, snapshotToken: String) = NotificationWireMessage.of(
        2, text(snapshotToken), text(entry.id), text(entry.epoch), number(entry.sequence), text(entry.appPackage),
        text(entry.appName), text(entry.title), text(entry.body),
        Cbor.Array(entry.wireActions.map { Cbor.Array(listOf(number(it.index), text(it.title), text(it.replyPlaceholder))) }),
    )

    private fun sendRemoval(entry: NotificationEntry) {
        val message = NotificationWireMessage.of(3, text(entry.id), text(entry.epoch), number(entry.sequence))
        links.values.filter { it.remoteCapability }.forEach { send(it, message) }
    }

    private fun send(link: Link, message: NotificationWireMessage) { scope.launch { sendNow(link, message) } }

    private suspend fun sendNow(link: Link, message: NotificationWireMessage): Boolean {
        if (links[link.channel.descriptor.transport] !== link) return false
        // A queued snapshot must not replay an entry removed or replaced while waiting to send.
        if (message.kind == 2L && active[message.text(1)]?.let {
            it.epoch == message.text(2) && it.sequence == message.number(3)
        } != true) return false
        try {
            link.channel.sendData(message.encode())
            val peer = peerKey(link.channel.descriptor.peer)
            when (message.kind) {
                2L -> {
                    val id = message.text(1)
                    val revision = DeliveredRevision(message.text(2), message.number(3))
                    if (active[id]?.let { it.epoch == revision.epoch && it.sequence == revision.sequence } == true) {
                        deliveredRevisions.getOrPut(peer) { mutableMapOf() }[id] = revision
                    }
                }
                3L -> {
                    val id = message.text(0)
                    val revision = DeliveredRevision(message.text(1), message.number(2))
                    val delivered = deliveredRevisions[peer]?.get(id)
                    if (delivered?.epoch == revision.epoch && delivered.sequence <= revision.sequence) {
                        deliveredRevisions[peer]?.remove(id)
                    }
                }
            }
            return true
        } catch (_: Exception) { /* Active state is sent again on the next secure connection. */ }
        return false
    }

    private fun executeAction(link: Link, message: NotificationWireMessage) {
        val requestId = message.text(0)
        val peer = peerKey(link.channel.descriptor.peer)
        val requestKey = "$peer:$requestId"
        val cached = completed[requestKey]
        if (cached != null && cached.expiry > now) { send(link, result(requestId, cached.result)); return }
        if (!inFlight.add(requestKey)) return
        scope.launch {
            val id = message.text(1)
            val entry = active[id]
            val delivered = deliveredRevisions[peer]?.get(id)
            val outcome = if (links[link.channel.descriptor.transport] !== link || entry == null ||
                message.text(2) != entry.epoch || entry.sequence != message.number(3) ||
                delivered != DeliveredRevision(entry.epoch, entry.sequence)) 1L
            else runCatching {
                val index = message.number(4).toInt()
                val target = entry.actions[index]
                val pending = if (index == -1) entry.statusBar.notification.contentIntent else target?.pendingIntent
                if (pending == null) 2L else {
                    val intent = Intent()
                    if (index >= 0 && message.text(5).isNotEmpty()) {
                        val remote = target?.remoteInput ?: return@runCatching 2L
                        RemoteInput.addResultsToIntent(arrayOf(remote), intent, Bundle().apply {
                            putCharSequence(remote.resultKey, message.text(5))
                        })
                    }
                    // Reached only after authenticating the peer and validating this active notification action.
                    // A Mac click is the user's gesture; Android 14+ requires its sender to opt in for
                    // a PendingIntent that needs to open the source app from the background.
                    sendNotificationAction(pending, intent)
                    0L
                }
            }.getOrElse { 3L }
            finishAction(link, peer, requestId, requestKey, outcome)
        }
    }

    private fun executeDismiss(link: Link, message: NotificationWireMessage) {
        val requestId = message.text(0)
        val peer = peerKey(link.channel.descriptor.peer)
        val requestKey = "$peer:$requestId"
        val cached = completed[requestKey]
        if (cached != null && cached.expiry > now) { send(link, result(requestId, cached.result)); return }
        if (!inFlight.add(requestKey)) return
        val entry = active[message.text(1)]
        val delivered = deliveredRevisions[peer]?.get(message.text(1))
        val outcome = if (links[link.channel.descriptor.transport] !== link || entry == null ||
            message.text(2) != entry.epoch || entry.sequence != message.number(3) ||
            delivered != DeliveredRevision(entry.epoch, entry.sequence)) 1L
        else if (listener == null) 2L
        else runCatching { listener?.cancelNotification(entry.key); 0L }.getOrElse { 3L }
        finishAction(link, peer, requestId, requestKey, outcome)
    }

    @Suppress("DEPRECATION", "NewApi")
    private fun sendNotificationAction(pending: PendingIntent, fillInIntent: Intent) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            pending.send(app, 0, fillInIntent)
            return
        }

        val options = ActivityOptions.makeBasic()
        when {
            Build.VERSION.SDK_INT >= 36 -> options.setPendingIntentBackgroundActivityStartMode(
                ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOW_ALWAYS,
            )
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE -> options.setPendingIntentBackgroundActivityStartMode(
                ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED,
            )
            else -> options.setPendingIntentBackgroundActivityLaunchAllowed(true)
        }
        pending.send(app, 0, fillInIntent, null, null, null, options.toBundle())
    }

    private fun finishAction(link: Link, peer: String, requestId: String, requestKey: String, outcome: Long) {
        inFlight.remove(requestKey)
        completed[requestKey] = Completed(outcome, now + RESULT_TTL)
        val peerResults = completed.keys.filter { it.startsWith("$peer:") }.toMutableList()
        while (peerResults.size > MAX_RESULTS_PER_PEER) completed.remove(peerResults.removeAt(0))
        val time = now
        completed.entries.removeAll { it.value.expiry <= time }
        send(link, result(requestId, outcome))
    }

    private fun clearPeerState(peer: String) {
        val prefix = "$peer:"
        completed.keys.filter { it.startsWith(prefix) }.forEach(completed::remove)
        inFlight.removeAll { it.startsWith(prefix) }
        deliveredRevisions.remove(peer)
    }

    private fun result(requestId: String, outcome: Long) = NotificationWireMessage.of(7, text(requestId), number(outcome))
    private fun notificationId(key: String) = MessageDigest.getInstance("SHA-256").digest(key.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }
    private fun peerKey(peer: DeviceIdentity) = "${peer.deviceId}:${peer.fingerprint}"

    companion object {
        private const val MAX_ACTIVE = 128
        private const val MAX_RESULTS_PER_PEER = 32
        private const val RESULT_TTL = 10 * 60_000L
        private const val MAX_ICON_CACHE_ENTRIES = 128
        private val SOURCE_ICON_SIZES = intArrayOf(96, 64, 48, 32)
        private fun text(value: String) = Cbor.Text(value)
        private fun number(value: Long) = Cbor.Integer(value)
    }
}

class NotificationMirrorService : NotificationListenerService() {
    private val owner get() = (application as io.github.anisharyal09.anice.AniCeApplication).notificationMirror
    override fun onListenerConnected() { super.onListenerConnected(); owner.listenerConnected(this) }
    override fun onListenerDisconnected() { owner.listenerDisconnected(this); super.onListenerDisconnected() }
    override fun onNotificationPosted(sbn: StatusBarNotification) { owner.notificationPosted(sbn) }
    override fun onNotificationRemoved(sbn: StatusBarNotification, rankingMap: RankingMap, reason: Int) {
        owner.notificationRemoved(sbn)
    }
}
