package ci.khoga.shopikaiss.terminal.printer

import android.content.Context
import android.content.pm.PackageManager
import ci.khoga.shopikaiss.terminal.LocalLog
import com.sunmi.peripheral.printer.InnerPrinterCallback
import com.sunmi.peripheral.printer.InnerPrinterManager
import com.sunmi.peripheral.printer.InnerResultCallback
import com.sunmi.peripheral.printer.SunmiPrinterService
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Imprimante intégrée des terminaux SUNMI (V2, V2s, P2, T2, D2, K2…) par le service système
 * `woyou.aidlservice.jiuiv5` et la bibliothèque officielle `com.sunmi:printerlibrary`.
 *
 * La liaison au service est asynchrone : le premier envoi attend la connexion (3 s au plus). Les
 * octets ESC/POS de la page passent tels quels par `sendRAWData` ; le tiroir des caisses fixes
 * (T2, D2) passe par `openDrawer` du service, l'impulsion ESC p n'y étant pas toujours relayée.
 */
class SunmiPrinterDriver(private val context: Context) : PrinterDriver {
    override val id = PrinterDriver.SUNMI
    override val label = "Imprimante intégrée SUNMI"

    @Volatile private var service: SunmiPrinterService? = null
    @Volatile private var connected = CountDownLatch(1)
    private var bound = false

    private val connection = object : InnerPrinterCallback() {
        override fun onConnected(service: SunmiPrinterService) {
            this@SunmiPrinterDriver.service = service
            connected.countDown()
            LocalLog.i("Service d'impression SUNMI connecté")
        }

        override fun onDisconnected() {
            service = null
            bound = false
            LocalLog.w("Service d'impression SUNMI déconnecté")
        }
    }

    private fun ensureService(): SunmiPrinterService {
        service?.let { return it }
        if (!bound) {
            connected = CountDownLatch(1)
            bound = try {
                InnerPrinterManager.getInstance().bindService(context, connection)
            } catch (e: Exception) {
                LocalLog.e("Liaison au service SUNMI impossible", e)
                false
            }
            if (!bound) throw IllegalStateException("sdk_absent")
        }
        connected.await(3, TimeUnit.SECONDS)
        return service ?: throw IllegalStateException("sunmi_service_timeout")
    }

    override fun write(bytes: ByteArray) {
        val s = ensureService()
        stateError(s.updatePrinterState())?.let { throw IllegalStateException(it) }
        run("sendRAWData") { s.sendRAWData(bytes, it) }
    }

    override fun openDrawer() {
        val s = ensureService()
        try {
            run("openDrawer") { s.openDrawer(it) }
        } catch (e: Exception) {
            LocalLog.w("openDrawer SUNMI indisponible, impulsion ESC p", e)
            run("sendRAWData") { s.sendRAWData(EscPos.drawerPulse(), it) }
        }
    }

    override fun status(): PrinterStatus = try {
        when (val state = ensureService().updatePrinterState()) {
            1 -> PrinterStatus.ready()
            4 -> PrinterStatus(false, PrinterStatus.PAPER_OUT, PrinterStatus.UNKNOWN, "paper_out")
            6 -> PrinterStatus(false, PrinterStatus.UNKNOWN, PrinterStatus.COVER_OPEN, "cover_open")
            2 -> PrinterStatus.unknown("printer_initialising")
            else -> PrinterStatus.failure(stateError(state) ?: "sunmi_state_$state")
        }
    } catch (e: Exception) {
        PrinterStatus.failure(e.message ?: "sunmi_error")
    }

    /** `getPrinterPaper()` : 1 = 58 mm, 2 = 80 mm. */
    override fun paperWidth(): Int = try {
        when (ensureService().getPrinterPaper()) {
            1 -> 58
            2 -> 80
            else -> 0
        }
    } catch (e: Exception) {
        0
    }

    override fun close() {
        if (!bound) return
        try {
            InnerPrinterManager.getInstance().unBindService(context, connection)
        } catch (_: Exception) {
        }
        bound = false
        service = null
    }

    /** Codes de `updatePrinterState()` qui empêchent l'impression (1 = prête, 2 = initialisation). */
    private fun stateError(state: Int): String? = when (state) {
        1, 2 -> null
        3 -> "printer_error"
        4 -> "paper_out"
        5 -> "printer_overheated"
        6 -> "cover_open"
        7 -> "cutter_error"
        505 -> "sdk_absent"
        else -> null
    }

    /** Appel avec rappel : attend `onRunResult` (5 s au plus ; sans réponse, l'envoi est réputé fait). */
    private fun run(method: String, call: (InnerResultCallback) -> Unit) {
        val done = CountDownLatch(1)
        var error: String? = null
        val callback = object : InnerResultCallback() {
            override fun onRunResult(isSuccess: Boolean) {
                if (!isSuccess) error = "sunmi_${method}_failed"
                done.countDown()
            }

            override fun onReturnString(result: String?) {}

            override fun onRaiseException(code: Int, msg: String?) {
                error = msg?.takeIf { it.isNotBlank() } ?: "sunmi_error_$code"
                done.countDown()
            }

            override fun onPrintResult(code: Int, msg: String?) {}
        }
        call(callback)
        if (!done.await(5, TimeUnit.SECONDS)) LocalLog.w("SUNMI $method : pas de rappel en 5 s")
        error?.let { throw IllegalStateException(it) }
    }

    companion object {
        const val SERVICE_PACKAGE = "woyou.aidlservice.jiuiv5"

        fun isAvailable(context: Context): Boolean = try {
            context.packageManager.getPackageInfo(SERVICE_PACKAGE, 0)
            true
        } catch (e: PackageManager.NameNotFoundException) {
            false
        }
    }
}
