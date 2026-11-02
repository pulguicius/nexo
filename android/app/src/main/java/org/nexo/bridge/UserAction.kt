package org.nexo.bridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings

/**
 * Cosas que Android solo deja hacer si el usuario las confirma con un toque.
 * Desde un servicio en segundo plano no se puede abrir una pantalla, así que se deja una
 * notificación; al tocarla se abre justo el panel que hace falta. Si la pantalla de Nexo
 * está abierta, se lanza directamente.
 */
object UserAction {
    const val CH_SERVICE = "nexo_service"
    const val CH_ACTIONS = "nexo_actions"

    const val ID_WIFI = 1001
    const val ID_BT = 1002

    /**
     * Crea los canales de notificación. Se llama al abrir la pantalla: en Android 13+ eso es
     * lo que hace que el sistema pida el permiso de avisos a las apps que apuntan a API 28.
     */
    fun ensureChannels(ctx: Context) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CH_SERVICE) == null) {
            val ch = NotificationChannel(CH_SERVICE, "Puente activo", NotificationManager.IMPORTANCE_LOW)
            ch.description = "Aviso fijo mientras el puente con Termux está encendido"
            ch.setShowBadge(false)
            nm.createNotificationChannel(ch)
        }
        if (nm.getNotificationChannel(CH_ACTIONS) == null) {
            val ch = NotificationChannel(CH_ACTIONS, "Acciones pendientes", NotificationManager.IMPORTANCE_HIGH)
            ch.description = "Cuando Android exige que confirmes algo con un toque"
            nm.createNotificationChannel(ch)
        }
    }

    fun open(ctx: Context, id: Int, title: String, text: String, intent: Intent) {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (BridgeState.uiVisible) {
            try {
                ctx.startActivity(intent)
                return
            } catch (_: Exception) {
                // seguimos con la notificación
            }
        }
        ensureChannels(ctx)
        val pi = PendingIntent.getActivity(
            ctx, id, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val n = Notification.Builder(ctx, CH_ACTIONS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(pi)
            .setAutoCancel(true)
            .build()
        (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(id, n)
    }

    fun wifiPanel(): Intent =
        if (Build.VERSION.SDK_INT >= 29) Intent(Settings.Panel.ACTION_WIFI)
        else Intent(Settings.ACTION_WIFI_SETTINGS)

    fun bluetoothEnable(): Intent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)

    fun bluetoothSettings(): Intent = Intent(Settings.ACTION_BLUETOOTH_SETTINGS)
}
