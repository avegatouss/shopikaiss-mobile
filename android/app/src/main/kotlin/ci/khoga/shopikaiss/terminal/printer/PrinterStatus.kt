package ci.khoga.shopikaiss.terminal.printer

/**
 * État de l'imprimante tel que le contrat n°4 le renvoie à la page :
 * `{"ok":true,"paper":"ok|out|near_end","cover":"closed|open","error":null}`.
 *
 * Quand le pilote ne sait pas lire l'état, `paper` et `cover` valent `"unknown"` et `ok` reste
 * vrai : l'absence d'information n'est pas une panne.
 */
data class PrinterStatus(
    val ok: Boolean,
    val paper: String,
    val cover: String,
    val error: String?,
) {
    fun toMap(): Map<String, Any?> = mapOf("ok" to ok, "paper" to paper, "cover" to cover, "error" to error)

    companion object {
        const val PAPER_OK = "ok"
        const val PAPER_OUT = "out"
        const val PAPER_NEAR_END = "near_end"
        const val COVER_CLOSED = "closed"
        const val COVER_OPEN = "open"
        const val UNKNOWN = "unknown"

        fun ready() = PrinterStatus(true, PAPER_OK, COVER_CLOSED, null)

        fun unknown(reason: String? = null) = PrinterStatus(true, UNKNOWN, UNKNOWN, reason)

        fun failure(error: String) = PrinterStatus(false, UNKNOWN, UNKNOWN, error)
    }
}
