package ci.khoga.shopikaiss.terminal.display

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Presentation
import android.content.Context
import android.graphics.Color
import android.hardware.display.DisplayManager
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Display
import android.view.WindowManager
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import ci.khoga.shopikaiss.terminal.LocalLog

/**
 * Afficheur client sur le second écran du terminal (SUNMI T2/D2, ST-T40…), via [Presentation].
 * Repris de l'application « ShopiKaiss Bridge » : rattaché à la fenêtre de l'activité (aucune
 * permission SYSTEM_ALERT_WINDOW), rouvert au rebranchement de l'écran sur la dernière URL.
 * La WebView de l'afficheur n'a pas le pont natif et reste confinée à l'origine de la caisse.
 *
 * Toutes les méthodes doivent être appelées sur le fil UI.
 */
class CustomerDisplayController(private val activity: Activity) : DisplayManager.DisplayListener {

    private val displayManager = activity.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
    private val handler = Handler(Looper.getMainLooper())
    private var presentation: CustomerPresentation? = null
    private var requestedUrl: String? = null
    private var allowedOrigin: String? = null

    fun start() = displayManager.registerDisplayListener(this, handler)

    fun stop() {
        displayManager.unregisterDisplayListener(this)
        dismiss()
    }

    fun secondaryDisplay(): Display? =
        displayManager.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION).firstOrNull { it.displayId != Display.DEFAULT_DISPLAY }

    fun displays(): List<Map<String, Int>> = displayManager.displays.map {
        val mode = it.mode
        mapOf("id" to it.displayId, "width" to mode.physicalWidth, "height" to mode.physicalHeight)
    }

    /** Renvoie null si l'affichage est lancé, sinon le code d'erreur pour la page. */
    fun show(url: String, origin: String): String? {
        if (originOf(url) == null || originOf(url) != originOf(origin)) return "origin_not_allowed"
        requestedUrl = url
        allowedOrigin = originOf(origin)
        val display = secondaryDisplay() ?: return "no_secondary_display"
        val current = presentation
        if (current != null && current.isShowing && current.display.displayId == display.displayId) {
            current.load(url)
            return null
        }
        dismiss()
        return try {
            CustomerPresentation(activity, display, allowedOrigin!!).also {
                it.show()
                it.load(url)
                presentation = it
            }
            LocalLog.i("Afficheur client ouvert sur l'écran ${display.displayId}")
            null
        } catch (e: WindowManager.InvalidDisplayException) {
            LocalLog.e("Écran ${display.displayId} invalide", e)
            "display_invalid"
        }
    }

    fun hide() {
        requestedUrl = null
        dismiss()
    }

    private fun dismiss() {
        presentation?.let {
            if (it.isShowing) it.dismiss()
            it.destroyWebView()
        }
        presentation = null
    }

    override fun onDisplayAdded(displayId: Int) {
        val url = requestedUrl
        val origin = allowedOrigin
        if (presentation == null && url != null && origin != null) show(url, origin)
    }

    override fun onDisplayRemoved(displayId: Int) {
        val current = presentation ?: return
        if (current.display.displayId != displayId) return
        // La page de l'afficheur renouvelle son jeton (/etat puis replaceState) : on rouvrira son URL courante,
        // pas celle du premier affichage, dont le jeton peut avoir expiré entre-temps.
        current.currentUrl()?.takeIf { originOf(it) == allowedOrigin }?.let { requestedUrl = it }
        dismiss()
    }

    override fun onDisplayChanged(displayId: Int) {}

    private class CustomerPresentation(
        context: Context,
        display: Display,
        private val origin: String,
    ) : Presentation(context, display) {
        private var webView: WebView? = null

        @SuppressLint("SetJavaScriptEnabled")
        override fun onCreate(savedInstanceState: Bundle?) {
            super.onCreate(savedInstanceState)
            window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            val wv = WebView(context)
            wv.settings.javaScriptEnabled = true
            wv.settings.domStorageEnabled = true
            wv.settings.mediaPlaybackRequiresUserGesture = false
            wv.setBackgroundColor(Color.BLACK)
            wv.isVerticalScrollBarEnabled = false
            wv.isHorizontalScrollBarEnabled = false
            wv.webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
                    originOf(request.url.toString()) != origin
            }
            setContentView(wv)
            webView = wv
        }

        fun load(url: String) {
            if (webView?.url != url) webView?.loadUrl(url)
        }

        /** URL affichée, y compris après un `history.replaceState` de la page. */
        fun currentUrl(): String? = webView?.url

        fun destroyWebView() {
            webView?.apply {
                stopLoading()
                destroy()
            }
            webView = null
        }
    }

    companion object {
        /** `scheme://hôte[:port]` en minuscules, ou null si l'URL n'est pas http(s). */
        fun originOf(url: String?): String? {
            if (url.isNullOrBlank()) return null
            val uri = Uri.parse(url)
            val scheme = uri.scheme?.lowercase() ?: return null
            if (scheme != "http" && scheme != "https") return null
            val host = uri.host?.lowercase() ?: return null
            val port = if (uri.port == -1 || (scheme == "https" && uri.port == 443) || (scheme == "http" && uri.port == 80)) "" else ":${uri.port}"
            return "$scheme://$host$port"
        }
    }
}
