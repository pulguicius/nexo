package org.nexo.bridge

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.os.storage.StorageVolume
import android.provider.DocumentsContract

/** Un disco (volumen) que Android tiene montado, o acaba de dejar de tener. `uuid` es el UUID del sistema de archivos («0123-4567»). */
class VolumeInfo(
    val uuid: String,
    val label: String,
    val state: String,
    val removable: Boolean,
    val primary: Boolean,
    val path: String?,
) {
    val mounted: Boolean get() = state == Environment.MEDIA_MOUNTED || state == Environment.MEDIA_MOUNTED_READ_ONLY
    val readOnly: Boolean get() = state == Environment.MEDIA_MOUNTED_READ_ONLY
}

/** Una carpeta de un disco a la que el usuario dio acceso a Nexo. `scope` es la ruta dentro del disco («» = el disco entero). */
class TreeGrant(val uuid: String, val tree: Uri, val rootDocId: String, val scope: String)

/**
 * Qué discos hay y a cuáles puede entrar Nexo. Solo lo público de Android: StorageManager para ver los volúmenes y el Storage
 * Access Framework para entrar (el permiso lo concede el usuario, por disco, en el selector de carpetas del sistema).
 */
object StorageVolumes {
    /** El proveedor de documentos de Android para el almacenamiento (interno, tarjetas y discos USB). */
    const val AUTHORITY = "com.android.externalstorage.documents"

    fun list(ctx: Context): List<VolumeInfo> {
        val sm = ctx.getSystemService(Context.STORAGE_SERVICE) as? StorageManager ?: return emptyList()
        val out = ArrayList<VolumeInfo>()
        for (v in sm.storageVolumes) {
            val uuid = v.uuid ?: continue // el almacenamiento interno emulado no tiene UUID
            if (v.isEmulated) continue
            out.add(VolumeInfo(uuid, label(ctx, v, uuid), v.state ?: "unknown", v.isRemovable, v.isPrimary, pathOf(v, uuid)))
        }
        return out
    }

    private fun label(ctx: Context, v: StorageVolume, uuid: String): String =
        try {
            v.getDescription(ctx)?.trim().takeUnless { it.isNullOrEmpty() } ?: uuid
        } catch (_: Exception) {
            uuid
        }

    /** Dónde monta Android el disco (para quien pueda verlo directamente). Android 11+ lo dice; antes se pregunta por reflexión. */
    private fun pathOf(v: StorageVolume, uuid: String): String {
        try {
            if (Build.VERSION.SDK_INT >= 30) {
                v.directory?.absolutePath?.let { return it }
            } else {
                @Suppress("DiscouragedPrivateApi")
                val p = StorageVolume::class.java.getMethod("getPath").invoke(v) as? String
                if (!p.isNullOrEmpty()) return p
            }
        } catch (_: Exception) {
        }
        return "/storage/$uuid"
    }

    fun find(ctx: Context, uuid: String?): VolumeInfo? = list(ctx).firstOrNull { it.uuid.equals(uuid, ignoreCase = true) }

    /** Tamaño total y espacio libre de cada disco, por UUID en minúsculas: longArrayOf(total, libre), con -1 si el sistema no lo dice. */
    fun capacity(ctx: Context): Map<String, LongArray> {
        val out = HashMap<String, LongArray>()
        try {
            val cols = arrayOf(
                DocumentsContract.Root.COLUMN_ROOT_ID,
                DocumentsContract.Root.COLUMN_CAPACITY_BYTES,
                DocumentsContract.Root.COLUMN_AVAILABLE_BYTES,
            )
            ctx.contentResolver.query(DocumentsContract.buildRootsUri(AUTHORITY), cols, null, null, null)?.use { c ->
                while (c.moveToNext()) {
                    val id = c.getString(0) ?: continue
                    val total = if (c.isNull(1)) -1L else c.getLong(1)
                    val free = if (c.isNull(2)) -1L else c.getLong(2)
                    out[id.lowercase()] = longArrayOf(total, free)
                }
            }
        } catch (_: Exception) {
        }
        return out
    }

    /** Las carpetas de discos a las que Nexo tiene acceso de lectura y escritura (permisos que el usuario concedió y Android conserva). */
    fun grants(ctx: Context): List<TreeGrant> {
        val out = ArrayList<TreeGrant>()
        for (p in ctx.contentResolver.persistedUriPermissions) {
            val u = p.uri
            if (!p.isReadPermission || !p.isWritePermission) continue
            if (u.authority != AUTHORITY || !DocumentsContract.isTreeUri(u)) continue
            val docId = try {
                DocumentsContract.getTreeDocumentId(u)
            } catch (_: Exception) {
                continue
            }
            val sp = StoragePath.splitDocId(docId) ?: continue
            out.add(TreeGrant(sp.first, u, docId, sp.second))
        }
        return out
    }

    fun grantFor(ctx: Context, uuid: String): TreeGrant? =
        StorageSelect.bestScope(grants(ctx).filter { it.uuid.equals(uuid, ignoreCase = true) }) { it.scope }

    /** Quita el acceso de Nexo a ese disco (Android deja de recordarlo). Devuelve cuántos permisos soltó. */
    fun release(ctx: Context, uuid: String): Int {
        var n = 0
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        for (g in grants(ctx).filter { it.uuid.equals(uuid, ignoreCase = true) }) {
            try {
                ctx.contentResolver.releasePersistableUriPermission(g.tree, flags)
                n++
            } catch (_: Exception) {
            }
        }
        return n
    }
}
