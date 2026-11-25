package org.nexo.bridge

import android.content.Context
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject

/** Reparte cada comando del protocolo (docs/PROTOCOLO.md) al manejador de WiFi, Bluetooth, audio, medios, USB, almacenamiento, red o notificaciones. */
class Commands(context: Context) {
    private val ctx: Context = context.applicationContext
    private val wifi = WifiHandler(ctx)
    private val bt = BluetoothHandler(ctx)
    val audio = AudioHandler(ctx)
    val media = MediaHandler(ctx)
    val usb = UsbHandler(ctx)
    val storage = StorageHandler(ctx)
    val net = NetHandler(ctx)
    val notif = NotifBridge(ctx)

    /** Lo que se le devuelve a un cliente al autenticarse. */
    fun hello(): JSONObject {
        val o = JSONObject()
        o.put("app", "nexo")
        o.put("version", versionName())
        o.put("proto", Protocol.VERSION)
        o.put("minor", Protocol.MINOR)
        o.put("android_sdk", Build.VERSION.SDK_INT)
        o.put("target_sdk", ctx.applicationInfo.targetSdkVersion)
        o.put("device", Build.MANUFACTURER + " " + Build.MODEL)
        o.put("wifi", wifi.hasHardware())
        o.put("bluetooth", bt.hasHardware())
        o.put("listener", NexoNotificationListener.isEnabled(ctx))
        o.put("usb", usb.hasHost())
        o.put("storage", storage.available())
        o.put("uptime_s", BridgeState.uptimeSeconds())
        o.put("commands", JSONArray(NAMES))
        return o
    }

    /** Estado actual de un tema de eventos ("wifi", "bt", "audio", "media", "usb", "storage", "net" o "notif"). */
    fun statusFor(topic: String): JSONObject = when (topic) {
        "wifi" -> wifi.status()
        "bt" -> bt.status()
        "audio" -> audio.status()
        "media" -> media.status()
        "usb" -> usb.status()
        "storage" -> storage.status()
        "net" -> net.status()
        "notif" -> notif.status()
        else -> throw CmdException("bad_request", "Tema desconocido: $topic")
    }

    /** `owner` es la conexión que manda el comando: las sesiones USB que abra se cierran con ella. */
    fun handle(cmd: String, req: JSONObject, owner: Any? = null): JSONObject = when (cmd) {
        "wifi.status" -> wifi.status()
        "wifi.enable" -> wifi.setEnabled(true)
        "wifi.disable" -> wifi.setEnabled(false)
        "wifi.scan" -> wifi.scan(req)
        "wifi.connect" -> wifi.connect(req)
        "wifi.disconnect" -> wifi.disconnect()
        "wifi.saved" -> wifi.saved()
        "wifi.forget" -> wifi.forget(req)
        "wifi.reconnect" -> wifi.reconnect(req)
        "bt.status" -> bt.status()
        "bt.enable" -> bt.setEnabled(true)
        "bt.disable" -> bt.setEnabled(false)
        "bt.paired" -> bt.paired()
        "bt.connect" -> bt.connect(req, true)
        "bt.disconnect" -> bt.connect(req, false)
        "bt.forget" -> bt.forget(req)
        "bt.rename" -> bt.rename(req)
        "bt.info" -> bt.info(req)
        "audio.status" -> audio.status()
        "audio.volume" -> audio.volume(req)
        "audio.outputs" -> audio.outputs()
        "audio.switch" -> audio.switch(req)
        "media.status" -> media.status()
        "media.play", "media.pause", "media.playpause", "media.stop", "media.next", "media.prev" -> media.control(cmd)
        "media.seek" -> media.seek(req)
        "media.art" -> media.art()
        "usb.status" -> usb.status()
        "usb.permission" -> usb.permission(req)
        "usb.open" -> usb.open(req, owner)
        "usb.close" -> usb.close(req)
        "usb.setup" -> usb.setup(req)
        "usb.control" -> usb.control(req)
        "storage.status" -> storage.status()
        "storage.access" -> storage.access(req)
        "storage.revoke" -> storage.revoke(req)
        "storage.list" -> storage.list(req)
        "storage.stat" -> storage.stat(req)
        "storage.open" -> storage.open(req, owner)
        "storage.read" -> storage.read(req)
        "storage.write" -> storage.write(req)
        "storage.sync" -> storage.sync(req)
        "storage.close" -> storage.close(req)
        "storage.mkdir" -> storage.mkdir(req)
        "storage.delete" -> storage.delete(req)
        "storage.rename" -> storage.rename(req)
        "storage.eject" -> storage.eject(req)
        "net.status" -> net.status()
        "notif.status" -> notif.status()
        "notif.list" -> notif.list()
        "notif.dismiss" -> notif.dismiss(req)
        "logs" -> logs(req)
        else -> throw CmdException("unknown_command", "Comando desconocido: $cmd")
    }

    /** Lo último que anotó la app (el mismo registro que ves en la pantalla). Nunca lleva claves ni el token. */
    private fun logs(req: JSONObject): JSONObject {
        val n = req.optInt("n", 50).coerceIn(1, 200)
        val lines = BridgeState.recent(n)
        return JSONObject()
            .put("lines", JSONArray(lines))
            .put("count", lines.size)
            .put("uptime_s", BridgeState.uptimeSeconds())
    }

    @Suppress("DEPRECATION")
    private fun versionName(): String = try {
        ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName ?: "?"
    } catch (_: Exception) {
        "?"
    }

    companion object {
        /**
         * Todos los comandos que esta app entiende (se envía en `hello.commands`).
         * tests/run_tests.sh comprueba que esta lista coincide con la de tests/fake_app.py.
         */
        val NAMES: List<String> = listOf(
            "hello", "ping", "subscribe", "unsubscribe", "logs",
            "wifi.status", "wifi.enable", "wifi.disable", "wifi.scan", "wifi.connect", "wifi.disconnect",
            "wifi.saved", "wifi.forget", "wifi.reconnect",
            "bt.status", "bt.enable", "bt.disable", "bt.paired", "bt.connect", "bt.disconnect",
            "bt.forget", "bt.rename", "bt.info",
            "audio.status", "audio.volume", "audio.outputs", "audio.switch",
            "media.status", "media.play", "media.pause", "media.playpause", "media.stop", "media.next", "media.prev",
            "media.seek", "media.art",
            "usb.status", "usb.permission", "usb.open", "usb.close", "usb.setup", "usb.control", "usb.attach",
            "storage.status", "storage.access", "storage.revoke", "storage.list", "storage.stat", "storage.open",
            "storage.read", "storage.write", "storage.sync", "storage.close", "storage.mkdir", "storage.delete",
            "storage.rename", "storage.eject",
            "net.status", "notif.status", "notif.list", "notif.dismiss",
        ).sorted()

        /** Temas a los que se suscribe quien no indica ninguno (y a los que puede suscribirse uno que sí los indica). */
        val TOPICS: List<String> = listOf("audio", "bt", "media", "storage", "usb", "wifi")

        /** Temas que hay que pedir expresamente en `subscribe`: `notif` lleva el contenido de tus notificaciones, y `net` es de la revisión 5. */
        val OPTIONAL_TOPICS: List<String> = listOf("net", "notif")

        /** Temas que no mandan un estado inicial al suscribirse: solo avisan de lo que pasa. */
        val NO_INITIAL_STATE: Set<String> = setOf("notif")
    }
}
