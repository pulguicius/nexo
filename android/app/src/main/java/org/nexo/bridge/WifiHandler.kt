package org.nexo.bridge

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.ScanResult
import android.net.wifi.SupplicantState
import android.net.wifi.WifiConfiguration
import android.net.wifi.WifiManager
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.net.Inet4Address
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * WiFi del móvil.
 *
 * La app apunta a API 28 a propósito (ver app/build.gradle.kts), así que las llamadas
 * "clásicas" de WifiManager siguen funcionando. Si el sistema o el fabricante las bloquea,
 * se responde needs_user_action y se deja una notificación para hacerlo con un toque.
 */
@Suppress("DEPRECATION")
class WifiHandler(context: Context) {
    private val ctx: Context = context.applicationContext
    private val wm: WifiManager? = ctx.getSystemService(Context.WIFI_SERVICE) as? WifiManager
    private val lm: LocationManager? = ctx.getSystemService(Context.LOCATION_SERVICE) as? LocationManager

    fun hasHardware(): Boolean = wm != null

    private fun requireWm(): WifiManager =
        wm ?: throw CmdException("unsupported", "Este móvil no tiene WiFi")

    private fun hasLocation(): Boolean =
        ctx.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED

    private fun locationEnabled(): Boolean {
        val l = lm ?: return false
        return if (Build.VERSION.SDK_INT >= 28) {
            l.isLocationEnabled
        } else {
            l.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                l.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        }
    }

    // ---------------------------------------------------------------- estado

    fun status(): JSONObject {
        val m = wm ?: return JSONObject().put("available", false)
        val enabled = m.isWifiEnabled
        val o = JSONObject()
        o.put("available", true)
        o.put("enabled", enabled)
        o.put("state", stateName(m.wifiState))
        o.put("permission_location", hasLocation())
        o.put("location_enabled", locationEnabled())

        var connected = false
        var ssid: String? = null
        var hidden = false
        var bssid: String? = null
        var rssi: Int? = null
        var freq: Int? = null
        var speed: Int? = null
        var ip: String? = null
        var gateway: String? = null
        var prefix: Int? = null
        var dns: List<String>? = null

        if (enabled) {
            val info = try {
                m.connectionInfo
            } catch (e: SecurityException) {
                null
            }
            if (info != null && info.networkId != -1 && info.supplicantState == SupplicantState.COMPLETED) {
                connected = true
                val raw: String? = info.ssid
                if (raw.isNullOrEmpty() || raw == UNKNOWN_SSID) {
                    hidden = true // Android lo oculta si falta el permiso/ubicación
                } else {
                    ssid = raw.removeSurrounding("\"")
                }
                val b: String? = info.bssid
                if (b != null && b != "02:00:00:00:00:00") bssid = b
                if (info.rssi > -127) rssi = info.rssi
                if (info.frequency > 0) freq = info.frequency
                if (info.linkSpeed > 0) speed = info.linkSpeed
                ip = ipToString(info.ipAddress)
                val cfg = ipConfig(m)
                if (cfg != null) {
                    ip = cfg.ip ?: ip
                    gateway = cfg.gateway
                    prefix = cfg.prefix
                    dns = cfg.dns
                }
            }
        }

        o.put("connected", connected)
        o.putOrNull("ssid", ssid)
        o.put("ssid_hidden", hidden)
        o.putOrNull("bssid", bssid)
        o.putOrNull("rssi", rssi)
        o.putOrNull("level", rssi?.let { levelOf(it) })
        o.putOrNull("frequency", freq)
        o.putOrNull("band", freq?.let { bandOf(it) })
        o.putOrNull("link_speed", speed)
        o.putOrNull("ip", ip)
        o.putOrNull("gateway", gateway)
        o.putOrNull("netmask", prefix?.let { netmaskText(it) })
        o.putOrNull("prefix", prefix)
        o.putOrNull("dns", dns?.let { JSONArray(it) })
        return o
    }

    /** Datos de red del WiFi actual: ip, puerta de enlace, prefijo (24) y DNS. */
    private class IpCfg(val ip: String?, val gateway: String?, val prefix: Int?, val dns: List<String>)

    /**
     * Primero se pregunta a ConnectivityManager (lo más fiable en Android recientes) y, si no
     * hay respuesta, a DhcpInfo (la API antigua, que sigue funcionando al apuntar a API 28).
     */
    @Suppress("DEPRECATION")
    private fun ipConfig(m: WifiManager): IpCfg? {
        try {
            val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            if (cm != null) {
                for (n in cm.allNetworks) {
                    val caps = cm.getNetworkCapabilities(n) ?: continue
                    if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) continue
                    val lp = cm.getLinkProperties(n) ?: continue
                    var ip: String? = null
                    var prefix: Int? = null
                    for (la in lp.linkAddresses) {
                        val a = la.address
                        if (a is Inet4Address) {
                            ip = a.hostAddress
                            prefix = la.prefixLength
                            break
                        }
                    }
                    if (ip == null) continue
                    var gw: String? = null
                    for (r in lp.routes) {
                        val g = r.gateway
                        if (r.isDefaultRoute && g is Inet4Address) {
                            gw = g.hostAddress
                            break
                        }
                    }
                    val dns = lp.dnsServers.mapNotNull { it.hostAddress?.substringBefore('%') }
                        .sortedBy { it.contains(':') } // primero las IPv4
                    return IpCfg(ip, gw, prefix, dns)
                }
            }
        } catch (_: Exception) {
            // seguimos con DhcpInfo
        }
        return try {
            val d = m.dhcpInfo ?: return null
            if (d.ipAddress == 0 && d.gateway == 0) return null
            IpCfg(
                ipToString(d.ipAddress), ipToString(d.gateway), prefixFromNetmask(d.netmask),
                listOfNotNull(ipToString(d.dns1), ipToString(d.dns2))
            )
        } catch (_: Exception) {
            null
        }
    }

    // ------------------------------------------------------- encender / apagar

    fun setEnabled(on: Boolean): JSONObject {
        val m = requireWm()
        if (m.isWifiEnabled != on) {
            val accepted = try {
                m.setWifiEnabled(on)
            } catch (e: SecurityException) {
                false
            }
            if (!accepted) {
                UserAction.open(
                    ctx, UserAction.ID_WIFI,
                    if (on) "Activar WiFi" else "Desactivar WiFi",
                    "Toca para cambiarlo: Android no deja que Nexo lo haga solo.",
                    UserAction.wifiPanel()
                )
                throw CmdException(
                    "needs_user_action",
                    "Android no dejó que Nexo cambie el WiFi (modo avión, punto de acceso activo o restricción del fabricante). " +
                        "Te dejé una notificación para hacerlo con un toque.",
                    JSONObject().put("action", "notification").put("opens", "wifi_panel")
                )
            }
            waitUntil(4000) { m.isWifiEnabled == on }
        }
        return status()
    }

    // ---------------------------------------------------------------- escaneo

    fun scan(req: JSONObject): JSONObject {
        val m = requireWm()
        if (!m.isWifiEnabled) throw CmdException("wifi_disabled", "El WiFi está apagado")
        if (!hasLocation()) {
            throw CmdException(
                "permission_denied",
                "Falta el permiso de ubicación: Android lo exige para ver las redes WiFi. Concédelo en la app Nexo.",
                JSONObject().put("permission", "ACCESS_FINE_LOCATION")
            )
        }
        val wantFresh = req.optBoolean("fresh", true)
        val timeout = req.optLong("timeout_ms", 4000).coerceIn(500L, 15000L)

        var fresh = false
        if (wantFresh) {
            val latch = CountDownLatch(1)
            val rcv = object : BroadcastReceiver() {
                override fun onReceive(c: Context?, i: Intent?) {
                    latch.countDown()
                }
            }
            ctx.registerReceiver(rcv, IntentFilter(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION))
            try {
                val started = try {
                    m.startScan()
                } catch (e: SecurityException) {
                    false
                }
                if (started) fresh = latch.await(timeout, TimeUnit.MILLISECONDS)
            } finally {
                try {
                    ctx.unregisterReceiver(rcv)
                } catch (_: Exception) {
                }
            }
        }

        val raw: List<ScanResult> = try {
            m.scanResults ?: emptyList()
        } catch (e: SecurityException) {
            throw CmdException("permission_denied", "Android negó leer las redes WiFi", JSONObject().put("permission", "ACCESS_FINE_LOCATION"))
        }

        // Una entrada por nombre de red (la de señal más fuerte).
        val best = LinkedHashMap<String, ScanResult>()
        var hiddenCount = 0
        for (r in raw.sortedByDescending { it.level }) {
            val name: String = r.SSID ?: ""
            if (name.isEmpty()) {
                hiddenCount++
                continue
            }
            if (!best.containsKey(name)) best[name] = r
        }

        val arr = JSONArray()
        for ((name, r) in best) {
            val sec = securityOf(r.capabilities ?: "")
            val n = JSONObject()
            n.put("ssid", name)
            n.putOrNull("bssid", r.BSSID)
            n.put("rssi", r.level)
            n.put("level", levelOf(r.level))
            n.put("frequency", r.frequency)
            n.put("band", bandOf(r.frequency))
            n.put("security", sec)
            n.put("secured", sec != "OPEN" && sec != "OWE")
            arr.put(n)
        }

        val o = JSONObject()
        o.put("networks", arr)
        o.put("fresh", fresh)
        o.put("hidden_count", hiddenCount)
        if (arr.length() == 0) {
            o.put(
                "hint",
                if (!locationEnabled()) "Enciende la ubicación del sistema (Ajustes > Ubicación): sin ella Android no entrega redes WiFi."
                else "Sin resultados todavía; Android limita los escaneos (unos 4 cada 2 minutos)."
            )
        }
        return o
    }

    // ---------------------------------------------------------------- conectar

    fun connect(req: JSONObject): JSONObject {
        val m = requireWm()
        val ssid = req.optString("ssid", "")
        if (ssid.isEmpty()) throw CmdException("bad_request", "Falta el campo ssid")
        val password: String? =
            if (req.has("password") && !req.isNull("password")) req.getString("password") else null
        val hidden = req.optBoolean("hidden", false)
        val waitMs = req.optLong("wait_ms", 12000).coerceIn(0L, 30000L)
        if (!m.isWifiEnabled) {
            throw CmdException("wifi_disabled", "El WiFi está apagado; enciéndelo primero")
        }

        // Redes que solo usan WPA3 (SAE) no se pueden crear con la API clásica.
        if (password != null) {
            val caps = try {
                m.scanResults?.filter { it.SSID == ssid }?.map { it.capabilities ?: "" } ?: emptyList()
            } catch (e: SecurityException) {
                emptyList()
            }
            if (caps.isNotEmpty() && caps.all { it.contains("SAE") && !it.contains("PSK") }) {
                return needsUser("Esa red usa solo WPA3, y Android no deja a Nexo crearla.")
            }
        }

        val quoted = "\"" + ssid + "\""
        var netId = -1
        try {
            netId = m.configuredNetworks?.firstOrNull { it.SSID == quoted }?.networkId ?: -1
        } catch (_: SecurityException) {
        }

        if (netId == -1 || password != null) {
            val cfg = WifiConfiguration()
            cfg.SSID = quoted
            cfg.hiddenSSID = hidden
            if (password == null) {
                cfg.allowedKeyManagement.set(WifiConfiguration.KeyMgmt.NONE)
            } else {
                cfg.allowedKeyManagement.set(WifiConfiguration.KeyMgmt.WPA_PSK)
                val rawHex = password.length == 64 && password.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
                cfg.preSharedKey = if (rawHex) password else "\"" + password + "\""
            }
            try {
                if (netId != -1) {
                    cfg.networkId = netId
                    m.updateNetwork(cfg) // si falla, se usa la clave que ya estaba guardada
                } else {
                    netId = m.addNetwork(cfg)
                }
            } catch (_: SecurityException) {
                netId = -1
            }
        }
        if (netId == -1) return needsUser("Android no dejó que Nexo guarde esa red.")

        val enabled = try {
            m.enableNetwork(netId, true)
        } catch (_: SecurityException) {
            false
        }
        if (!enabled) return needsUser("Android no dejó que Nexo se conecte a esa red.")
        m.reconnect()

        var connected = false
        if (waitMs > 0) connected = waitUntil(waitMs) { connectedNetworkId(m) == netId }

        val o = JSONObject()
        o.put("requested", true)
        o.put("network_id", netId)
        o.put("ssid", ssid)
        o.put("connected", connected)
        if (!connected) {
            o.put("hint", "No se confirmó la conexión: revisa la clave o la cobertura.")
        }
        return o
    }

    fun disconnect(): JSONObject {
        val m = requireWm()
        val ok = try {
            m.disconnect()
        } catch (_: SecurityException) {
            false
        }
        if (!ok) throw CmdException("failed", "Android no aceptó desconectar el WiFi")
        return JSONObject().put("requested", true)
    }

    // ------------------------------------------------- redes guardadas

    private fun requireLocationPermission() {
        if (!hasLocation()) {
            throw CmdException(
                "permission_denied",
                "Falta el permiso de ubicación: Android lo exige para ver las redes guardadas. Concédelo en la app Nexo.",
                JSONObject().put("permission", "ACCESS_FINE_LOCATION")
            )
        }
    }

    private fun configured(m: WifiManager): List<WifiConfiguration> = try {
        m.configuredNetworks ?: emptyList()
    } catch (_: SecurityException) {
        throw CmdException(
            "permission_denied", "Android negó leer las redes guardadas",
            JSONObject().put("permission", "ACCESS_FINE_LOCATION")
        )
    }

    private fun ssidOf(c: WifiConfiguration): String = (c.SSID ?: "").removeSurrounding("\"")

    fun saved(): JSONObject {
        val m = requireWm()
        requireLocationPermission()
        val currentId = connectedNetworkId(m)
        val arr = JSONArray()
        for (c in configured(m)) {
            val name = ssidOf(c)
            if (name.isEmpty() || name == UNKNOWN_SSID) continue
            val n = JSONObject()
            n.put("network_id", c.networkId)
            n.put("ssid", name)
            n.put("security", securityOf(c))
            n.put("hidden", c.hiddenSSID)
            n.put("current", currentId != -1 && c.networkId == currentId)
            arr.put(n)
        }
        return JSONObject().put("networks", arr)
    }

    fun forget(req: JSONObject): JSONObject {
        val m = requireWm()
        val byId = req.has("network_id") && !req.isNull("network_id")
        val bySsid = req.has("ssid") && !req.isNull("ssid")
        if (!byId && !bySsid) throw CmdException("bad_request", "Indica ssid o network_id")
        requireLocationPermission()
        val all = configured(m)
        val targets = if (byId) {
            val id = req.optInt("network_id", Int.MIN_VALUE)
            all.filter { it.networkId == id }
        } else {
            val name = req.optString("ssid", "")
            all.filter { ssidOf(it) == name }
        }
        if (targets.isEmpty()) throw CmdException("not_found", "No hay ninguna red guardada con ese nombre")
        var removed = 0
        for (c in targets) {
            val ok = try {
                m.removeNetwork(c.networkId)
            } catch (_: SecurityException) {
                false
            }
            if (ok) removed++
        }
        if (removed == 0) {
            needsUser(
                "Android no dejó que Nexo borre esa red (solo puede borrarla quien la creó).",
                "Olvidar una red WiFi"
            )
        }
        try {
            m.saveConfiguration() // en Android 9 o menos hace falta para que el cambio quede guardado
        } catch (_: Exception) {
        }
        return JSONObject().put("removed", removed)
    }

    fun reconnect(req: JSONObject): JSONObject {
        val m = requireWm()
        if (!m.isWifiEnabled) throw CmdException("wifi_disabled", "El WiFi está apagado")
        val waitMs = req.optLong("wait_ms", 8000).coerceIn(0L, 30000L)
        val asked = try {
            if (connectedNetworkId(m) == -1) m.reconnect() else m.reassociate()
        } catch (_: SecurityException) {
            false
        }
        if (!asked) throw CmdException("failed", "Android no aceptó reconectar el WiFi")
        val connected = if (waitMs > 0) waitUntil(waitMs) { connectedNetworkId(m) != -1 } else connectedNetworkId(m) != -1
        val o = JSONObject()
        o.put("requested", true)
        o.put("connected", connected)
        if (!connected) o.put("hint", "No se confirmó la conexión: puede que la red no esté a la vista.")
        return o
    }

    // ---------------------------------------------------------------- ayudas

    private fun connectedNetworkId(m: WifiManager): Int {
        val info = (try {
            m.connectionInfo
        } catch (_: SecurityException) {
            null
        }) ?: return -1
        return if (info.supplicantState == SupplicantState.COMPLETED) info.networkId else -1
    }

    /** Devuelve (lanzando) needs_user_action y deja la notificación del panel WiFi. */
    private fun needsUser(why: String, title: String = "Conectar a una red WiFi"): Nothing {
        UserAction.open(
            ctx, UserAction.ID_WIFI, title,
            "Toca para abrir el panel de WiFi: $why", UserAction.wifiPanel()
        )
        throw CmdException(
            "needs_user_action",
            "$why Te dejé una notificación que abre el panel de WiFi.",
            JSONObject().put("action", "notification").put("opens", "wifi_panel")
        )
    }

    companion object {
        private const val UNKNOWN_SSID = "<unknown ssid>"

        fun stateName(s: Int): String = when (s) {
            WifiManager.WIFI_STATE_ENABLED -> "enabled"
            WifiManager.WIFI_STATE_ENABLING -> "enabling"
            WifiManager.WIFI_STATE_DISABLING -> "disabling"
            WifiManager.WIFI_STATE_DISABLED -> "disabled"
            else -> "unknown"
        }

        /** 0 (sin señal) a 4 (excelente), calculado a partir de los dBm. */
        fun levelOf(rssi: Int): Int = when {
            rssi <= -100 -> 0
            rssi >= -55 -> 4
            else -> (rssi + 100) * 4 / 45
        }

        fun bandOf(mhz: Int): String = when {
            mhz < 3000 -> "2.4GHz"
            mhz < 5925 -> "5GHz"
            else -> "6GHz"
        }

        /** Seguridad de una red GUARDADA (la de una red a la vista sale de securityOf(String)). */
        fun securityOf(c: WifiConfiguration): String {
            val km = c.allowedKeyManagement
            return when {
                km.get(WifiConfiguration.KeyMgmt.SAE) -> "WPA3"
                km.get(WifiConfiguration.KeyMgmt.OWE) -> "OWE"
                km.get(WifiConfiguration.KeyMgmt.WPA_EAP) || km.get(WifiConfiguration.KeyMgmt.IEEE8021X) -> "WPA2"
                km.get(WifiConfiguration.KeyMgmt.WPA_PSK) || km.get(4) -> // 4 = WPA2_PSK (constante oculta)
                    if (c.allowedProtocols.get(WifiConfiguration.Protocol.RSN) || !c.allowedProtocols.get(WifiConfiguration.Protocol.WPA)) "WPA2" else "WPA"
                c.wepKeys?.any { it != null } == true -> "WEP"
                else -> "OPEN"
            }
        }

        fun securityOf(cap: String): String = when {
            cap.contains("SAE") -> "WPA3"
            cap.contains("WPA2") || cap.contains("RSN") -> "WPA2"
            cap.contains("WPA") -> "WPA"
            cap.contains("WEP") -> "WEP"
            cap.contains("OWE") -> "OWE"
            else -> "OPEN"
        }
    }
}
