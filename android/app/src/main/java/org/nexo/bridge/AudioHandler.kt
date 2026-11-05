package org.nexo.bridge

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject

/**
 * Audio del móvil: volumen de MÚSICA, silencio, y qué salida está sonando (altavoz, auriculares
 * Bluetooth, USB…).
 *
 * Cambiar el volumen no pide permisos especiales. Lo que Android NO deja hacer a una app normal es
 * redirigir el audio del sistema a otra salida: `audio.switch` valida la salida y abre el panel de
 * volumen para que el usuario la elija con un toque.
 */
class AudioHandler(context: Context) {
    private val ctx: Context = context.applicationContext
    private val am: AudioManager? = ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager

    fun hasHardware(): Boolean = am != null

    private fun requireAm(): AudioManager =
        am ?: throw CmdException("unsupported", "Este móvil no tiene gestor de audio")

    private fun minVolume(a: AudioManager): Int =
        if (Build.VERSION.SDK_INT >= 28) a.getStreamMinVolume(AudioManager.STREAM_MUSIC) else 0

    private fun isMuted(a: AudioManager, level: Int): Boolean =
        if (Build.VERSION.SDK_INT >= 23) a.isStreamMute(AudioManager.STREAM_MUSIC) else level == 0

    /** Porcentaje (0-100) redondeado de `level` entre `lo` y `hi`. */
    private fun pct(level: Int, lo: Int, hi: Int): Int =
        if (hi <= lo) 0 else ((level - lo) * 100.0 / (hi - lo) + 0.5).toInt().coerceIn(0, 100)

    // ---------------------------------------------------------------- estado

    fun status(): JSONObject {
        val a = am ?: return JSONObject().put("available", false)
        val lo = minVolume(a)
        val hi = a.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        val level = a.getStreamVolume(AudioManager.STREAM_MUSIC)
        val o = JSONObject()
        o.put("available", true)
        o.put("stream", "music")
        o.put("level", level)
        o.put("min", lo)
        o.put("max", hi)
        o.put("volume", pct(level, lo, hi))
        o.put("muted", isMuted(a, level))
        val out = try {
            activeOutput(a, listOutputs(a))
        } catch (_: Exception) {
            null
        }
        o.putOrNull("output", out?.let { outputJson(it, true, withActive = false) })
        o.put(
            "ringer", when (a.ringerMode) {
                AudioManager.RINGER_MODE_SILENT -> "silent"
                AudioManager.RINGER_MODE_VIBRATE -> "vibrate"
                else -> "normal"
            }
        )
        return o
    }

    // ---------------------------------------------------------------- volumen

    fun volume(req: JSONObject): JSONObject {
        val a = requireAm()
        val keys = listOf("percent", "level", "delta", "mute").filter { req.has(it) }
        if (keys.size != 1) throw CmdException("bad_request", "Indica exactamente uno de: percent, level, delta, mute")
        val key = keys[0]
        val v: Any? = req.opt(key)
        val flags = if (req.optBoolean("show_ui", false)) AudioManager.FLAG_SHOW_UI else 0
        val stream = AudioManager.STREAM_MUSIC
        val lo = minVolume(a)
        val hi = a.getStreamMaxVolume(stream)
        val cur = a.getStreamVolume(stream)

        fun unmute() {
            if (isMuted(a, cur)) a.adjustStreamVolume(stream, AudioManager.ADJUST_UNMUTE, flags)
        }

        when (key) {
            "mute" -> {
                val dir = when {
                    v == "toggle" -> AudioManager.ADJUST_TOGGLE_MUTE
                    v is Boolean -> if (v) AudioManager.ADJUST_MUTE else AudioManager.ADJUST_UNMUTE
                    else -> throw CmdException("bad_request", "mute debe ser true, false o \"toggle\"")
                }
                a.adjustStreamVolume(stream, dir, flags)
            }
            "percent" -> {
                if (v !is Number || v.toDouble() < 0.0 || v.toDouble() > 100.0) {
                    throw CmdException("bad_request", "percent debe estar entre 0 y 100")
                }
                val target = (v.toDouble() / 100.0 * (hi - lo) + 0.5).toInt() + lo
                a.setStreamVolume(stream, target.coerceIn(lo, hi), flags)
                unmute()
            }
            "level" -> {
                if (v !is Number || v.toDouble() != Math.floor(v.toDouble())) {
                    throw CmdException("bad_request", "level debe ser un entero")
                }
                a.setStreamVolume(stream, v.toInt().coerceIn(lo, hi), flags)
                unmute()
            }
            else -> { // delta
                if (v !is Number) throw CmdException("bad_request", "delta debe ser un número")
                val d = v.toDouble()
                var target = ((pct(cur, lo, hi) + d) / 100.0 * (hi - lo) + 0.5).toInt() + lo
                if (d != 0.0 && target == cur) target += if (d > 0) 1 else -1 // al menos un escalón
                a.setStreamVolume(stream, target.coerceIn(lo, hi), flags)
                if (d > 0) unmute()
            }
        }
        return status()
    }

    // ---------------------------------------------------------------- salidas

    fun outputs(): JSONObject {
        val a = requireAm()
        val list = listOutputs(a)
        val active = try {
            activeOutput(a, list)
        } catch (_: Exception) {
            null
        }
        val arr = JSONArray()
        for (d in list) arr.put(outputJson(d, active != null && d.id == active.id, withActive = true))
        return JSONObject().put("outputs", arr)
    }

    fun switch(req: JSONObject): JSONObject {
        val a = requireAm()
        val hasId = req.has("id") && req.opt("id") is Number
        val type = req.optString("type", "")
        if (!hasId && type.isEmpty()) throw CmdException("bad_request", "Indica id o type")
        val id = req.optInt("id", Int.MIN_VALUE)
        val found = listOutputs(a).firstOrNull { (hasId && it.id == id) || (type.isNotEmpty() && typeName(it.type) == type) }
            ?: throw CmdException("not_found", "Esa salida de audio no existe")
        UserAction.open(
            ctx, UserAction.ID_AUDIO, "Cambiar la salida de audio",
            "Toca para elegir «" + displayName(found) + "» en el panel de volumen.",
            UserAction.volumePanel()
        )
        throw CmdException(
            "needs_user_action",
            "Android no deja que una app normal cambie la salida de audio del sistema. " +
                "Te dejé una notificación que abre el panel de volumen.",
            JSONObject().put("action", "notification").put("opens", "volume_panel")
        )
    }

    private fun listOutputs(a: AudioManager): List<AudioDeviceInfo> {
        if (Build.VERSION.SDK_INT < 23) return emptyList()
        return a.getDevices(AudioManager.GET_DEVICES_OUTPUTS).filter {
            it.isSink && it.type != AudioDeviceInfo.TYPE_TELEPHONY &&
                it.type != AudioDeviceInfo.TYPE_REMOTE_SUBMIX && it.type != AudioDeviceInfo.TYPE_BUS
        }
    }

    /**
     * La salida por la que sonaría la música ahora. En Android 13+ se le pregunta al sistema;
     * antes se usa el orden habitual de Android: Bluetooth, cable, USB, HDMI y, por último, el altavoz.
     */
    private fun activeOutput(a: AudioManager, list: List<AudioDeviceInfo>): AudioDeviceInfo? {
        if (Build.VERSION.SDK_INT >= 33) {
            try {
                val attrs = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
                val first = a.getAudioDevicesForAttributes(attrs).firstOrNull()
                if (first != null) return list.firstOrNull { it.id == first.id } ?: first
            } catch (_: Exception) {
                // seguimos con el orden habitual
            }
        }
        for (t in PRIORITY) {
            val d = list.firstOrNull { it.type == t }
            if (d != null) return d
        }
        return list.firstOrNull()
    }

    private fun addressOf(d: AudioDeviceInfo): String =
        if (Build.VERSION.SDK_INT >= 28) d.address ?: "" else ""

    private fun displayName(d: AudioDeviceInfo): String {
        when (d.type) {
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> return "Altavoz del teléfono"
            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> return "Auricular del teléfono"
        }
        val n = d.productName?.toString()
        return if (n.isNullOrBlank()) typeName(d.type) else n
    }

    private fun outputJson(d: AudioDeviceInfo, active: Boolean, withActive: Boolean): JSONObject {
        val o = JSONObject()
        o.put("id", d.id)
        o.put("type", typeName(d.type))
        o.put("name", displayName(d))
        o.put("address", addressOf(d))
        if (withActive) o.put("active", active)
        return o
    }

    companion object {
        /** Qué salida gana cuando hay varias (de mayor a menor prioridad). */
        private val PRIORITY = intArrayOf(
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
            AudioDeviceInfo.TYPE_BLE_SPEAKER,
            AudioDeviceInfo.TYPE_HEARING_AID,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_USB_DEVICE,
            AudioDeviceInfo.TYPE_HDMI,
            AudioDeviceInfo.TYPE_LINE_ANALOG,
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE,
        )

        fun typeName(t: Int): String = when (t) {
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "earpiece"
            AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wired_headset"
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "wired_headphones"
            AudioDeviceInfo.TYPE_USB_HEADSET -> "usb_headset"
            AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_ACCESSORY -> "usb_device"
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "bluetooth_a2dp"
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "bluetooth_sco"
            AudioDeviceInfo.TYPE_BLE_HEADSET -> "ble_headset"
            AudioDeviceInfo.TYPE_BLE_SPEAKER -> "ble_speaker"
            AudioDeviceInfo.TYPE_HEARING_AID -> "hearing_aid"
            AudioDeviceInfo.TYPE_HDMI, AudioDeviceInfo.TYPE_HDMI_ARC -> "hdmi"
            AudioDeviceInfo.TYPE_LINE_ANALOG, AudioDeviceInfo.TYPE_LINE_DIGITAL -> "line"
            AudioDeviceInfo.TYPE_DOCK -> "dock"
            else -> "other"
        }
    }
}
