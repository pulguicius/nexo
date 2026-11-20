package org.nexo.bridge

import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.FileNotFoundException
import java.io.IOException

/**
 * DocFs sobre el Storage Access Framework: la carpeta (o el disco entero) que el usuario eligió en el selector de Android y de la
 * que Nexo guardó el permiso (StorageGrantActivity). No hace falta ningún permiso de almacenamiento amplio.
 *
 * Solo entiende el proveedor de Android para discos (`com.android.externalstorage.documents`), donde el identificador de un documento
 * es «UUID:ruta/relativa»: así se llega a cualquier ruta sin recorrer las carpetas una a una.
 * NO se ha probado con un disco real (docs/USB-ALMACENAMIENTO.md): la lógica que lo rodea sí (StorageLogicTest.kt).
 */
class SafDocFs(
    context: Context,
    private val tree: Uri,
    private val rootDocId: String,
    override val readOnly: Boolean,
) : DocFs {
    private val cr = context.applicationContext.contentResolver

    private companion object {
        val COLS = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_SIZE,
            Document.COLUMN_LAST_MODIFIED,
            Document.COLUMN_FLAGS,
        )
        const val BINARY = "application/octet-stream"
    }

    private fun uri(parts: List<String>): Uri =
        DocumentsContract.buildDocumentUriUsingTree(tree, StoragePath.docId(rootDocId, parts))

    private fun denied() = StorageException(
        "no_access", "Android ya no deja a Nexo entrar en ese disco: vuelve a darle acceso (nexo usb access)"
    )

    private fun entry(c: Cursor): DocEntry {
        val name = c.getString(1) ?: ""
        val mime = c.getString(2)
        val dir = mime == Document.MIME_TYPE_DIR
        val size = if (c.isNull(3)) 0L else c.getLong(3)
        val mtime = if (c.isNull(4)) 0L else c.getLong(4)
        val flags = if (c.isNull(5)) 0 else c.getInt(5)
        val writable = if (dir) flags and Document.FLAG_DIR_SUPPORTS_CREATE != 0 else flags and Document.FLAG_SUPPORTS_WRITE != 0
        return DocEntry(name, dir, if (dir) 0L else size, mtime, if (dir) null else mime, writable)
    }

    private fun queryOne(u: Uri): DocEntry? {
        try {
            cr.query(u, COLS, null, null, null)?.use { c -> if (c.moveToFirst()) return entry(c) }
        } catch (_: SecurityException) {
            throw denied()
        } catch (_: Exception) {
            // un documento que no existe hace que el proveedor lance una excepción: para nosotros es «no está»
        }
        return null
    }

    override fun stat(parts: List<String>): DocEntry? = queryOne(uri(parts))

    override fun list(parts: List<String>): List<DocEntry>? {
        val u = DocumentsContract.buildChildDocumentsUriUsingTree(tree, StoragePath.docId(rootDocId, parts))
        try {
            return cr.query(u, COLS, null, null, null)?.use { c ->
                val out = ArrayList<DocEntry>(c.count.coerceAtLeast(0))
                while (c.moveToNext()) out.add(entry(c))
                out
            }
        } catch (_: SecurityException) {
            throw denied()
        } catch (_: Exception) {
            return null
        }
    }

    private fun made(u: Uri?, wanted: String, what: String): DocEntry {
        if (u == null) throw StorageException("io_error", "Android no dejó $what «$wanted» (¿disco en solo lectura?)")
        return queryOne(u) ?: DocEntry(wanted, false, 0L, 0L)
    }

    override fun createFile(parent: List<String>, name: String): DocEntry {
        val u = try {
            DocumentsContract.createDocument(cr, uri(parent), BINARY, name)
        } catch (_: SecurityException) {
            throw denied()
        } catch (e: Exception) {
            throw StorageException("io_error", "Android no dejó crear «$name»: " + (e.message ?: e.javaClass.simpleName))
        }
        return made(u, name, "crear")
    }

    override fun createDir(parent: List<String>, name: String): DocEntry {
        val u = try {
            DocumentsContract.createDocument(cr, uri(parent), Document.MIME_TYPE_DIR, name)
        } catch (_: SecurityException) {
            throw denied()
        } catch (e: Exception) {
            throw StorageException("io_error", "Android no dejó crear la carpeta «$name»: " + (e.message ?: e.javaClass.simpleName))
        }
        return made(u, name, "crear la carpeta")
    }

    override fun delete(parts: List<String>): Boolean = try {
        DocumentsContract.deleteDocument(cr, uri(parts))
    } catch (_: SecurityException) {
        throw denied()
    } catch (_: Exception) {
        false
    }

    override fun rename(parts: List<String>, newName: String): DocEntry {
        val u = try {
            DocumentsContract.renameDocument(cr, uri(parts), newName)
        } catch (_: SecurityException) {
            throw denied()
        } catch (e: Exception) {
            throw StorageException("io_error", "Android no dejó renombrar a «$newName»: " + (e.message ?: e.javaClass.simpleName))
        }
        return made(u, newName, "renombrar a")
    }

    override fun move(parts: List<String>, newParent: List<String>): DocEntry {
        val u = try {
            DocumentsContract.moveDocument(cr, uri(parts), uri(parts.dropLast(1)), uri(newParent))
        } catch (_: SecurityException) {
            throw denied()
        } catch (e: Exception) {
            throw StorageException("io_error", "Android no dejó mover «" + parts.last() + "»: " + (e.message ?: e.javaClass.simpleName))
        }
        return made(u, parts.last(), "mover")
    }

    override fun open(parts: List<String>, writable: Boolean): DocFile {
        val pfd = try {
            cr.openFileDescriptor(uri(parts), if (writable) "rw" else "r")
        } catch (_: SecurityException) {
            throw denied()
        } catch (_: FileNotFoundException) {
            throw StorageException("not_found", "No existe: " + StoragePath.join(parts))
        } catch (e: Exception) {
            throw StorageException("io_error", "Android no dejó abrir el archivo: " + (e.message ?: e.javaClass.simpleName))
        } ?: throw StorageException("io_error", "Android no dejó abrir el archivo")
        return SafFile(pfd)
    }
}

/** Un archivo abierto con Os.pread/pwrite sobre el descriptor que entregó el proveedor (los de discos son archivos de verdad, con posición). */
private class SafFile(private val pfd: ParcelFileDescriptor) : DocFile {
    private val fd get() = pfd.fileDescriptor

    private fun errno(e: ErrnoException, what: String): StorageException = when (e.errno) {
        OsConstants.ENOSPC, OsConstants.EDQUOT -> StorageException("no_space", "El disco está lleno")
        OsConstants.EFBIG -> StorageException("too_big", "El sistema de archivos del disco no admite un archivo tan grande (FAT32: máximo 4 GB)")
        OsConstants.EROFS, OsConstants.EACCES, OsConstants.EPERM -> StorageException("read_only", "El disco no deja escribir")
        else -> StorageException("io_error", what + ": " + (e.message ?: ("errno " + e.errno)))
    }

    override fun size(): Long = try {
        Os.fstat(fd).st_size
    } catch (e: ErrnoException) {
        throw errno(e, "No se pudo leer el tamaño")
    }

    override fun read(pos: Long, buf: ByteArray, off: Int, len: Int): Int = try {
        Os.pread(fd, buf, off, len, pos)
    } catch (e: ErrnoException) {
        throw errno(e, "Error al leer")
    }

    override fun write(pos: Long, buf: ByteArray, off: Int, len: Int): Int {
        var done = 0
        try {
            while (done < len) {
                val n = Os.pwrite(fd, buf, off + done, len - done, pos + done)
                if (n <= 0) throw StorageException("io_error", "El disco no aceptó más datos")
                done += n
            }
        } catch (e: ErrnoException) {
            throw errno(e, "Error al escribir")
        }
        return done
    }

    override fun truncate(len: Long) {
        try {
            Os.ftruncate(fd, len)
        } catch (e: ErrnoException) {
            throw errno(e, "No se pudo vaciar el archivo")
        }
    }

    override fun sync() {
        try {
            Os.fsync(fd)
        } catch (e: ErrnoException) {
            // algunos sistemas de archivos (o descriptores) no admiten fsync: no es un fallo de los datos
            if (e.errno != OsConstants.EINVAL && e.errno != OsConstants.ENOTSUP) throw errno(e, "No se pudo vaciar al disco")
        }
    }

    override fun close() {
        try {
            pfd.close()
        } catch (_: IOException) {
        }
    }
}
