// SPDX-License-Identifier: GPL-3.0-or-later
// Adapts Android BLE callbacks to scan-local compatibility discovery events.
package io.github.anisharyal09.anice.infrastructure.bluetooth

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import java.util.UUID

/** Permission checks live at the discovery entry point; permission races are caught here. */
@SuppressLint("MissingPermission")
class AndroidBleCentralAdapter(private val context: Context) : CentralAdapter {
    private val handler = Handler(Looper.getMainLooper())
    private val bluetooth get() = context.getSystemService(BluetoothManager::class.java)?.adapter
    private val serviceUuid = UUID.fromString(BlePayloadCodec.SERVICE_UUID)
    private val characteristicUuid = UUID.fromString(BlePayloadCodec.CHARACTERISTIC_UUID)
    private var scanner: android.bluetooth.le.BluetoothLeScanner? = null
    private var scanCallback: ScanCallback? = null
    private var scanEpoch = 0L
    private var nextRow = 0L
    // Addresses exist only inside this active-scan map. No toString/logging or persistence.
    private val candidates = linkedMapOf<String, Pair<Long, BluetoothDevice>>()
    private var gatt: BluetoothGatt? = null
    private var gattEpoch = 0L
    private var characteristic: BluetoothGattCharacteristic? = null
    private var onEvent: ((CentralEvent) -> Unit)? = null

    override fun scan(found: (Long) -> Unit, failed: () -> Unit): Boolean {
        stopScan()
        val epoch = ++scanEpoch
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                handler.post {
                    if (scanEpoch != epoch || scanCallback !== this) return@post
                    if (result.scanRecord?.serviceUuids?.contains(ParcelUuid(serviceUuid)) != true) return@post
                    try {
                        val address = result.device.address
                        if (candidates.containsKey(address) || candidates.size >= 32) return@post
                        val id = ++nextRow
                        candidates[address] = id to result.device
                        found(id)
                    } catch (_: SecurityException) { failed() }
                }
            }
            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                results.forEach { onScanResult(0, it) }
            }
            override fun onScanFailed(errorCode: Int) {
                handler.post { if (scanEpoch == epoch && scanCallback === this) failed() }
            }
        }
        return try {
            val nativeScanner = bluetooth?.bluetoothLeScanner ?: return false
            scanner = nativeScanner; scanCallback = callback
            nativeScanner.startScan(
                listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(serviceUuid)).build()),
                ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), callback,
            )
            true
        } catch (_: SecurityException) { stopScan(); false }
          catch (_: IllegalStateException) { stopScan(); false }
    }
    override fun stopScan() {
        scanEpoch++
        val callback = scanCallback
        scanCallback = null; candidates.clear()
        try { if (callback != null) scanner?.stopScan(callback) }
        catch (_: SecurityException) { /* Permission was revoked; invalidate local work. */ }
        catch (_: IllegalStateException) { /* Radio unavailable. */ }
        scanner = null
    }
    override fun connect(rowId: Long, event: (CentralEvent) -> Unit): Boolean {
        val selected = candidates.values.firstOrNull { it.first == rowId }?.second
        stopScan(); close()
        if (selected == null) return false
        val epoch = ++gattEpoch
        onEvent = event
        val callback = object : BluetoothGattCallback() {
            private fun deliver(client: BluetoothGatt, value: CentralEvent) {
                handler.post { if (epoch == gattEpoch && client === gatt) onEvent?.invoke(value) }
            }
            override fun onConnectionStateChange(client: BluetoothGatt, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_DISCONNECTED) deliver(client, CentralEvent.Disconnected)
                else if (status != BluetoothGatt.GATT_SUCCESS) deliver(client, CentralEvent.Failed("Bluetooth connection failed. Scan again."))
                else if (newState == BluetoothProfile.STATE_CONNECTED) deliver(client, CentralEvent.Connected)
            }
            override fun onServicesDiscovered(client: BluetoothGatt, status: Int) {
                handler.post {
                    if (epoch != gattEpoch || client !== gatt) return@post
                    if (status != BluetoothGatt.GATT_SUCCESS) {
                        onEvent?.invoke(CentralEvent.Failed("Service discovery failed. Scan again.")); return@post
                    }
                    val value = client.getService(serviceUuid)?.getCharacteristic(characteristicUuid)
                    if (value == null || value.properties and BluetoothGattCharacteristic.PROPERTY_READ == 0) {
                        onEvent?.invoke(CentralEvent.Failed("This device does not expose the aniCe discovery service. Scan again.")); return@post
                    }
                    characteristic = value
                    onEvent?.invoke(CentralEvent.ServicesFound)
                }
            }
            private fun readResult(client: BluetoothGatt, value: BluetoothGattCharacteristic, bytes: ByteArray, status: Int) {
                if (value.uuid != characteristicUuid) return
                deliver(client, if (status == BluetoothGatt.GATT_SUCCESS) CentralEvent.Read(bytes.copyOf())
                    else CentralEvent.Failed("Discovery read failed. Scan again."))
            }
            @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
            override fun onCharacteristicRead(client: BluetoothGatt, value: BluetoothGattCharacteristic, status: Int) {
                if (android.os.Build.VERSION.SDK_INT < 33) readResult(client, value, value.value ?: byteArrayOf(), status)
            }
            override fun onCharacteristicRead(client: BluetoothGatt, value: BluetoothGattCharacteristic, bytes: ByteArray, status: Int) {
                readResult(client, value, bytes, status)
            }
        }
        return try {
            gatt = selected.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
            gatt != null
        } catch (_: SecurityException) { close(); false }
          catch (_: IllegalStateException) { close(); false }
    }
    override fun discoverServices(): Boolean = try { gatt?.discoverServices() == true }
        catch (_: SecurityException) { false } catch (_: IllegalStateException) { false }
    override fun read(): Boolean = try { characteristic?.let { gatt?.readCharacteristic(it) } == true }
        catch (_: SecurityException) { false } catch (_: IllegalStateException) { false }
    override fun disconnect() {
        try { gatt?.disconnect() } catch (_: SecurityException) { close() } catch (_: IllegalStateException) { close() }
    }
    override fun close() {
        gattEpoch++; onEvent = null; characteristic = null
        val client = gatt; gatt = null
        try { client?.close() } catch (_: SecurityException) { /* OS owns revoked handles. */ }
    }
}
