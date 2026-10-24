package ci.khoga.shopikaiss.terminal

import android.Manifest
import android.app.Activity
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Handler
import android.os.Looper
import ci.khoga.shopikaiss.terminal.display.CustomerDisplayController
import ci.khoga.shopikaiss.terminal.printer.BluetoothPrinterDriver
import ci.khoga.shopikaiss.terminal.printer.PrinterDriver
import ci.khoga.shopikaiss.terminal.printer.PrinterManager
import ci.khoga.shopikaiss.terminal.printer.PrinterSettings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Canal `ci.khoga.shopikaiss/terminal` : ce que le Dart (et, par lui, la page de la caisse) demande
 * au matériel. Les accès imprimante passent sur un fil dédié (ils bloquent) ; l'afficheur client
 * et les réponses au Dart sur le fil UI.
 *
 * Les ordres imprimante répondent toujours une map `{"ok":…, "error":…}` (contrat n°4), jamais une
 * exception de canal : la page doit pouvoir afficher le code d'erreur.
 */
class TerminalPlugin(private val activity: Activity, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor { Thread(it, "shopikaiss-printer") }
    private val printers = PrinterManager(activity) { main.post { requestBluetoothPermission() } }
    private val display = CustomerDisplayController(activity).also { it.start() }
    private val keyboard = KeyboardBlocker(activity).also { it.start() }
    private var toneGenerator: ToneGenerator? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "info" -> background(result) { info() }
            "configure" -> background(result) { printers.configure(settingsFrom(call)) }
            "printRaw" -> printerCall(result) { it.write(call.argument<ByteArray>("bytes") ?: ByteArray(0)) }
            "openDrawer" -> printerCall(result) { it.openDrawer() }
            "status" -> background(result) { printers.use { it.status() }.toMap() }
            "beep" -> {
                beep(call.argument<Int>("ms") ?: 80)
                result.success(OK)
            }
            "showCustomerDisplay" -> {
                val error = display.show(call.argument<String>("url").orEmpty(), call.argument<String>("allowedOrigin").orEmpty())
                result.success(if (error == null) OK else failure(error))
            }
            "setSoftKeyboardBlocked" -> {
                keyboard.blocked = call.argument<Boolean>("blocked") == true
                result.success(OK)
            }
            "hideCustomerDisplay" -> {
                display.hide()
                result.success(OK)
            }
            "bluetoothDevices" -> {
                if (!BluetoothPrinterDriver.hasPermission(activity)) requestBluetoothPermission()
                result.success(BluetoothPrinterDriver.bonded(activity))
            }
            "usbDevices" -> result.success(PrinterManager.usbDevices(activity))
            "serialPorts" -> background(result) { PrinterManager.serialPorts() }
            else -> result.notImplemented()
        }
    }

    private fun info(): Map<String, Any?> {
        val detected = printers.detect()
        val paper = if (detected == PrinterDriver.NONE) 0 else runCatching { printers.use { it.paperWidth() } }.getOrDefault(0)
        return mapOf(
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "brand" to Build.BRAND,
            "android" to Build.VERSION.RELEASE,
            "sdk" to Build.VERSION.SDK_INT,
            "displays" to onUiBlocking { display.displays() },
            "hasSecondaryDisplay" to onUiBlocking { display.secondaryDisplay() != null },
            "screenInches" to onUiBlocking { display.mainScreenInches() },
            "detectedDriver" to detected,
            "detectedLabel" to PrinterManager.label(detected),
            "detectedPaper" to paper,
        )
    }

    private fun settingsFrom(call: MethodCall) = PrinterSettings(
        driver = call.argument<String>("driver") ?: PrinterDriver.AUTO,
        serialPath = call.argument<String>("serialPath") ?: "/dev/ttyS1",
        serialBaud = call.argument<Int>("serialBaud") ?: 115200,
        bluetoothAddress = call.argument<String>("bluetoothAddress").orEmpty(),
        usbVendorId = call.argument<Int>("usbVendorId") ?: 0,
        usbProductId = call.argument<Int>("usbProductId") ?: 0,
    )

    private fun printerCall(result: MethodChannel.Result, block: (PrinterDriver) -> Unit) = background(result) {
        try {
            printers.use(block)
            OK
        } catch (e: Exception) {
            LocalLog.e("Imprimante en échec", e)
            failure(e.message ?: e.javaClass.simpleName)
        }
    }

    private fun <T> background(result: MethodChannel.Result, block: () -> T) {
        io.execute {
            val value = try {
                Result.success(block())
            } catch (e: Exception) {
                Result.failure(e)
            }
            main.post {
                value.fold(
                    onSuccess = { result.success(it) },
                    onFailure = { result.error("terminal_error", it.message ?: it.javaClass.simpleName, null) },
                )
            }
        }
    }

    private fun <T> onUiBlocking(block: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return block()
        val latch = java.util.concurrent.CountDownLatch(1)
        var value: Result<T>? = null
        main.post {
            value = runCatching(block)
            latch.countDown()
        }
        latch.await(2, java.util.concurrent.TimeUnit.SECONDS)
        return value?.getOrThrow() ?: throw IllegalStateException("ui_timeout")
    }

    private fun beep(ms: Int) {
        val tg = toneGenerator ?: ToneGenerator(AudioManager.STREAM_MUSIC, ToneGenerator.MAX_VOLUME).also { toneGenerator = it }
        tg.startTone(ToneGenerator.TONE_PROP_BEEP, ms.coerceIn(10, 2000))
    }

    private fun requestBluetoothPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            activity.requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), REQUEST_BLUETOOTH)
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        display.stop()
        io.execute { printers.close() }
        io.shutdown()
        toneGenerator?.release()
        toneGenerator = null
    }

    companion object {
        const val CHANNEL = "ci.khoga.shopikaiss/terminal"
        private const val REQUEST_BLUETOOTH = 4101
        private val OK = mapOf("ok" to true)
        private fun failure(error: String) = mapOf("ok" to false, "error" to error)
    }
}
