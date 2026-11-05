package org.nexo.bridge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Enciende el puente al arrancar el móvil (o tras actualizar la app) si el usuario lo pidió.
 * Si Android no deja arrancar el servicio desde aquí, deja una notificación: un toque lo enciende.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        if (!Prefs.startOnBoot(context)) return
        val pending = goAsync()
        try {
            BridgeService.start(context)
        } catch (e: Exception) {
            BridgeState.log("No se pudo iniciar al arrancar: " + e.javaClass.simpleName)
            try {
                UserAction.open(
                    context, UserAction.ID_RECOVERY, "Nexo no pudo encenderse solo",
                    "Toca para encender el puente.", Intent(context, StartActivity::class.java)
                )
            } catch (_: Exception) {
            }
        } finally {
            pending.finish()
        }
    }
}
