package ci.khoga.shopikaiss.terminal.printer

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothClass
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
 * L'arrêt d'une recherche en cours (`cancelDiscovery`) exige en plus BLUETOOTH_SCAN depuis Android 12 : il n'est fait
 * que si cette permission est accordée (une recherche ne tourne presque jamais pendant la caisse), sinon l'appel levait
 * une SecurityException et aucune impression ne partait (Xiaomi Android 15, imprimante portable PT-210, 2026-10-24).
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
        try {
            val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
                ?: throw IllegalStateException("bluetooth_absent")
            if (!adapter.isEnabled) throw IllegalStateException("bluetooth_disabled")
            val device = findDevice(adapter.bondedDevices.orEmpty(), address)
                ?: throw IllegalStateException("bluetooth_printer_not_found")
            safeCancelDiscovery(context, adapter)
            val s = connect(device)
            socket = s
            LocalLog.i("Bluetooth connecté : ${device.name} (${device.address})")
            return s.outputStream.also { output = it }
        } catch (e: SecurityException) {
            // Permission retirée dans les réglages Android, ou exigée par un appel propre au constructeur.
            LocalLog.e("Bluetooth : permission refusée", e)
            onPermissionNeeded()
            throw IllegalStateException("bluetooth_permission_pending")
        }
    }

    /**
     * Liaison SPP sécurisée, puis non sécurisée : beaucoup d'imprimantes portables bon marché (PT-210, MPT-II…) refusent
     * la première ou la font échouer après l'appairage.
     */
    private fun connect(device: BluetoothDevice): BluetoothSocket {
        val secure = device.createRfcommSocketToServiceRecord(SPP)
        try {
            secure.connect()
            return secure
        } catch (e: java.io.IOException) {
            try { secure.close() } catch (_: Exception) {}
            LocalLog.i("Bluetooth : liaison sécurisée refusée par ${device.address}, essai non sécurisé (${e.message})")
        }
        val insecure = device.createInsecureRfcommSocketToServiceRecord(SPP)
        try {
            insecure.connect()
            return insecure
        } catch (e: java.io.IOException) {
            try { insecure.close() } catch (_: Exception) {}
            throw IllegalStateException("bluetooth_connect_failed")
        }
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

        /** Arrête une recherche en cours, seulement si BLUETOOTH_SCAN est accordée (isDiscovering l'exige aussi). */
        fun safeCancelDiscovery(context: Context, adapter: BluetoothAdapter) {
            if (!canScan(context)) return
            try {
                if (adapter.isDiscovering) adapter.cancelDiscovery()
            } catch (_: SecurityException) {
            }
        }

        /** BLUETOOTH_SCAN (Android 12+) : seulement pour arrêter une recherche en cours, jamais exigée pour imprimer. */
        fun canScan(context: Context): Boolean =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                context.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED

        fun hasPermission(context: Context): Boolean =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED

        /** Noms courants des imprimantes portables ESC/POS (PT-210, MPT-II, RPP02N, MTP-II, Goojprt…). */
        private val PRINTER_NAME = Regex("(printer|imprim|^pt-?[0-9]|^mpt|^mtp|^rpp|^pos|^goojprt|^xp-|^zj-|^bt-?print)", RegexOption.IGNORE_CASE)

        /** Imprimante appairée : classe Bluetooth « imagerie » (imprimantes) ou nom usuel d'imprimante. */
        @SuppressLint("MissingPermission")
        fun looksLikePrinter(device: BluetoothDevice): Boolean {
            val major = try { device.bluetoothClass?.majorDeviceClass } catch (_: SecurityException) { null }
            return major == BluetoothClass.Device.Major.IMAGING || PRINTER_NAME.containsMatchIn(device.name ?: "")
        }

        /**
         * Adresse choisie, sinon (« automatique ») l'imprimante intégrée virtuelle « InnerPrinter » des terminaux, sinon
         * la première imprimante appairée (téléphone ou tablette avec imprimante portable). Un téléphone ou un casque
         * appairé n'est jamais choisi d'office.
         */
        fun findDevice(devices: Collection<BluetoothDevice>, address: String): BluetoothDevice? =
            if (address.isNotBlank()) devices.firstOrNull { it.address.equals(address, ignoreCase = true) }
            else devices.firstOrNull { (it.name ?: "").lowercase() in INNER_NAMES } ?: devices.firstOrNull { looksLikePrinter(it) }

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

        /** Imprimante appairée (intégrée « InnerPrinter » ou portable) : choisie par le mode automatique sans SUNMI ni USB. */
        @SuppressLint("MissingPermission")
        fun hasPairedPrinter(context: Context): Boolean {
            if (!hasPermission(context)) return false
            val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter ?: return false
            return try {
                findDevice(adapter.bondedDevices.orEmpty(), "") != null
            } catch (_: SecurityException) {
                false
            }
        }

        /** Imprimante intégrée virtuelle appairée ? */
        fun hasInnerPrinter(context: Context): Boolean =
            bonded(context).any { (it["name"] ?: "").lowercase() in INNER_NAMES }
    }
}
