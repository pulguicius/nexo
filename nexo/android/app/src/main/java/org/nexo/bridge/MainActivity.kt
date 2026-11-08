package org.nexo.bridge

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.app.NotificationManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.location.LocationManager
import android.media.AudioManager
import android.media.ToneGenerator
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.provider.Settings
import android.text.InputType
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast

/**
 * Pantalla única de Nexo: encender/apagar el puente, enlazarlo con Termux, revisar permisos
 * y ver la actividad. Se construye por código (sin layouts XML) para no depender de nada más.
 */
class MainActivity : Activity() {

    private companion object {
        val BG = Color.parseColor("#0F1115")
        val CARD = Color.parseColor("#1A1D24")
        val ACCENT = Color.parseColor("#F4B860")
        val TEXT = Color.parseColor("#ECEAE4")
        val MUTED = Color.parseColor("#9A9FA8")
        val GOOD = Color.parseColor("#7BD88F")
        val BAD = Color.parseColor("#F28B82")
        val LINE = Color.parseColor("#3A3F4A")
        const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT
        const val REQ_PERMS = 7
    }

    private val ui = Handler(Looper.getMainLooper())
    private lateinit var tvState: TextView
    private lateinit var tvDetail: TextView
    private lateinit var tvError: TextView
    private lateinit var btnToggle: Button
    private lateinit var tvToken: TextView
    private lateinit var tvPerms: TextView
    private lateinit var tvLog: TextView
    private lateinit var tvAudio: TextView
    private lateinit var tvMedia: TextView
    private lateinit var etPort: EditText
    private var tokenShown = false
    private var probing = false
    private val audioProbe by lazy { AudioHandler(this) }
    private val mediaProbe by lazy { MediaHandler(this) }

    private val tick = object : Runnable {
        override fun run() {
            refresh()
            ui.postDelayed(this, 1000)
        }
    }

    // ---------------------------------------------------------------- ciclo de vida

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Crear los canales aquí hace que Android 13+ pida el permiso de avisos al abrir la app.
        UserAction.ensureChannels(this)

        val scroll = ScrollView(this)
        scroll.setBackgroundColor(BG)
        val col = LinearLayout(this)
        col.orientation = LinearLayout.VERTICAL
        col.setPadding(dp(16), dp(24), dp(16), dp(32))
        scroll.addView(col, ViewGroup.LayoutParams(MATCH, WRAP))
        setContentView(scroll)

        col.addView(text("Nexo", 30f, ACCENT, bold = true))
        col.addView(text("Puente de WiFi y Bluetooth entre Android y Termux", 14f, MUTED), lp(bottom = 16))

        // Estado
        tvState = text("", 22f, TEXT, bold = true)
        tvDetail = text("", 14f, MUTED)
        tvError = text("", 13f, BAD)
        btnToggle = button("Iniciar puente", primary = true) { toggleService() }
        col.addView(card(null, tvState, tvDetail, tvError, btnToggle, button("Reiniciar puente") { restartService() }), lp(bottom = 12))

        // Enlazar con Termux
        tvToken = text("", 13f, TEXT, mono = true)
        val rowToken = row(
            button("Mostrar token") { setTokenShown(!tokenShown) },
            button("Token nuevo") { confirmRegenerate() }
        )
        col.addView(
            card(
                "ENLAZAR CON TERMUX",
                text(
                    "Pulsa el botón y pega el comando en Termux (F-Droid, Monet o cualquier otro) o dentro de " +
                        "una distro de proot. Instala el cliente «nexo» ya enlazado, sin internet.",
                    13f, MUTED
                ),
                button("Copiar comando de instalación", primary = true) { copyInstall() },
                button("Copiar solo el token") { copyToken() },
                tvToken,
                rowToken
            ),
            lp(bottom = 12)
        )

        // Audio y música
        tvAudio = text("", 13f, TEXT)
        tvMedia = text("", 13f, TEXT)
        col.addView(
            card(
                "AUDIO Y MÚSICA",
                tvAudio,
                tvMedia,
                text(
                    "Para ver y controlar la música (título, pausa, siguiente, carátula) Android exige el «acceso a " +
                        "notificaciones». Nexo solo lo usa para las sesiones de medios: no lee ni guarda tus notificaciones." +
                        (if (Build.VERSION.SDK_INT >= 33)
                            "\n\nSi el interruptor sale en gris (Android 13 o más, app instalada desde un APK): Ajustes › Aplicaciones › " +
                                "Nexo › ⋮ (arriba a la derecha) › «Permitir ajustes restringidos», y vuelve a intentarlo."
                        else ""),
                    12f, MUTED
                ),
                button("Dar acceso a notificaciones") { openListenerSettings() },
                button("Probar sonido") { playTestTone() }
            ),
            lp(bottom = 12)
        )

        // Permisos
        tvPerms = text("", 13f, TEXT)
        col.addView(
            card(
                "PERMISOS",
                tvPerms,
                button("Conceder permisos") { askPermissions() },
                button("Abrir ajustes de la app") { openAppSettings() }
            ),
            lp(bottom = 12)
        )

        // Que Android no lo cierre
        col.addView(
            card(
                "QUE ANDROID NO LO CIERRE",
                text(
                    "Xiaomi/HyperOS y otras capas cierran apps en segundo plano. Pon la batería de Nexo en " +
                        "«Sin restricciones» y activa el inicio automático; si no, el puente se apaga solo.",
                    13f, MUTED
                ),
                button("Ahorro de batería") { openBattery() },
                button("Inicio automático (Xiaomi)") { openAutostart() }
            ),
            lp(bottom = 12)
        )

        // Opciones
        val swBoot = Switch(this)
        swBoot.text = "Iniciar con el móvil"
        swBoot.setTextColor(TEXT)
        swBoot.isChecked = Prefs.startOnBoot(this)
        swBoot.setOnCheckedChangeListener { _, checked -> Prefs.setStartOnBoot(this, checked) }
        etPort = EditText(this)
        etPort.setText(Prefs.port(this).toString())
        etPort.inputType = InputType.TYPE_CLASS_NUMBER
        etPort.setTextColor(TEXT)
        val rowPort = LinearLayout(this)
        rowPort.orientation = LinearLayout.HORIZONTAL
        rowPort.addView(text("Puerto", 14f, MUTED), LinearLayout.LayoutParams(WRAP, WRAP))
        rowPort.addView(etPort, LinearLayout.LayoutParams(0, WRAP, 1f))
        rowPort.addView(button("Guardar") { savePort() }, LinearLayout.LayoutParams(WRAP, WRAP))
        col.addView(card("OPCIONES", swBoot, rowPort), lp(bottom = 12))

        // Actividad
        tvLog = text("", 11f, MUTED, mono = true)
        col.addView(card("ACTIVIDAD", tvLog, button("Copiar registro (últimas 100 líneas)") { copyLog() }), lp(bottom = 12))

        col.addView(
            text("Nexo v" + versionName() + " · Solo escucha en 127.0.0.1 · Sin anuncios ni telemetría", 11f, MUTED)
        )
    }

    override fun onResume() {
        super.onResume()
        BridgeState.uiVisible = true
        tick.run()
    }

    override fun onPause() {
        ui.removeCallbacks(tick)
        BridgeState.uiVisible = false
        if (tokenShown) setTokenShown(false) // que no quede a la vista en «recientes»
        super.onPause()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        refresh()
    }

    // ---------------------------------------------------------------- pantalla

    private fun refresh() {
        val running = BridgeState.running
        tvState.text = if (running) "Puente encendido" else "Puente apagado"
        tvState.setTextColor(if (running) GOOD else TEXT)
        tvDetail.text = if (running) {
            "127.0.0.1:" + BridgeState.port + " · " + clientsText(BridgeState.clients) + " · activo " + uptimeText(BridgeState.uptimeSeconds())
        } else {
            "Puerto " + Prefs.port(this)
        }
        val err = BridgeState.lastError
        tvError.text = err ?: ""
        tvError.visibility = if (err == null) View.GONE else View.VISIBLE
        btnToggle.text = if (running) "Detener puente" else "Iniciar puente"
        tvToken.text = if (tokenShown) Prefs.token(this) else "Token: ••••••••••••"
        tvPerms.text = permsText()
        val lines = BridgeState.recent(14)
        tvLog.text = if (lines.isEmpty()) "Aún no hay actividad." else lines.joinToString("\n")
        probeAudioAndMedia()
    }

    /** Pregunta por el audio y la música en otro hilo (son llamadas a Android que no conviene hacer en la pantalla). */
    private fun probeAudioAndMedia() {
        if (probing) return
        probing = true
        Thread {
            var audioLine: String
            var mediaLine: String
            try {
                val a = audioProbe.status()
                audioLine = if (a.optBoolean("available")) {
                    val out = a.optJSONObject("output")?.optString("name")
                    "Volumen de música: " + a.optInt("volume") + " %" + (if (a.optBoolean("muted")) " (en silencio)" else "") +
                        (if (out.isNullOrEmpty()) "" else "\nSalida: $out")
                } else {
                    "Audio no disponible en este móvil"
                }
            } catch (e: Exception) {
                audioLine = "Audio: " + e.javaClass.simpleName
            }
            try {
                val m = mediaProbe.status()
                mediaLine = when {
                    !m.optBoolean("listener") -> "✘ Música: falta el acceso a notificaciones"
                    !m.optBoolean("available") -> "✔ Acceso concedido · no suena nada ahora"
                    else -> {
                        val t = m.optString("title").ifEmpty { "(sin título)" }
                        val ar = m.optString("artist")
                        val app = m.optString("app").ifEmpty { m.optString("package") }
                        "✔ " + m.optString("state") + ": " + t + (if (ar.isEmpty()) "" else " — $ar") + "\n($app)"
                    }
                }
            } catch (e: Exception) {
                mediaLine = "Música: " + e.javaClass.simpleName
            }
            ui.post {
                probing = false
                tvAudio.text = audioLine
                tvMedia.text = mediaLine
            }
        }.start()
    }

    private fun uptimeText(s: Long): String = when {
        s < 60 -> "$s s"
        s < 3600 -> (s / 60).toString() + " min"
        else -> (s / 3600).toString() + " h " + ((s % 3600) / 60) + " min"
    }

    @Suppress("DEPRECATION")
    private fun versionName(): String = try {
        packageManager.getPackageInfo(packageName, 0).versionName ?: "?"
    } catch (_: Exception) {
        "?"
    }

    /** Mientras el token está a la vista, Android no deja hacer capturas ni mostrarlo en «recientes». */
    private fun setTokenShown(v: Boolean) {
        tokenShown = v
        if (v) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        refresh()
    }

    private fun clientsText(n: Int): String = when (n) {
        0 -> "sin clientes"
        1 -> "1 cliente conectado"
        else -> "$n clientes conectados"
    }

    private fun mark(ok: Boolean, label: String) = (if (ok) "✔ " else "✘ ") + label

    private fun permsText(): String {
        val lines = ArrayList<String>()
        lines.add(mark(granted(Manifest.permission.ACCESS_FINE_LOCATION), "Ubicación (nombre del WiFi y redes cercanas)"))
        val lm = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        val locOn = lm != null && (if (Build.VERSION.SDK_INT >= 28) lm.isLocationEnabled else true)
        lines.add(mark(locOn, "Ubicación del sistema encendida"))
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        lines.add(mark(nm.areNotificationsEnabled(), "Avisos permitidos"))
        lines.add(mark(NexoNotificationListener.isEnabled(this), "Acceso a notificaciones (música)"))
        if (Build.VERSION.SDK_INT >= 31) {
            lines.add(mark(granted("android.permission.BLUETOOTH_CONNECT"), "Bluetooth (dispositivos cercanos)"))
        }
        return lines.joinToString("\n")
    }

    // ---------------------------------------------------------------- acciones

    private fun toggleService() {
        if (BridgeState.running) {
            BridgeService.stop(this)
        } else {
            BridgeState.lastError = null
            try {
                BridgeService.start(this)
            } catch (e: Exception) {
                toast("No se pudo iniciar: " + e.javaClass.simpleName)
            }
        }
        ui.postDelayed({ refresh() }, 400)
    }

    private fun restartService() {
        BridgeState.lastError = null
        BridgeService.stop(this)
        ui.postDelayed({
            try {
                BridgeService.start(this)
            } catch (e: Exception) {
                toast("No se pudo iniciar: " + e.javaClass.simpleName)
            }
            refresh()
        }, 700)
        toast("Reiniciando el puente…")
    }

    private fun openListenerSettings() {
        try {
            startActivity(UserAction.notificationListenerSettings())
        } catch (_: Exception) {
            toast("Abre Ajustes › Notificaciones › Acceso a notificaciones y activa Nexo")
        }
    }

    /** Un pitido corto por la salida de música: sirve para comprobar por dónde suena (altavoz, auriculares…). */
    private fun playTestTone() {
        try {
            val tg = ToneGenerator(AudioManager.STREAM_MUSIC, 80)
            tg.startTone(ToneGenerator.TONE_PROP_BEEP, 300)
            ui.postDelayed({ tg.release() }, 600)
        } catch (_: Exception) {
            toast("No se pudo reproducir el sonido de prueba")
        }
    }

    private fun copyLog() {
        val lines = BridgeState.recent(100)
        if (lines.isEmpty()) {
            toast("Aún no hay registro")
            return
        }
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        cm.setPrimaryClip(ClipData.newPlainText("Nexo registro", lines.joinToString("\n")))
        toast("Copiadas " + lines.size + " líneas (no llevan claves ni el token)")
    }

    private fun copyInstall() {
        try {
            val cmd = Bootstrap.oneLiner(this, Prefs.port(this), Prefs.token(this))
            copy(cmd)
            toast(
                (if (BridgeState.running) "Comando copiado. Pégalo en Termux y pulsa Enter."
                else "Comando copiado. Antes de pegarlo, enciende el puente.") +
                    " Lleva tu token: no lo compartas ni lo pegues en chats."
            )
        } catch (e: Exception) {
            toast("No se pudo preparar el comando: " + e.javaClass.simpleName)
        }
    }

    private fun copyToken() {
        copy(Prefs.token(this))
        toast("Token copiado. Quien lo tenga controla tu WiFi y Bluetooth: no lo compartas.")
    }

    private fun copy(text: String) {
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = ClipData.newPlainText("Nexo", text)
        // Android 13+: que no se muestre el contenido en la vista previa del portapapeles.
        val extras = PersistableBundle()
        extras.putBoolean("android.content.extra.IS_SENSITIVE", true)
        clip.description.extras = extras
        cm.setPrimaryClip(clip)
    }

    private fun confirmRegenerate() {
        AlertDialog.Builder(this)
            .setTitle("¿Generar un token nuevo?")
            .setMessage("Los Termux ya enlazados dejarán de funcionar hasta que vuelvas a pegar el comando de instalación.")
            .setPositiveButton("Generar") { _, _ ->
                Prefs.regenerateToken(this)
                refresh()
                toast("Token nuevo creado")
            }
            .setNegativeButton("Cancelar", null)
            .show()
    }

    private fun savePort() {
        val p = etPort.text.toString().trim().toIntOrNull()
        if (p == null || p < 1024 || p > 65535) {
            toast("Usa un puerto entre 1024 y 65535")
            return
        }
        if (p == Prefs.port(this)) return
        Prefs.setPort(this, p)
        if (BridgeState.running) {
            BridgeService.stop(this)
            ui.postDelayed({ BridgeService.start(this) }, 700)
        }
        toast("Puerto $p guardado. Vuelve a copiar el comando para actualizar Termux.")
        refresh()
    }

    private fun granted(p: String) = checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    private fun askPermissions() {
        val need = ArrayList<String>()
        if (!granted(Manifest.permission.ACCESS_FINE_LOCATION)) need.add(Manifest.permission.ACCESS_FINE_LOCATION)
        if (Build.VERSION.SDK_INT >= 31 && !granted("android.permission.BLUETOOTH_CONNECT")) {
            need.add("android.permission.BLUETOOTH_CONNECT")
        }
        if (Build.VERSION.SDK_INT >= 33 && !granted("android.permission.POST_NOTIFICATIONS")) {
            need.add("android.permission.POST_NOTIFICATIONS")
        }
        if (need.isEmpty()) {
            toast("Ya tienes todos los permisos que se pueden pedir aquí")
            return
        }
        requestPermissions(need.toTypedArray(), REQ_PERMS)
    }

    private fun openAppSettings() {
        try {
            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
        } catch (_: Exception) {
            toast("No se pudo abrir los ajustes")
        }
    }

    private fun openBattery() {
        val xiaomi = Build.MANUFACTURER.equals("xiaomi", true) || Build.MANUFACTURER.equals("redmi", true) ||
            Build.MANUFACTURER.equals("poco", true)
        val steps = if (xiaomi) {
            "1. En la pantalla que se abre, busca Nexo y elige «Sin restricciones».\n" +
                "2. Activa «Inicio automático» (botón de abajo).\n" +
                "3. En Recientes, mantén pulsada la tarjeta de Nexo y toca el candado.\n\n" +
                "HyperOS/MIUI congela las apps en segundo plano aunque el puente esté encendido; con esto lo hace mucho menos."
        } else {
            "1. En la pantalla que se abre, busca Nexo y elige «Sin restricciones» (o «No optimizar»).\n" +
                "2. Si tu móvil tiene «Inicio automático» o «Apps protegidas», actívalo para Nexo."
        }
        AlertDialog.Builder(this)
            .setTitle("Que Android no cierre el puente")
            .setMessage(steps)
            .setPositiveButton("Abrir ajustes") { _, _ ->
                try {
                    startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                } catch (_: Exception) {
                    openAppSettings()
                }
            }
            .setNegativeButton("Ahora no", null)
            .show()
    }

    private fun openAutostart() {
        val i = Intent()
        i.component = ComponentName(
            "com.miui.securitycenter",
            "com.miui.permcenter.autostart.AutoStartManagementActivity"
        )
        try {
            startActivity(i)
        } catch (_: Exception) {
            toast("Busca «Inicio automático» en los permisos de la app")
            openAppSettings()
        }
    }

    // ---------------------------------------------------------------- piezas de interfaz

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density + 0.5f).toInt()

    private fun toast(s: String) = Toast.makeText(this, s, Toast.LENGTH_LONG).show()

    private fun lp(top: Int = 0, bottom: Int = 0): LinearLayout.LayoutParams {
        val p = LinearLayout.LayoutParams(MATCH, WRAP)
        p.topMargin = dp(top)
        p.bottomMargin = dp(bottom)
        return p
    }

    private fun text(s: String, sp: Float, color: Int, bold: Boolean = false, mono: Boolean = false): TextView {
        val t = TextView(this)
        t.text = s
        t.textSize = sp
        t.setTextColor(color)
        if (mono) t.typeface = Typeface.MONOSPACE else if (bold) t.typeface = Typeface.DEFAULT_BOLD
        return t
    }

    private fun button(label: String, primary: Boolean = false, onClick: () -> Unit): Button {
        val b = Button(this)
        b.text = label
        b.isAllCaps = false
        b.textSize = 15f
        b.minHeight = dp(48)
        b.setTextColor(if (primary) Color.parseColor("#1A1305") else TEXT)
        val bg = GradientDrawable()
        bg.cornerRadius = dp(12).toFloat()
        if (primary) {
            bg.setColor(ACCENT)
        } else {
            bg.setColor(Color.TRANSPARENT)
            bg.setStroke(dp(1), LINE)
        }
        b.background = bg
        b.setOnClickListener { onClick() }
        return b
    }

    private fun row(vararg views: View): LinearLayout {
        val r = LinearLayout(this)
        r.orientation = LinearLayout.HORIZONTAL
        for (v in views) r.addView(v, LinearLayout.LayoutParams(0, WRAP, 1f))
        return r
    }

    private fun card(title: String?, vararg views: View): LinearLayout {
        val c = LinearLayout(this)
        c.orientation = LinearLayout.VERTICAL
        c.setPadding(dp(16), dp(14), dp(16), dp(16))
        val bg = GradientDrawable()
        bg.setColor(CARD)
        bg.cornerRadius = dp(16).toFloat()
        c.background = bg
        if (title != null) c.addView(text(title, 12f, ACCENT, bold = true))
        for (v in views) c.addView(v, lp(top = 8))
        return c
    }
}
