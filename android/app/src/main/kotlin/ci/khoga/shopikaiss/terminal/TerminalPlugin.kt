package ci.khoga.shopikaiss.terminal

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.os.BatteryManager
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
    private val display = CustomerDisplayController(activity) { status ->
        main.post { channel.invokeMethod("customerDisplayError", mapOf("status" to status)) }
    }.also { it.start() }
    private val keyboard = KeyboardBlocker(activity).also { it.start() }
    private var toneGenerator: ToneGenerator? = null
    private var pendingImage: MethodChannel.Result? = null
    private var pendingSave: Pair<MethodChannel.Result, ByteArray>? = null
    private var pendingOpen: MethodChannel.Result? = null

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
            "reloadCustomerDisplay" -> {
                val error = display.reload()
                result.success(if (error == null) OK else failure(error))
            }
            "hideCustomerDisplay" -> {
                display.hide()
                result.success(OK)
            }
            "pushCustomerDisplay" -> {
                val error = display.push(call.argument<String>("script").orEmpty(), call.argument<String>("html").orEmpty())
                result.success(if (error == null) OK else failure(error))
            }
            "bluetoothDevices" -> {
                if (!BluetoothPrinterDriver.hasPermission(activity)) requestBluetoothPermission()
                result.success(BluetoothPrinterDriver.bonded(activity))
            }
            "usbDevices" -> result.success(PrinterManager.usbDevices(activity))
            "pickImage" -> pickImage(result)
            "lastCrash" -> result.success(CrashLog.read(activity))
            "clearCrash" -> {
                CrashLog.clear(activity)
                result.success(OK)
            }
            "serialPorts" -> background(result) { PrinterManager.serialPorts() }
            "battery" -> result.success(battery())
            "startMasterService" -> {
                MasterService.start(activity, call.argument<String>("text") ?: "Caisse maîtresse active")
                result.success(OK)
            }
            "stopMasterService" -> {
                MasterService.stop(activity)
                result.success(OK)
            }
            "saveDocument" -> saveDocument(call, result)
            "openDocument" -> openDocument(result)
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
            // Les deux d'un coup (même autorisation « Appareils à proximité ») : CONNECT pour imprimer, SCAN pour cancelDiscovery.
            activity.requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN), REQUEST_BLUETOOTH)
        }
    }

    /**
     * Logo des tickets : sélecteur d'images du système (PNG ou JPG), lu une fois puis gardé par le Dart.
     * Rend les octets (2 Mo + 1 au plus, le Dart refuse au-delà) ou null si rien n'est choisi.
     */
    private fun pickImage(result: MethodChannel.Result) {
        if (pendingImage != null) {
            result.success(null)
            return
        }
        val intent = Intent(Intent.ACTION_GET_CONTENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("image/*")
            .putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/png", "image/jpeg"))
        pendingImage = result
        try {
            activity.startActivityForResult(intent, PICK_IMAGE)
        } catch (_: ActivityNotFoundException) {
            pendingImage = null
            result.success(null)
        }
    }

    /** Niveau de batterie (0 à 100, -1 inconnu) et branchement sur secteur ou USB. */
    private fun battery(): Map<String, Any> {
        val intent = activity.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val plugged = intent?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
        return mapOf("ok" to true, "level" to (if (level >= 0 && scale > 0) level * 100 / scale else -1), "plugged" to (plugged != 0))
    }

    /** Sauvegarde de la caisse : le gérant choisit où l'enregistrer (carte, clé USB, Drive) ; rien n'est écrit ailleurs. */
    private fun saveDocument(call: MethodCall, result: MethodChannel.Result) {
        val bytes = call.argument<ByteArray>("bytes")
        if (bytes == null || pendingSave != null) {
            result.success(failure("busy"))
            return
        }
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("application/octet-stream")
            .putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: "caisse.skcaisse")
        pendingSave = result to bytes
        try {
            activity.startActivityForResult(intent, SAVE_DOCUMENT)
        } catch (_: ActivityNotFoundException) {
            pendingSave = null
            result.success(failure("no_picker"))
        }
    }

    /** Fichier de sauvegarde choisi par le gérant (200 Mo au plus), ou null. */
    private fun openDocument(result: MethodChannel.Result) {
        if (pendingOpen != null) {
            result.success(null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
        pendingOpen = result
        try {
            activity.startActivityForResult(intent, OPEN_DOCUMENT)
        } catch (_: ActivityNotFoundException) {
            pendingOpen = null
            result.success(null)
        }
    }

    private fun onDocumentResult(requestCode: Int, resultCode: Int, data: Intent?) {
        val uri = data?.data
        if (requestCode == SAVE_DOCUMENT) {
            val (reply, bytes) = pendingSave ?: return
            pendingSave = null
            if (resultCode != Activity.RESULT_OK || uri == null) {
                reply.success(failure("cancelled"))
                return
            }
            Thread {
                val outcome = try {
                    val stream = activity.contentResolver.openOutputStream(uri, "wt") ?: throw IllegalStateException("no_stream")
                    stream.use {
                        it.write(bytes)
                        it.flush()
                    }
                    OK
                } catch (e: Exception) {
                    failure(e.message ?: e.javaClass.simpleName)
                }
                main.post { reply.success(outcome) }
            }.start()
            return
        }
        val reply = pendingOpen ?: return
        pendingOpen = null
        if (resultCode != Activity.RESULT_OK || uri == null) {
            reply.success(null)
            return
        }
        Thread {
            val bytes = try {
                activity.contentResolver.openInputStream(uri)?.use { input ->
                    val limit = 200 * 1024 * 1024
                    val buffer = java.io.ByteArrayOutputStream()
                    val chunk = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(chunk)
                        if (n < 0) break
                        buffer.write(chunk, 0, n)
                        if (buffer.size() > limit) throw IllegalStateException("too_large")
                    }
                    buffer.toByteArray()
                }
            } catch (_: Exception) {
                null
            }
            main.post { reply.success(bytes) }
        }.start()
    }

    /** Appelé par [MainActivity.onActivityResult] ; vrai si la réponse est celle d'un sélecteur de ce canal. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == SAVE_DOCUMENT || requestCode == OPEN_DOCUMENT) {
            onDocumentResult(requestCode, resultCode, data)
            return true
        }
        if (requestCode != PICK_IMAGE) return false
        val reply = pendingImage ?: return true
        pendingImage = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            reply.success(null)
            return true
        }
        Thread {
            val bytes = try {
                activity.contentResolver.openInputStream(uri)?.use { input ->
                    val limit = 2 * 1024 * 1024 + 1
                    val buffer = java.io.ByteArrayOutputStream()
                    val chunk = ByteArray(16 * 1024)
                    while (buffer.size() < limit) {
                        val n = input.read(chunk, 0, minOf(chunk.size, limit - buffer.size()))
                        if (n < 0) break
                        buffer.write(chunk, 0, n)
                    }
                    buffer.toByteArray()
                }
            } catch (_: Exception) {
                null
            }
            main.post { reply.success(bytes) }
        }.start()
        return true
    }

    fun dispose() {
        pendingImage?.success(null)
        pendingImage = null
        pendingSave?.first?.success(failure("cancelled"))
        pendingSave = null
        pendingOpen?.success(null)
        pendingOpen = null
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
        private const val PICK_IMAGE = 4102
        private const val SAVE_DOCUMENT = 4103
        private const val OPEN_DOCUMENT = 4104
        private val OK = mapOf("ok" to true)
        private fun failure(error: String) = mapOf("ok" to false, "error" to error)
    }
}
