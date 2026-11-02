package org.nexo.bridge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Enciende el puente al arrancar el móvil (o tras actualizar la app) si el usuario lo pidió. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        if (!Prefs.startOnBoot(context)) return
        try {
            BridgeService.start(context)
        } catch (e: Exception) {
            BridgeState.log("No se pudo iniciar al arrancar: " + e.javaClass.simpleName)
        }
    }
}
