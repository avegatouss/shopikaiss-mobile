package ci.khoga.shopikaiss.terminal.printer

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import ci.khoga.shopikaiss.terminal.LocalLog

/**
 * Imprimante exposée en USB (hôte USB de la carte) : interface de classe imprimante (7) ou
 * interface désignée par vendorId/productId, écriture sur l'endpoint bulk OUT.
 *
 * Permission : Android exige l'accord de l'utilisateur pour chaque appareil USB. Deux voies :
 * - l'intent-filter `USB_DEVICE_ATTACHED` du manifeste (res/xml/usb_printer_filter.xml) : en
 *   cochant « Toujours utiliser » au branchement, l'accord est mémorisé ;
 * - sinon, au premier envoi, le pilote affiche la demande et renvoie `usb_permission_pending` :
 *   la page réessaie après l'accord (la vente, elle, est déjà enregistrée).
 *
 * [vendorId]/[productId] à 0 = détection automatique de la première interface de classe 7.
 */
class UsbPrinterDriver(
    private val context: Context,
    private val vendorId: Int,
    private val productId: Int,
) : PrinterDriver {
    override val id = PrinterDriver.USB
    override val label = if (vendorId == 0) "USB (détection automatique)" else "USB %04x:%04x".format(vendorId, productId)

    private val usbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager

    private var connection: UsbDeviceConnection? = null
    private var claimed: UsbInterface? = null
    private var outEndpoint: UsbEndpoint? = null
    private var inEndpoint: UsbEndpoint? = null

    private class Target(val device: UsbDevice, val intf: UsbInterface, val out: UsbEndpoint, val inp: UsbEndpoint?)

    private fun findTarget(): Target? {
        for (device in usbManager.deviceList.values) {
            val explicit = vendorId != 0
            if (explicit && (device.vendorId != vendorId || (productId != 0 && device.productId != productId))) continue
            for (i in 0 until device.interfaceCount) {
                val intf = device.getInterface(i)
                if (!explicit && intf.interfaceClass != UsbConstants.USB_CLASS_PRINTER) continue
                var out: UsbEndpoint? = null
                var inp: UsbEndpoint? = null
                for (e in 0 until intf.endpointCount) {
                    val ep = intf.getEndpoint(e)
                    if (ep.type != UsbConstants.USB_ENDPOINT_XFER_BULK) continue
                    if (ep.direction == UsbConstants.USB_DIR_OUT && out == null) out = ep
                    if (ep.direction == UsbConstants.USB_DIR_IN && inp == null) inp = ep
                }
                if (out != null) return Target(device, intf, out, inp)
            }
        }
        return null
    }

    private fun ensureOpen(): UsbDeviceConnection {
        connection?.let { return it }
        val target = findTarget() ?: throw IllegalStateException("usb_printer_not_found")
        if (!usbManager.hasPermission(target.device)) {
            requestPermission(target.device)
            throw IllegalStateException("usb_permission_pending")
        }
        val conn = usbManager.openDevice(target.device) ?: throw IllegalStateException("usb_open_failed")
        if (!conn.claimInterface(target.intf, true)) {
            conn.close()
            throw IllegalStateException("usb_claim_failed")
        }
        connection = conn
        claimed = target.intf
        outEndpoint = target.out
        inEndpoint = target.inp
        LocalLog.i("USB ouvert : %04x:%04x interface %d".format(target.device.vendorId, target.device.productId, target.intf.id))
        return conn
    }

    private fun requestPermission(device: UsbDevice) {
        // Intent explicite (setPackage) : obligatoire avec FLAG_MUTABLE depuis Android 14 ; MUTABLE
        // car le système ajoute EXTRA_DEVICE et EXTRA_PERMISSION_GRANTED à la réponse.
        val intent = Intent(ACTION_USB_PERMISSION).setPackage(context.packageName)
        val pending = PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_MUTABLE)
        usbManager.requestPermission(device, pending)
        LocalLog.w("Permission USB demandée pour %04x:%04x".format(device.vendorId, device.productId))
    }

    override fun write(bytes: ByteArray) {
        try {
            val conn = ensureOpen()
            val ep = outEndpoint ?: throw IllegalStateException("usb_no_out_endpoint")
            var offset = 0
            while (offset < bytes.size) {
                val length = minOf(CHUNK, bytes.size - offset)
                val sent = conn.bulkTransfer(ep, bytes, offset, length, TIMEOUT_MS)
                if (sent <= 0) throw IllegalStateException("usb_write_failed")
                offset += sent
            }
        } catch (e: Exception) {
            if (e.message != "usb_permission_pending") close()
            throw e
        }
    }

    override fun status(): PrinterStatus {
        return try {
            val conn = ensureOpen()
            val out = outEndpoint ?: return PrinterStatus.unknown()
            val inp = inEndpoint ?: return PrinterStatus.unknown("usb_write_only")
            val offline = query(conn, out, inp, EscPos.STATUS_OFFLINE)
            val paper = query(conn, out, inp, EscPos.STATUS_PAPER)
            if (offline == null && paper == null) PrinterStatus.unknown("no_status_response") else EscPos.parseStatus(offline, paper)
        } catch (e: Exception) {
            PrinterStatus.failure(e.message ?: "usb_error")
        }
    }

    private fun query(conn: UsbDeviceConnection, out: UsbEndpoint, inp: UsbEndpoint, command: ByteArray): Int? {
        if (conn.bulkTransfer(out, command, command.size, TIMEOUT_MS) != command.size) return null
        val buffer = ByteArray(inp.maxPacketSize.coerceAtLeast(8))
        val read = conn.bulkTransfer(inp, buffer, buffer.size, 300)
        return if (read > 0) buffer[read - 1].toInt() and 0xFF else null
    }

    override fun close() {
        try { claimed?.let { connection?.releaseInterface(it) } } catch (_: Exception) {}
        try { connection?.close() } catch (_: Exception) {}
        connection = null
        claimed = null
        outEndpoint = null
        inEndpoint = null
    }

    companion object {
        const val ACTION_USB_PERMISSION = "ci.khoga.shopikaiss.terminal.USB_PERMISSION"
        private const val CHUNK = 16 * 1024
        private const val TIMEOUT_MS = 3000
    }
}
