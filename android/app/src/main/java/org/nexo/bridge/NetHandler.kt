package org.nexo.bridge

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import org.json.JSONObject

/**
 * La red que usa el móvil (protocolo 1.5): `net.status` y los eventos del tema `net`.
 *
 * Es solo lectura y no pide ningún permiso nuevo (ACCESS_NETWORK_STATE ya estaba). Sirve para que Linux sepa si el móvil tiene
 * internet de verdad y por dónde sale (WiFi, datos móviles, cable…): nexo-dbus lo usa para que NetworkManager diga «conectado» o
 * «sin conexión» con la verdad, y `nexo net` lo muestra. No cuenta nombres de redes, direcciones ni nada que identifique la red.
 */
class NetHandler(context: Context) {
    private val ctx: Context = context.applicationContext
    private val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager

    /** Lo asigna el servicio del puente: se llama (en el hilo principal) cuando cambia la red por defecto. */
    @Volatile
    var onChange: (() -> Unit)? = null
    private var cb: ConnectivityManager.NetworkCallback? = null

    fun status(): JSONObject {
        val c = current()
        return JSONObject()
            .put("available", cm != null)
            .put("type", NetLogic.typeOf(c))
            .put("internet", c?.internet == true)
            .put("validated", c?.validated == true)
            .put("metered", NetLogic.metered(c))
            .put("vpn", c?.vpn == true)
            .put("captive", c?.captive == true)
    }

    /** Lo que Android cuenta de la red por defecto ahora mismo, o null si no hay ninguna. */
    private fun current(): NetLogic.Caps? {
        val m = cm ?: return null
        return try {
            val n = m.activeNetwork ?: return null
            val nc = m.getNetworkCapabilities(n) ?: return null
            capsOf(nc)
        } catch (_: SecurityException) {
            null
        } catch (_: RuntimeException) {
            null
        }
    }

    private fun capsOf(nc: NetworkCapabilities) = NetLogic.Caps(
        wifi = nc.hasTransport(NetworkCapabilities.TRANSPORT_WIFI),
        cellular = nc.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR),
        ethernet = nc.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET),
        bluetooth = nc.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH),
        vpn = nc.hasTransport(NetworkCapabilities.TRANSPORT_VPN) || !nc.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN),
        internet = nc.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),
        validated = nc.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
        notMetered = nc.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
        captive = nc.hasCapability(NetworkCapabilities.NET_CAPABILITY_CAPTIVE_PORTAL),
    )

    /**
     * Empieza a vigilar la red por defecto. Android avisa con ráfagas (cada cambio de señal): el servicio las junta en una sola.
     * Sin este aviso `net.status` sigue funcionando; solo faltan los eventos.
     */
    @Synchronized
    fun watch() {
        if (cb != null) return
        val m = cm ?: return
        val c = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = changed()
            override fun onLost(network: Network) = changed()
            override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) = changed()
        }
        try {
            m.registerDefaultNetworkCallback(c, Handler(Looper.getMainLooper()))
            cb = c
        } catch (_: Exception) {
            BridgeState.log("No se pudo vigilar la red del móvil (los eventos «net» no llegarán)")
        }
    }

    @Synchronized
    fun unwatch() {
        val c = cb ?: return
        cb = null
        try {
            cm?.unregisterNetworkCallback(c)
        } catch (_: Exception) {
        }
    }

    private fun changed() {
        onChange?.invoke()
    }
}
