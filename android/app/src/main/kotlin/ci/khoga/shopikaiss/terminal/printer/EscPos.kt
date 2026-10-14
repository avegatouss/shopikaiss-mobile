package ci.khoga.shopikaiss.terminal.printer

/**
 * Commandes ESC/POS dont l'application a besoin pour elle-même : tiroir et lecture d'état.
 * Le ticket de vente n'est pas construit ici : la page l'envoie déjà encodé (`escpos-ticket.js`).
 */
object EscPos {
    const val ESC: Byte = 0x1B
    const val DLE: Byte = 0x10
    const val EOT: Byte = 0x04

    /** ESC p m t1 t2 : impulsion tiroir sur la broche 2 (m=0), 50 ms haut, 500 ms bas (unités de 2 ms). */
    fun drawerPulse(pin: Int = 0, onMs: Int = 50, offMs: Int = 500): ByteArray =
        byteArrayOf(ESC, 0x70, pin.coerceIn(0, 1).toByte(), (onMs / 2).coerceIn(1, 255).toByte(), (offMs / 2).coerceIn(1, 255).toByte())

    /** DLE EOT 2 : état « hors ligne » (capot, arrêt sur fin de papier, erreur). */
    val STATUS_OFFLINE = byteArrayOf(DLE, EOT, 0x02)

    /** DLE EOT 4 : capteurs du rouleau (presque fini, fini). */
    val STATUS_PAPER = byteArrayOf(DLE, EOT, 0x04)

    /** Un octet de réponse DLE EOT valide a les bits 1 et 4 à 1, les bits 0 et 7 à 0. */
    fun isValidStatusByte(b: Int): Boolean = (b and 0x93) == 0x12

    /** Interprète les réponses à DLE EOT 2 ([offline]) et DLE EOT 4 ([paper]). */
    fun parseStatus(offline: Int?, paper: Int?): PrinterStatus {
        val offlineValid = offline != null && isValidStatusByte(offline)
        val paperValid = paper != null && isValidStatusByte(paper)

        val cover = when {
            !offlineValid -> PrinterStatus.UNKNOWN
            (offline!! and 0x04) != 0 -> PrinterStatus.COVER_OPEN
            else -> PrinterStatus.COVER_CLOSED
        }

        val paperState = when {
            paperValid && (paper!! and 0x60) != 0 -> PrinterStatus.PAPER_OUT
            offlineValid && (offline!! and 0x20) != 0 -> PrinterStatus.PAPER_OUT
            paperValid && (paper!! and 0x0C) != 0 -> PrinterStatus.PAPER_NEAR_END
            paperValid -> PrinterStatus.PAPER_OK
            else -> PrinterStatus.UNKNOWN
        }

        val error = when {
            offlineValid && (offline!! and 0x40) != 0 -> "printer_error"
            cover == PrinterStatus.COVER_OPEN -> "cover_open"
            paperState == PrinterStatus.PAPER_OUT -> "paper_out"
            else -> null
        }

        return PrinterStatus(ok = error == null, paper = paperState, cover = cover, error = error)
    }
}
