package ci.khoga.shopikaiss.terminal

import android.app.Activity
import android.graphics.Rect
import android.os.Build
import android.view.ViewTreeObserver
import android.view.WindowInsets
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager

/**
 * Blocage du clavier de l'écran au niveau Android (caisse avec clavier externe ou douchette), en filet du
 * `inputmode="none"` posé par la page : dès que le clavier virtuel apparaît alors que le blocage est actif, il est
 * refermé. Les touches d'un clavier physique arrivent toujours au champ qui a le focus.
 */
class KeyboardBlocker(private val activity: Activity) {

    var blocked = false
        set(value) {
            field = value
            activity.window.setSoftInputMode(
                WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE or
                    if (value) WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN else WindowManager.LayoutParams.SOFT_INPUT_STATE_UNSPECIFIED,
            )
            if (value) hideNow()
        }

    private val root get() = activity.window.decorView

    private val listener = ViewTreeObserver.OnGlobalLayoutListener {
        if (blocked && imeVisible()) hideNow()
    }

    fun start() {
        root.viewTreeObserver.addOnGlobalLayoutListener(listener)
    }

    fun stop() {
        root.viewTreeObserver.removeOnGlobalLayoutListener(listener)
    }

    private fun imeVisible(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return root.rootWindowInsets?.isVisible(WindowInsets.Type.ime()) == true
        }
        // Avant Android 11 : la fenêtre (adjustResize) perd plus d'un quart de sa hauteur quand le clavier s'ouvre.
        val visible = Rect().also { root.getWindowVisibleDisplayFrame(it) }
        val height = root.rootView.height
        return height > 0 && height - visible.bottom > height / 4
    }

    private fun hideNow() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity.window.insetsController?.hide(WindowInsets.Type.ime())
        }
        val imm = activity.getSystemService(InputMethodManager::class.java) ?: return
        val token = (activity.currentFocus ?: root).windowToken ?: return
        imm.hideSoftInputFromWindow(token, 0)
    }
}
