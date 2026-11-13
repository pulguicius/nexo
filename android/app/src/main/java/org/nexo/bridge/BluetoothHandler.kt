package org.nexo.bridge

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothClass
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.lang.reflect.InvocationTargetException
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Bluetooth del móvil.
 *
 * Encender/apagar se intenta directo (funciona al apuntar a API 28, ver build.gradle.kts).
 * Conectar o desconectar un dispositivo YA emparejado no lo permite Android a apps normales
 * (las funciones están reservadas al sistema), así que en ese caso se deja una notificación
 * que abre los ajustes de Bluetooth.
 */
@Suppress("DEPRECATION")
class BluetoothHandler(context: Context) {
    private val ctx: Context = context.applicationContext
    private val mgr: BluetoothManager? = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter: BluetoothAdapter? get() = mgr?.adapter

    fun hasHardware(): Boolean = adapter != null

    private fun requireAdapter(): BluetoothAdapter =
        adapter ?: throw CmdException("unsupported", "Este móvil no tiene Bluetooth")

    // ---------------------------------------------------------------- estado

    fun status(): JSONObject {
        val a = adapter ?: return JSONObject().put("available", false)
        val st = a.state
        val o = JSONObject()
        o.put("available", true)
        o.put("enabled", st == BluetoothAdapter.STATE_ON)
        o.put("state", stateName(st))
        o.putOrNull("name", try {
            a.name
        } catch (_: SecurityException) {
            null
        })

        var connected = false
        var bonded: Int? = null
        if (st == BluetoothAdapter.STATE_ON) {
            try {
                connected = PROFILES.keys.any { a.getProfileConnectionState(it) == BluetoothProfile.STATE_CONNECTED } ||
                    (mgr?.getConnectedDevices(BluetoothProfile.GATT)?.isNotEmpty() ?: false)
                bonded = a.bondedDevices?.size
            } catch (_: SecurityException) {
                o.put("permission_missing", "BLUETOOTH_CONNECT")
            }
        }
        o.put("connected", connected)
        o.putOrNull("bonded_count", bonded)
        return o
    }

    // ------------------------------------------------------- encender / apagar

    fun setEnabled(on: Boolean): JSONObject {
        val a = requireAdapter()
        val isOn = a.state == BluetoothAdapter.STATE_ON
        if (isOn != on) {
            val accepted = try {
                if (on) a.enable() else a.disable()
            } catch (_: SecurityException) {
                false
            }
            if (!accepted) {
                UserAction.open(
                    ctx, UserAction.ID_BT,
                    if (on) "Activar Bluetooth" else "Desactivar Bluetooth",
                    "Toca para cambiarlo: Android no deja que Nexo lo haga solo.",
                    if (on) UserAction.bluetoothEnable() else UserAction.bluetoothSettings()
                )
                throw CmdException(
                    "needs_user_action",
                    "Android no dejó que Nexo cambie el Bluetooth. Te dejé una notificación para hacerlo con un toque.",
                    JSONObject().put("action", "notification").put("opens", if (on) "bluetooth_enable" else "bluetooth_settings")
                )
            }
            waitUntil(5000) { (a.state == BluetoothAdapter.STATE_ON) == on }
        }
        return status()
    }

    // --------------------------------------------------------------- emparejados

    fun paired(): JSONObject {
        val a = requireAdapter()
        if (a.state != BluetoothAdapter.STATE_ON) {
            throw CmdException("bluetooth_disabled", "El Bluetooth está apagado")
        }
        val bonded: Set<BluetoothDevice> = try {
            a.bondedDevices ?: emptySet()
        } catch (_: SecurityException) {
            throw CmdException(
                "permission_denied", "Android negó leer los dispositivos emparejados",
                JSONObject().put("permission", "BLUETOOTH_CONNECT")
            )
        }
        val live = connectedByProfile(a)

        val arr = JSONArray()
        for (d in bonded) {
            val addr: String = d.address ?: continue
            val profiles = live[addr]
            val o = JSONObject()
            o.putOrNull("name", try {
                d.name
            } catch (_: SecurityException) {
                null
            })
            o.put("address", addr)
            o.put("connected", profiles != null && profiles.isNotEmpty())
            o.put("profiles", JSONArray(profiles?.sorted() ?: emptyList<String>()))
            o.put("type", typeName(d.type))
            o.put("class", classOf(d.bluetoothClass))
            arr.put(o)
        }
        return JSONObject().put("devices", arr)
    }

    /**
     * Quién está conectado ahora, por perfil. Se pregunta a los servicios de perfil de Android
     * (audio, manos libres, teclados/ratones) y a GATT (dispositivos BLE).
     */
    private fun connectedByProfile(a: BluetoothAdapter): Map<String, Set<String>> {
        val result = ConcurrentHashMap<String, MutableSet<String>>()
        val proxies = ConcurrentHashMap<Int, BluetoothProfile>()
        val latch = CountDownLatch(PROFILES.size)

        for ((profile, label) in PROFILES) {
            val listener = object : BluetoothProfile.ServiceListener {
                override fun onServiceConnected(p: Int, proxy: BluetoothProfile) {
                    try {
                        for (d in proxy.connectedDevices) {
                            val addr = d.address ?: continue
                            result.getOrPut(addr) { Collections.synchronizedSet(HashSet<String>()) }.add(label)
                        }
                    } catch (_: Exception) {
                    }
                    proxies[p] = proxy
                    latch.countDown()
                }

                override fun onServiceDisconnected(p: Int) {}
            }
            val asked = try {
                a.getProfileProxy(ctx, listener, profile)
            } catch (_: Exception) {
                false
            }
            if (!asked) latch.countDown()
        }
        latch.await(2000, TimeUnit.MILLISECONDS)
        for ((p, proxy) in proxies) {
            try {
                a.closeProfileProxy(p, proxy)
            } catch (_: Exception) {
            }
        }
        try {
            mgr?.getConnectedDevices(BluetoothProfile.GATT)?.forEach { d ->
                val addr = d.address ?: return@forEach
                result.getOrPut(addr) { Collections.synchronizedSet(HashSet<String>()) }.add("gatt")
            }
        } catch (_: Exception) {
        }
        return result
    }

    // ------------------------------------------------- conectar / desconectar

    /** Valida `address` y devuelve el adaptador y el dispositivo emparejado (o lanza el error que toque). */
    private fun bondedDevice(req: JSONObject): Pair<BluetoothAdapter, BluetoothDevice> {
        val a = requireAdapter()
        val addr = req.optString("address", "").uppercase()
        if (!ADDR.matches(addr)) {
            throw CmdException("bad_request", "Falta address (formato AA:BB:CC:DD:EE:FF)")
        }
        if (a.state != BluetoothAdapter.STATE_ON) {
            throw CmdException("bluetooth_disabled", "El Bluetooth está apagado")
        }
        val dev = try {
            a.bondedDevices?.firstOrNull { it.address.equals(addr, ignoreCase = true) }
        } catch (_: SecurityException) {
            throw CmdException(
                "permission_denied", "Android negó leer los dispositivos emparejados",
                JSONObject().put("permission", "BLUETOOTH_CONNECT")
            )
        } ?: throw CmdException("not_paired", "Ese dispositivo no está emparejado en Android")
        return Pair(a, dev)
    }

    private fun nameOf(d: BluetoothDevice): String? = try {
        d.name
    } catch (_: SecurityException) {
        null
    }

    fun connect(req: JSONObject, connect: Boolean): JSONObject {
        val (_, dev) = bondedDevice(req)
        val name: String = nameOf(dev) ?: dev.address
        UserAction.open(
            ctx, UserAction.ID_BT,
            if (connect) "Conectar $name" else "Desconectar $name",
            "Toca para abrir los ajustes de Bluetooth.",
            UserAction.bluetoothSettings()
        )
        throw CmdException(
            "needs_user_action",
            "Android no permite que una app normal conecte o desconecte dispositivos Bluetooth. " +
                "Te dejé una notificación que abre los ajustes de Bluetooth.",
            JSONObject().put("action", "notification").put("opens", "bluetooth_settings")
        )
    }

    // ------------------------------------------- olvidar / renombrar / info

    /**
     * Desempareja. `BluetoothDevice.removeBond()` NO es API pública: se llama por reflexión y solo
     * funciona porque la app apunta a API 28. Si Android la bloquea, se pide un toque (no se falla en silencio).
     */
    fun forget(req: JSONObject): JSONObject {
        val (a, dev) = bondedDevice(req)
        val addr = dev.address
        val accepted = try {
            BluetoothDevice::class.java.getMethod("removeBond").invoke(dev) as? Boolean ?: false
        } catch (_: Exception) {
            false
        }
        if (!accepted) {
            UserAction.open(
                ctx, UserAction.ID_BT, "Olvidar " + (nameOf(dev) ?: addr),
                "Toca para abrir los ajustes de Bluetooth y olvidar el dispositivo.",
                UserAction.bluetoothSettings()
            )
            throw CmdException(
                "needs_user_action",
                "Android no dejó que Nexo desempareje el dispositivo. Te dejé una notificación que abre los ajustes de Bluetooth.",
                JSONObject().put("action", "notification").put("opens", "bluetooth_settings")
            )
        }
        val gone = waitUntil(3000) {
            try {
                a.bondedDevices?.none { it.address.equals(addr, ignoreCase = true) } ?: true
            } catch (_: SecurityException) {
                true
            }
        }
        val o = JSONObject().put("removed", gone)
        if (!gone) o.put("hint", "Android aceptó la orden pero el dispositivo sigue emparejado.")
        return o
    }

    /** Cambia el nombre que Android muestra para ese dispositivo (alias). Con `name` vacío, quita el alias. */
    fun rename(req: JSONObject): JSONObject {
        val (_, dev) = bondedDevice(req)
        if (Build.VERSION.SDK_INT < 31) {
            throw CmdException("unsupported", "Renombrar dispositivos Bluetooth necesita Android 12 o más")
        }
        val name = req.optString("name", "").trim()
        // Se llama por reflexión: setAlias devolvía boolean en Android 12 y devuelve int en Android 13+;
        // una llamada directa fallaría (NoSuchMethodError) en una de las dos.
        val ok = try {
            val m = BluetoothDevice::class.java.getMethod("setAlias", String::class.java)
            val r = m.invoke(dev, if (name.isEmpty()) nameOf(dev) else name)
            when (r) {
                is Boolean -> r
                is Int -> r == 0 // BluetoothStatusCodes.SUCCESS
                else -> true
            }
        } catch (e: InvocationTargetException) {
            val c = e.cause
            if (c is SecurityException) {
                throw CmdException(
                    "permission_denied", "Android negó cambiar el nombre",
                    JSONObject().put("permission", "BLUETOOTH_CONNECT")
                )
            }
            false
        } catch (_: Exception) {
            false
        }
        if (!ok) throw CmdException("failed", "Android no aceptó cambiar el nombre del dispositivo")
        return JSONObject().put("address", dev.address).putOrNull("alias", aliasOf(dev))
    }

    fun info(req: JSONObject): JSONObject {
        val (a, dev) = bondedDevice(req)
        val addr = dev.address
        val live = connectedByProfile(a)[addr]
        val o = JSONObject()
        o.put("address", addr)
        o.putOrNull("name", nameOf(dev))
        o.putOrNull("alias", aliasOf(dev))
        o.put("type", typeName(dev.type))
        o.put("class", classOf(dev.bluetoothClass))
        o.put(
            "bond_state", when (dev.bondState) {
                BluetoothDevice.BOND_BONDED -> "bonded"
                BluetoothDevice.BOND_BONDING -> "bonding"
                else -> "none"
            }
        )
        o.put("connected", live != null && live.isNotEmpty())
        o.put("profiles", JSONArray(live?.sorted() ?: emptyList<String>()))
        val uu = JSONArray()
        try {
            dev.uuids?.forEach { uu.put(it.toString().lowercase()) }
        } catch (_: SecurityException) {
        }
        o.put("uuids", uu)
        o.putOrNull("battery", batteryOf(dev))
        return o
    }

    private fun aliasOf(d: BluetoothDevice): String? = try {
        if (Build.VERSION.SDK_INT >= 30) d.alias ?: d.name else d.name
    } catch (_: SecurityException) {
        null
    }

    /** Porcentaje de batería del dispositivo si lo informa (API oculta, por reflexión); null si no. */
    private fun batteryOf(d: BluetoothDevice): Int? = try {
        val v = BluetoothDevice::class.java.getMethod("getBatteryLevel").invoke(d) as? Int
        if (v != null && v in 0..100) v else null
    } catch (_: Exception) {
        null
    }

    // ---------------------------------------------------------------- ayudas

    companion object {
        // 4 = INPUT_DEVICE (teclados/ratones). Es una constante oculta del SDK, pero el número es estable.
        private const val PROFILE_INPUT_DEVICE = 4

        private val PROFILES: Map<Int, String> = mapOf(
            BluetoothProfile.HEADSET to "headset",
            BluetoothProfile.A2DP to "a2dp",
            PROFILE_INPUT_DEVICE to "hid",
        )

        private val ADDR = Regex("^([0-9A-F]{2}:){5}[0-9A-F]{2}$")

        fun stateName(s: Int): String = when (s) {
            BluetoothAdapter.STATE_ON -> "on"
            BluetoothAdapter.STATE_OFF -> "off"
            BluetoothAdapter.STATE_TURNING_ON -> "turning_on"
            BluetoothAdapter.STATE_TURNING_OFF -> "turning_off"
            else -> "unknown"
        }

        fun typeName(t: Int): String = when (t) {
            BluetoothDevice.DEVICE_TYPE_CLASSIC -> "classic"
            BluetoothDevice.DEVICE_TYPE_LE -> "le"
            BluetoothDevice.DEVICE_TYPE_DUAL -> "dual"
            else -> "unknown"
        }

        fun classOf(c: BluetoothClass?): String = when (c?.majorDeviceClass) {
            BluetoothClass.Device.Major.AUDIO_VIDEO -> "audio"
            BluetoothClass.Device.Major.PHONE -> "phone"
            BluetoothClass.Device.Major.COMPUTER -> "computer"
            BluetoothClass.Device.Major.PERIPHERAL -> "peripheral"
            BluetoothClass.Device.Major.WEARABLE -> "wearable"
            BluetoothClass.Device.Major.HEALTH -> "health"
            BluetoothClass.Device.Major.IMAGING -> "imaging"
            BluetoothClass.Device.Major.NETWORKING -> "networking"
            BluetoothClass.Device.Major.TOY -> "toy"
            null -> "unknown"
            else -> "other"
        }
    }
}
