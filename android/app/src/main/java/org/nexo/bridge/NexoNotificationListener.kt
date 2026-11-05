package org.nexo.bridge

import android.content.ComponentName
import android.content.Context
import android.provider.Settings
import android.service.notification.NotificationListenerService

/**
 * Android solo deja que una app vea las sesiones de medios de las demás (la música que suena, sus
 * botones y su carátula) si tiene concedido el «acceso a notificaciones». Este servicio es esa
 * llave: en esta versión NO lee ni guarda ninguna notificación; solo existe para que
 * `MediaSessionManager.getActiveSessions()` nos conteste.
 *
 * El usuario lo concede una sola vez en Ajustes › Notificaciones › Acceso a notificaciones.
 */
class NexoNotificationListener : NotificationListenerService() {

    companion object {
        @Volatile
        var connected = false
            private set

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
        connected = true
        BridgeState.log("Acceso a notificaciones activo")
        onChange?.invoke()
    }

    override fun onListenerDisconnected() {
        connected = false
        BridgeState.log("Acceso a notificaciones perdido")
        onChange?.invoke()
    }
}
