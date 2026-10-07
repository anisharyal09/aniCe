// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.infrastructure.bluetooth

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.*
import android.util.Log
import io.github.anisharyal09.anice.infrastructure.pairing.*
import java.util.UUID

/** Main-thread serialized GATT control pipe. Handles/addresses never leave this adapter. */
@SuppressLint("MissingPermission")
class AndroidPairingTransport(
    private val context: Context,
    private val row: (Long) -> Unit,
    private val connected: () -> Unit,
    private val message: (ByteArray) -> Unit,
    private val ended: (Boolean, PairingTransportFailure?) -> Unit,
    private val progress: (String, Long) -> Unit,
) {
  private val handler = Handler(Looper.getMainLooper())
  private val adapter
    get() = context.getSystemService(BluetoothManager::class.java)?.adapter

  private var scanner: BluetoothLeScanner? = null
  private var scan: ScanCallback? = null
  private val candidates = linkedMapOf<String, Pair<Long, BluetoothDevice>>()
  private var next = 0L
  private var client: BluetoothGatt? = null
  private var write: BluetoothGattCharacteristic? = null
  private var indicate: BluetoothGattCharacteristic? = null
  private var epoch = 0L
  private var stage = "idle"
  private var mtu = 23
  private var incoming = PairingReassembler()
  private val queue = java.util.ArrayDeque<ByteArray>()
  private var writing = false
  private var id = 0L
  private var budget = 0
  private var closeAfterFlush = false
  private var closing = false
  private var closedCallback = false
  private val search = PairingSearchWindow<BluetoothDevice>(SystemClock::elapsedRealtime)
  private var scanDeadline = 0L
  private var connectionDeadline = 0L
  private var locating = false
  private var setupRecovery = GattSetupRecovery()
  private var lastCandidateFailure: PairingTransportFailure? = null
  val scanEndFailure
    get() = lastCandidateFailure

  // QR lookup connects as soon as a result arrives. A nonmatching invitation resumes
  // the bounded scan, retaining only temporary device handles for this operation.
  fun nextCandidate(failure: PairingTransportFailure? = null): Boolean {
    lastCandidateFailure = failure
    closeClient()
    if (!locating || !search.canContinue()) return false
    scanForCandidates()
    return true
  }

  fun matched() {
    locating = false
    search.clear()
  }

  fun startScan(qr: Boolean = false) {
    close()
    closedCallback = false
    closing = false
    locating = qr
    lastCandidateFailure = null
    search.begin()
    scanDeadline = search.deadline
    scanForCandidates()
  }

  private fun scanForCandidates() {
    val op = ++epoch
    stage = "scan"
    progress("scan", scanDeadline)
    val cb =
        object : ScanCallback() {
          override fun onScanResult(type: Int, result: ScanResult) {
            handler.post {
              if (epoch != op || scan !== this) return@post
              try {
                if (result.scanRecord
                    ?.serviceUuids
                    ?.contains(ParcelUuid(UUID.fromString(BlePayloadCodec.SERVICE_UUID))) != true)
                    return@post
                if (SystemClock.elapsedRealtime() >= scanDeadline) return@post
                val device = result.device
                if (locating) {
                  if (!search.claim(device)) return@post
                  stopScan()
                  connect(device)
                } else {
                  val address = device.address
                  if (candidates.containsKey(address) || candidates.size >= 32) return@post
                  val n = ++next
                  candidates[address] = n to device
                  row(n)
                }
              } catch (_: SecurityException) {
                finish(
                    false,
                    "Bluetooth permission changed. Allow access and start again.",
                )
              }
            }
          }

          override fun onBatchScanResults(results: MutableList<ScanResult>) {
            results.forEach { onScanResult(0, it) }
          }

          override fun onScanFailed(code: Int) {
            handler.post {
              if (epoch == op) finish(false, "Bluetooth scanning could not start. Try again.")
            }
          }
        }
    try {
      scan = cb
      scanner = adapter?.bluetoothLeScanner ?: throw PairingException()
      scanner!!.startScan(
          listOf(
              ScanFilter.Builder()
                  .setServiceUuid(ParcelUuid(UUID.fromString(BlePayloadCodec.SERVICE_UUID)))
                  .build()),
          ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(),
          cb,
      )
    } catch (_: Exception) {
      finish(false, "Bluetooth scanning could not start. Check Bluetooth and permissions.")
    }
    handler.postDelayed(
        {
          if (epoch == op && stage == "scan") {
            // Preserve an observed setup failure instead of hiding it as a scan timeout.
            val previous = lastCandidateFailure
            if (locating && previous != null) {
              finish(false, previous.message, recovery = previous.recovery)
              return@postDelayed
            }
            finish(
                false,
                if (locating)
                    "No nearby Mac matched this QR invitation. Show a fresh QR code on your Mac and try again."
                else "Scan ended. Scan again to find nearby devices.",
            )
          }
        },
        (scanDeadline - SystemClock.elapsedRealtime()).coerceAtLeast(0),
    )
  }

  fun select(row: Long) {
    val device = candidates.values.firstOrNull { it.first == row }?.second ?: return
    stopScan()
    connect(device)
  }

  private fun stopScan() {
    val cb = scan
    scan = null
    candidates.clear()
    try {
      if (cb != null) scanner?.stopScan(cb)
    } catch (_: Exception) {}
    scanner = null
  }

  private fun connect(device: BluetoothDevice) {
    val op = ++epoch
    stage = "connect"
    connectionDeadline = SystemClock.elapsedRealtime() + 15000
    progress("connecting", connectionDeadline)
    incoming = PairingReassembler()
    setupRecovery = GattSetupRecovery()
    mtu = 23
    id = 0
    budget = 0
    closing = false
    closedCallback = false
    val callback =
        object : BluetoothGattCallback() {
          private fun dispatch(
              g: BluetoothGatt,
              allowClosing: Boolean = false,
              block: () -> Unit,
          ) {
            handler.post {
              if (epoch == op && client === g && (!closing || allowClosing))
                  try {
                    block()
                  } catch (_: Exception) {
                    finish(false)
                  }
            }
          }

          override fun onConnectionStateChange(g: BluetoothGatt, status: Int, state: Int) =
              dispatch(g, allowClosing = true) {
                if (closing && state != BluetoothProfile.STATE_DISCONNECTED) return@dispatch
                Log.i(
                    "aniCe-pairing",
                    "connection status=$status connected=${state == BluetoothProfile.STATE_CONNECTED}",
                )
                if (state == BluetoothProfile.STATE_DISCONNECTED) {
                  finish(closing)
                } else if (status != BluetoothGatt.GATT_SUCCESS) {
                  finish(
                      false,
                      "Bluetooth connection failed. Start a fresh invitation and try again.",
                      retryCandidate = true,
                  )
                } else if (state == BluetoothProfile.STATE_CONNECTED && stage == "connect") {
                  refreshGatt(g)
                  stage = "mtu"
                  progress("mtu", connectionDeadline)
                  if (!g.requestMtu(517)) {
                    services(g)
                  } else
                      handler.postDelayed(
                          {
                            if (epoch == op && stage == "mtu") {
                              mtu = 23
                              services(g)
                            }
                          },
                          2000,
                      )
                }
              }

          override fun onMtuChanged(g: BluetoothGatt, value: Int, status: Int) =
              dispatch(g) {
                if (stage == "mtu") {
                  mtu = if (status == BluetoothGatt.GATT_SUCCESS) value.coerceIn(23, 517) else 23
                  services(g)
                }
              }

          override fun onServicesDiscovered(g: BluetoothGatt, status: Int) =
              dispatch(g) {
                if (stage != "services" && stage != "layoutRefresh") return@dispatch
                Log.i("aniCe-pairing", "service_discovery status=$status")
                require(status == BluetoothGatt.GATT_SUCCESS)
                if (setupRecovery.afterPendingOperation()) {
                  services(g)
                  return@dispatch
                }
                val allServices = g.services
                Log.i(
                    "aniCe-pairing",
                    "all_services_count=${allServices.size} uuids=${allServices.map { it.uuid }}",
                )
                val profiles =
                    allServices.filter { it.uuid == UUID.fromString(BlePayloadCodec.SERVICE_UUID) }
                val complete =
                    profiles.filter {
                      it.getCharacteristic(UUID.fromString(PairingCodec.WRITE_UUID)) != null &&
                          it.getCharacteristic(UUID.fromString(PairingCodec.INDICATE_UUID)) != null
                    }
                Log.i(
                    "aniCe-pairing",
                    "profile_count=${profiles.size} complete_profile_count=${complete.size}",
                )
                if (complete.size > 1) {
                  finish(
                      false,
                      "More than one pairing service was found on this Mac. Quit extra copies of aniCe and restart the Mac app.",
                  )
                  return@dispatch
                }
                if (complete.isEmpty()) {
                  if (setupRecovery.retryMissingLayout()) {
                    stage = "layoutRefresh"
                    progress("services", connectionDeadline)
                    Log.i("aniCe-pairing", "missing_layout_rediscovery with cache refresh")
                    refreshGatt(g)
                    handler.postDelayed(
                        { if (epoch == op && stage == "layoutRefresh") services(g) },
                        300,
                    )
                    return@dispatch
                  }
                  finish(
                      false,
                      if (profiles.isEmpty())
                        "Could not discover the Mac's pairing service. Start a fresh invitation and try again."
                      else
                        "The phone could not see the Mac’s pairing channels. Make sure the updated Mac app has an invitation open. If it does, turn Bluetooth off and on in phone Settings and retry to refresh the connection.",
                      retryCandidate = true,
                      recovery = PairingTransportRecovery.bluetoothSettings,
                  )
                  return@dispatch
                }
                val s = complete.first()
                val w = s.getCharacteristic(UUID.fromString(PairingCodec.WRITE_UUID))
                val r = s.getCharacteristic(UUID.fromString(PairingCodec.INDICATE_UUID))
                Log.i(
                    "aniCe-pairing",
                    "profile discovery=${s.getCharacteristic(UUID.fromString(BlePayloadCodec.CHARACTERISTIC_UUID)) != null} write=${w != null} indicate=${r != null}",
                )
                require(w != null && r != null)
                require(
                    w.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0 &&
                        r.properties and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0)
                write = w
                indicate = r
                require(g.setCharacteristicNotification(r, true))
                val d =
                    r.getDescriptor(UUID.fromString("00002902-0000-1000-8000-00805f9b34fb"))
                        ?: throw PairingException()
                stage = "subscribe"
                progress("subscribe", connectionDeadline)
                @Suppress("DEPRECATION")
                val started =
                    if (Build.VERSION.SDK_INT >= 33)
                        g.writeDescriptor(
                            d,
                            BluetoothGattDescriptor.ENABLE_INDICATION_VALUE,
                        ) == BluetoothStatusCodes.SUCCESS
                    else {
                      d.value = BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
                      g.writeDescriptor(d)
                    }
                require(started)
              }

          override fun onServiceChanged(g: BluetoothGatt) =
              dispatch(g) {
                Log.i("aniCe-pairing", "service_changed stage=$stage")
                when (stage) {
                  "connect",
                  "mtu",
                  "services",
                  "layoutRefresh",
                  "subscribe" -> setupRecovery.invalidate()
                  else ->
                      finish(
                          false,
                          "The Mac’s Bluetooth services changed during pairing. Start a fresh invitation.",
                      )
                }
              }

          override fun onDescriptorWrite(
              g: BluetoothGatt,
              d: BluetoothGattDescriptor,
              status: Int,
          ) =
              dispatch(g) {
                if (stage == "subscribe") {
                  Log.i("aniCe-pairing", "reply_subscription status=$status")
                  if (setupRecovery.afterPendingOperation()) {
                    indicate?.let { g.setCharacteristicNotification(it, false) }
                    write = null
                    indicate = null
                    services(g)
                    return@dispatch
                  }
                  require(
                      d.characteristic.uuid == indicate?.uuid &&
                          status == BluetoothGatt.GATT_SUCCESS)
                  stage = "ready"
                  progress("checking", SystemClock.elapsedRealtime() + 10000)
                  connected()
                }
              }

          @Deprecated("Legacy callback required before API 33")
          override fun onCharacteristicChanged(
              g: BluetoothGatt,
              c: BluetoothGattCharacteristic,
          ) {
            if (Build.VERSION.SDK_INT < 33) {
              @Suppress("DEPRECATION") val value = c.value?.clone() ?: byteArrayOf()
              changed(g, c, value)
            }
          }

          override fun onCharacteristicChanged(
              g: BluetoothGatt,
              c: BluetoothGattCharacteristic,
              value: ByteArray,
          ) {
            changed(g, c, value.clone())
          }

          private fun changed(
              g: BluetoothGatt,
              c: BluetoothGattCharacteristic,
              value: ByteArray,
          ) =
              dispatch(g) {
                require(stage == "ready" && c.uuid == indicate?.uuid)
                incoming.receive(value)?.let { bytes ->
                  require(budget + bytes.size <= 32768)
                  budget += bytes.size
                  message(bytes)
                }
              }

          override fun onCharacteristicWrite(
              g: BluetoothGatt,
              c: BluetoothGattCharacteristic,
              status: Int,
          ) =
              dispatch(g) {
                require(c.uuid == write?.uuid && writing && status == BluetoothGatt.GATT_SUCCESS)
                queue.removeFirst()
                writing = false
                flush()
              }
        }
    try {
      client = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
      require(client != null)
    } catch (_: Exception) {
      finish(false)
    }
    handler.postDelayed(
        {
          if (epoch == op && stage != "ready")
              finish(false, failureMessage(), retryCandidate = true)
        },
        15000,
    )
  }

  private fun services(g: BluetoothGatt) {
    if (closing || g !== client) return
    if (stage == "connect" || stage == "mtu" || stage == "layoutRefresh")
        setupRecovery.afterPendingOperation()
    stage = "services"
    progress("services", connectionDeadline)
    try {
      require(g.discoverServices())
    } catch (_: Exception) {
      finish(false, failureMessage(), retryCandidate = true)
    }
  }

  fun send(data: ByteArray) {
    try {
      require(stage == "ready" && !closing && budget + data.size <= 32768)
      budget += data.size
      queue.addAll(PairingReassembler.fragments(data, id++, mtu - 3))
      flush()
    } catch (_: Exception) {
      finish(false)
    }
  }

  private fun flush() {
    if (writing || closing) return
    val f = queue.peekFirst()
    if (f == null) {
      if (closeAfterFlush) disconnect()
      return
    }
    val g = client ?: throw PairingException()
    val c = write ?: throw PairingException()
    writing = true
    @Suppress("DEPRECATION")
    val started =
        if (Build.VERSION.SDK_INT >= 33)
            g.writeCharacteristic(c, f, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) ==
                BluetoothStatusCodes.SUCCESS
        else {
          c.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
          c.value = f
          g.writeCharacteristic(c)
        }
    require(started)
  }

  fun finishAfterWrites() {
    closeAfterFlush = true
    try {
      flush()
    } catch (_: Exception) {
      finish(false)
    }
  }

  private fun disconnect() {
    closing = true
    val op = epoch
    try {
      client?.disconnect()
    } catch (_: Exception) {
      finish(true)
    }
    handler.postDelayed({ if (epoch == op) finish(true) }, 2000)
  }

  fun cancel() {
    locating = false
    search.clear()
    stopScan()
    if (client != null) {
      queue.clear()
      writing = false
      closeAfterFlush = false
      disconnect()
    } else close()
  }

  private fun closeClient() {
    epoch++
    try {
      if (!closing) client?.disconnect()
    } catch (_: Exception) {}
    try {
      client?.close()
    } catch (_: Exception) {}
    client = null
    write = null
    indicate = null
    queue.clear()
    writing = false
    closeAfterFlush = false
    stage = "idle"
    incoming = PairingReassembler()
  }

  fun close() {
    locating = false
    stopScan()
    search.clear()
    closeClient()
  }

  /**
   * Flushes Android's in-memory GATT service cache for the remote peripheral.
   *
   * Android caches service attribute tables by Bluetooth MAC address without querying the
   * peripheral over the air if a cached entry exists. When a peripheral changes its GATT layout
   * or when Phase 3 discovery preceded pairing, Android returns a stale cache in a few milliseconds.
   * Invoking the hidden `refresh` method forces Android to perform fresh over-the-air discovery.
   */
  private fun refreshGatt(g: BluetoothGatt): Boolean {
    return try {
      val method = g.javaClass.getMethod("refresh")
      val ok = (method.invoke(g) as? Boolean) ?: false
      Log.i("aniCe-pairing", "gatt_refresh success=$ok")
      ok
    } catch (e: Throwable) {
      Log.w("aniCe-pairing", "gatt_refresh reflection unavailable", e)
      false
    }
  }

  private fun failureMessage(): String =
      when (stage) {
        "connect" ->
            "Could not connect to your Mac. Keep aniCe's pairing invitation open and try again."
        "mtu",
        "services" ->
            "Could not discover the Mac's pairing service. Start a fresh invitation and try again."
        "subscribe" ->
            "Could not open the Mac's pairing reply channel. Start a fresh invitation and try again."
        "ready" -> "The pairing connection was interrupted. Start again."
        else -> "Bluetooth pairing was interrupted. Start again."
      }

  private fun finish(
      success: Boolean,
      reason: String? = null,
      retryCandidate: Boolean = false,
      recovery: PairingTransportRecovery = PairingTransportRecovery.retry,
  ) {
    val failure =
        if (success) null else PairingTransportFailure(reason ?: failureMessage(), recovery)
    if (!success && locating && (reason == null || retryCandidate) && nextCandidate(failure)) return
    if (closedCallback) return
    closedCallback = true
    close()
    Log.i("aniCe-pairing", "transport_end succeeded=$success")
    ended(success, failure)
  }
}
