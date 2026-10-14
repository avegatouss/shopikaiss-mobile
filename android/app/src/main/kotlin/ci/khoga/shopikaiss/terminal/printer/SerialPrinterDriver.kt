package ci.khoga.shopikaiss.terminal.printer

import ci.khoga.shopikaiss.terminal.LocalLog
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.TimeUnit

/**
 * Imprimante interne reliée à un port série de la carte (`/dev/ttyS*`), cas fréquent sur les
 * terminaux Rockchip : écriture brute des octets ESC/POS dans le nœud de périphérique.
 *
 * Prérequis (à vérifier sur le ST-T40, voir docs/deploiement-terminal.md) :
 * - le nœud doit être lisible/inscriptible par une application ordinaire (`crw-rw-rw-`, droit posé
 *   par la ROM constructeur). Sinon : SDK constructeur, ou ROM/`chmod` en usine — une application
 *   non système ne peut pas s'octroyer ce droit ;
 * - le débit : Java ne sait pas régler un tty sans code natif. Si [baud] est renseigné, le pilote
 *   tente `stty -F <port> <baud> raw -echo` (toybox d'Android) une fois à l'ouverture et journalise
 *   le résultat ; sinon le port garde le débit fixé par la ROM.
 */
class SerialPrinterDriver(
    private val path: String,
    private val baud: Int?,
) : PrinterDriver {
    override val id = PrinterDriver.SERIAL
    override val label = "Port série $path" + (baud?.let { " ($it bauds)" } ?: "")

    private var output: FileOutputStream? = null
    private var input: FileInputStream? = null

    private fun ensureOpen(): FileOutputStream {
        output?.let { return it }
        require(path.matches(Regex("^/dev/tty[A-Za-z0-9]+$"))) { "Port série invalide : $path" }
        val device = File(path)
        if (!device.exists()) throw IllegalStateException("Port $path introuvable")
        if (!device.canWrite()) throw IllegalStateException("Port $path non inscriptible (droits du nœud : voir la doc)")
        if (baud != null) configureBaud()
        return FileOutputStream(device).also {
            output = it
            input = try {
                if (device.canRead()) FileInputStream(device) else null
            } catch (e: Exception) {
                null
            }
            LocalLog.i("Port série $path ouvert" + if (input == null) " (écriture seule)" else "")
        }
    }

    private fun configureBaud() {
        try {
            val process = ProcessBuilder("stty", "-F", path, baud.toString(), "raw", "-echo")
                .redirectErrorStream(true)
                .start()
            val finished = process.waitFor(2, TimeUnit.SECONDS)
            val outputText = process.inputStream.bufferedReader().readText().trim()
            if (!finished) process.destroy()
            if (finished && process.exitValue() == 0) {
                LocalLog.i("stty $path $baud : appliqué")
            } else {
                LocalLog.w("stty $path $baud : non appliqué ($outputText) — débit de la ROM conservé")
            }
        } catch (e: Exception) {
            LocalLog.w("stty indisponible — débit de la ROM conservé", e)
        }
    }

    override fun write(bytes: ByteArray) {
        try {
            val out = ensureOpen()
            out.write(bytes)
            out.flush()
        } catch (e: Exception) {
            close()
            throw e
        }
    }

    override fun status(): PrinterStatus {
        return try {
            val out = ensureOpen()
            val inp = input ?: return PrinterStatus.unknown("serial_write_only")
            drain(inp)
            out.write(EscPos.STATUS_OFFLINE); out.flush()
            val offline = readByte(inp, 300)
            out.write(EscPos.STATUS_PAPER); out.flush()
            val paper = readByte(inp, 300)
            if (offline == null && paper == null) PrinterStatus.unknown("no_status_response") else EscPos.parseStatus(offline, paper)
        } catch (e: Exception) {
            close()
            PrinterStatus.failure(e.message ?: "serial_error")
        }
    }

    private fun drain(inp: FileInputStream) {
        while (inp.available() > 0) inp.read()
    }

    private fun readByte(inp: FileInputStream, timeoutMs: Long): Int? {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (inp.available() > 0) return inp.read()
            Thread.sleep(10)
        }
        return null
    }

    override fun close() {
        try { output?.close() } catch (_: Exception) {}
        try { input?.close() } catch (_: Exception) {}
        output = null
        input = null
    }
}
