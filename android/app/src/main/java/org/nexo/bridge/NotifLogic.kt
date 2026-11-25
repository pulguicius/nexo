package org.nexo.bridge

import android.service.notification.NotificationListenerService

/**
 * Reenvío de notificaciones a Linux (protocolo 1.5): las reglas que NO dependen de Android, para poder probarlas en la JVM
 * (NotifLogicTest). NotifBridge.kt las une con el servicio de acceso a notificaciones y habla el protocolo.
 *
 * Privacidad: las notificaciones solo salen de Android si el usuario activó «Reenviar notificaciones a Linux» en la app, solo por
 * 127.0.0.1 y solo a un cliente con el token que se suscribió al tema `notif` (o llamó a `notif.list`). Nexo no las guarda.
 */
object NotifLogic {
    /** Caracteres que se envían del título y del texto (lo demás se corta con «…»). */
    const val MAX_TITLE = 160
    const val MAX_TEXT = 500

    /** Lo máximo que devuelve `notif.list`: una línea del protocolo mide como mucho 64 KiB. */
    const val MAX_LIST = 40
    const val MAX_LIST_BYTES = 48 * 1024

    /** Recorta a `max` caracteres (contando el «…» final) sin partir un emoji por la mitad. Quita los espacios de los extremos. */
    fun clip(s: String?, max: Int): String {
        if (s == null || max <= 0) return ""
        val t = s.trim()
        if (t.length <= max) return t
        var end = max - 1
        if (end > 0 && Character.isHighSurrogate(t[end - 1])) end -= 1
        return t.substring(0, end.coerceAtLeast(0)) + "…"
    }

    /** Importancia de Android (0 ninguna, 1 mínima, 2 baja, 3 normal, 4 alta, 5 urgente); si no se sabe, 3. */
    fun importance(raw: Int?): Int = if (raw != null && raw in 0..5) raw else 3

    /**
     * ¿Se reenvía esta notificación? No las de la propia Nexo (serían un bucle), ni los resúmenes de grupo (repiten lo que ya
     * dicen las notificaciones del grupo), ni los controles de música (categoría «transport»: de eso se ocupa MPRIS).
     */
    fun forward(pkg: String, self: String, groupSummary: Boolean, category: String?): Boolean =
        pkg != self && !groupSummary && category != "transport"

    /** Qué ve el usuario de una notificación: si no cambia, no hace falta avisar otra vez. */
    fun fingerprint(title: String, text: String, ongoing: Boolean, importance: Int, category: String?): String =
        listOf(title, text, ongoing.toString(), importance.toString(), category ?: "").joinToString("\u0001")

    /** Motivo por el que Android quitó una notificación → uno de los del protocolo: clicked, dismissed, cancelled, timeout u other. */
    fun reasonName(reason: Int): String = when (reason) {
        NotificationListenerService.REASON_CLICK -> "clicked"
        NotificationListenerService.REASON_CANCEL,
        NotificationListenerService.REASON_CANCEL_ALL,
        NotificationListenerService.REASON_LISTENER_CANCEL,
        NotificationListenerService.REASON_LISTENER_CANCEL_ALL -> "dismissed"
        NotificationListenerService.REASON_APP_CANCEL,
        NotificationListenerService.REASON_APP_CANCEL_ALL -> "cancelled"
        NotificationListenerService.REASON_TIMEOUT -> "timeout"
        else -> "other"
    }

    /** Cuántos de los primeros elementos (con esos tamaños en bytes, separados por una coma) caben en `maxBytes` y en `maxCount`. */
    fun takeWithin(sizes: List<Int>, maxCount: Int, maxBytes: Int): Int {
        var total = 0
        var n = 0
        for (s in sizes) {
            if (n >= maxCount) break
            val next = total + s + (if (n > 0) 1 else 0)
            if (next > maxBytes) break
            total = next
            n++
        }
        return n
    }

    /**
     * Evita avisar dos veces de lo mismo. Las apps vuelven a publicar la misma notificación muchas veces (una barra de progreso,
     * un reproductor): si el contenido no cambió no se reenvía. Una notificación normal que se repite igual SÍ se reenvía si pasó
     * un rato (`repeatMs`): puede ser otro «Llamada perdida» idéntico.
     */
    class Dedupe(private val repeatMs: Long = 10_000L, private val max: Int = 500) {
        private class Last(val fp: String, val at: Long)

        private val last = object : LinkedHashMap<String, Last>(16, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Last>?): Boolean = size > max
        }

        /** ¿Hay que reenviar esta publicación? Si sí, la recuerda. */
        @Synchronized
        fun allow(key: String, fp: String, ongoing: Boolean, now: Long): Boolean {
            val old = last[key]
            val same = old != null && old.fp == fp
            val ok = !same || (!ongoing && now - old!!.at >= repeatMs)
            if (ok) last[key] = Last(fp, now)
            return ok
        }

        /** Se quitó la notificación: se olvida. Devuelve si se había reenviado (si no, tampoco hay que avisar de que se quitó). */
        @Synchronized
        fun forget(key: String): Boolean = last.remove(key) != null

        @Synchronized
        fun clear() = last.clear()
    }

    /** Como mucho `max` avisos cada `windowMs`: un móvil que publica cientos de notificaciones de golpe no ahoga a Linux. */
    class Limiter(private val max: Int, private val windowMs: Long) {
        private val times = ArrayDeque<Long>()

        @Synchronized
        fun allow(now: Long): Boolean {
            while (times.isNotEmpty() && now - times.first() >= windowMs) times.removeFirst()
            if (times.size >= max) return false
            times.addLast(now)
            return true
        }
    }
}
