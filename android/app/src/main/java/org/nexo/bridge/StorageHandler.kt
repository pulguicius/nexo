package org.nexo.bridge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.SystemClock
import android.os.storage.StorageManager
import android.os.storage.StorageVolume
import android.provider.DocumentsContract
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Almacenamiento USB (protocolo 1.4): pendrives, discos duros y SSD externos conectados al móvil.
 *
 * Android monta el disco por su cuenta (vold) y lo enseña como un volumen; una distro de proot ni lo ve ni puede montar nada. Nexo no
 * pide «acceso a todos los archivos»: el usuario elige el disco en el selector de carpetas de Android (storage.access →
 * StorageGrantActivity) y Nexo conserva ese permiso. Con él, esta clase ofrece a Linux las operaciones sobre archivos
 * (storage.list/stat/open/read/write/close/mkdir/delete/rename) y la expulsión (storage.eject).
 *
 * Las lecturas y escrituras van en trozos de base64 por la conexión JSON (storage.read/storage.write): sin estados raros y sin
 * conexiones de bytes, a cambio de un poco de velocidad. Las reglas están en StorageLogic.kt (probadas en JVM); lo que toca el disco,
 * en StorageSaf.kt. Nada de esto se ha probado con un disco real (docs/USB-ALMACENAMIENTO.md).
 */
class StorageHandler(context: Context) {
    private val ctx: Context = context.applicationContext
    private val handles = HandleTable()
    private val waits = ConcurrentHashMap<String, CountDownLatch>()
    private val denied = ConcurrentHashMap<String, Boolean>()
    private var registered = false
    private var callback: StorageManager.StorageVolumeCallback? = null

    /** El servicio pone aquí lo que avisa a los clientes suscritos al tema «storage». */
    @Volatile
    var onChange: (() -> Unit)? = null

    /** ¿Tiene este móvil el servicio de almacenamiento de Android? (Todos; se mantiene por si algún sistema raro no.) */
    fun available(): Boolean = ctx.getSystemService(Context.STORAGE_SERVICE) is StorageManager

    // ----------------------------------------------------------------------------------- avisos de Android

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, i: Intent?) {
            val action = i?.action ?: return
            // Los avisos llevan «file:///storage/UUID»: de ahí sale qué disco es.
            val uuid = i.data?.lastPathSegment
            if (uuid != null && action != Intent.ACTION_MEDIA_MOUNTED && action != Intent.ACTION_MEDIA_CHECKING) {
                val n = handles.forVolume(uuid)
                if (n > 0) BridgeState.log("Disco USB desmontado: se cerraron $n archivos abiertos")
            }
            onChange?.invoke()
        }
    }

    /** Empieza a escuchar los avisos de Android (se llama al encender el puente). */
    fun watch() {
        if (registered) return
        val f = IntentFilter()
        f.addAction(Intent.ACTION_MEDIA_MOUNTED)
        f.addAction(Intent.ACTION_MEDIA_UNMOUNTED)
        f.addAction(Intent.ACTION_MEDIA_EJECT)
        f.addAction(Intent.ACTION_MEDIA_REMOVED)
        f.addAction(Intent.ACTION_MEDIA_BAD_REMOVAL)
        f.addAction(Intent.ACTION_MEDIA_CHECKING)
        f.addDataScheme("file")
        ctx.registerReceiver(receiver, f)
        if (Build.VERSION.SDK_INT >= 30) {
            val sm = ctx.getSystemService(Context.STORAGE_SERVICE) as? StorageManager
            val cb = object : StorageManager.StorageVolumeCallback() {
                override fun onStateChanged(volume: StorageVolume) {
                    val id = volume.uuid
                    if (id != null && volume.state != android.os.Environment.MEDIA_MOUNTED &&
                        volume.state != android.os.Environment.MEDIA_MOUNTED_READ_ONLY
                    ) handles.forVolume(id)
                    onChange?.invoke()
                }
            }
            try {
                sm?.registerStorageVolumeCallback(ctx.mainExecutor, cb)
                callback = cb
            } catch (_: Exception) {
            }
        }
        StorageGrantBus.onResult = { uuid, granted ->
            if (!granted) denied[uuid.lowercase()] = true
            waits.remove(uuid.lowercase())?.countDown()
            onChange?.invoke()
        }
        registered = true
    }

    /** Deja de escuchar y cierra todos los archivos (se llama al apagar el puente). */
    fun unwatch() {
        if (registered) {
            try {
                ctx.unregisterReceiver(receiver)
            } catch (_: Exception) {
            }
            callback?.let {
                try {
                    (ctx.getSystemService(Context.STORAGE_SERVICE) as? StorageManager)?.unregisterStorageVolumeCallback(it)
                } catch (_: Exception) {
                }
            }
            callback = null
            StorageGrantBus.onResult = null
            registered = false
        }
        handles.closeWhere { true }
        for (l in waits.values) l.countDown()
        waits.clear()
    }

    /** Cierra los archivos que abrió una conexión que ya no existe. */
    fun ownerGone(owner: Any?) {
        if (owner == null) return
        val n = handles.forOwner(owner)
        if (n > 0) BridgeState.log("Se cerraron $n archivos de un disco USB de un cliente que se fue")
    }

    // ----------------------------------------------------------------------------------- ayudantes

    private inline fun <T> guard(block: () -> T): T = try {
        block()
    } catch (e: StorageException) {
        throw CmdException(e.code, e.message ?: e.code)
    }

    private fun str(req: JSONObject, key: String): String? = if (!req.has(key) || req.isNull(key)) null else req.optString(key)

    private fun path(req: JSONObject, key: String = "path", default: String? = null): List<String> =
        StoragePath.parse(str(req, key) ?: default)

    private fun pickVolume(req: JSONObject): VolumeInfo =
        StorageSelect.pick(StorageVolumes.list(ctx), str(req, "volume"), { it.uuid }, { it.label })

    /** El volumen, y que esté montado (si no, lo que hay que decirle al usuario). */
    private fun mountedVolume(req: JSONObject): VolumeInfo {
        val v = pickVolume(req)
        if (!v.mounted) {
            throw CmdException(
                "unavailable", "El disco «" + v.label + "» no está montado (estado: " + v.state + ")",
                JSONObject().put("volume", v.uuid).put("state", v.state)
            )
        }
        return v
    }

    private fun opsFor(v: VolumeInfo): StorageOps {
        val g = StorageVolumes.grantFor(ctx, v.uuid) ?: throw CmdException(
            "no_access",
            "Nexo todavía no tiene acceso al disco «" + v.label + "»: pídelo con storage.access (nexo usb access) y elige el disco en el móvil",
            JSONObject().put("volume", v.uuid)
        )
        return StorageOps(SafDocFs(ctx, g.tree, g.rootDocId, v.readOnly))
    }

    private fun entryJson(e: DocEntry): JSONObject {
        val o = JSONObject()
        o.put("name", e.name)
        o.put("type", if (e.dir) "dir" else "file")
        o.put("size", e.size)
        o.put("mtime_ms", e.mtimeMs)
        if (e.mime != null) o.put("mime", e.mime)
        o.put("writable", e.writable)
        return o
    }

    private fun massStorageDevices(): Int {
        val um = ctx.getSystemService(Context.USB_SERVICE) as? UsbManager ?: return 0
        return try {
            um.deviceList.values.count { d -> (0 until d.interfaceCount).any { d.getInterface(it).interfaceClass == UsbConstants.USB_CLASS_MASS_STORAGE } }
        } catch (_: Exception) {
            0
        }
    }

    private fun volumeJson(v: VolumeInfo, cap: LongArray?, g: TreeGrant?): JSONObject {
        val o = JSONObject()
        o.put("id", v.uuid)
        o.put("uuid", v.uuid)
        o.put("label", v.label)
        o.put("state", v.state)
        o.put("mounted", v.mounted)
        o.put("readonly", v.readOnly)
        o.put("removable", v.removable)
        o.put("primary", v.primary)
        o.putOrNull("path", v.path)
        o.put("granted", g != null)
        o.putOrNull("scope", g?.scope)
        o.put("open_files", handles.count(v.uuid))
        o.putOrNull("total", cap?.get(0)?.takeIf { it >= 0 })
        o.putOrNull("free", cap?.get(1)?.takeIf { it >= 0 })
        return o
    }

    // ----------------------------------------------------------------------------------- comandos

    /** Los discos que Android tiene montados, a cuáles puede entrar Nexo y cuántos archivos hay abiertos. */
    fun status(): JSONObject {
        val cap = StorageVolumes.capacity(ctx)
        val grants = StorageVolumes.grants(ctx)
        val arr = JSONArray()
        for (v in StorageVolumes.list(ctx)) {
            val g = StorageSelect.bestScope(grants.filter { it.uuid.equals(v.uuid, ignoreCase = true) }) { it.scope }
            arr.put(volumeJson(v, cap[v.uuid.lowercase()], g))
        }
        return JSONObject()
            .put("available", available())
            .put("volumes", arr)
            .put("mass_storage_devices", massStorageDevices())
            .put("open_files", handles.count())
    }

    /**
     * Pide que el usuario dé acceso a un disco. Si ya lo hay, lo dice; si no, abre el selector de carpetas de Android (o deja una
     * notificación que lo abre) y, con `wait_ms`, espera la respuesta. `denied:true` = el usuario dijo que no.
     */
    fun access(req: JSONObject): JSONObject = guard {
        val v = mountedVolume(req)
        val key = v.uuid.lowercase()
        if (StorageVolumes.grantFor(ctx, v.uuid) != null) {
            return@guard JSONObject().put("volume", v.uuid).put("granted", true).put("requested", false).put("denied", false)
        }
        val wait = req.optLong("wait_ms", 0L).coerceIn(0L, 30000L)
        val latch = waits.computeIfAbsent(key) { CountDownLatch(1) }
        denied.remove(key)
        UserAction.open(
            ctx, UserAction.ID_STORAGE, "Nexo: acceso al disco «" + v.label + "»",
            "Toca y elige el disco para darle acceso a Nexo", StorageGrantActivity.intent(ctx, v.uuid)
        )
        if (wait > 0) latch.await(wait, TimeUnit.MILLISECONDS)
        val granted = StorageVolumes.grantFor(ctx, v.uuid) != null
        JSONObject().put("volume", v.uuid).put("granted", granted).put("requested", true)
            .put("denied", !granted && denied.containsKey(key))
    }

    /** Quita el acceso de Nexo a un disco (cierra antes sus archivos). */
    fun revoke(req: JSONObject): JSONObject = guard {
        val v = pickVolume(req)
        handles.forVolume(v.uuid)
        val n = StorageVolumes.release(ctx, v.uuid)
        onChange?.invoke()
        JSONObject().put("volume", v.uuid).put("released", n)
    }

    fun list(req: JSONObject): JSONObject = guard {
        val v = mountedVolume(req)
        val parts = path(req, default = "/")
        val page = opsFor(v).list(
            parts, req.optInt("offset", 0), req.optInt("limit", StorageLimits.LIST_DEFAULT)
        )
        val arr = JSONArray()
        for (e in page.entries) arr.put(entryJson(e))
        JSONObject().put("path", StoragePath.join(parts)).put("entries", arr).put("total", page.total).put("offset", page.offset)
    }

    fun stat(req: JSONObject): JSONObject = guard {
        val v = mountedVolume(req)
        val parts = path(req, default = "/")
        val e = opsFor(v).stat(parts)
        entryJson(e).put("path", StoragePath.join(parts))
    }

    /**
     * Abre un archivo. `mode`: `r` (leer), `w` (crear/vaciar y escribir), `a` (crear si falta y escribir al final: `size` dice dónde)
     * o `rw` (leer y escribir uno que ya existe). `create`, `truncate` y `exclusive` ajustan lo que cada modo hace por omisión.
     */
    fun open(req: JSONObject, owner: Any?): JSONObject = guard {
        val v = mountedVolume(req)
        val parts = path(req)
        val mode = str(req, "mode") ?: "r"
        val write: Boolean
        val defCreate: Boolean
        val defTruncate: Boolean
        when (mode) {
            "r" -> { write = false; defCreate = false; defTruncate = false }
            "w" -> { write = true; defCreate = true; defTruncate = true }
            "a" -> { write = true; defCreate = true; defTruncate = false }
            "rw" -> { write = true; defCreate = false; defTruncate = false }
            else -> throw StorageException("bad_request", "mode debe ser r, w, a o rw")
        }
        val file = opsFor(v).open(
            parts, write, req.optBoolean("create", defCreate), req.optBoolean("truncate", defTruncate), req.optBoolean("exclusive", false)
        )
        val h = handles.add(v.uuid, StoragePath.join(parts), file, write, owner)
        val size = try {
            file.size()
        } catch (e: StorageException) {
            handles.close(h.id)
            throw e
        }
        JSONObject().put("handle", h.id).put("size", size).put("writable", write)
    }

    fun read(req: JSONObject): JSONObject = guard {
        val h = handles.get(str(req, "handle"))
        val off = req.optLong("offset", -1L)
        if (off < 0) throw StorageException("bad_request", "Falta offset (0 o más)")
        val len = req.optInt("len", StorageLimits.READ_MAX).coerceIn(1, StorageLimits.READ_MAX)
        val buf = ByteArray(len)
        val n = h.file.read(off, buf, 0, len)
        h.rx += n
        val eof = n < len || off + n >= h.file.size()
        JSONObject().put("n", n).put("eof", eof).put("data", Base64.encodeToString(buf, 0, n, Base64.NO_WRAP))
    }

    fun write(req: JSONObject): JSONObject = guard {
        val h = handles.get(str(req, "handle"))
        if (!h.writable) throw StorageException("read_only", "Ese archivo está abierto solo para leer")
        val off = req.optLong("offset", -1L)
        if (off < 0) throw StorageException("bad_request", "Falta offset (0 o más)")
        val data = try {
            Base64.decode(str(req, "data") ?: "", Base64.DEFAULT)
        } catch (_: IllegalArgumentException) {
            throw StorageException("bad_request", "data no es base64 válido")
        }
        if (data.size > StorageLimits.WRITE_MAX) {
            throw StorageException("bad_request", "Cada storage.write admite como mucho " + StorageLimits.WRITE_MAX + " bytes")
        }
        val n = h.file.write(off, data, 0, data.size)
        h.tx += n
        JSONObject().put("n", n)
    }

    /** Vacía al disco lo escrito: de un archivo (`handle`) o de todos los abiertos de un disco (`volume`). */
    fun sync(req: JSONObject): JSONObject = guard {
        val id = str(req, "handle")
        if (id != null) {
            val h = handles.get(id)
            if (h.writable) h.file.sync()
            JSONObject().put("synced", if (h.writable) 1 else 0)
        } else {
            JSONObject().put("synced", handles.syncVolume(pickVolume(req).uuid))
        }
    }

    fun close(req: JSONObject): JSONObject = guard {
        JSONObject().put("closed", handles.close(str(req, "handle")))
    }

    fun mkdir(req: JSONObject): JSONObject = guard {
        val v = mountedVolume(req)
        opsFor(v).mkdir(path(req), req.optBoolean("parents", false))
        JSONObject().put("created", true)
    }

    fun delete(req: JSONObject): JSONObject = guard {
        val v = mountedVolume(req)
        opsFor(v).delete(path(req))
        JSONObject().put("deleted", true)
    }

    fun rename(req: JSONObject): JSONObject = guard {
        val v = mountedVolume(req)
        opsFor(v).rename(path(req, "from"), path(req, "to"), req.optBoolean("overwrite", false))
        JSONObject().put("renamed", true)
    }

    /**
     * Expulsión segura «cuando se puede»: cierra los archivos abiertos de ese disco (vaciándolos antes) y le pide a Android que lo
     * expulse con DocumentsContract.ejectRoot. Una app normal puede no tener permiso para eso (Android lo ignora sin avisar), así que
     * se mira el estado después: `ejected:false` + `hint` dicen qué hacer a mano (el botón «Expulsar» de Android).
     */
    fun eject(req: JSONObject): JSONObject = guard {
        val v = pickVolume(req)
        val closed = handles.forVolume(v.uuid)
        var attempted = false
        if (v.mounted) {
            // DocumentsContract.ejectRoot existe desde Android 10 (API 29): antes no hay manera de pedirlo, y solo se explica cómo hacerlo a mano.
            if (Build.VERSION.SDK_INT >= 29) {
                try {
                    DocumentsContract.ejectRoot(ctx.contentResolver, DocumentsContract.buildRootUri(StorageVolumes.AUTHORITY, v.uuid))
                    attempted = true
                } catch (_: Exception) {
                }
            }
            val t0 = SystemClock.elapsedRealtime()
            while (attempted && SystemClock.elapsedRealtime() - t0 < 3000L) {
                val now = StorageVolumes.find(ctx, v.uuid)
                if (now == null || !now.mounted) break
                try {
                    Thread.sleep(150)
                } catch (_: InterruptedException) {
                    break
                }
            }
        }
        val now = StorageVolumes.find(ctx, v.uuid)
        val gone = now == null || !now.mounted
        val o = JSONObject().put("volume", v.uuid).put("closed_files", closed).put("attempted", attempted)
            .put("ejected", gone).put("state", now?.state ?: "removed")
        if (!gone) {
            o.put("hint", "Android no dejó expulsarlo desde Nexo: usa «Expulsar» en la notificación del disco o en Ajustes › Almacenamiento, y desenchúfalo después")
        }
        onChange?.invoke()
        o
    }
}
