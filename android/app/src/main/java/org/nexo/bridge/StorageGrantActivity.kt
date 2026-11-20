package org.nexo.bridge

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.DocumentsContract
import android.widget.Toast

/** Aquí avisa la pantalla de elegir carpeta; quien espera es StorageHandler. */
object StorageGrantBus {
    @Volatile
    var onResult: ((uuid: String, granted: Boolean) -> Unit)? = null
}

/**
 * Pantalla sin interfaz propia que abre el selector de carpetas de Android (Storage Access Framework) sobre un disco USB y guarda el
 * permiso que el usuario conceda. Es la única forma que tiene una app normal de escribir en un disco USB sin pedir «acceso a todos los
 * archivos». Se abre desde la notificación que deja `storage.access` (o `nexo usb access`) y desde el botón de la pantalla de Nexo.
 *
 * En Android 11+ el selector no deja elegir la raíz de la tarjeta SD ni la de la memoria interna, pero los discos USB sí
 * (ExternalStorageProvider lo permite expresamente); si en tu móvil no, elige una carpeta del disco: Nexo trabajará dentro de ella.
 */
class StorageGrantActivity : Activity() {
    companion object {
        const val EXTRA_VOLUME = "volume"
        private const val REQ = 4201

        fun intent(ctx: Context, uuid: String?): Intent =
            Intent(ctx, StorageGrantActivity::class.java).also { if (uuid != null) it.putExtra(EXTRA_VOLUME, uuid) }
    }

    private var uuid: String? = null
    private var label: String = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        uuid = savedInstanceState?.getString("uuid") ?: intent?.getStringExtra(EXTRA_VOLUME)
        label = savedInstanceState?.getString("label") ?: ""
        if (savedInstanceState == null) launchPicker()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putString("uuid", uuid)
        outState.putString("label", label)
    }

    private fun toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_LONG).show()

    private fun launchPicker() {
        val vols = StorageVolumes.list(this).filter { it.mounted }
        val wanted = uuid
        val vol = vols.firstOrNull { wanted != null && it.uuid.equals(wanted, ignoreCase = true) }
            ?: if (wanted == null) {
                vols.firstOrNull { it.removable && StorageVolumes.grantFor(this, it.uuid) == null } ?: vols.firstOrNull { it.removable }
            } else null
        if (vol == null) {
            toast("No hay ningún disco USB montado: conéctalo y espera a que Android lo reconozca")
            finish()
            return
        }
        uuid = vol.uuid
        label = vol.label
        val i = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        if (Build.VERSION.SDK_INT >= 26) {
            i.putExtra(DocumentsContract.EXTRA_INITIAL_URI, DocumentsContract.buildDocumentUri(StorageVolumes.AUTHORITY, vol.uuid + ":"))
        }
        i.addFlags(
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
        )
        toast("Elige el disco «" + vol.label + "» y pulsa «Usar esta carpeta» (así le das acceso a Nexo)")
        try {
            startActivityForResult(i, REQ)
        } catch (_: ActivityNotFoundException) {
            toast("Este móvil no tiene selector de carpetas de Android")
            StorageGrantBus.onResult?.invoke(vol.uuid, false)
            finish()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ) {
            val id = uuid
            val tree = data?.data
            val ok = resultCode == RESULT_OK && tree != null && accept(tree)
            BridgeState.log(if (ok) "Acceso a un disco USB: concedido" else "Acceso a un disco USB: no concedido")
            if (id != null) StorageGrantBus.onResult?.invoke(id, ok)
        }
        finish()
    }

    /** Solo vale una carpeta del propio disco: si el usuario eligió otra cosa, se rechaza y no se guarda nada. */
    private fun accept(tree: Uri): Boolean {
        val id = uuid ?: return false
        if (tree.authority != StorageVolumes.AUTHORITY || !DocumentsContract.isTreeUri(tree)) {
            toast("Eso no es una carpeta del disco USB")
            return false
        }
        val sp = StoragePath.splitDocId(DocumentsContract.getTreeDocumentId(tree))
        if (sp == null || !sp.first.equals(id, ignoreCase = true)) {
            toast("Elige una carpeta del disco «$label», no de otro sitio")
            return false
        }
        return try {
            contentResolver.takePersistableUriPermission(
                tree, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
            true
        } catch (_: SecurityException) {
            toast("Android no dejó guardar el permiso")
            false
        }
    }
}
