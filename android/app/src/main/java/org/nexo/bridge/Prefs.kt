package org.nexo.bridge

import android.content.Context
import java.security.SecureRandom

/** Ajustes que se guardan en el móvil: token, puerto y arranque automático. */
object Prefs {
    const val DEFAULT_PORT = 8765

    private const val FILE = "nexo"
    private const val K_TOKEN = "token"
    private const val K_PORT = "port"
    private const val K_BOOT = "start_on_boot"
    private const val K_WANTED = "service_wanted"

    private fun sp(c: Context) =
        c.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    /** Token secreto que Termux debe presentar. Se crea solo la primera vez. */
    @Synchronized
    fun token(c: Context): String {
        val s = sp(c)
        val old = s.getString(K_TOKEN, null)
        if (!old.isNullOrEmpty()) return old
        return newToken().also { s.edit().putString(K_TOKEN, it).apply() }
    }

    /** Invalida el token anterior: los clientes ya enlazados dejan de funcionar. */
    @Synchronized
    fun regenerateToken(c: Context): String =
        newToken().also { sp(c).edit().putString(K_TOKEN, it).apply() }

    private fun newToken(): String {
        val b = ByteArray(24) // 192 bits
        SecureRandom().nextBytes(b)
        return b.joinToString("") { String.format("%02x", it) }
    }

    fun port(c: Context): Int = sp(c).getInt(K_PORT, DEFAULT_PORT)
    fun setPort(c: Context, port: Int) = sp(c).edit().putInt(K_PORT, port).apply()

    fun startOnBoot(c: Context): Boolean = sp(c).getBoolean(K_BOOT, false)
    fun setStartOnBoot(c: Context, v: Boolean) = sp(c).edit().putBoolean(K_BOOT, v).apply()

    /** Si el usuario dejó el puente encendido (para la pantalla). */
    fun serviceWanted(c: Context): Boolean = sp(c).getBoolean(K_WANTED, false)
    fun setServiceWanted(c: Context, v: Boolean) = sp(c).edit().putBoolean(K_WANTED, v).apply()
}
