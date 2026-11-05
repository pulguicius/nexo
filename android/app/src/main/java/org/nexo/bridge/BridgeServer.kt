package org.nexo.bridge

import android.content.Context
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.security.MessageDigest
import java.util.concurrent.Callable
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.ExecutionException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/** Nombre con el que el propio puente se hace ping a sí mismo: no cuenta como cliente ni se anota. */
const val WATCHDOG_CLIENT = "nexo-watchdog"

/**
 * Servidor TCP que SOLO escucha en 127.0.0.1 (nunca es visible desde la red).
 * Protocolo: un objeto JSON por línea (ver docs/PROTOCOLO.md).
 *
 * Seguridad: cualquier app del móvil puede conectarse a un puerto local, así que hasta que
 * el cliente no envíe `hello` con el token correcto solo se acepta `bootstrap`, que devuelve
 * contenido público (el instalador del cliente) y nunca contiene el token. `bootstrap` tiene
 * límite de ritmo (1 cada 2 s y 10 por minuto en total) para que nadie lo use para agotar la app.
 *
 * Robustez: cada comando corre en su propio hilo con un plazo; si se pasa, el cliente recibe
 * `timeout` y la conexión sigue viva (un comando colgado no deja a nadie sin respuesta).
 */
class BridgeServer(
    private val ctx: Context,
    private val port: Int,
    private val token: () -> String,
    private val commands: Commands,
    private val onClientsChanged: () -> Unit,
) {
    private companion object {
        const val AUTH_TIMEOUT_MS = 8000
        const val AUTH_FAIL_DELAY_MS = 800L
        const val MAX_CLIENTS = 16
        const val BOOTSTRAP_MIN_GAP_MS = 2000L
        const val BOOTSTRAP_MAX_PER_MIN = 10
    }

    private var server: ServerSocket? = null
    private val pool: ExecutorService = Executors.newCachedThreadPool()

    /** Aquí corren los comandos (aparte de los hilos de las conexiones) para poder ponerles plazo. */
    private val cmdPool: ExecutorService = Executors.newCachedThreadPool()
    private val clients = CopyOnWriteArrayList<Client>()

    @Volatile
    private var stopping = false

    @Throws(IOException::class)
    fun start() {
        val ss = ServerSocket()
        ss.reuseAddress = true
        ss.bind(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), port), 16)
        server = ss
        pool.execute { acceptLoop(ss) }
    }

    fun stop() {
        stopping = true
        try {
            server?.close()
        } catch (_: IOException) {
        }
        for (c in clients) c.close()
        pool.shutdownNow()
        cmdPool.shutdownNow()
    }

    /** Envía un evento a todos los clientes autenticados que lo pidieron con `subscribe`. */
    fun broadcast(topic: String, data: JSONObject) {
        val line = Protocol.event(topic, data).toString()
        for (c in clients) {
            if (c.authed && c.wants(topic)) c.sendLine(line)
        }
    }

    private fun refreshCount() {
        BridgeState.clients = clients.count { it.authed && !it.silent }
        onClientsChanged()
    }

    private fun acceptLoop(ss: ServerSocket) {
        while (!stopping) {
            val s = try {
                ss.accept()
            } catch (_: IOException) {
                if (stopping || ss.isClosed) break
                // Un fallo suelto de accept() (p. ej. demasiados archivos abiertos) no debe matar el puente.
                BridgeState.log("accept() falló; sigo escuchando")
                try {
                    Thread.sleep(200)
                } catch (_: InterruptedException) {
                    break
                }
                continue
            }
            if (clients.size >= MAX_CLIENTS) {
                try {
                    s.close()
                } catch (_: IOException) {
                }
                continue
            }
            val c = Client(s)
            clients.add(c)
            try {
                pool.execute(c)
            } catch (_: Exception) {
                clients.remove(c)
                c.close()
            }
        }
    }

    /**
     * Lee hasta '\n' (máx. 64 KiB). Devuelve null si el cliente cerró sin enviar nada.
     * Si `deadline` (ms) no es 0, se corta al pasarse: así nadie ocupa un cupo mandando un byte por segundo.
     */
    private fun readLine(input: InputStream, deadline: Long): String? {
        val buf = ByteArrayOutputStream(256)
        while (true) {
            if (deadline > 0 && System.currentTimeMillis() > deadline) throw SocketTimeoutException()
            val b = input.read()
            if (b < 0) return if (buf.size() == 0) null else buf.toString("UTF-8").trimEnd('\r')
            if (b == '\n'.code) return buf.toString("UTF-8").trimEnd('\r')
            if (buf.size() >= Protocol.MAX_LINE_BYTES) throw IOException("línea demasiado larga")
            buf.write(b)
        }
    }

    private fun tokensEqual(a: String, b: String): Boolean =
        MessageDigest.isEqual(a.toByteArray(Charsets.UTF_8), b.toByteArray(Charsets.UTF_8))

    /** Qué se anota en el registro de la pantalla. Nunca claves ni token. */
    private fun describe(cmd: String, req: JSONObject): String = when (cmd) {
        "wifi.connect" -> "wifi.connect " + req.optString("ssid", "").take(32)
        "bt.connect", "bt.disconnect", "bt.forget", "bt.rename", "bt.info" -> cmd + " " + req.optString("address", "").take(17)
        "wifi.forget" -> "wifi.forget " + req.optString("ssid", req.opt("network_id")?.toString() ?: "").take(32)
        "audio.volume" -> "audio.volume " + listOf("percent", "level", "delta", "mute").firstOrNull { req.has(it) }.orEmpty()
        else -> cmd
    }

    private val bootstrapLock = Any()
    private val bootstrapAt = ArrayDeque<Long>()

    /** Límite de ritmo de `bootstrap` (global, no por conexión: abrir muchas conexiones no lo esquiva). */
    private fun bootstrapAllowed(): Boolean = synchronized(bootstrapLock) {
        val now = SystemClock.elapsedRealtime()
        while (bootstrapAt.isNotEmpty() && now - bootstrapAt.first() > 60_000L) bootstrapAt.removeFirst()
        if (bootstrapAt.isNotEmpty() && now - bootstrapAt.last() < BOOTSTRAP_MIN_GAP_MS) return false
        if (bootstrapAt.size >= BOOTSTRAP_MAX_PER_MIN) return false
        bootstrapAt.addLast(now)
        true
    }

    /** Plazo (ms) de cada comando: lo que él mismo espera como máximo más un margen. */
    private fun timeoutFor(cmd: String, req: JSONObject): Long = when (cmd) {
        "wifi.connect" -> req.optLong("wait_ms", 12000).coerceIn(0L, 30000L) + 8000L
        "wifi.reconnect" -> req.optLong("wait_ms", 8000).coerceIn(0L, 30000L) + 6000L
        "wifi.scan" -> req.optLong("timeout_ms", 4000).coerceIn(500L, 15000L) + 6000L
        "wifi.enable", "wifi.disable" -> 10000L
        "bt.enable", "bt.disable" -> 12000L
        "bt.paired", "bt.info", "bt.forget" -> 10000L
        else -> 8000L
    }

    private inner class Client(private val sock: Socket) : Runnable {
        @Volatile
        var authed = false

        /** true para el ping interno del puente: ni se cuenta ni se anota. */
        @Volatile
        var silent = false

        @Volatile
        private var topics: Set<String> = emptySet()

        @Volatile
        private var closed = false

        private val writeLock = Any()

        fun wants(topic: String): Boolean = topics.contains(topic)

        fun send(o: JSONObject) = sendLine(o.toString())

        fun sendLine(line: String) {
            try {
                synchronized(writeLock) {
                    val out = sock.getOutputStream()
                    out.write((line + "\n").toByteArray(Charsets.UTF_8))
                    out.flush()
                }
            } catch (_: IOException) {
                close()
            }
        }

        fun close() {
            if (closed) return
            closed = true
            try {
                sock.close()
            } catch (_: IOException) {
            }
            if (clients.remove(this) && !silent) refreshCount()
        }

        override fun run() {
            try {
                sock.tcpNoDelay = true
                sock.soTimeout = AUTH_TIMEOUT_MS
                val input = sock.getInputStream().buffered()
                val connectedAt = System.currentTimeMillis()
                while (!stopping && !closed) {
                    val deadline = if (authed) 0L else connectedAt + AUTH_TIMEOUT_MS
                    val raw = readLine(input, deadline) ?: break
                    if (raw.isBlank()) continue
                    if (!handleLine(raw)) break
                }
            } catch (_: SocketTimeoutException) {
                BridgeState.log("Se cerró una conexión que no se autenticó a tiempo")
            } catch (_: IOException) {
                // el cliente se fue
            } catch (_: InterruptedException) {
                // el puente se está deteniendo
            } catch (e: Exception) {
                BridgeState.log("Error interno: " + e.javaClass.simpleName)
            } finally {
                close()
            }
        }

        /** Devuelve false si hay que cerrar la conexión. */
        private fun handleLine(raw: String): Boolean {
            val req: JSONObject = try {
                JSONObject(raw)
            } catch (_: JSONException) {
                send(Protocol.error(null, "bad_request", "Eso no es JSON válido"))
                return authed
            }
            val id: Any? = req.opt("id")
            val cmd = req.optString("cmd", "")

            if (cmd == "bootstrap") {
                if (bootstrapAllowed()) {
                    serveBootstrap()
                } else {
                    send(Protocol.error(null, "rate_limited", "Demasiadas peticiones de instalación seguidas; espera unos segundos"))
                    BridgeState.log("Se frenó una petición de instalador (demasiado seguidas)")
                }
                return false
            }

            if (!authed) {
                if (cmd != "hello") {
                    send(Protocol.error(id, "unauthorized", "Primero envía hello con el token"))
                    return false
                }
                if (!tokensEqual(req.optString("token", ""), token())) {
                    Thread.sleep(AUTH_FAIL_DELAY_MS)
                    send(Protocol.error(id, "unauthorized", "Token incorrecto"))
                    BridgeState.log("Intento de conexión con token incorrecto")
                    return false
                }
                authed = true
                sock.soTimeout = 0
                val who = req.optString("client", "?").take(40)
                silent = who == WATCHDOG_CLIENT
                // Primero la respuesta (que es lo que espera el cliente); el recuento y el registro, después.
                send(Protocol.ok(id, commands.hello()))
                if (!silent) {
                    refreshCount()
                    BridgeState.log("Cliente conectado: $who")
                }
                return true
            }

            when (cmd) {
                "" -> send(Protocol.error(id, "bad_request", "Falta el campo cmd"))
                "hello" -> send(Protocol.ok(id, commands.hello()))
                "ping" -> send(Protocol.ok(id, JSONObject().put("pong", true).put("t", System.currentTimeMillis())))
                "subscribe" -> subscribe(id, req)
                "unsubscribe" -> {
                    topics = emptySet()
                    send(Protocol.ok(id))
                }
                else -> runCommand(id, cmd, req)
            }
            return true
        }

        private fun subscribe(id: Any?, req: JSONObject) {
            val wanted = HashSet<String>()
            val arr = req.optJSONArray("topics")
            if (arr == null) {
                wanted.addAll(Commands.TOPICS)
            } else {
                for (i in 0 until arr.length()) {
                    val t = arr.optString(i)
                    if (t in Commands.TOPICS) wanted.add(t)
                }
            }
            topics = wanted
            val list = JSONArray()
            for (t in wanted.sorted()) list.put(t)
            send(Protocol.ok(id, JSONObject().put("topics", list)))
            // Estado inicial de cada tema, para que quien mira no espere al primer cambio.
            pool.execute {
                for (t in wanted) {
                    try {
                        send(Protocol.event(t, commands.statusFor(t)))
                    } catch (_: Exception) {
                    }
                }
            }
        }

        private fun runCommand(id: Any?, cmd: String, req: JSONObject) {
            val t0 = SystemClock.elapsedRealtime()
            val job = try {
                cmdPool.submit(Callable { commands.handle(cmd, req) })
            } catch (_: RejectedExecutionException) {
                send(Protocol.error(id, "internal", "El puente se está deteniendo"))
                return
            }
            val resp: JSONObject = try {
                Protocol.ok(id, job.get(timeoutFor(cmd, req), TimeUnit.MILLISECONDS))
            } catch (_: TimeoutException) {
                job.cancel(true) // interrumpe la espera del comando; la conexión sigue viva
                Protocol.error(id, "timeout", "El comando $cmd tardó demasiado y se canceló")
            } catch (e: ExecutionException) {
                errorFor(id, e.cause ?: e)
            }

            // Se contesta AL INSTANTE; anotar en el registro (que toca la pantalla) va después.
            send(resp)
            val ms = SystemClock.elapsedRealtime() - t0
            if (resp.optBoolean("ok", false)) {
                BridgeState.log("> " + describe(cmd, req) + if (ms >= 300) " ($ms ms)" else "")
            } else {
                BridgeState.log("x " + cmd + ": " + resp.optString("error", "error") + if (ms >= 300) " ($ms ms)" else "")
            }
        }

        private fun errorFor(id: Any?, t: Throwable): JSONObject = when (t) {
            is CmdException -> Protocol.error(id, t.code, t.message ?: t.code, t.extra)
            is SecurityException -> Protocol.error(id, "permission_denied", "Android negó un permiso: " + (t.message ?: ""))
            else -> Protocol.error(id, "internal", t.javaClass.simpleName + ": " + (t.message ?: ""))
        }

        private fun serveBootstrap() {
            try {
                val bytes = Bootstrap.bundle(ctx)
                synchronized(writeLock) {
                    val out = sock.getOutputStream()
                    out.write(bytes)
                    out.flush()
                }
                try {
                    sock.shutdownOutput()
                } catch (_: IOException) {
                }
                BridgeState.log("Se entregó el instalador del cliente de Termux")
            } catch (e: Exception) {
                BridgeState.log("Falló la entrega del instalador: " + e.javaClass.simpleName)
            }
        }
    }
}
