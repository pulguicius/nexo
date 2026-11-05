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
import android.content.pm.ServiceInfo
import android.database.ContentObserver
import android.graphics.drawable.Icon
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import org.json.JSONObject
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Servicio en primer plano que mantiene abierto el puente mientras el móvil lo necesite.
 * Va con notificación fija (Android lo exige) y reenvía los cambios de WiFi, Bluetooth, audio y
 * música a los clientes suscritos.
 *
 * Se cuida solo: si el puerto está ocupado reintenta cada 5 s, y cada ~45 s se hace un ping a sí
 * mismo; si falla dos veces seguidas, reinicia el servidor.
 */
class BridgeService : Service() {

    companion object {
        const val ACTION_STOP = "org.nexo.bridge.STOP"
        private const val NOTIF_ID = 1
        private const val BIND_RETRY_MS = 5000L
        private const val WATCHDOG_MS = 45_000L
        private const val EVENT_DEBOUNCE_MS = 300L

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
    private val wd: ExecutorService = Executors.newSingleThreadExecutor()
    private var registered = false
    private var alive = false
    private var bindFailures = 0
    private var pingFailures = 0
    private var audioCb: AudioDeviceCallback? = null
    private var volumeObs: ContentObserver? = null

    /** Último estado enviado de los temas que no cambian solos (para no repetir eventos idénticos). */
    private val lastSent = HashMap<String, String>()

    private val emitters: Map<String, Runnable> = mapOf(
        "wifi" to Runnable { emit("wifi") },
        "bt" to Runnable { emit("bt") },
        "audio" to Runnable { emit("audio") },
        "media" to Runnable { emit("media") },
    )

    /** Los avisos de Android llegan a ráfagas: se juntan 300 ms antes de avisar a los clientes. */
    private fun schedule(topic: String) {
        val r = emitters[topic] ?: return
        main.removeCallbacks(r)
        main.postDelayed(r, EVENT_DEBOUNCE_MS)
    }

    private val events = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, i: Intent?) {
            val action = i?.action ?: return
            when {
                action.startsWith("android.net.wifi") -> schedule("wifi")
                action.startsWith("android.bluetooth") -> {
                    schedule("bt")
                    schedule("audio") // al (des)conectar unos auriculares cambia la salida de audio
                }
                action == "android.media.VOLUME_CHANGED_ACTION" -> {
                    // Llega por cualquier tipo de volumen; solo importa el de música (3).
                    val stream = i.getIntExtra("android.media.EXTRA_VOLUME_STREAM_TYPE", AudioManager.STREAM_MUSIC)
                    if (stream == AudioManager.STREAM_MUSIC) schedule("audio")
                }
                else -> schedule("audio") // silencio, modo timbre
            }
        }
    }

    private val retryBind = Runnable { if (alive && server == null) startServer() }

    private val watchdog = object : Runnable {
        override fun run() {
            if (!alive) return
            if (server != null) wd.execute { selfCheck() }
            NexoNotificationListener.requestRebindIfNeeded(applicationContext)
            main.postDelayed(this, WATCHDOG_MS)
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
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIF_ID, buildNotification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            } else {
                startForeground(NOTIF_ID, buildNotification())
            }
        } catch (e: Exception) {
            // Android 12+ puede negarse si el arranque viene de segundo plano sin permiso.
            BridgeState.log("Android no dejó pasar a primer plano: " + e.javaClass.simpleName)
            UserAction.open(
                this, UserAction.ID_RECOVERY, "Nexo no pudo encenderse solo",
                "Toca para encender el puente.", Intent(this, StartActivity::class.java)
            )
            stopSelf()
            return START_NOT_STICKY
        }
        Prefs.setServiceWanted(this, true)
        if (!alive) {
            alive = true
            main.postDelayed(watchdog, WATCHDOG_MS)
        }
        if (server == null) startServer()
        return START_STICKY
    }

    private fun startServer() {
        val port = Prefs.port(this)
        val cmds = commands ?: Commands(applicationContext)
        val srv = BridgeServer(
            applicationContext, port,
            { Prefs.token(applicationContext) },
            cmds,
            { refreshNotification() }
        )
        try {
            srv.start()
        } catch (e: IOException) {
            // Suele pasar justo tras un cierre brusco: el puerto tarda unos segundos en liberarse.
            val msg = "No se pudo abrir 127.0.0.1:" + port + " (" + (e.message ?: "?") + "). ¿Otra app usa ese puerto?"
            BridgeState.running = false
            BridgeState.startedAt = 0L
            BridgeState.lastError = msg
            if (bindFailures % 12 == 0) BridgeState.log("$msg Reintento cada 5 s.")
            bindFailures++
            refreshNotification()
            main.removeCallbacks(retryBind)
            main.postDelayed(retryBind, BIND_RETRY_MS)
            return
        }
        server = srv
        commands = cmds
        bindFailures = 0
        pingFailures = 0
        BridgeState.port = port
        BridgeState.running = true
        BridgeState.startedAt = SystemClock.elapsedRealtime()
        BridgeState.lastError = null
        BridgeState.log("Puente escuchando en 127.0.0.1:" + port)
        registerEvents()
        cmds.media.onChange = { schedule("media") }
        cmds.media.watch()
        NexoNotificationListener.onChange = {
            main.post {
                commands?.media?.watch()
                schedule("media")
            }
        }
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
        // Audio: volumen y silencio de la música, modo timbre
        f.addAction("android.media.VOLUME_CHANGED_ACTION")
        f.addAction("android.media.STREAM_MUTE_CHANGED_ACTION")
        f.addAction(AudioManager.RINGER_MODE_CHANGED_ACTION)
        registerReceiver(events, f)
        registered = true

        // Salidas de audio que aparecen o desaparecen (cable, USB, Bluetooth).
        val am = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        if (am != null) {
            val cb = object : AudioDeviceCallback() {
                override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) = schedule("audio")
                override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) = schedule("audio")
            }
            am.registerAudioDeviceCallback(cb, main)
            audioCb = cb
        }
        // Algunos móviles no mandan VOLUME_CHANGED_ACTION a apps de terceros: el volumen también se guarda
        // en los ajustes del sistema, así que se vigila ahí (las ráfagas se juntan en schedule()).
        try {
            val obs = object : ContentObserver(main) {
                override fun onChange(selfChange: Boolean) = schedule("audio")
            }
            contentResolver.registerContentObserver(Settings.System.CONTENT_URI, true, obs)
            volumeObs = obs
        } catch (_: Exception) {
        }
    }

    private fun unregisterEvents() {
        if (registered) {
            try {
                unregisterReceiver(events)
            } catch (_: Exception) {
            }
            registered = false
        }
        val am = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        audioCb?.let {
            try {
                am?.unregisterAudioDeviceCallback(it)
            } catch (_: Exception) {
            }
        }
        audioCb = null
        volumeObs?.let {
            try {
                contentResolver.unregisterContentObserver(it)
            } catch (_: Exception) {
            }
        }
        volumeObs = null
    }

    private fun emit(topic: String) {
        try {
            bg.execute {
                val srv = server
                val cmds = commands
                if (srv != null && cmds != null) {
                    try {
                        val st = cmds.statusFor(topic)
                        // audio y bt no tienen datos que cambien solos: no se repite un estado idéntico.
                        if (topic == "audio" || topic == "bt") {
                            val key = st.toString()
                            synchronized(lastSent) {
                                if (lastSent[topic] == key) return@execute
                                lastSent[topic] = key
                            }
                        }
                        srv.broadcast(topic, st)
                    } catch (_: Exception) {
                    }
                }
            }
        } catch (_: Exception) {
            // el servicio ya se estaba cerrando
        }
    }

    /**
     * Se conecta a su propio puerto, se autentica y hace ping. Si falla dos veces seguidas, reinicia
     * el servidor (el cliente "nexo-watchdog" no cuenta como cliente ni se anota).
     */
    private fun selfCheck() {
        val srv = server ?: return
        val ok = try {
            Socket().use { s ->
                s.connect(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), BridgeState.port), 1500)
                s.soTimeout = 3000
                val out = s.getOutputStream()
                val inp = s.getInputStream().bufferedReader(Charsets.UTF_8)
                val hello = JSONObject().put("id", "w1").put("cmd", "hello")
                    .put("token", Prefs.token(applicationContext)).put("client", WATCHDOG_CLIENT)
                out.write((hello.toString() + "\n").toByteArray(Charsets.UTF_8))
                out.flush()
                if (!JSONObject(inp.readLine() ?: return@use false).optBoolean("ok", false)) return@use false
                out.write("{\"id\":\"w2\",\"cmd\":\"ping\"}\n".toByteArray(Charsets.UTF_8))
                out.flush()
                JSONObject(inp.readLine() ?: return@use false).optBoolean("ok", false)
            }
        } catch (_: Exception) {
            false
        }
        if (ok) {
            pingFailures = 0
            return
        }
        pingFailures++
        if (pingFailures < 2) return
        pingFailures = 0
        BridgeState.log("El puente no contestó a su propio ping: reinicio el servidor")
        main.post {
            if (alive && server === srv) {
                srv.stop()
                server = null
                BridgeState.running = false
                BridgeState.startedAt = 0L
                startServer()
            }
        }
    }

    private fun buildNotification(): Notification {
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), flags)
        val stopIntent = Intent(this, BridgeService::class.java).setAction(ACTION_STOP)
        val stop = PendingIntent.getService(this, 1, stopIntent, flags)
        val n = BridgeState.clients
        val text = when {
            BridgeState.running -> "127.0.0.1:" + BridgeState.port + " · " + when (n) {
                0 -> "sin clientes"
                1 -> "1 cliente conectado"
                else -> "$n clientes conectados"
            }
            BridgeState.lastError != null -> "Esperando el puerto " + Prefs.port(this) + " (ocupado)…"
            else -> "Iniciando…"
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
        if (!alive) return
        try {
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIF_ID, buildNotification())
        } catch (_: Exception) {
        }
    }

    override fun onDestroy() {
        alive = false
        BridgeState.running = false
        BridgeState.startedAt = 0L
        BridgeState.clients = 0
        unregisterEvents()
        NexoNotificationListener.onChange = null
        commands?.media?.let {
            it.onChange = null
            it.unwatch()
        }
        main.removeCallbacksAndMessages(null)
        server?.stop()
        server = null
        commands = null
        bg.shutdownNow()
        wd.shutdownNow()
        BridgeState.log("Puente detenido")
        super.onDestroy()
    }
}
