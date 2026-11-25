package org.nexo.bridge

import android.app.Notification
import android.content.Context
import android.os.SystemClock
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONArray
import org.json.JSONObject

/**
 * Reenvío de notificaciones de Android a Linux (protocolo 1.5): `notif.status`, `notif.list`, `notif.dismiss` y los eventos del tema
 * `notif` (`posted` y `removed`). Linux las puede enseñar con dunst, mako o lo que haya (nexo-dbus las entrega a
 * org.freedesktop.Notifications) y quitarlas del móvil cuando las cierras allí.
 *
 * Hace falta el «acceso a notificaciones» de Android Y que el usuario active «Reenviar notificaciones a Linux» en la app (apagado
 * por defecto: el contenido de tus notificaciones es privado). Sin las dos cosas no sale nada. Nada se guarda: solo se reenvía lo
 * que pasa mientras hay un cliente suscrito. Las reglas puras (qué se reenvía, recortes, repeticiones) están en NotifLogic.kt.
 */
class NotifBridge(context: Context) {
    private val ctx: Context = context.applicationContext
    private val labels = HashMap<String, String>()
    private val seen = NotifLogic.Dedupe()
    private val limiter = NotifLogic.Limiter(40, 10_000L)

    @Volatile
    private var dropping = false

    /** Quien difunde un evento del tema `notif` a los clientes suscritos (lo asigna el servicio del puente). */
    @Volatile
    var sink: ((JSONObject) -> Unit)? = null

    // ---------------------------------------------------------------- comandos

    fun status(): JSONObject {
        return JSONObject()
            .put("access", NexoNotificationListener.isEnabled(ctx))
            .put("forwarding", Prefs.forwardNotifications(ctx))
            .put("active", visible().size)
    }

    fun list(): JSONObject {
        requireReady()
        val ranks = rankings()
        val views = ArrayList<JSONObject>()
        for (sbn in visible()) views.add(view(sbn, rankOf(ranks, sbn.key)))
        val n = NotifLogic.takeWithin(views.map { it.toString().toByteArray(Charsets.UTF_8).size }, NotifLogic.MAX_LIST, NotifLogic.MAX_LIST_BYTES)
        val arr = JSONArray()
        for (i in 0 until n) arr.put(views[i])
        return JSONObject().put("notifications", arr)
    }

    fun dismiss(req: JSONObject): JSONObject {
        requireReady()
        val key = req.optString("key", "")
        if (key.isEmpty()) throw CmdException("bad_request", "Falta «key»: la clave de la notificación (mírala con notif.list)")
        val l = NexoNotificationListener.instance ?: throw needsAccess()
        val sbn = try {
            l.activeNotifications?.firstOrNull { it.key == key }
        } catch (_: Exception) {
            null
        } ?: throw CmdException("not_found", "No hay ninguna notificación con esa clave")
        if (!sbn.isClearable) throw CmdException("failed", "Android no deja quitar esa notificación (es fija o de un servicio que está en marcha)")
        try {
            l.cancelNotification(key)
        } catch (e: Exception) {
            throw CmdException("failed", "Android no quiso quitarla: " + e.javaClass.simpleName)
        }
        return JSONObject().put("dismissed", true)
    }

    // ---------------------------------------------------------------- cómo se ve una notificación

    fun view(sbn: StatusBarNotification, rank: NotificationListenerService.Ranking?): JSONObject {
        val n = sbn.notification
        val ex = n.extras
        return JSONObject()
            .put("key", sbn.key)
            .put("package", sbn.packageName)
            .put("app", appLabel(sbn.packageName))
            .put("title", NotifLogic.clip(ex?.getCharSequence(Notification.EXTRA_TITLE)?.toString(), NotifLogic.MAX_TITLE))
            .put("text", NotifLogic.clip(bodyOf(n), NotifLogic.MAX_TEXT))
            .put("time", sbn.postTime)
            .putOrNull("category", n.category)
            .put("importance", NotifLogic.importance(rank?.importance))
            .put("ongoing", sbn.isOngoing)
            .put("clearable", sbn.isClearable)
    }

    /** El cuerpo: el texto, si no el texto largo, si no la última línea de una lista (correo). */
    private fun bodyOf(n: Notification): String? {
        val ex = n.extras ?: return null
        val text = ex.getCharSequence(Notification.EXTRA_TEXT)?.toString()
        if (!text.isNullOrBlank()) return text
        val big = ex.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
        if (!big.isNullOrBlank()) return big
        return ex.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)?.lastOrNull()?.toString()
    }

    fun postedEvent(sbn: StatusBarNotification, rank: NotificationListenerService.Ranking?): JSONObject {
        return view(sbn, rank).put("op", "posted")
    }

    fun removedEvent(key: String, reason: String): JSONObject {
        return JSONObject().put("op", "removed").put("key", key).put("reason", reason)
    }

    // ---------------------------------------------------------------- eventos (los llama NexoNotificationListener)

    fun onPosted(sbn: StatusBarNotification, map: NotificationListenerService.RankingMap?) {
        val out = sink ?: return
        if (!Prefs.forwardNotifications(ctx) || !wanted(sbn)) return
        val ev = postedEvent(sbn, rankOf(map, sbn.key))
        val fp = NotifLogic.fingerprint(
            ev.optString("title"), ev.optString("text"), ev.optBoolean("ongoing"), ev.optInt("importance"), ev.optString("category", "")
        )
        val now = SystemClock.elapsedRealtime()
        if (!seen.allow(sbn.key, fp, sbn.isOngoing, now)) return
        if (!limiter.allow(now)) {
            if (!dropping) {
                dropping = true
                BridgeState.log("Muchas notificaciones seguidas: se omiten algunas para no saturar a Linux")
            }
            return
        }
        dropping = false
        out(ev)
    }

    fun onRemoved(sbn: StatusBarNotification, reason: Int) {
        val out = sink ?: return
        // solo se avisa de que se quitó si se avisó de que llegó
        if (!seen.forget(sbn.key) || !Prefs.forwardNotifications(ctx)) return
        out(removedEvent(sbn.key, NotifLogic.reasonName(reason)))
    }

    /** El servicio de acceso a notificaciones se desconectó (o se apagó el reenvío): se olvida lo reenviado. */
    fun reset() {
        seen.clear()
        dropping = false
    }

    // ---------------------------------------------------------------- auxiliares

    private fun wanted(sbn: StatusBarNotification): Boolean = NotifLogic.forward(
        sbn.packageName ?: "", ctx.packageName, (sbn.notification.flags and Notification.FLAG_GROUP_SUMMARY) != 0, sbn.notification.category
    )

    /** Las notificaciones activas que se reenvían, las más nuevas primero. */
    private fun visible(): List<StatusBarNotification> {
        val l = NexoNotificationListener.instance ?: return emptyList()
        val all = try {
            l.activeNotifications
        } catch (_: Exception) {
            null
        } ?: return emptyList()
        return all.filter { wanted(it) }.sortedByDescending { it.postTime }
    }

    private fun rankings(): NotificationListenerService.RankingMap? = try {
        NexoNotificationListener.instance?.currentRanking
    } catch (_: Exception) {
        null
    }

    private fun rankOf(map: NotificationListenerService.RankingMap?, key: String): NotificationListenerService.Ranking? {
        if (map == null) return null
        val r = NotificationListenerService.Ranking()
        return if (map.getRanking(key, r)) r else null
    }

    private fun appLabel(pkg: String): String = synchronized(labels) {
        labels.getOrPut(pkg) {
            try {
                ctx.packageManager.getApplicationLabel(ctx.packageManager.getApplicationInfo(pkg, 0)).toString()
            } catch (_: Exception) {
                pkg
            }
        }
    }

    /** Sin el acceso a notificaciones, o sin el reenvío activado, no se puede: se deja una notificación que abre lo que falta. */
    private fun requireReady() {
        if (!NexoNotificationListener.isEnabled(ctx)) throw needsAccess()
        if (!Prefs.forwardNotifications(ctx)) {
            UserAction.open(
                ctx, UserAction.ID_FORWARD, "Reenviar notificaciones a Linux",
                "Toca para activar el reenvío en Nexo (tus notificaciones no salen del móvil hasta que lo actives).", UserAction.nexoApp(ctx)
            )
            throw CmdException(
                "needs_user_action",
                "Activa «Reenviar notificaciones a Linux» en la app Nexo: tus notificaciones no salen de Android hasta que lo actives. " +
                    "Te dejé una notificación que abre la app.",
                JSONObject().put("action", "notification").put("opens", "nexo_app")
            )
        }
    }

    private fun needsAccess(): CmdException {
        UserAction.open(
            ctx, UserAction.ID_LISTENER, "Dar acceso a notificaciones",
            "Toca para concederle a Nexo el acceso a las notificaciones.", UserAction.notificationListenerSettings()
        )
        return CmdException(
            "needs_user_action",
            "Da a Nexo el acceso a las notificaciones en los ajustes de Android. Te dejé una notificación que abre esos ajustes. " +
                "(Android 13 o más: si el interruptor sale en gris, ve a Ajustes › Aplicaciones › Nexo › ⋮ › Permitir ajustes restringidos.)",
            JSONObject().put("action", "notification").put("opens", "notification_listener_settings")
        )
    }
}
