package org.nexo.bridge

import android.content.ComponentName
import android.content.Context
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * Android solo deja que una app vea las sesiones de medios de las demás (la música que suena, sus
 * botones y su carátula) si tiene concedido el «acceso a notificaciones». Este servicio es esa
 * llave. Además, desde la 0.4.3, si el usuario activa «Reenviar notificaciones a Linux» en la app,
 * pasa lo que ocurre con las notificaciones a NotifBridge (que las entrega por el puente local a los
 * clientes suscritos). Con el interruptor apagado (lo normal) NO lee ni reenvía ninguna notificación,
 * y no guarda nada nunca.
 *
 * El usuario lo concede una sola vez en Ajustes › Notificaciones › Acceso a notificaciones.
 */
class NexoNotificationListener : NotificationListenerService() {

    companion object {
        @Volatile
        var connected = false
            private set

        /** El servicio, mientras Android lo tiene enlazado (para `activeNotifications` y `cancelNotification`). */
        @Volatile
        var instance: NexoNotificationListener? = null
            private set

        /** Lo asigna el servicio del puente mientras escucha: sin él no se reenvía nada. */
        @Volatile
        var bridge: NotifBridge? = null

        /** ¿Le dio el usuario el acceso a notificaciones a Nexo? */
        fun isEnabled(ctx: Context): Boolean {
            val flat = Settings.Secure.getString(ctx.contentResolver, "enabled_notification_listeners") ?: return false
            val me = ComponentName(ctx, NexoNotificationListener::class.java)
            return flat.split(':').any { ComponentName.unflattenFromString(it) == me }
        }

        /** Pide a Android que vuelva a enlazar el servicio (por si el sistema lo soltó). */
        fun requestRebindIfNeeded(ctx: Context) {
            if (!connected && isEnabled(ctx)) {
                try {
                    requestRebind(ComponentName(ctx, NexoNotificationListener::class.java))
                } catch (_: Exception) {
                }
            }
        }

        /** Lo asigna el servicio del puente para enterarse cuando el acceso se concede o se pierde. */
        @Volatile
        var onChange: (() -> Unit)? = null
    }

    override fun onListenerConnected() {
        instance = this
        connected = true
        BridgeState.log("Acceso a notificaciones activo")
        onChange?.invoke()
    }

    override fun onListenerDisconnected() {
        connected = false
        instance = null
        bridge?.reset()
        BridgeState.log("Acceso a notificaciones perdido")
        onChange?.invoke()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?, rankingMap: RankingMap?) {
        if (sbn == null) return
        try {
            bridge?.onPosted(sbn, rankingMap)
        } catch (_: Exception) {
            // una notificación rara no debe tirar el servicio
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?, rankingMap: RankingMap?, reason: Int) {
        if (sbn == null) return
        try {
            bridge?.onRemoved(sbn, reason)
        } catch (_: Exception) {
        }
    }
}
