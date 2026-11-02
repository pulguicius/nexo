package org.nexo.bridge

import android.content.Context
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
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Servidor TCP que SOLO escucha en 127.0.0.1 (nunca es visible desde la red).
 * Protocolo: un objeto JSON por línea (ver docs/PROTOCOLO.md).
 *
 * Seguridad: cualquier app del móvil puede conectarse a un puerto local, así que hasta que
 * el cliente no envíe `hello` con el token correcto solo se acepta `bootstrap`, que devuelve
 * contenido público (el instalador del cliente) y nunca contiene el token.
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
    }

    private var server: ServerSocket? = null
    private val pool: ExecutorService = Executors.newCachedThreadPool()
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
    }

    /** Envía un evento a todos los clientes autenticados que lo pidieron con `subscribe`. */
    fun broadcast(topic: String, data: JSONObject) {
        val line = Protocol.event(topic, data).toString()
        for (c in clients) {
            if (c.authed && c.wants(topic)) c.sendLine(line)
        }
    }

    private fun refreshCount() {
        BridgeState.clients = clients.count { it.authed }
        onClientsChanged()
    }

    private fun acceptLoop(ss: ServerSocket) {
        while (!stopping) {
            val s = try {
                ss.accept()
            } catch (_: IOException) {
                break
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
        "bt.connect", "bt.disconnect" -> cmd + " " + req.optString("address", "").take(17)
        else -> cmd
    }

    private inner class Client(private val sock: Socket) : Runnable {
        @Volatile
        var authed = false

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
            if (clients.remove(this)) refreshCount()
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
                serveBootstrap()
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
send(Protocol.ok(id, commands.hello())) // <-- ENVIAR PRIMERO
refreshCount()                          // <-- UI DESPUÉS
BridgeState.log("Cliente conectado: " + req.optString("client", "?").take(40))
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
                wanted.add("wifi")
                wanted.add("bt")
            } else {
                for (i in 0 until arr.length()) {
                    val t = arr.optString(i)
                    if (t == "wifi" || t == "bt") wanted.add(t)
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
    // 1. Ejecutamos el comando y preparamos la respuesta
    val resp: JSONObject = try {
        Protocol.ok(id, commands.handle(cmd, req))
    } catch (e: CmdException) {
        Protocol.error(id, e.code, e.message ?: e.code, e.extra)
    } catch (e: SecurityException) {
        Protocol.error(id, "permission_denied", "Android negó un permiso: " + (e.message ?: ""))
    } catch (e: Exception) {
        Protocol.error(id, "internal", e.javaClass.simpleName + ": " + (e.message ?: ""))
    }
    
    // 2. ENVIAMOS AL INSTANTE (milisegundos)
    send(resp)
    
    // 3. Logueamos DESPUÉS para no bloquear al cliente
    if (resp.has("error")) {
        val errCode = resp.optJSONObject("error")?.optString("code") ?: "error"
        BridgeState.log("x " + cmd + ": " + errCode)
    } else {
        BridgeState.log("> " + describe(cmd, req))
    }
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
