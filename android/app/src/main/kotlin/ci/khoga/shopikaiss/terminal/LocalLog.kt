package ci.khoga.shopikaiss.terminal

import android.util.Log

/** Journal Android (`adb logcat -s ShopiKaiss`). */
object LocalLog {
    private const val TAG = "ShopiKaiss"

    fun i(message: String) = Log.i(TAG, message)

    fun w(message: String, error: Throwable? = null) = Log.w(TAG, message, error)

    fun e(message: String, error: Throwable? = null) = Log.e(TAG, message, error)
}
