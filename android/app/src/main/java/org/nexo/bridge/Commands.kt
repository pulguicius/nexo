package org.nexo.bridge

import android.content.Context
import android.os.Build
import org.json.JSONObject

/** Reparte cada comando del protocolo al manejador de WiFi o de Bluetooth. */
class Commands(context: Context) {
    private val ctx: Context = context.applicationContext
    private val wifi = WifiHandler(ctx)
    private val bt = BluetoothHandler(ctx)

    /** Lo que se le devuelve a un cliente al autenticarse. */
    fun hello(): JSONObject {
        val o = JSONObject()
        o.put("app", "nexo")
        o.put("version", versionName())
        o.put("proto", Protocol.VERSION)
        o.put("android_sdk", Build.VERSION.SDK_INT)
        o.put("target_sdk", ctx.applicationInfo.targetSdkVersion)
        o.put("device", Build.MANUFACTURER + " " + Build.MODEL)
        o.put("wifi", wifi.hasHardware())
        o.put("bluetooth", bt.hasHardware())
        return o
    }

    /** Estado actual de un tema de eventos ("wifi" o "bt"). */
    fun statusFor(topic: String): JSONObject = if (topic == "wifi") wifi.status() else bt.status()

    fun handle(cmd: String, req: JSONObject): JSONObject = when (cmd) {
        "wifi.status" -> wifi.status()
        "wifi.enable" -> wifi.setEnabled(true)
        "wifi.disable" -> wifi.setEnabled(false)
        "wifi.scan" -> wifi.scan(req)
        "wifi.connect" -> wifi.connect(req)
        "wifi.disconnect" -> wifi.disconnect()
        "bt.status" -> bt.status()
        "bt.enable" -> bt.setEnabled(true)
        "bt.disable" -> bt.setEnabled(false)
        "bt.paired" -> bt.paired()
        "bt.connect" -> bt.connect(req, true)
        "bt.disconnect" -> bt.connect(req, false)
        else -> throw CmdException("unknown_command", "Comando desconocido: $cmd")
    }

    @Suppress("DEPRECATION")
    private fun versionName(): String = try {
        ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName ?: "?"
    } catch (_: Exception) {
        "?"
    }
}
