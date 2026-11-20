package org.nexo.bridge

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * USB serie (protocolo 1.3): Arduino, ESP32 y adaptadores USB↔serie conectados al móvil por OTG o por un hub.
 *
 * Android NO deja montar ni exponer `/dev/bus/usb` a Linux, así que esta capa abre el dispositivo con la API oficial
 * (UsbManager + UsbDeviceConnection, tras pedir permiso al usuario) y le pasa a Linux solo los bytes de la línea serie:
 *   · una conexión de control (comandos JSON: usb.status, usb.permission, usb.open, usb.setup, usb.control, usb.close) y
 *   · otra de datos (usb.attach), que a partir de ahí deja de ser JSON y lleva los bytes crudos en los dos sentidos.
 * La sesión muere con la conexión de control que la abrió, o al desenchufar el dispositivo.
 *
 * Los chips (CDC-ACM, CP210x, FTDI, CH34x) están en UsbSerial.kt; no se han probado con hardware real (docs/USB.md).
 * Esta clase no toca el almacenamiento USB (pendrives, discos): eso es de StorageHandler (0.4.2) y usa otros mecanismos.
 */
class UsbHandler(context: Context) {
    private val ctx: Context = context.applicationContext
    private val usb: UsbManager? = ctx.getSystemService(Context.USB_SERVICE) as? UsbManager
    private val sessions = ConcurrentHashMap<String, UsbSession>()
    private val pending = HashMap<Int, PermWait>()
    private val seq = AtomicInteger(1)
    private val openLock = Any()
    private var registered = false

    /** El servicio pone aquí lo que avisa a los clientes suscritos al tema «usb». */
    @Volatile
    var onChange: (() -> Unit)? = null

    companion object {
        const val ACTION_PERMISSION = "org.nexo.bridge.USB_PERMISSION"
        private const val CTRL_TIMEOUT_MS = 5000
        private const val PERMISSION_RETRY_MS = 60_000L
    }

    /** ¿Tiene este móvil modo anfitrión USB (OTG)? */
    fun hasHost(): Boolean = ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_USB_HOST)

    // ----------------------------------------------------------------------------------- avisos de Android

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, i: Intent?) {
            val action = i?.action ?: return
            @Suppress("DEPRECATION")
            val dev: UsbDevice? = i.getParcelableExtra(UsbManager.EXTRA_DEVICE)
            when (action) {
                UsbManager.ACTION_USB_DEVICE_ATTACHED -> BridgeState.log("USB conectado: " + label(dev))
                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    BridgeState.log("USB desconectado: " + label(dev))
                    if (dev != null) deviceGone(dev.deviceId)
                }
                ACTION_PERMISSION -> {
                    val granted = i.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    if (dev != null) {
                        val w = synchronized(pending) { pending.remove(dev.deviceId) }
                        w?.finish(granted)
                        BridgeState.log("USB: permiso " + (if (granted) "concedido" else "denegado") + " para " + label(dev))
                    }
                }
            }
            onChange?.invoke()
        }
    }

    /** Empieza a escuchar los avisos de Android (se llama al encender el puente). */
    fun watch() {
        if (registered) return
        val f = IntentFilter()
        f.addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
        f.addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        f.addAction(ACTION_PERMISSION)
        ctx.registerReceiver(receiver, f)
        registered = true
    }

    /** Deja de escuchar y cierra todas las sesiones (se llama al apagar el puente). */
    fun unwatch() {
        if (registered) {
            try {
                ctx.unregisterReceiver(receiver)
            } catch (_: Exception) {
            }
            registered = false
        }
        for (s in sessions.values.toList()) endSession(s)
        synchronized(pending) {
            for (w in pending.values) w.finish(false)
            pending.clear()
        }
    }

    /** Cierra las sesiones que abrió una conexión que ya no existe. */
    fun ownerGone(owner: Any?) {
        if (owner == null) return
        var any = false
        for (s in sessions.values.toList()) {
            if (s.owner === owner) {
                endSession(s)
                any = true
            }
        }
        if (any) onChange?.invoke()
    }

    private fun deviceGone(devId: Int) {
        for (s in sessions.values.toList()) if (s.devId == devId) endSession(s)
        synchronized(pending) { pending.remove(devId) }?.finish(false)
    }

    private fun endSession(s: UsbSession) {
        sessions.remove(s.id)
        s.close()
    }

    // ----------------------------------------------------------------------------------- lectura del estado

    private fun manager(): UsbManager = usb ?: throw CmdException("unsupported", "Este móvil no tiene servicio USB")

    private fun devices(): List<UsbDevice> = (usb?.deviceList?.values ?: emptyList<UsbDevice>()).sortedBy { it.deviceId }

    private fun label(d: UsbDevice?): String {
        if (d == null) return "?"
        return String.format("%04x:%04x", d.vendorId, d.productId)
    }

    private fun infoOf(dev: UsbDevice, bcd: Int = -1): UsbInfo {
        val ifs = ArrayList<UsbIf>()
        for (i in 0 until dev.interfaceCount) {
            val f = dev.getInterface(i)
            val eps = ArrayList<UsbEp>()
            for (e in 0 until f.endpointCount) {
                val ep = f.getEndpoint(e)
                eps.add(UsbEp(ep.address, ep.type, ep.maxPacketSize))
            }
            ifs.add(UsbIf(f.id, f.interfaceClass, f.interfaceSubclass, f.interfaceProtocol, eps))
        }
        return UsbInfo(dev.vendorId, dev.productId, dev.deviceClass, ifs, bcd)
    }

    /** Las cadenas del dispositivo pueden exigir permiso según la versión de Android: sin él, se devuelven como null. */
    private fun safe(f: () -> String?): String? = try {
        f()?.takeIf { it.isNotEmpty() }
    } catch (_: SecurityException) {
        null
    }

    private fun busAddress(dev: UsbDevice): Pair<Int, Int> {
        val m = Regex("""/(\d+)/(\d+)$""").find(dev.deviceName ?: "")
        return if (m != null) Pair(m.groupValues[1].toInt(), m.groupValues[2].toInt()) else Pair(dev.deviceId / 1000, dev.deviceId % 1000)
    }

    private fun view(dev: UsbDevice): JSONObject {
        val info = infoOf(dev)
        val chip = UsbIds.chip(info)
        val ba = busAddress(dev)
        val ifs = JSONArray()
        for (f in info.ifaces) {
            ifs.put(
                JSONObject().put("id", f.id).put("class", f.cls).put("subclass", f.sub)
                    .put("protocol", f.proto).put("endpoints", f.eps.size)
            )
        }
        return JSONObject()
            .put("id", dev.deviceId)
            .put("path", dev.deviceName)
            .put("bus", ba.first)
            .put("address", ba.second)
            .put("vid", String.format("%04x", dev.vendorId))
            .put("pid", String.format("%04x", dev.productId))
            .putOrNull("vendor", safe { dev.manufacturerName })
            .putOrNull("product", safe { dev.productName })
            .putOrNull("serial", safe { dev.serialNumber })
            .put("class", dev.deviceClass)
            .put("kind", UsbIds.kind(info))
            .putOrNull("driver", chip?.tag)
            .put("serial_capable", chip != null)
            .put("permission", usb?.hasPermission(dev) ?: false)
            .putOrNull("note", UsbIds.note(info))
            .put("interfaces", ifs)
    }

    private fun sessionView(s: UsbSession): JSONObject {
        return JSONObject()
            .put("session", s.id)
            .put("device", s.devId)
            .put("driver", s.chip.tag)
            .put("baud", s.line.baud)
            .put("bits", s.line.bits)
            .put("parity", s.line.parity)
            .put("stop", s.line.stopJson)
            .put("dtr", s.dtr)
            .put("rts", s.rts)
            .put("attached", s.attached.get())
            .put("rx", s.rx.get())
            .put("tx", s.tx.get())
    }

    private fun stepsJson(steps: List<Step>): JSONArray {
        val a = JSONArray()
        for (st in steps) a.put(JSONObject().put("op", st.op).put("rc", st.rc))
        return a
    }

    fun status(): JSONObject {
        val devs = JSONArray()
        for (d in devices()) {
            try {
                devs.put(view(d))
            } catch (_: Exception) {
                // un dispositivo que desaparece justo ahora: se omite
            }
        }
        val sess = JSONArray()
        for (s in sessions.values.sortedBy { it.seq }) sess.put(sessionView(s))
        return JSONObject().put("host", hasHost()).put("devices", devs).put("sessions", sess)
    }

    // ----------------------------------------------------------------------------------- permiso de Android

    private class PermWait {
        val latch = CountDownLatch(1)
        val at: Long = SystemClock.elapsedRealtime()

        @Volatile
        var granted: Boolean? = null

        fun finish(g: Boolean) {
            granted = g
            latch.countDown()
        }
    }

    private fun find(req: JSONObject): UsbDevice {
        val want = req.optInt("device", -1)
        if (!req.has("device") || want < 0) throw CmdException("bad_request", "Falta «device» (el id que da usb.status)")
        return devices().firstOrNull { it.deviceId == want }
            ?: throw CmdException("not_found", "No hay ningún dispositivo USB con id $want (¿lo desenchufaste?)")
    }

    private fun session(req: JSONObject): UsbSession =
        sessions[req.optString("session", "")] ?: throw CmdException("not_found", "Esa sesión USB no existe (¿se cerró o desenchufaste el dispositivo?)")

    private fun permissionIntent(): PendingIntent {
        val i = Intent(ACTION_PERMISSION).setPackage(ctx.packageName)
        // Android rellena el aviso con el dispositivo y la respuesta: tiene que ser mutable (desde Android 12 hay que decirlo).
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
        return PendingIntent.getBroadcast(ctx, 0, i, flags)
    }

    /**
     * Pide a Android el permiso para hablar con el dispositivo (sale un diálogo en la pantalla del móvil).
     * `wait_ms` (0-30000) es lo que se espera la respuesta del usuario; sin ella, se contesta enseguida y el cliente consulta después.
     */
    fun permission(req: JSONObject): JSONObject {
        val mgr = manager()
        val dev = find(req)
        val id = dev.deviceId
        val wait = req.optLong("wait_ms", 0L).coerceIn(0L, 30_000L)
        if (mgr.hasPermission(dev)) return permJson(id, granted = true, requested = false, denied = false)
        var send = false
        val w: PermWait = synchronized(pending) {
            val cur = pending[id]
            if (cur == null || SystemClock.elapsedRealtime() - cur.at > PERMISSION_RETRY_MS) {
                val n = PermWait()
                pending[id] = n
                send = true
                n
            } else {
                cur
            }
        }
        if (send) mgr.requestPermission(dev, permissionIntent())
        if (wait > 0L) {
            try {
                w.latch.await(wait, TimeUnit.MILLISECONDS)
            } catch (_: InterruptedException) {
            }
        }
        val granted = mgr.hasPermission(dev)
        return permJson(id, granted = granted, requested = true, denied = !granted && w.granted == false)
    }

    private fun permJson(id: Int, granted: Boolean, requested: Boolean, denied: Boolean): JSONObject {
        return JSONObject().put("device", id).put("granted", granted).put("requested", requested).put("denied", denied)
    }

    // ----------------------------------------------------------------------------------- sesiones

    private fun lineFrom(req: JSONObject, base: Line): Line = try {
        Line.of(
            req.optInt("baud", base.baud), req.optInt("bits", base.bits),
            req.optString("parity", base.parity), req.optDouble("stop", base.stop),
        )
    } catch (e: IllegalArgumentException) {
        throw CmdException("bad_request", e.message ?: "parámetros de línea no válidos")
    }

    /** Si alguna orden obligatoria del chip falló, se avisa de cuál (las demás solo quedan anotadas en `steps`). */
    private fun requireOk(steps: List<Step>) {
        val bad = steps.firstOrNull { it.fatal && it.failed }
        if (bad != null) {
            throw CmdException(
                "failed",
                "El adaptador no aceptó la orden «" + bad.op + "» (Android devolvió " + bad.rc + "); ¿se desenchufó o hay otra app usándolo?",
                JSONObject().put("steps", stepsJson(steps)),
            )
        }
    }

    private fun <T> driverCall(f: () -> T): T = try {
        f()
    } catch (e: UnsupportedOperationException) {
        throw CmdException("unsupported", e.message ?: "El adaptador no admite esa configuración")
    }

    private fun bcdOf(conn: UsbDeviceConnection): Int {
        val raw = try {
            conn.rawDescriptors
        } catch (_: Exception) {
            null
        }
        return if (raw != null && raw.size >= 14) ((raw[13].toInt() and 0xFF) shl 8) or (raw[12].toInt() and 0xFF) else -1
    }

    /** Abre el dispositivo, reclama sus interfaces y deja el chip configurado. `owner` es la conexión que la pide. */
    fun open(req: JSONObject, owner: Any?): JSONObject {
        val mgr = manager()
        val dev = find(req)
        if (!mgr.hasPermission(dev)) {
            throw CmdException(
                "permission_denied", "Falta el permiso de Android para este dispositivo USB (usb.permission)",
                JSONObject().put("needs_permission", true),
            )
        }
        val line = lineFrom(req, Line.DEFAULT)
        val dtr = req.optBoolean("dtr", true)
        val rts = req.optBoolean("rts", true)
        try {
            UsbPlanner.plan(infoOf(dev))
        } catch (e: IllegalArgumentException) {
            throw CmdException("unsupported", e.message ?: "No sé hablar con este dispositivo USB")
        }
        synchronized(openLock) {
            if (sessions.values.any { it.devId == dev.deviceId }) throw CmdException("busy", "Ese dispositivo USB ya está abierto por otra sesión")
            val conn = mgr.openDevice(dev) ?: throw CmdException("failed", "Android no pudo abrir el dispositivo USB (¿lo usa otra app?)")
            val claimed = ArrayList<UsbInterface>()
            try {
                val bcd = bcdOf(conn)
                val plan = UsbPlanner.plan(infoOf(dev, bcd))
                for (id in plan.claim) {
                    val f = (0 until dev.interfaceCount).map { dev.getInterface(it) }.first { it.id == id }
                    // force = true: si el núcleo de Android ya tenía un controlador pegado a la interfaz, se lo quita
                    if (!conn.claimInterface(f, true)) throw CmdException("busy", "No pude reclamar la interfaz $id del dispositivo (¿la usa otra app o el sistema?)")
                    claimed.add(f)
                }
                val link = AndroidLink(conn, endpoint(claimed, plan.epIn), endpoint(claimed, plan.epOut))
                val drv = SerialDrivers.create(plan, link, bcd)
                val steps = driverCall { drv.init(line, dtr, rts) }
                requireOk(steps)
                val s = UsbSession(
                    "s" + seq.getAndIncrement(), dev.deviceId, dev.deviceName ?: "", plan, conn, claimed, drv, SerialPort(link, drv), owner, line, dtr, rts,
                )
                sessions[s.id] = s
                BridgeState.log("USB abierto: " + label(dev) + " (" + plan.chip.tag + ", " + line.baud + " baudios)")
                onChange?.invoke()
                return sessionView(s)
                    .put("ep_in", plan.epIn.address)
                    .put("ep_out", plan.epOut.address)
                    .put("packet", plan.epIn.maxPacket)
                    .put("steps", stepsJson(steps))
            } catch (t: Throwable) {
                for (f in claimed) {
                    try {
                        conn.releaseInterface(f)
                    } catch (_: Exception) {
                    }
                }
                conn.close()
                throw t
            }
        }
    }

    private fun endpoint(claimed: List<UsbInterface>, ep: UsbEp): UsbEndpoint {
        for (f in claimed) {
            for (i in 0 until f.endpointCount) {
                val e = f.getEndpoint(i)
                if (e.address == ep.address) return e
            }
        }
        throw CmdException("failed", "No encuentro el extremo USB 0x" + Integer.toHexString(ep.address))
    }

    fun setup(req: JSONObject): JSONObject {
        val s = session(req)
        val line = lineFrom(req, s.line)
        val steps = synchronized(s.ctlLock) { driverCall { s.drv.setLine(line) } }
        requireOk(steps)
        s.line = line
        return sessionView(s).put("steps", stepsJson(steps))
    }

    fun control(req: JSONObject): JSONObject {
        val s = session(req)
        val steps = ArrayList<Step>()
        synchronized(s.ctlLock) {
            if (req.has("dtr") || req.has("rts")) {
                val dtr = if (req.has("dtr")) req.optBoolean("dtr") else s.dtr
                val rts = if (req.has("rts")) req.optBoolean("rts") else s.rts
                val st = driverCall { s.drv.setLines(dtr, rts) }
                steps.addAll(st)
                if (st.none { it.fatal && it.failed }) {
                    s.dtr = dtr
                    s.rts = rts
                }
            }
            if (req.has("brk")) steps.addAll(driverCall { s.drv.setBreak(req.optBoolean("brk")) })
        }
        requireOk(steps)
        return sessionView(s).put("steps", stepsJson(steps))
    }

    fun close(req: JSONObject): JSONObject {
        val s = session(req)
        endSession(s)
        BridgeState.log("USB cerrado (sesión " + s.id + ")")
        onChange?.invoke()
        return JSONObject().put("closed", true)
    }

    // ----------------------------------------------------------------------------------- flujo de datos (usb.attach)

    /** Reserva el flujo de datos de una sesión (solo una conexión a la vez). La conexión pasa después a ser de bytes crudos. */
    fun attach(req: JSONObject): UsbSession {
        val s = session(req)
        if (!s.alive) throw CmdException("not_found", "Esa sesión USB ya no existe")
        if (!s.attached.compareAndSet(false, true)) throw CmdException("busy", "Esa sesión USB ya tiene un flujo conectado")
        onChange?.invoke()
        return s
    }

    /** El flujo de datos terminó (el cliente se fue o el dispositivo ya no está). */
    fun detach(s: UsbSession) {
        s.attached.set(false)
        if (!s.alive) sessions.remove(s.id)
        onChange?.invoke()
    }

    /** ¿Sigue el dispositivo de esta sesión enchufado? */
    fun isPlugged(s: UsbSession): Boolean = usb?.deviceList?.containsKey(s.devName) ?: false

    private class AndroidLink(
        private val conn: UsbDeviceConnection,
        private val epIn: UsbEndpoint,
        private val epOut: UsbEndpoint,
    ) : UsbLink {
        override fun control(type: Int, req: Int, value: Int, index: Int, data: ByteArray?, len: Int): Int =
            conn.controlTransfer(type, req, value, index, data, len, CTRL_TIMEOUT_MS)

        override fun bulkIn(buf: ByteArray, len: Int, timeoutMs: Int): Int = conn.bulkTransfer(epIn, buf, len, timeoutMs)

        override fun bulkOut(buf: ByteArray, off: Int, len: Int, timeoutMs: Int): Int = conn.bulkTransfer(epOut, buf, off, len, timeoutMs)
    }
}

/** Una sesión abierta con un adaptador serie. */
class UsbSession(
    val id: String,
    val devId: Int,
    val devName: String,
    val plan: UsbPlan,
    private val conn: UsbDeviceConnection,
    private val claimed: List<UsbInterface>,
    val drv: SerialDriver,
    val port: SerialPort,
    /** La conexión de control que la abrió (al cerrarse, la sesión se cierra). */
    val owner: Any?,
    @Volatile var line: Line,
    @Volatile var dtr: Boolean,
    @Volatile var rts: Boolean,
) {
    val chip: Chip get() = plan.chip
    val seq: Int = id.drop(1).toIntOrNull() ?: 0

    @Volatile
    var alive = true
        private set
    val attached = AtomicBoolean(false)
    val rx = AtomicLong(0)
    val tx = AtomicLong(0)
    val ctlLock = Any()

    @Volatile
    private var socketCloser: (() -> Unit)? = null

    fun close() {
        synchronized(this) {
            if (!alive) return
            alive = false
        }
        try {
            socketCloser?.invoke()
        } catch (_: Exception) {
        }
        for (f in claimed) {
            try {
                conn.releaseInterface(f)
            } catch (_: Exception) {
            }
        }
        try {
            conn.close()
        } catch (_: Exception) {
        }
    }

    /**
     * Mueve bytes entre el socket del cliente y el dispositivo hasta que uno de los dos se cierre. Bloquea el hilo que la llama.
     * `closeSocket` cierra la conexión del cliente; `plugged` dice si el dispositivo sigue enchufado.
     */
    fun pump(input: InputStream, out: OutputStream, writeLock: Any, closeSocket: () -> Unit, plugged: () -> Boolean) {
        socketCloser = closeSocket
        val done = AtomicBoolean(false)
        val reader = Thread({
            val buf = ByteArray(RX_BUF)
            var misses = 0
            try {
                while (alive && !done.get()) {
                    val n = port.read(buf, RX_POLL_MS)
                    if (n > 0) {
                        misses = 0
                        rx.addAndGet(n.toLong())
                        synchronized(writeLock) {
                            out.write(buf, 0, n)
                            out.flush()
                        }
                    } else if (n < 0) {
                        // Android no distingue «no llegó nada» de «falló»: cada ~2 s se comprueba si el dispositivo sigue ahí
                        misses++
                        if (misses % 20 == 0 && !plugged()) {
                            close()
                            break
                        }
                    }
                }
            } catch (_: IOException) {
                // el cliente se fue
            } finally {
                done.set(true)
                closeSocket()
            }
        }, "nexo-usb-rx")
        reader.isDaemon = true
        reader.start()
        val buf = ByteArray(RX_BUF)
        try {
            while (alive && !done.get()) {
                val n = input.read(buf)
                if (n < 0) break
                if (n > 0) {
                    if (!port.write(buf, 0, n)) break
                    tx.addAndGet(n.toLong())
                }
            }
        } catch (_: IOException) {
            // el cliente se fue
        } finally {
            done.set(true)
            closeSocket()
        }
    }

    private companion object {
        const val RX_BUF = 16384
        const val RX_POLL_MS = 100
    }
}
