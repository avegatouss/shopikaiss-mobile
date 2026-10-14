package ci.khoga.shopikaiss.terminal.printer

/**
 * Point d'extension matériel : la page envoie des octets ESC/POS, le pilote les remet à
 * l'imprimante par le canal propre au terminal (repris de l'application « ShopiKaiss Bridge »).
 *
 * Les méthodes sont appelées depuis le fil d'impression de [PrinterManager] (jamais le fil UI), une
 * à la fois. Elles peuvent donc bloquer quelques centaines de ms.
 */
interface PrinterDriver {
    /** Identifiant stable : `sunmi`, `usb`, `bluetooth`, `serial`, `none`. */
    val id: String

    /** Libellé lisible, pour l'écran de réglage. */
    val label: String

    /** Envoie des octets bruts. Lève une exception (message = code d'erreur du contrat) en cas d'échec. */
    @Throws(Exception::class)
    fun write(bytes: ByteArray)

    /** Lit l'état si le canal le permet ; sinon [PrinterStatus.unknown]. Ne lève pas. */
    fun status(): PrinterStatus

    /** Ouvre le tiroir-caisse. Par défaut : impulsion ESC p sur la broche 2. */
    @Throws(Exception::class)
    fun openDrawer() = write(EscPos.drawerPulse())

    /** Largeur de papier connue du pilote (58/80), 0 si inconnue. */
    fun paperWidth(): Int = 0

    /** Libère le port. Appelé au changement de pilote et à la destruction de l'activité. */
    fun close() {}

    companion object {
        const val AUTO = "auto"
        const val SUNMI = "sunmi"
        const val USB = "usb"
        const val BLUETOOTH = "bluetooth"
        const val SERIAL = "serial"
        const val NONE = "none"
    }
}

/** Aucune imprimante : chaque envoi échoue avec un code que la page sait afficher. */
class NoPrinterDriver : PrinterDriver {
    override val id = PrinterDriver.NONE
    override val label = "Aucune imprimante"

    override fun write(bytes: ByteArray) = throw IllegalStateException("printer_not_configured")

    override fun status() = PrinterStatus.failure("printer_not_configured")
}
