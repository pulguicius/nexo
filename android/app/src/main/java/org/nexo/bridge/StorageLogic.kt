package org.nexo.bridge

/*
 * Almacenamiento USB (pendrives, discos duros y SSD externos; protocolo 1.4): la parte que NO es Android.
 *
 * Aquí viven las reglas (rutas, qué pasa al crear, borrar, renombrar…) y la tabla de archivos abiertos. No importa nada de Android:
 * se prueba en una JVM con un árbol en memoria (StorageLogicTest.kt). Lo que de verdad toca el disco es StorageSaf.kt, que implementa
 * DocFs con el Storage Access Framework (la carpeta que el usuario elige en el selector de Android; Nexo no pide permisos de
 * almacenamiento amplios). StorageHandler.kt lo une todo y habla el protocolo.
 */

import java.util.concurrent.atomic.AtomicInteger

/** Un fallo de una operación de almacenamiento. `code` es uno de los códigos del protocolo (docs/PROTOCOLO.md). */
class StorageException(val code: String, message: String) : Exception(message)

/** Una entrada de una carpeta (o el propio objeto, en stat). `size` y `mtimeMs` valen 0 si el sistema no los dice. */
class DocEntry(
    val name: String,
    val dir: Boolean,
    val size: Long,
    val mtimeMs: Long,
    val mime: String? = null,
    val writable: Boolean = true,
)

/** Un archivo abierto: lecturas y escrituras en una posición dada (como pread/pwrite), sin estado de «posición actual». */
interface DocFile {
    fun size(): Long

    /** Lee hasta `len` bytes desde `pos`; 0 = fin del archivo. */
    fun read(pos: Long, buf: ByteArray, off: Int, len: Int): Int

    /** Escribe los `len` bytes (o lanza una StorageException); devuelve cuántos. */
    fun write(pos: Long, buf: ByteArray, off: Int, len: Int): Int
    fun truncate(len: Long)
    fun sync()
    fun close()
}

/**
 * Un árbol de documentos al que se llega con rutas ya normalizadas (lista de nombres, sin «..»). En el móvil es el de SAF
 * (StorageSaf.kt); en las pruebas, uno en memoria. Las implementaciones lanzan StorageException si algo sale mal por dentro;
 * «no existe» no es un fallo: stat devuelve null.
 */
interface DocFs {
    /** El sistema montó el disco en solo lectura (o no deja escribir en esa carpeta). */
    val readOnly: Boolean

    fun stat(parts: List<String>): DocEntry?

    /** Los hijos de una carpeta; null si no existe o no es una carpeta. */
    fun list(parts: List<String>): List<DocEntry>?

    /** Crea un archivo vacío. Devuelve la entrada con el nombre REAL (Android renombra «a.txt» a «a (1).txt» si ya existía). */
    fun createFile(parent: List<String>, name: String): DocEntry
    fun createDir(parent: List<String>, name: String): DocEntry
    fun delete(parts: List<String>): Boolean
    fun rename(parts: List<String>, newName: String): DocEntry
    fun move(parts: List<String>, newParent: List<String>): DocEntry
    fun open(parts: List<String>, writable: Boolean): DocFile
}

object StorageLimits {
    /** Lo máximo que devuelve un storage.read (en bytes crudos; en base64 cabe en una línea). */
    const val READ_MAX = 49152

    /** Lo máximo que acepta un storage.write: una línea del protocolo mide como mucho 64 KiB y el base64 abulta un tercio más. */
    const val WRITE_MAX = 32768
    const val LIST_DEFAULT = 500
    const val LIST_MAX = 2000
    const val MAX_HANDLES = 64
    const val MAX_HANDLES_PER_OWNER = 16
}

object StoragePath {
    const val MAX_PATH = 4096
    const val MAX_NAME_BYTES = 255

    /**
     * Convierte «/Música/rock/» (o «Música//rock») en ["Música", "rock"]. Rechaza «..», los caracteres de control y los nombres
     * demasiado largos: nada de lo que llegue por el puente puede salirse del disco ni colar caracteres raros en un identificador.
     */
    fun parse(path: String?): List<String> {
        if (path == null) throw StorageException("bad_request", "Falta la ruta (path)")
        if (path.length > MAX_PATH) throw StorageException("bad_path", "La ruta es demasiado larga")
        val out = ArrayList<String>()
        for (seg in path.split('/')) {
            if (seg.isEmpty() || seg == ".") continue
            checkName(seg)
            out.add(seg)
        }
        return out
    }

    /** Un nombre suelto (el de un archivo o carpeta). */
    fun checkName(name: String) {
        if (name.isEmpty()) throw StorageException("bad_path", "Un nombre está vacío")
        if (name == "." || name == "..") throw StorageException("bad_path", "«$name» no se permite en una ruta")
        for (ch in name) {
            if (ch < ' ' || ch == '\u007f') throw StorageException("bad_path", "Un nombre lleva un carácter de control")
            if (ch == '/') throw StorageException("bad_path", "Un nombre no puede llevar «/»")
        }
        if (name.toByteArray(Charsets.UTF_8).size > MAX_NAME_BYTES) throw StorageException("bad_path", "Un nombre pasa de $MAX_NAME_BYTES bytes")
    }

    /** Los caracteres que Android cambia por «_» al crear o renombrar algo en un disco (FileUtils.buildValidFatFilename): FAT, exFAT y NTFS no los admiten. */
    const val BAD_NEW_CHARS = "\"*:<>?\\|"

    /**
     * El nombre de algo NUEVO (un archivo o carpeta que se crea, o el destino de un renombrado). Android sustituiría esos caracteres sin
     * avisar y el archivo acabaría llamándose otra cosa: mejor rechazarlo antes y decir por qué. Los nombres que YA existen (por ejemplo
     * en un disco ext4) se pueden leer, borrar y mover igualmente: esta comprobación no se aplica a ellos.
     */
    fun checkNewName(name: String) {
        for (ch in name) {
            if (BAD_NEW_CHARS.indexOf(ch) >= 0) {
                throw StorageException("bad_path", "Los discos USB no admiten el carácter «$ch» en un nombre nuevo: «$name» (usa otro nombre)")
            }
        }
        if (name.endsWith(".") || name.endsWith(" ")) {
            throw StorageException("bad_path", "Un nombre nuevo no puede acabar en punto ni en espacio: «$name»")
        }
    }

    /**
     * ¿Es `got` lo que Android hace con `wanted` cuando ya hay algo con ese nombre? Al crear añade « (1)» al final («a.txt (1)»); al
     * renombrar lo mete antes de la extensión («a (1).txt»).
     */
    fun isUniquified(wanted: String, got: String): Boolean {
        fun numbered(prefix: String, suffix: String): Boolean {
            if (!got.startsWith("$prefix (") || !got.endsWith(")$suffix") || got.length < prefix.length + 2 + suffix.length + 2) return false
            val mid = got.substring(prefix.length + 2, got.length - suffix.length - 1)
            return mid.isNotEmpty() && mid.all { it in '0'..'9' }
        }
        if (numbered(wanted, "")) return true
        val dot = wanted.lastIndexOf('.')
        return dot > 0 && numbered(wanted.substring(0, dot), wanted.substring(dot))
    }

    fun join(parts: List<String>): String = "/" + parts.joinToString("/")

    /** Identificador de documento de Android (ExternalStorageProvider): «UUID:ruta/relativa». La raíz de un disco es «UUID:». */
    fun docId(rootDocId: String, parts: List<String>): String {
        if (parts.isEmpty()) return rootDocId
        val tail = parts.joinToString("/")
        return if (rootDocId.endsWith(":") || rootDocId.endsWith("/")) rootDocId + tail else "$rootDocId/$tail"
    }

    /** «0123-4567:Música/rock» → ("0123-4567", "Música/rock"); null si no lleva «:». */
    fun splitDocId(docId: String?): Pair<String, String>? {
        if (docId == null) return null
        val i = docId.indexOf(':')
        if (i <= 0) return null
        return Pair(docId.substring(0, i), docId.substring(i + 1))
    }
}

/** Las reglas de las operaciones, sobre un DocFs. No guarda estado: se crea una por orden. */
class StorageOps(private val fs: DocFs) {
    class Page(val entries: List<DocEntry>, val total: Int, val offset: Int)

    private fun notFound(parts: List<String>) = StorageException("not_found", "No existe: " + StoragePath.join(parts))

    private fun needWritable() {
        if (fs.readOnly) throw StorageException("read_only", "El disco está en solo lectura")
    }

    /** Android guardó algo con otro nombre del pedido: «a (1).txt» si ya había uno igual, u otro si el disco no admite ese nombre. */
    private fun mismatch(wanted: List<String>, got: String): StorageException =
        if (StoragePath.isUniquified(wanted.last(), got)) StorageException("exists", "Ya existe: " + StoragePath.join(wanted))
        else StorageException("bad_path", "El disco no admite ese nombre: Android lo guardaría como «$got»")

    private fun checkParentDir(parent: List<String>) {
        if (parent.isEmpty()) return
        val e = fs.stat(parent) ?: throw notFound(parent)
        if (!e.dir) throw StorageException("not_dir", "No es una carpeta: " + StoragePath.join(parent))
    }

    fun stat(parts: List<String>): DocEntry {
        if (parts.isEmpty()) return DocEntry("", true, 0, 0, null, !fs.readOnly)
        return fs.stat(parts) ?: throw notFound(parts)
    }

    /** Una página de una carpeta: las carpetas primero y por nombre (sin distinguir mayúsculas), siempre en el mismo orden. */
    fun list(parts: List<String>, offset: Int, limit: Int): Page {
        if (parts.isNotEmpty()) {
            val e = fs.stat(parts) ?: throw notFound(parts)
            if (!e.dir) throw StorageException("not_dir", "No es una carpeta: " + StoragePath.join(parts))
        }
        val all = fs.list(parts) ?: throw notFound(parts)
        val sorted = all.sortedWith(compareBy<DocEntry>({ !it.dir }, { it.name.lowercase() }, { it.name }))
        val off = offset.coerceAtLeast(0)
        val lim = limit.coerceIn(1, StorageLimits.LIST_MAX)
        return Page(sorted.drop(off).take(lim), sorted.size, off)
    }

    /**
     * Abre un archivo. `create` y `truncate` solo cuentan si es de escritura; `exclusive` falla si ya existe.
     * Para crear, la carpeta de arriba tiene que existir.
     */
    fun open(parts: List<String>, write: Boolean, create: Boolean, truncate: Boolean, exclusive: Boolean): DocFile {
        if (parts.isEmpty()) throw StorageException("is_dir", "La raíz del disco es una carpeta")
        if (write) needWritable()
        val e = fs.stat(parts)
        if (e != null && e.dir) throw StorageException("is_dir", "Es una carpeta: " + StoragePath.join(parts))
        if (e != null && write && exclusive) throw StorageException("exists", "Ya existe: " + StoragePath.join(parts))
        if (e == null) {
            if (!write || !create) throw notFound(parts)
            val parent = parts.dropLast(1)
            checkParentDir(parent)
            StoragePath.checkNewName(parts.last())
            val made = fs.createFile(parent, parts.last())
            if (made.name != parts.last()) {
                // Android le puso otro nombre (ya había uno igual, p. ej. «A.TXT» y «a.txt» en FAT, o el disco no admite ese nombre): se deshace.
                try {
                    fs.delete(parent + made.name)
                } catch (_: Exception) {
                }
                throw mismatch(parts, made.name)
            }
        } else if (write && !e.writable) {
            throw StorageException("read_only", "No se puede escribir en: " + StoragePath.join(parts))
        }
        val f = fs.open(parts, write)
        if (write && truncate) {
            try {
                f.truncate(0)
            } catch (t: Throwable) {
                try {
                    f.close()
                } catch (_: Exception) {
                }
                throw t
            }
        }
        return f
    }

    fun mkdir(parts: List<String>, parents: Boolean) {
        needWritable()
        if (parts.isEmpty()) {
            if (parents) return
            throw StorageException("exists", "La raíz del disco ya existe")
        }
        val e = fs.stat(parts)
        if (e != null) {
            if (e.dir && parents) return
            throw StorageException("exists", "Ya existe: " + StoragePath.join(parts))
        }
        val parent = parts.dropLast(1)
        if (parent.isNotEmpty()) {
            val pe = fs.stat(parent)
            if (pe == null) {
                if (!parents) throw notFound(parent)
                // Antes de crear nada, que ningún nivel nuevo lleve un nombre que el disco no admita (si no, quedaría la mitad hecha).
                var first = parts.size - 1
                while (first > 0 && fs.stat(parts.subList(0, first)) == null) first--
                for (i in first until parts.size) StoragePath.checkNewName(parts[i])
                mkdir(parent, true)
            } else if (!pe.dir) {
                throw StorageException("not_dir", "No es una carpeta: " + StoragePath.join(parent))
            }
        }
        StoragePath.checkNewName(parts.last())
        val made = fs.createDir(parent, parts.last())
        if (made.name != parts.last()) {
            try {
                fs.delete(parent + made.name)
            } catch (_: Exception) {
            }
            throw mismatch(parts, made.name)
        }
    }

    /**
     * Borra un archivo o una carpeta VACÍA. Nunca de forma recursiva: Android borra las carpetas enteras sin avisar, así que aquí se
     * comprueba antes; quien quiera borrar un árbol lo recorre (nexo usb rm -r) y cada paso es una orden corta.
     */
    fun delete(parts: List<String>) {
        needWritable()
        if (parts.isEmpty()) throw StorageException("bad_path", "La raíz del disco no se borra")
        val e = fs.stat(parts) ?: throw notFound(parts)
        if (e.dir) {
            val kids = fs.list(parts) ?: throw StorageException("io_error", "No se pudo leer la carpeta: " + StoragePath.join(parts))
            if (kids.isNotEmpty()) throw StorageException("not_empty", "La carpeta no está vacía: " + StoragePath.join(parts))
        }
        if (!fs.delete(parts)) throw StorageException("io_error", "Android no pudo borrar: " + StoragePath.join(parts))
    }

    /** Renombra o mueve DENTRO del mismo disco. Con `overwrite` sustituye lo que haya (un archivo, o una carpeta vacía). */
    fun rename(from: List<String>, to: List<String>, overwrite: Boolean) {
        needWritable()
        if (from.isEmpty() || to.isEmpty()) throw StorageException("bad_path", "La raíz del disco no se mueve ni se sustituye")
        if (from == to) return
        if (to.size > from.size && to.subList(0, from.size) == from) {
            throw StorageException("bad_path", "No se puede mover una carpeta dentro de sí misma")
        }
        StoragePath.checkNewName(to.last())
        val src = fs.stat(from) ?: throw notFound(from)
        val dst = fs.stat(to)
        if (dst != null) {
            // Mismo objeto con otras mayúsculas (FAT no las distingue): es un renombrado normal.
            val sameEntry = from.dropLast(1) == to.dropLast(1) && from.last().equals(to.last(), ignoreCase = true)
            if (!sameEntry) {
                if (!overwrite) throw StorageException("exists", "Ya existe: " + StoragePath.join(to))
                if (dst.dir && !src.dir) throw StorageException("is_dir", "El destino es una carpeta: " + StoragePath.join(to))
                if (!dst.dir && src.dir) throw StorageException("not_dir", "El destino es un archivo: " + StoragePath.join(to))
                delete(to)
            }
        }
        val toParent = to.dropLast(1)
        checkParentDir(toParent)
        val name = to.last()
        if (from.dropLast(1) == toParent) {
            val r = fs.rename(from, name)
            if (r.name != name) {
                // Android le puso otro nombre (ya había uno igual, o el disco no admite ese): se devuelve el original y se avisa.
                try {
                    fs.rename(toParent + r.name, from.last())
                } catch (_: Exception) {
                }
                throw mismatch(to, r.name)
            }
        } else {
            moveAndRename(from, toParent, name, to)
        }
    }

    /**
     * Mover a otra carpeta Y cambiar el nombre. Android mueve conservando el nombre y renombra por separado, y cualquiera de los dos pasos
     * puede chocar con algo que ya haya (el nombre nuevo en la carpeta de origen, o el viejo en la de destino): se elige el orden que no
     * choca y, si los dos chocan, se avisa antes de tocar nada. Si el segundo paso falla, se intenta dejar el primero deshecho.
     */
    private fun moveAndRename(from: List<String>, toParent: List<String>, name: String, to: List<String>) {
        val old = from.last()
        val fromParent = from.dropLast(1)
        if (old == name) {
            val m = fs.move(from, toParent)
            if (m.name != name) throw mismatch(to, m.name)
            return
        }
        if (fs.stat(fromParent + name) == null) {
            // 1.º se renombra en su carpeta, 2.º se mueve ya con el nombre final.
            val r = fs.rename(from, name)
            if (r.name != name) {
                try {
                    fs.rename(fromParent + r.name, old)
                } catch (_: Exception) {
                }
                throw mismatch(to, r.name)
            }
            try {
                val m = fs.move(fromParent + name, toParent)
                if (m.name != name) throw mismatch(to, m.name)
            } catch (t: Throwable) {
                try {
                    fs.rename(fromParent + name, old)
                } catch (_: Exception) {
                }
                throw t
            }
        } else if (fs.stat(toParent + old) == null) {
            // 1.º se mueve con el nombre viejo, 2.º se renombra en su sitio nuevo.
            val m = fs.move(from, toParent)
            try {
                val r = fs.rename(toParent + m.name, name)
                if (r.name != name) {
                    try {
                        fs.rename(toParent + r.name, m.name)
                    } catch (_: Exception) {
                    }
                    throw mismatch(to, r.name)
                }
            } catch (t: Throwable) {
                try {
                    fs.move(toParent + m.name, fromParent)
                } catch (_: Exception) {
                }
                throw t
            }
        } else {
            throw StorageException(
                "exists",
                "Hay otro «$name» en la carpeta de origen y otro «$old» en la de destino: renombra primero uno de los dos"
            )
        }
    }
}

/** Un archivo abierto por un cliente. `owner` es la conexión que lo abrió: al cerrarse, se cierra con ella. */
class OpenFile(
    val id: String,
    val volume: String,
    val path: String,
    val file: DocFile,
    val writable: Boolean,
    val owner: Any?,
) {
    @Volatile
    var rx = 0L

    @Volatile
    var tx = 0L
}

/** La tabla de archivos abiertos: con tope total y por conexión, para que un cliente descuidado no agote los descriptores de Android. */
class HandleTable(
    private val maxTotal: Int = StorageLimits.MAX_HANDLES,
    private val maxPerOwner: Int = StorageLimits.MAX_HANDLES_PER_OWNER,
) {
    private val lock = Any()
    private val map = LinkedHashMap<String, OpenFile>()
    private val seq = AtomicInteger(1)

    fun add(volume: String, path: String, file: DocFile, writable: Boolean, owner: Any?): OpenFile {
        synchronized(lock) {
            val full = map.size >= maxTotal || (owner != null && map.values.count { it.owner === owner } >= maxPerOwner)
            if (!full) {
                val h = OpenFile("h" + seq.getAndIncrement(), volume, path, file, writable, owner)
                map[h.id] = h
                return h
            }
        }
        try {
            file.close()
        } catch (_: Exception) {
        }
        throw StorageException("limit", "Demasiados archivos abiertos a la vez")
    }

    fun get(id: String?): OpenFile = synchronized(lock) { map[id] } ?: throw StorageException("not_found", "Ese archivo ya no está abierto")

    /** Cierra un archivo (vaciándolo al disco antes si era de escritura). Si el vaciado falla, el archivo se cierra igual y el fallo se propaga. */
    fun close(id: String?): Boolean {
        val h = synchronized(lock) { map.remove(id) } ?: return false
        finish(h)
        return true
    }

    /** Cierra los que cumplan la condición, sin propagar fallos (se usa al desconectarse un cliente o al expulsar un disco). */
    fun closeWhere(pred: (OpenFile) -> Boolean): Int {
        val gone = synchronized(lock) {
            val l = map.values.filter(pred)
            for (h in l) map.remove(h.id)
            l
        }
        for (h in gone) {
            try {
                finish(h)
            } catch (_: Exception) {
            }
        }
        return gone.size
    }

    fun forOwner(owner: Any?): Int = closeWhere { it.owner === owner }

    fun forVolume(volume: String): Int = closeWhere { it.volume.equals(volume, ignoreCase = true) }

    fun count(volume: String? = null): Int = synchronized(lock) {
        if (volume == null) map.size else map.values.count { it.volume.equals(volume, ignoreCase = true) }
    }

    /** Vacía al disco todo lo abierto de ese volumen sin cerrarlo. Devuelve cuántos archivos eran de escritura. */
    fun syncVolume(volume: String): Int {
        val l = synchronized(lock) { map.values.filter { it.writable && it.volume.equals(volume, ignoreCase = true) } }
        for (h in l) h.file.sync()
        return l.size
    }

    private fun finish(h: OpenFile) {
        try {
            if (h.writable) h.file.sync()
        } finally {
            h.file.close()
        }
    }
}

/** Qué volumen quiere decir el cliente: su UUID (sin distinguir mayúsculas) o, si es único, su etiqueta. */
object StorageSelect {
    fun <T> pick(items: List<T>, key: String?, uuidOf: (T) -> String, labelOf: (T) -> String): T {
        val k = key?.trim().orEmpty()
        if (k.isEmpty()) throw StorageException("bad_request", "Falta el volumen (volume)")
        items.firstOrNull { uuidOf(it).equals(k, ignoreCase = true) }?.let { return it }
        val byLabel = items.filter { labelOf(it).equals(k, ignoreCase = true) }
        if (byLabel.size == 1) return byLabel[0]
        if (byLabel.size > 1) throw StorageException("bad_request", "Hay varios discos que se llaman «$k»: usa su UUID")
        throw StorageException("not_found", "No hay ningún disco «$k»")
    }

    /** De varias carpetas autorizadas de un mismo disco se usa la más alta (la más corta); a igual altura, la primera. */
    fun <T> bestScope(items: List<T>, scopeOf: (T) -> String): T? =
        items.minWithOrNull(compareBy { scopeOf(it).split('/').count { s -> s.isNotEmpty() } })
}
