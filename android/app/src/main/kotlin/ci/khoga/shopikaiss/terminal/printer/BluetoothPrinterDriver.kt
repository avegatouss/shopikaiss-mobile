package ci.khoga.shopikaiss.terminal.printer

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import ci.khoga.shopikaiss.terminal.LocalLog
import java.io.OutputStream
import java.util.UUID

/**
 * Imprimante en Bluetooth classique (profil série SPP) : imprimante intégrée exposée comme
 * périphérique virtuel « InnerPrinter » (nombreux terminaux Android chinois, anciens SUNMI) ou
 * imprimante portable appairée.
 *
 * [address] vide = premier périphérique appairé nommé « InnerPrinter » / « Printer ».
 * Android 12+ exige la permission BLUETOOTH_CONNECT : sans elle, le pilote renvoie
 * `bluetooth_permission_pending` et l'activité affiche la demande ([onPermissionNeeded]).
 */
@SuppressLint("MissingPermission")
class BluetoothPrinterDriver(
    private val context: Context,
    private val address: String,
    private val onPermissionNeeded: () -> Unit,
) : PrinterDriver {
    override val id = PrinterDriver.BLUETOOTH
    override val label = if (address.isBlank()) "Bluetooth (InnerPrinter)" else "Bluetooth $address"

    private var socket: BluetoothSocket? = null
    private var output: OutputStream? = null

    private fun ensureOpen(): OutputStream {
        output?.let { return it }
        if (!hasPermission(context)) {
            onPermissionNeeded()
            throw IllegalStateException("bluetooth_permission_pending")
        }
        val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
            ?: throw IllegalStateException("bluetooth_absent")
        if (!adapter.isEnabled) throw IllegalStateException("bluetooth_disabled")
        val device = findDevice(adapter.bondedDevices.orEmpty(), address)
            ?: throw IllegalStateException("bluetooth_printer_not_found")
        adapter.cancelDiscovery()
        val s = device.createRfcommSocketToServiceRecord(SPP)
        s.connect()
        socket = s
        LocalLog.i("Bluetooth connecté : ${device.name} (${device.address})")
        return s.outputStream.also { output = it }
    }

    override fun write(bytes: ByteArray) {
        // Une liaison SPP retombe en veille : un échec d'écriture rouvre la liaison une fois.
        for (attempt in 1..2) {
            try {
                val out = ensureOpen()
                out.write(bytes)
                out.flush()
                return
            } catch (e: Exception) {
                close()
                if (attempt == 2 || e.message?.startsWith("bluetooth_") == true) throw e
            }
        }
    }

    override fun status(): PrinterStatus = try {
        ensureOpen()
        PrinterStatus.unknown("bluetooth_write_only")
    } catch (e: Exception) {
        PrinterStatus.failure(e.message ?: "bluetooth_error")
    }

    override fun close() {
        try { output?.close() } catch (_: Exception) {}
        try { socket?.close() } catch (_: Exception) {}
        output = null
        socket = null
    }

    companion object {
        private val SPP: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
        private val INNER_NAMES = listOf("innerprinter", "inner printer", "printer001", "bluetoothprinter")

        fun hasPermission(context: Context): Boolean =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED

        fun findDevice(devices: Collection<BluetoothDevice>, address: String): BluetoothDevice? =
            if (address.isNotBlank()) devices.firstOrNull { it.address.equals(address, ignoreCase = true) }
            else devices.firstOrNull { (it.name ?: "").lowercase() in INNER_NAMES }

        /** Périphériques appairés, pour l'écran de réglage (vide sans permission). */
        fun bonded(context: Context): List<Map<String, String>> {
            if (!hasPermission(context)) return emptyList()
            val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter ?: return emptyList()
            return try {
                adapter.bondedDevices.orEmpty().map { mapOf("name" to (it.name ?: "?"), "address" to it.address) }
            } catch (e: SecurityException) {
                emptyList()
            }
        }

        /** Imprimante intégrée virtuelle appairée ? */
        fun hasInnerPrinter(context: Context): Boolean =
            bonded(context).any { (it["name"] ?: "").lowercase() in INNER_NAMES }
    }
}
