package org.nexo.bridge

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Estado compartido entre el servicio y la pantalla (los dos viven en el mismo proceso).
 * Nunca se escriben aquí contraseñas ni el token.
 */
object BridgeState {
    @Volatile var running = false
    @Volatile var port = Prefs.DEFAULT_PORT
    @Volatile var clients = 0
    @Volatile var lastError: String? = null
    @Volatile var uiVisible = false

    private const val MAX_LINES = 80
    private val lines = ArrayList<String>()
    private val fmt = SimpleDateFormat("HH:mm:ss", Locale.US)

    @Synchronized
    fun log(msg: String) {
        lines.add(fmt.format(Date()) + "  " + msg)
        while (lines.size > MAX_LINES) lines.removeAt(0)
    }

    @Synchronized
    fun recent(n: Int): List<String> = lines.takeLast(n)
}
