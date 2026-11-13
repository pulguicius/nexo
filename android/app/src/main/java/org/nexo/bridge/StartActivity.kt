package org.nexo.bridge

import android.app.Activity
import android.os.Bundle

/**
 * Actividad sin pantalla que enciende el puente y se cierra al instante.
 *
 * Sirve para `nexo start` (am start -n org.nexo.bridge/.StartActivity) y para la notificación
 * «Toca para encender el puente»: abrir una actividad despierta a la app aunque Android (HyperOS,
 * MIUI…) la tuviera congelada, y desde una actividad visible Android sí deja arrancar el servicio.
 */
class StartActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            BridgeService.start(this)
        } catch (e: Exception) {
            BridgeState.log("No se pudo iniciar desde StartActivity: " + e.javaClass.simpleName)
        }
        finish()
    }
}
