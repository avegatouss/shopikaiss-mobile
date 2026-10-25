package ci.khoga.shopikaiss.terminal

import android.content.Context
import android.os.Build
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Dernière panne native de l'application (exception Java/Kotlin non rattrapée, manque de mémoire…), écrite sur le
 * terminal juste avant l'arrêt et montrée au redémarrage dans Réglages › Diagnostic. Une panne native échappe au Dart :
 * sans ce fichier, « l'application se ferme » ne laisse aucune trace exploitable.
 */
object CrashLog {
    private const val FILE = "derniere-panne.txt"

    fun install(context: Context) {
        val app = context.applicationContext
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                val stack = StringWriter().also { error.printStackTrace(PrintWriter(it)) }.toString()
                val runtime = Runtime.getRuntime()
                val memory = "mémoire Java : ${(runtime.totalMemory() - runtime.freeMemory()) / 1048576} Mo utilisés sur ${runtime.maxMemory() / 1048576} Mo"
                val date = SimpleDateFormat("dd/MM/yyyy HH:mm:ss", Locale.FRANCE).format(Date())
                File(app.filesDir, FILE).writeText(
                    "Panne du $date — fil « ${thread.name} »\n${Build.MANUFACTURER} ${Build.MODEL}, Android ${Build.VERSION.RELEASE}\n$memory\n\n${stack.take(12000)}",
                )
            } catch (_: Throwable) {
            }
            previous?.uncaughtException(thread, error)
        }
    }

    fun read(context: Context): String? = File(context.filesDir, FILE).takeIf { it.exists() }?.readText()

    fun clear(context: Context) {
        File(context.filesDir, FILE).delete()
    }
}
