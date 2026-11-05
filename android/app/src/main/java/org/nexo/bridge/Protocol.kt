package org.nexo.bridge

import org.json.JSONObject

/** Error que se le devuelve al cliente como {"ok":false,"error":código,"message":...}. */
class CmdException(
    val code: String,
    message: String,
    val extra: JSONObject? = null,
) : Exception(message)

/** Formato de los mensajes. Ver docs/PROTOCOLO.md. Una línea = un objeto JSON. */
object Protocol {
    const val VERSION = 1

    /** Revisión dentro de la versión 1 (ver docs/PROTOCOLO.md): la 2 añade audio, media y comandos de WiFi/Bluetooth. */
    const val MINOR = 2
    const val MAX_LINE_BYTES = 64 * 1024

    fun ok(id: Any?, data: JSONObject? = null): JSONObject {
        val o = JSONObject()
        o.put("id", id ?: JSONObject.NULL)
        o.put("ok", true)
        if (data != null) o.put("data", data)
        return o
    }

    fun error(id: Any?, code: String, message: String, extra: JSONObject? = null): JSONObject {
        val o = JSONObject()
        o.put("id", id ?: JSONObject.NULL)
        o.put("ok", false)
        o.put("error", code)
        o.put("message", message)
        if (extra != null) {
            val keys = extra.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                o.put(k, extra.get(k))
            }
        }
        return o
    }

    fun event(topic: String, data: JSONObject): JSONObject {
        val o = JSONObject()
        o.put("event", topic)
        o.put("data", data)
        return o
    }
}

/** put() que guarda null como JSON null (el put normal de org.json borraría la clave). */
fun JSONObject.putOrNull(key: String, value: Any?): JSONObject = put(key, value ?: JSONObject.NULL)
