package ci.khoga.shopikaiss.terminal

import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var terminal: TerminalPlugin? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        CrashLog.install(this)
        // Caisse : l'écran ne doit pas se mettre en veille pendant le service.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        terminal = TerminalPlugin(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    @Deprecated("Sélecteur de logo des tickets : simple aller-retour, sans bibliothèque d'activité.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (terminal?.onActivityResult(requestCode, resultCode, data) == true) return
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        terminal?.dispose()
        terminal = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
