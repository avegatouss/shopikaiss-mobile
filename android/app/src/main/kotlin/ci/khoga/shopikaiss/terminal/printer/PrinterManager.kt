package ci.khoga.shopikaiss.terminal.printer

import android.content.Context
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbManager
import android.os.Build
import ci.khoga.shopikaiss.terminal.LocalLog

/** Réglages d'imprimante reçus de l'écran de configuration (Dart). */
data class PrinterSettings(
    val driver: String = PrinterDriver.AUTO,
    val serialPath: String = "/dev/ttyS1",
    val serialBaud: Int = 115200,
    val bluetoothAddress: String = "",
    val usbVendorId: Int = 0,
    val usbProductId: Int = 0,
)

/**
 * Choisit le pilote (réglage explicite ou détection automatique du terminal) et sérialise les
 * accès : deux impressions simultanées ne doivent jamais entrelacer leurs octets.
 */
class PrinterManager(
    private val context: Context,
    private val onBluetoothPermissionNeeded: () -> Unit,
) {
    private val lock = Any()
    private var settings = PrinterSettings()
    private var driver: PrinterDriver? = null

    /** Applique de nouveaux réglages ; renvoie l'identifiant du pilote effectivement retenu. */
    fun configure(newSettings: PrinterSettings): String = synchronized(lock) {
        driver?.close()
        driver = null
        settings = newSettings
        current().id
    }

    fun current(): PrinterDriver = synchronized(lock) {
        driver ?: create(resolve(settings.driver)).also {
            driver = it
            LocalLog.i("Pilote d'imprimante : ${it.label}")
        }
    }

    fun <T> use(block: (PrinterDriver) -> T): T = synchronized(lock) { block(current()) }

    fun close() = synchronized(lock) {
        driver?.close()
        driver = null
    }

    /** `auto` → pilote du terminal détecté ; tout autre identifiant est gardé tel quel. */
    private fun resolve(id: String): String = if (id == PrinterDriver.AUTO) detect() else id

    private fun create(id: String): PrinterDriver = when (id) {
        PrinterDriver.SUNMI -> SunmiPrinterDriver(context.applicationContext)
        PrinterDriver.USB -> UsbPrinterDriver(context.applicationContext, settings.usbVendorId, settings.usbProductId)
        PrinterDriver.BLUETOOTH -> BluetoothPrinterDriver(context.applicationContext, settings.bluetoothAddress, onBluetoothPermissionNeeded)
        PrinterDriver.SERIAL -> SerialPrinterDriver(settings.serialPath, settings.serialBaud.takeIf { it > 0 })
        else -> NoPrinterDriver()
    }

    /**
     * Détection de l'imprimante intégrée, du plus sûr au moins sûr :
     * 1. service d'impression SUNMI installé ;
     * 2. appareil USB de classe imprimante (iMin, terminaux Rockchip à imprimante USB interne…) ;
     * 3. imprimante Bluetooth appairée : « InnerPrinter » virtuelle, sinon imprimante portable (PT-210, MPT-II…).
     * Le port série n'est jamais choisi d'office : écrire sur le mauvais `/dev/ttyS*` peut piloter
     * un autre périphérique de la carte. Il se règle à la main.
     */
    fun detect(): String {
        val ctx = context.applicationContext
        return when {
            SunmiPrinterDriver.isAvailable(ctx) -> PrinterDriver.SUNMI
            hasUsbPrinter(ctx) -> PrinterDriver.USB
            BluetoothPrinterDriver.hasPairedPrinter(ctx) -> PrinterDriver.BLUETOOTH
            else -> PrinterDriver.NONE
        }
    }

    companion object {
        fun label(id: String): String = when (id) {
            PrinterDriver.SUNMI -> "Imprimante intégrée SUNMI"
            PrinterDriver.USB -> "Imprimante USB interne"
            PrinterDriver.BLUETOOTH -> "Imprimante Bluetooth appairée"
            PrinterDriver.SERIAL -> "Port série"
            else -> "Aucune imprimante intégrée détectée"
        }

        fun hasUsbPrinter(context: Context): Boolean = usbDevices(context).any { it["printer"] == true }

        fun usbDevices(context: Context): List<Map<String, Any>> {
            val manager = context.getSystemService(Context.USB_SERVICE) as UsbManager
            return manager.deviceList.values.map { device ->
                val printer = (0 until device.interfaceCount).any { device.getInterface(it).interfaceClass == UsbConstants.USB_CLASS_PRINTER }
                mapOf(
                    "vendorId" to device.vendorId,
                    "productId" to device.productId,
                    "name" to (device.productName ?: device.deviceName),
                    "printer" to printer,
                )
            }
        }

        /** Nœuds série candidats, avec leur droit d'écriture pour une application ordinaire. */
        fun serialPorts(): List<Map<String, Any>> =
            (java.io.File("/dev").listFiles { f -> f.name.matches(Regex("^tty(S|HS|MT|MSM|USB|ACM)[0-9]+$")) } ?: emptyArray())
                .sortedBy { it.name }
                .map { mapOf("path" to it.absolutePath, "writable" to it.canWrite()) }

        fun deviceLabel(): String = "${Build.MANUFACTURER} ${Build.MODEL}".trim()
    }
}
