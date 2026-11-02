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
    private lateinit var etPort: EditText
    private var tokenShown = false

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
        col.addView(card(null, tvState, tvDetail, tvError, btnToggle), lp(bottom = 12))

        // Enlazar con Termux
        tvToken = text("", 13f, TEXT, mono = true)
        val rowToken = row(
            button("Mostrar token") { tokenShown = !tokenShown; refresh() },
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
        col.addView(card("ACTIVIDAD", tvLog), lp(bottom = 12))

        col.addView(
            text("Nexo v0.1.0 · Solo escucha en 127.0.0.1 · Sin anuncios ni telemetría", 11f, MUTED)
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
            "127.0.0.1:" + BridgeState.port + " · " + clientsText(BridgeState.clients)
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

    private fun copyInstall() {
        try {
            val cmd = Bootstrap.oneLiner(this, Prefs.port(this), Prefs.token(this))
            copy(cmd)
            toast(
                if (BridgeState.running) "Comando copiado. Pégalo en Termux y pulsa Enter."
                else "Comando copiado. Antes de pegarlo, enciende el puente."
            )
        } catch (e: Exception) {
            toast("No se pudo preparar el comando: " + e.javaClass.simpleName)
        }
    }

    private fun copyToken() {
        copy(Prefs.token(this))
        toast("Token copiado")
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
        try {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        } catch (_: Exception) {
            openAppSettings()
        }
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
