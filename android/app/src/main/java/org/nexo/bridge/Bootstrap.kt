package org.nexo.bridge

import android.content.Context
import android.util.Base64
import java.security.MessageDigest

/**
 * Instalar el cliente en Termux sin internet y sin importar qué Termux uses
 * (F-Droid, GitHub, Monet o cualquier fork).
 *
 * El APK lleva dentro el cliente (`bin/nexo`), el puente D-Bus para escritorios (`bin/nexo-dbus`),
 * el programa para pasar y explorar archivos entre móviles (`bin/nexo-tools`) y el instalador (`install.sh`).
 * El servidor, ante {"cmd":"bootstrap"}, devuelve un único script con los cuatro. La app también genera un
 * comando de una línea (oneliner.tpl) que lo descarga por 127.0.0.1, COMPRUEBA su SHA-256 y
 * solo entonces lo ejecuta. Esa comprobación impide que otra app que se haya adelantado a
 * ocupar el puerto te cuele un script distinto.
 */
object Bootstrap {
    @Volatile
    private var cached: ByteArray? = null

    fun bundle(ctx: Context): ByteArray {
        cached?.let { return it }
        synchronized(this) {
            cached?.let { return it }
            val built = build(ctx)
            cached = built
            return built
        }
    }

    // Normaliza a LF: un CRLF colado al editar en Windows rompería el script en Termux.
    private fun readAsset(ctx: Context, name: String): String =
        ctx.assets.open(name).use { it.readBytes() }
            .toString(Charsets.UTF_8)
            .replace("\r\n", "\n")

    private fun b64(text: String): String =
        Base64.encodeToString(text.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)

    private fun build(ctx: Context): ByteArray {
        val client64 = b64(readAsset(ctx, "bin/nexo"))
        val dbus64 = b64(readAsset(ctx, "bin/nexo-dbus"))
        val tools64 = b64(readAsset(ctx, "bin/nexo-tools"))
        val installer = readAsset(ctx, "install.sh")
        // Sin `export`: una variable de entorno no puede pasar de 128 KiB y los archivos son mayores que eso.
        // nexo-dbus (D-Bus para escritorios) y nexo-tools (archivos entre móviles) viajan igual; no se activan solos.
        val head = "#!/usr/bin/env bash\nNEXO_CLIENT_B64='$client64'\nNEXO_DBUS_B64='$dbus64'\nNEXO_TOOLS_B64='$tools64'\n"
        return (head + installer).toByteArray(Charsets.UTF_8)
    }

    fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { String.format("%02x", it) }

    /** Comando de una línea para pegar en Termux (o dentro de cualquier distro de proot). */
    fun oneLiner(ctx: Context, port: Int, token: String): String =
        readAsset(ctx, "oneliner.tpl").trim()
            .replace("@PORT@", port.toString())
            .replace("@TOKEN@", token)
            .replace("@SHA256@", sha256(bundle(ctx)))
}
