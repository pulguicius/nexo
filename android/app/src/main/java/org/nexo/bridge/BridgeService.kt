package org.nexo.bridge

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.drawable.Icon
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Servicio en primer plano que mantiene abierto el puente mientras el móvil lo necesite.
 * Va con notificación fija (Android lo exige) y reenvía los cambios de WiFi/Bluetooth
 * a los clientes suscritos.
 */
class BridgeService : Service() {

    companion object {
        const val ACTION_STOP = "org.nexo.bridge.STOP"
        private const val NOTIF_ID = 1

        fun start(ctx: Context) {
            ctx.startForegroundService(Intent(ctx, BridgeService::class.java))
        }

        fun stop(ctx: Context) {
            Prefs.setServiceWanted(ctx, false)
            ctx.stopService(Intent(ctx, BridgeService::class.java))
        }
    }

    private var server: BridgeServer? = null
    private var commands: Commands? = null
    private val main = Handler(Looper.getMainLooper())
    private val bg: ExecutorService = Executors.newSingleThreadExecutor()
    private var registered = false

    private val emitWifi = Runnable { emit("wifi") }
    private val emitBt = Runnable { emit("bt") }

    /** Los avisos de Android llegan a ráfagas: se juntan 300 ms antes de avisar a los clientes. */
    private val events = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, i: Intent?) {
            val action = i?.action ?: return
            val r = if (action.startsWith("android.net.wifi")) emitWifi else emitBt
            main.removeCallbacks(r)
            main.postDelayed(r, 300)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            Prefs.setServiceWanted(this, false)
            stopSelf()
            return START_NOT_STICKY
        }
        UserAction.ensureChannels(this)
        try {
            startForeground(NOTIF_ID, buildNotification())
        } catch (e: Exception) {
            // Android 12+ puede negarse si el arranque viene de segundo plano sin permiso.
            BridgeState.log("Android no dejó pasar a primer plano: " + e.javaClass.simpleName)
            stopSelf()
            return START_NOT_STICKY
        }
        Prefs.setServiceWanted(this, true)
        if (server == null) startServer()
        return START_STICKY
    }

    private fun startServer() {
        val port = Prefs.port(this)
        val cmds = Commands(applicationContext)
        val srv = BridgeServer(
            applicationContext, port,
            { Prefs.token(applicationContext) },
            cmds,
            { refreshNotification() }
        )
        try {
            srv.start()
        } catch (e: IOException) {
            val msg = "No se pudo abrir 127.0.0.1:" + port + " (" + (e.message ?: "?") + "). ¿Otra app usa ese puerto?"
            BridgeState.running = false
            BridgeState.lastError = msg
            BridgeState.log(msg)
            stopSelf()
            return
        }
        server = srv
        commands = cmds
        BridgeState.port = port
        BridgeState.running = true
        BridgeState.lastError = null
        BridgeState.log("Puente escuchando en 127.0.0.1:" + port)
        registerEvents()
        refreshNotification()
    }

    private fun registerEvents() {
        if (registered) return
        val f = IntentFilter()
        f.addAction(WifiManager.WIFI_STATE_CHANGED_ACTION)
        f.addAction(WifiManager.NETWORK_STATE_CHANGED_ACTION)
        f.addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
        f.addAction(BluetoothAdapter.ACTION_CONNECTION_STATE_CHANGED)
        f.addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
        f.addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
        f.addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
        f.addAction("android.bluetooth.a2dp.profile.action.CONNECTION_STATE_CHANGED")
        f.addAction("android.bluetooth.headset.profile.action.CONNECTION_STATE_CHANGED")
        registerReceiver(events, f)
        registered = true
    }

    private fun emit(topic: String) {
        try {
            bg.execute {
                val srv = server
                val cmds = commands
                if (srv != null && cmds != null) {
                    try {
                        srv.broadcast(topic, cmds.statusFor(topic))
                    } catch (_: Exception) {
                    }
                }
            }
        } catch (_: Exception) {
            // el servicio ya se estaba cerrando
        }
    }

    private fun buildNotification(): Notification {
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), flags)
        val stopIntent = Intent(this, BridgeService::class.java).setAction(ACTION_STOP)
        val stop = PendingIntent.getService(this, 1, stopIntent, flags)
        val n = BridgeState.clients
        val text = if (!BridgeState.running) {
            "Iniciando…"
        } else {
            "127.0.0.1:" + BridgeState.port + " · " + when (n) {
                0 -> "sin clientes"
                1 -> "1 cliente conectado"
                else -> "$n clientes conectados"
            }
        }
        val detener = Notification.Action.Builder(
            Icon.createWithResource(this, R.drawable.ic_notification), "Detener", stop
        ).build()
        return Notification.Builder(this, UserAction.CH_SERVICE)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Nexo activo")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(detener)
            .build()
    }

    private fun refreshNotification() {
        if (!BridgeState.running) return
        try {
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIF_ID, buildNotification())
        } catch (_: Exception) {
        }
    }

    override fun onDestroy() {
        BridgeState.running = false
        BridgeState.clients = 0
        if (registered) {
            try {
                unregisterReceiver(events)
            } catch (_: Exception) {
            }
            registered = false
        }
        main.removeCallbacksAndMessages(null)
        server?.stop()
        server = null
        commands = null
        bg.shutdownNow()
        BridgeState.log("Puente detenido")
        super.onDestroy()
    }
}
