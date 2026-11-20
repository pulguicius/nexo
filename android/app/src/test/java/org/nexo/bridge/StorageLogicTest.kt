package org.nexo.bridge

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Pruebas en JVM (sin Android) de StorageLogic.kt: rutas, reglas de las operaciones sobre un disco y la tabla de archivos abiertos.
 * El «disco» es un árbol en memoria que imita lo que hace de verdad Android (ExternalStorageProvider): al crear o renombrar a un nombre
 * que ya existe le añade « (1)», FAT no distingue mayúsculas y un disco en solo lectura no deja escribir.
 * Lo que NO prueba: la conversación con Android (StorageSaf.kt), que solo se ha comprobado que compila (docs/USB-ALMACENAMIENTO.md).
 */
class StorageLogicTest {

    // ------------------------------------------------------------------------------------------ un disco en memoria

    private class Node(var name: String, val dir: Boolean) {
        val kids = LinkedHashMap<String, Node>()
        var data = ByteArray(0)
        var mtime = 1_700_000_000_000L
    }

    private class MemFile(val node: Node, val writable: Boolean, val log: MutableList<String>) : DocFile {
        var closed = false
        var failSync = false
        override fun size(): Long = node.data.size.toLong()
        override fun read(pos: Long, buf: ByteArray, off: Int, len: Int): Int {
            if (closed) throw StorageException("io_error", "cerrado")
            if (pos >= node.data.size) return 0
            val n = minOf(len.toLong(), node.data.size - pos).toInt()
            System.arraycopy(node.data, pos.toInt(), buf, off, n)
            return n
        }

        override fun write(pos: Long, buf: ByteArray, off: Int, len: Int): Int {
            if (closed) throw StorageException("io_error", "cerrado")
            if (!writable) throw StorageException("read_only", "solo lectura")
            val end = (pos + len).toInt()
            if (end > node.data.size) node.data = node.data.copyOf(end)
            System.arraycopy(buf, off, node.data, pos.toInt(), len)
            return len
        }

        override fun truncate(len: Long) {
            node.data = node.data.copyOf(len.toInt())
        }

        override fun sync() {
            log.add("sync " + node.name)
            if (failSync) throw StorageException("io_error", "fallo al vaciar")
        }

        override fun close() {
            log.add("close " + node.name)
            closed = true
        }
    }

    private class MemoryDocFs(
        override val readOnly: Boolean = false,
        private val caseInsensitive: Boolean = false,
        private val uniquify: Boolean = true,
    ) : DocFs {
        val root = Node("", true)
        val log = ArrayList<String>()
        val opened = ArrayList<MemFile>()

        private fun key(n: String) = if (caseInsensitive) n.lowercase() else n

        fun node(parts: List<String>): Node? {
            var cur = root
            for (p in parts) cur = (if (!cur.dir) null else cur.kids[key(p)]) ?: return null
            return cur
        }

        private fun entry(n: Node) = DocEntry(n.name, n.dir, if (n.dir) 0L else n.data.size.toLong(), n.mtime, if (n.dir) null else "application/octet-stream", !readOnly)

        fun put(path: String, text: String? = null) {
            var cur = root
            val parts = path.trim('/').split('/')
            for ((i, p) in parts.withIndex()) {
                val last = i == parts.size - 1
                val isDir = !last || text == null
                cur = cur.kids.getOrPut(key(p)) { Node(p, isDir) }
            }
            if (text != null) cur.data = text.toByteArray()
        }

        override fun stat(parts: List<String>): DocEntry? = node(parts)?.let { entry(it) }
        override fun list(parts: List<String>): List<DocEntry>? = node(parts)?.takeIf { it.dir }?.kids?.values?.map { entry(it) }

        private fun unique(parent: Node, name: String): String {
            if (!uniquify || parent.kids[key(name)] == null) return name
            val dot = name.lastIndexOf('.')
            val stem = if (dot > 0) name.substring(0, dot) else name
            val ext = if (dot > 0) name.substring(dot) else ""
            var i = 1
            while (parent.kids[key("$stem ($i)$ext")] != null) i++
            return "$stem ($i)$ext"
        }

        private fun make(parent: List<String>, name: String, dir: Boolean): DocEntry {
            if (readOnly) throw StorageException("io_error", "solo lectura")
            val p = node(parent) ?: throw StorageException("io_error", "no hay carpeta")
            val real = unique(p, name)
            if (p.kids[key(real)] != null) throw StorageException("io_error", "ya existe")
            val n = Node(real, dir)
            p.kids[key(real)] = n
            return entry(n)
        }

        override fun createFile(parent: List<String>, name: String) = make(parent, name, false)
        override fun createDir(parent: List<String>, name: String) = make(parent, name, true)

        override fun delete(parts: List<String>): Boolean {
            val p = node(parts.dropLast(1)) ?: return false
            return p.kids.remove(key(parts.last())) != null
        }

        override fun rename(parts: List<String>, newName: String): DocEntry {
            val p = node(parts.dropLast(1)) ?: throw StorageException("io_error", "no hay carpeta")
            val n = p.kids.remove(key(parts.last())) ?: throw StorageException("io_error", "no existe")
            val real = unique(p, newName)
            n.name = real
            p.kids[key(real)] = n
            return entry(n)
        }

        override fun move(parts: List<String>, newParent: List<String>): DocEntry {
            val from = node(parts.dropLast(1)) ?: throw StorageException("io_error", "no hay carpeta")
            val to = node(newParent) ?: throw StorageException("io_error", "no hay destino")
            val n = from.kids[key(parts.last())] ?: throw StorageException("io_error", "no existe")
            if (to.kids[key(n.name)] != null) throw StorageException("io_error", "ya existe en el destino")
            from.kids.remove(key(parts.last()))
            to.kids[key(n.name)] = n
            return entry(n)
        }

        override fun open(parts: List<String>, writable: Boolean): DocFile {
            val n = node(parts) ?: throw StorageException("not_found", "no existe")
            val f = MemFile(n, writable, log)
            opened.add(f)
            return f
        }
    }

    private fun code(block: () -> Unit): String {
        try {
            block()
        } catch (e: StorageException) {
            return e.code
        }
        fail("tenía que fallar con una StorageException")
        return ""
    }

    private fun p(path: String) = StoragePath.parse(path)

    // ------------------------------------------------------------------------------------------ rutas

    @Test
    fun parseNormalizaRutas() {
        assertEquals(emptyList<String>(), p("/"))
        assertEquals(emptyList<String>(), p(""))
        assertEquals(listOf("a", "b"), p("a/b"))
        assertEquals(listOf("a", "b"), p("//a///b/"))
        assertEquals(listOf("a", "b"), p("./a/./b"))
        assertEquals(listOf("Música", "日本語", "a b.txt"), p("/Música/日本語/a b.txt"))
        assertEquals(listOf("a\\b"), p("a\\b")) // la barra invertida es un carácter más: no separa
    }

    @Test
    fun parseRechazaLoPeligroso() {
        assertEquals("bad_path", code { p("a/../b") })
        assertEquals("bad_path", code { p("..") })
        assertEquals("bad_path", code { p("/../../etc/passwd") })
        assertEquals("bad_path", code { p("a/b\u0000c") })
        assertEquals("bad_path", code { p("a\nb") })
        assertEquals("bad_path", code { p("a\tb") })
        assertEquals("bad_path", code { p("a\u007fb") })
        assertEquals("bad_request", code { StoragePath.parse(null) })
        assertEquals("bad_path", code { p("x".repeat(StoragePath.MAX_PATH + 1)) })
    }

    @Test
    fun parseLimitaElNombreEnBytesNoEnLetras() {
        p("e".repeat(255))
        assertEquals("bad_path", code { p("e".repeat(256)) })
        p("é".repeat(127)) // 254 bytes
        assertEquals("bad_path", code { p("é".repeat(128)) }) // 256 bytes
        p("日".repeat(85)) // 255 bytes
        assertEquals("bad_path", code { p("日".repeat(86)) })
    }

    @Test
    fun checkNameYJoin() {
        StoragePath.checkName("a.txt")
        assertEquals("bad_path", code { StoragePath.checkName("") })
        assertEquals("bad_path", code { StoragePath.checkName(".") })
        assertEquals("bad_path", code { StoragePath.checkName("..") })
        assertEquals("bad_path", code { StoragePath.checkName("a/b") })
        assertEquals("/", StoragePath.join(emptyList()))
        assertEquals("/a/b", StoragePath.join(listOf("a", "b")))
    }

    @Test
    fun identificadoresDeDocumento() {
        assertEquals("0123-4567:", StoragePath.docId("0123-4567:", emptyList()))
        assertEquals("0123-4567:a/b", StoragePath.docId("0123-4567:", listOf("a", "b")))
        assertEquals("0123-4567:Music/a.mp3", StoragePath.docId("0123-4567:Music", listOf("a.mp3")))
        assertEquals("0123-4567:Music", StoragePath.docId("0123-4567:Music", emptyList()))
        assertEquals(Pair("0123-4567", "Música/rock"), StoragePath.splitDocId("0123-4567:Música/rock"))
        assertEquals(Pair("0123-4567", ""), StoragePath.splitDocId("0123-4567:"))
        assertEquals(Pair("a", "b:c"), StoragePath.splitDocId("a:b:c"))
        assertNull(StoragePath.splitDocId("sin-dos-puntos"))
        assertNull(StoragePath.splitDocId(":x"))
        assertNull(StoragePath.splitDocId(null))
    }

    // ------------------------------------------------------------------------------------------ stat y list

    @Test
    fun statYList() {
        val fs = MemoryDocFs()
        fs.put("Zeta/x.txt", "x")
        fs.put("alfa/y.txt", "yy")
        fs.put("Beta.txt", "bbb")
        fs.put("beta2.txt", "b")
        fs.put("A.txt", "")
        val ops = StorageOps(fs)
        assertTrue(ops.stat(emptyList()).dir)
        assertEquals(3L, ops.stat(p("Beta.txt")).size)
        assertEquals("not_found", code { ops.stat(p("nada")) })
        val page = ops.list(emptyList(), 0, 100)
        // las carpetas primero y por nombre sin distinguir mayúsculas
        assertEquals(listOf("alfa", "Zeta", "A.txt", "Beta.txt", "beta2.txt"), page.entries.map { it.name })
        assertEquals(5, page.total)
        assertEquals(listOf("A.txt", "Beta.txt"), ops.list(emptyList(), 2, 2).entries.map { it.name })
        assertEquals(5, ops.list(emptyList(), 2, 2).total)
        assertEquals(2, ops.list(emptyList(), 0, 2).entries.size)
        assertEquals(1, ops.list(emptyList(), 0, 0).entries.size) // el límite mínimo es 1
        assertEquals(0, ops.list(emptyList(), 50, 10).entries.size)
        assertEquals(0, ops.list(emptyList(), -5, 10).offset) // un offset negativo cuenta como 0
        assertEquals("not_dir", code { ops.list(p("Beta.txt"), 0, 10) })
        assertEquals("not_found", code { ops.list(p("nada"), 0, 10) })
        assertEquals(listOf("x.txt"), ops.list(p("Zeta"), 0, 10).entries.map { it.name })
    }

    @Test
    fun listaGrandePaginada() {
        val fs = MemoryDocFs()
        for (i in 0 until 1234) fs.put("d/f%04d.bin".format(i), "")
        val ops = StorageOps(fs)
        val seen = ArrayList<String>()
        var off = 0
        while (true) {
            val pg = ops.list(p("d"), off, 500)
            seen.addAll(pg.entries.map { it.name })
            off += pg.entries.size
            if (off >= pg.total) break
        }
        assertEquals(1234, seen.size)
        assertEquals(seen.sorted(), seen)
        assertEquals(seen.toSet().size, seen.size)
    }

    // ------------------------------------------------------------------------------------------ open

    @Test
    fun abrirParaLeer() {
        val fs = MemoryDocFs()
        fs.put("a/b.txt", "hola")
        val ops = StorageOps(fs)
        val f = ops.open(p("a/b.txt"), write = false, create = false, truncate = false, exclusive = false)
        val buf = ByteArray(10)
        assertEquals(4, f.read(0, buf, 0, 10))
        assertEquals("hola", String(buf, 0, 4))
        assertEquals(2, f.read(2, buf, 0, 10))
        assertEquals(0, f.read(4, buf, 0, 10))
        assertEquals("not_found", code { ops.open(p("a/nada.txt"), false, false, false, false) })
        assertEquals("is_dir", code { ops.open(p("a"), false, false, false, false) })
        assertEquals("is_dir", code { ops.open(emptyList(), false, false, false, false) })
        // crear no cuenta si es de lectura
        assertEquals("not_found", code { ops.open(p("a/nuevo"), write = false, create = true, truncate = false, exclusive = false) })
    }

    @Test
    fun abrirParaEscribir() {
        val fs = MemoryDocFs()
        fs.put("a/b.txt", "hola mundo")
        val ops = StorageOps(fs)
        // sin create no se crea
        assertEquals("not_found", code { ops.open(p("a/n.txt"), true, false, false, false) })
        // crear
        val f = ops.open(p("a/n.txt"), true, true, true, false)
        f.write(0, "abc".toByteArray(), 0, 3)
        assertEquals("abc", String(fs.node(p("a/n.txt"))!!.data))
        // exclusivo falla si existe
        assertEquals("exists", code { ops.open(p("a/b.txt"), true, true, false, true) })
        // sin truncar se conserva (y se puede escribir al final)
        val g = ops.open(p("a/b.txt"), true, false, false, false)
        assertEquals(10L, g.size())
        g.write(10, "!".toByteArray(), 0, 1)
        assertEquals("hola mundo!", String(fs.node(p("a/b.txt"))!!.data))
        // truncar vacía
        ops.open(p("a/b.txt"), true, false, true, false)
        assertEquals(0, fs.node(p("a/b.txt"))!!.data.size)
        // la carpeta de arriba tiene que existir y ser carpeta
        assertEquals("not_found", code { ops.open(p("zzz/n.txt"), true, true, true, false) })
        assertEquals("not_dir", code { ops.open(p("a/b.txt/n.txt"), true, true, true, false) })
    }

    @Test
    fun androidLePoneOtroNombreYSeDeshace() {
        // FAT: «A.TXT» y «a.txt» son el mismo archivo. Android crearía «a (1).txt»: Nexo lo borra y avisa en vez de escribir en el equivocado.
        val fs = MemoryDocFs(caseInsensitive = false, uniquify = true)
        fs.put("A.TXT", "viejo")
        val ops = StorageOps(fs)
        // stat de «a.txt» no lo ve (distingue mayúsculas): se intenta crear y Android lo llama «a.txt» (no existe): vale
        ops.open(p("a.txt"), true, true, true, false)
        // ahora sí existe «a.txt»: un create exclusivo choca
        assertEquals("exists", code { ops.open(p("a.txt"), true, true, true, true) })

        // Un sistema que dice que no existe pero luego uniquifica: lo simulamos con un DocFs que miente en stat
        class Liar : DocFs by MemoryDocFs() {
            val inner = MemoryDocFs().also { it.put("a.txt", "x") }
            override fun stat(parts: List<String>): DocEntry? = if (parts == listOf("a.txt")) null else inner.stat(parts)
            override fun createFile(parent: List<String>, name: String): DocEntry = inner.createFile(parent, name)
            override fun delete(parts: List<String>): Boolean = inner.delete(parts)
        }
        val liar = Liar()
        assertEquals("exists", code { StorageOps(liar).open(p("a.txt"), true, true, true, false) })
        assertNull(liar.inner.node(p("a (1).txt"))) // no quedó el archivo sobrante
        assertNotNull(liar.inner.node(p("a.txt")))
    }

    @Test
    fun soloLecturaNoDejaEscribir() {
        val fs = MemoryDocFs(readOnly = true)
        fs.put("a/b.txt", "x")
        val ops = StorageOps(fs)
        ops.open(p("a/b.txt"), false, false, false, false).close()
        assertEquals("read_only", code { ops.open(p("a/b.txt"), true, false, false, false) })
        assertEquals("read_only", code { ops.open(p("a/n.txt"), true, true, true, false) })
        assertEquals("read_only", code { ops.mkdir(p("c"), false) })
        assertEquals("read_only", code { ops.delete(p("a/b.txt")) })
        assertEquals("read_only", code { ops.rename(p("a/b.txt"), p("a/c.txt"), false) })
        assertFalse(ops.stat(emptyList()).writable)
    }

    // ------------------------------------------------------------------------------------------ mkdir

    @Test
    fun mkdir() {
        val fs = MemoryDocFs()
        fs.put("a/f.txt", "x")
        val ops = StorageOps(fs)
        ops.mkdir(p("a/b"), false)
        assertTrue(fs.node(p("a/b"))!!.dir)
        assertEquals("exists", code { ops.mkdir(p("a/b"), false) })
        ops.mkdir(p("a/b"), true) // -p: si ya es una carpeta, vale
        assertEquals("exists", code { ops.mkdir(p("a/f.txt"), true) }) // pero un archivo no es una carpeta
        assertEquals("not_found", code { ops.mkdir(p("x/y/z"), false) })
        ops.mkdir(p("x/y/z"), true)
        assertTrue(fs.node(p("x/y/z"))!!.dir)
        assertEquals("not_dir", code { ops.mkdir(p("a/f.txt/z"), true) })
        assertEquals("not_dir", code { ops.mkdir(p("a/f.txt/z"), false) })
        assertEquals("exists", code { ops.mkdir(emptyList(), false) })
        ops.mkdir(emptyList(), true)
    }

    @Test
    fun mkdirSiAndroidLeCambiaElNombre() {
        val fs = MemoryDocFs(caseInsensitive = false)
        // «Música» existe como archivo; crear la carpeta «Música» lo evita porque stat la ve: aquí simulamos que no la ve
        class Liar : DocFs by MemoryDocFs() {
            val inner = MemoryDocFs().also { it.put("d") }
            override fun stat(parts: List<String>): DocEntry? = if (parts == listOf("d")) null else inner.stat(parts)
            override fun createDir(parent: List<String>, name: String): DocEntry = inner.createDir(parent, name)
            override fun delete(parts: List<String>): Boolean = inner.delete(parts)
        }
        val liar = Liar()
        assertEquals("exists", code { StorageOps(liar).mkdir(p("d"), false) })
        assertNull(liar.inner.node(p("d (1)")))
        assertNotNull(fs)
    }

    // ------------------------------------------------------------------------------------------ delete

    @Test
    fun borrarNuncaEsRecursivo() {
        val fs = MemoryDocFs()
        fs.put("a/b/c.txt", "x")
        fs.put("a/d.txt", "y")
        fs.put("vacia")
        val ops = StorageOps(fs)
        assertEquals("not_empty", code { ops.delete(p("a")) })
        assertEquals("not_empty", code { ops.delete(p("a/b")) })
        assertNotNull(fs.node(p("a/b/c.txt"))) // no se borró nada
        ops.delete(p("vacia"))
        assertNull(fs.node(p("vacia")))
        ops.delete(p("a/b/c.txt"))
        ops.delete(p("a/b"))
        assertNull(fs.node(p("a/b")))
        assertEquals("not_found", code { ops.delete(p("a/b")) })
        assertEquals("bad_path", code { ops.delete(emptyList()) })
    }

    // ------------------------------------------------------------------------------------------ rename

    @Test
    fun renombrarYMover() {
        val fs = MemoryDocFs()
        fs.put("a/f.txt", "uno")
        fs.put("b")
        fs.put("c/d/g.txt", "dos")
        val ops = StorageOps(fs)
        ops.rename(p("a/f.txt"), p("a/h.txt"), false)
        assertNull(fs.node(p("a/f.txt")))
        assertEquals("uno", String(fs.node(p("a/h.txt"))!!.data))
        ops.rename(p("a/h.txt"), p("b/h.txt"), false) // mover
        assertEquals("uno", String(fs.node(p("b/h.txt"))!!.data))
        ops.rename(p("b/h.txt"), p("c/otro.txt"), false) // mover y cambiar el nombre
        assertEquals("uno", String(fs.node(p("c/otro.txt"))!!.data))
        ops.rename(p("c/d"), p("b/d2"), false) // una carpeta con su contenido
        assertEquals("dos", String(fs.node(p("b/d2/g.txt"))!!.data))
        ops.rename(p("b/d2"), p("b/d2"), false) // mismo sitio: nada
        assertNotNull(fs.node(p("b/d2")))
    }

    @Test
    fun renombrarConflictos() {
        val fs = MemoryDocFs()
        fs.put("f.txt", "f")
        fs.put("g.txt", "g")
        fs.put("d")
        fs.put("e/x.txt", "x")
        fs.put("vacia")
        val ops = StorageOps(fs)
        assertEquals("exists", code { ops.rename(p("f.txt"), p("g.txt"), false) })
        assertEquals("f", String(fs.node(p("f.txt"))!!.data)) // no se tocó nada
        ops.rename(p("f.txt"), p("g.txt"), true) // sustituir
        assertEquals("f", String(fs.node(p("g.txt"))!!.data))
        assertNull(fs.node(p("f.txt")))
        assertEquals("is_dir", code { ops.rename(p("g.txt"), p("d"), true) }) // un archivo no sustituye a una carpeta
        assertEquals("not_dir", code { ops.rename(p("d"), p("g.txt"), true) }) // ni al revés
        assertEquals("not_empty", code { ops.rename(p("vacia"), p("e"), true) }) // ni una carpeta a otra con cosas
        ops.rename(p("e"), p("vacia"), true) // sí a una vacía
        assertEquals("x", String(fs.node(p("vacia/x.txt"))!!.data))
        assertEquals("not_found", code { ops.rename(p("nada"), p("otro"), false) })
        assertEquals("not_found", code { ops.rename(p("g.txt"), p("zzz/g.txt"), false) })
        assertEquals("not_dir", code { ops.rename(p("g.txt"), p("vacia/x.txt/y"), false) })
        assertEquals("bad_path", code { ops.rename(emptyList(), p("x"), false) })
        assertEquals("bad_path", code { ops.rename(p("g.txt"), emptyList(), true) })
    }

    @Test
    fun noSeMueveUnaCarpetaDentroDeSiMisma() {
        val fs = MemoryDocFs()
        fs.put("a/b/c")
        val ops = StorageOps(fs)
        assertEquals("bad_path", code { ops.rename(p("a"), p("a/b/x"), false) })
        assertEquals("bad_path", code { ops.rename(p("a"), p("a/x"), true) })
        assertNotNull(fs.node(p("a/b/c")))
        // pero «a» y «ab» no son «dentro»
        fs.put("ab")
        ops.rename(p("a"), p("ab/a"), false)
        assertNotNull(fs.node(p("ab/a/b/c")))
    }

    @Test
    fun renombrarSoloMayusculasEnFat() {
        val fs = MemoryDocFs(caseInsensitive = true, uniquify = false)
        fs.put("foto.jpg", "x")
        val ops = StorageOps(fs)
        ops.rename(p("foto.jpg"), p("FOTO.JPG"), false) // es el mismo objeto: no es un conflicto
        assertEquals("FOTO.JPG", fs.node(p("foto.jpg"))!!.name)
        fs.put("otra.jpg", "y")
        assertEquals("exists", code { ops.rename(p("otra.jpg"), p("FOTO.jpg"), false) })
    }

    @Test
    fun androidLePoneOtroNombreAlRenombrar() {
        // Un sistema que miente en stat («b.txt» no existe) pero luego lo renombra a «b (1).txt» porque sí existe: se deshace y se avisa.
        class Liar : DocFs by MemoryDocFs() {
            val inner = MemoryDocFs().also {
                it.put("a.txt", "a")
                it.put("b.txt", "b")
            }

            override fun stat(parts: List<String>): DocEntry? = if (parts == listOf("b.txt")) null else inner.stat(parts)
            override fun rename(parts: List<String>, newName: String): DocEntry = inner.rename(parts, newName)
        }
        val liar = Liar()
        assertEquals("exists", code { StorageOps(liar).rename(p("a.txt"), p("b.txt"), false) })
        assertEquals("a", String(liar.inner.node(p("a.txt"))!!.data)) // volvió a llamarse como antes
        assertEquals("b", String(liar.inner.node(p("b.txt"))!!.data)) // y el otro no se tocó
        assertNull(liar.inner.node(p("b (1).txt")))

        // Mover a otra carpeta cambiando el nombre
        val fs = MemoryDocFs()
        fs.put("a.txt", "a")
        fs.put("d")
        StorageOps(fs).rename(p("a.txt"), p("d/z.txt"), false)
        assertEquals("a", String(fs.node(p("d/z.txt"))!!.data))
        assertNull(fs.node(p("a.txt")))
    }


    // ------------------------------------------------------------------------------------------ nombres que el disco no admite

    @Test
    fun nombresNuevosQueElDiscoNoAdmite() {
        for (bad in listOf("a:b", "x?", "\"q\"", "a<b", "a>b", "a|b", "a\\b", "m*", "fin.", "fin ", "12:30:00 copia.tar")) {
            assertEquals(bad, "bad_path", code { StoragePath.checkNewName(bad) })
        }
        for (ok in listOf("a b.txt", "ñandú ü.txt", "(1).txt", "a-b_c.d", ".oculto", "a.b.c", "100%", "a&b", "a;b", "a#b", "[x]")) {
            StoragePath.checkNewName(ok) // no lanza
        }
    }

    @Test
    fun crearConUnNombreMalo() {
        val fs = MemoryDocFs()
        fs.put("d")
        val ops = StorageOps(fs)
        assertEquals("bad_path", code { ops.open(p("d/hora 10:20.txt"), true, true, true, false) })
        assertNull(fs.node(p("d/hora 10_20.txt"))) // y no se creó nada (ni con otro nombre)
        assertEquals(0, fs.node(p("d"))!!.kids.size)
        assertEquals("bad_path", code { ops.mkdir(p("d/que?"), false) })
        assertEquals("bad_path", code { ops.rename(p("d"), p("d2:"), false) })
        assertNotNull(fs.node(p("d")))
    }

    @Test
    fun mkdirConVariosNivelesNoDejaLaMitadHecha() {
        val fs = MemoryDocFs()
        fs.put("a")
        val ops = StorageOps(fs)
        assertEquals("bad_path", code { ops.mkdir(p("a/b/c:d/e"), true) })
        assertNull(fs.node(p("a/b"))) // «b» tampoco se creó: se comprueba todo antes
        ops.mkdir(p("a/b/c d/e"), true)
        assertNotNull(fs.node(p("a/b/c d/e")))
    }

    @Test
    fun losNombresQueYaExistenSiSePuedenUsar() {
        // un disco ext4 puede tener «a:b»: se lee, se mueve a un nombre bueno y se borra aunque no se pueda CREAR uno así
        val fs = MemoryDocFs()
        fs.put("raro:nombre.txt", "x")
        fs.put("carpeta:rara/f.txt", "y")
        val ops = StorageOps(fs)
        assertEquals("raro:nombre.txt", ops.stat(p("raro:nombre.txt")).name)
        assertEquals(1, ops.list(p("carpeta:rara"), 0, 10).total)
        ops.open(p("raro:nombre.txt"), false, false, false, false).close()
        ops.mkdir(p("carpeta:rara"), true) // ya existe: con parents no es un error
        ops.mkdir(p("carpeta:rara/nueva"), false) // un nivel nuevo dentro de una carpeta rara: vale
        ops.rename(p("raro:nombre.txt"), p("bueno.txt"), false)
        ops.delete(p("carpeta:rara/f.txt"))
        assertNull(fs.node(p("raro:nombre.txt")))
        assertNotNull(fs.node(p("bueno.txt")))
    }

    @Test
    fun cuandoAndroidGuardaConOtroNombreSeDiceElMotivo() {
        // Android devuelve «a (1).txt» / «a.txt (1)» = ya había uno: exists. Cualquier otro nombre = el disco no admite el pedido: bad_path.
        assertTrue(StoragePath.isUniquified("a.txt", "a (1).txt"))
        assertTrue(StoragePath.isUniquified("a.txt", "a.txt (1)"))
        assertTrue(StoragePath.isUniquified("a.txt", "a (23).txt"))
        assertTrue(StoragePath.isUniquified("carpeta", "carpeta (2)"))
        assertTrue(StoragePath.isUniquified(".bashrc", ".bashrc (1)"))
        assertTrue(StoragePath.isUniquified("a.tar.gz", "a.tar (1).gz"))
        assertFalse(StoragePath.isUniquified("a.txt", "a.txt"))
        assertFalse(StoragePath.isUniquified("a.txt", "a_.txt"))
        assertFalse(StoragePath.isUniquified("a.txt", "a ().txt"))
        assertFalse(StoragePath.isUniquified("a.txt", "a (x).txt"))
        assertFalse(StoragePath.isUniquified("a.txt", "b (1).txt"))
        assertFalse(StoragePath.isUniquified("a.txt", "a (1).bin"))
        assertFalse(StoragePath.isUniquified("a", "a ("))

        class Sanitizer : DocFs by MemoryDocFs() {
            val inner = MemoryDocFs()
            override fun createFile(parent: List<String>, name: String): DocEntry = inner.createFile(parent, name.trimEnd('.') + "_")
            override fun stat(parts: List<String>): DocEntry? = inner.stat(parts)
            override fun delete(parts: List<String>): Boolean = inner.delete(parts)
        }
        val san = Sanitizer()
        // el nombre ya pasa checkNewName («hola»), pero el disco lo guarda como «hola_»: bad_path y no queda el archivo
        assertEquals("bad_path", code { StorageOps(san).open(p("hola"), true, true, true, false) })
        assertNull(san.inner.node(p("hola_")))
    }

    // ------------------------------------------------------------------------------------------ mover + renombrar

    @Test
    fun moverYRenombrarSinChoques() {
        // el nombre nuevo YA existe en la carpeta de origen: se mueve primero y se renombra después
        val fs = MemoryDocFs()
        fs.put("a/x.txt", "origen")
        fs.put("a/y.txt", "otro en origen")
        fs.put("b")
        StorageOps(fs).rename(p("a/x.txt"), p("b/y.txt"), false)
        assertEquals("origen", String(fs.node(p("b/y.txt"))!!.data))
        assertEquals("otro en origen", String(fs.node(p("a/y.txt"))!!.data)) // el de la carpeta de origen no se tocó
        assertNull(fs.node(p("a/x.txt")))

        // el nombre VIEJO ya existe en la carpeta de destino: se renombra primero y se mueve después
        val fs2 = MemoryDocFs()
        fs2.put("a/x.txt", "origen")
        fs2.put("b/x.txt", "otro en destino")
        StorageOps(fs2).rename(p("a/x.txt"), p("b/z.txt"), false)
        assertEquals("origen", String(fs2.node(p("b/z.txt"))!!.data))
        assertEquals("otro en destino", String(fs2.node(p("b/x.txt"))!!.data))

        // chocan los dos: se avisa antes de tocar nada
        val fs3 = MemoryDocFs()
        fs3.put("a/x.txt", "origen")
        fs3.put("a/y.txt", "uno")
        fs3.put("b/x.txt", "dos")
        assertEquals("exists", code { StorageOps(fs3).rename(p("a/x.txt"), p("b/y.txt"), false) })
        assertEquals("origen", String(fs3.node(p("a/x.txt"))!!.data))
        assertEquals("uno", String(fs3.node(p("a/y.txt"))!!.data))
        assertEquals("dos", String(fs3.node(p("b/x.txt"))!!.data))

        // sin cambio de nombre: un movimiento sin más
        val fs4 = MemoryDocFs()
        fs4.put("a/x.txt", "uno")
        fs4.put("b")
        StorageOps(fs4).rename(p("a/x.txt"), p("b/x.txt"), false)
        assertEquals("uno", String(fs4.node(p("b/x.txt"))!!.data))
    }

    @Test
    fun siElSegundoPasoFallaSeDeshaceElPrimero() {
        // mover falla (no hay carpeta de destino que acepte): el archivo vuelve a llamarse como antes
        class FailMove : DocFs by MemoryDocFs() {
            val inner = MemoryDocFs().also {
                it.put("a/x.txt", "origen")
                it.put("b")
            }
            override fun stat(parts: List<String>): DocEntry? = inner.stat(parts)
            override fun rename(parts: List<String>, newName: String): DocEntry = inner.rename(parts, newName)
            override fun move(parts: List<String>, newParent: List<String>): DocEntry = throw StorageException("io_error", "no se pudo")
        }
        val f = FailMove()
        assertEquals("io_error", code { StorageOps(f).rename(p("a/x.txt"), p("b/z.txt"), false) })
        assertEquals("origen", String(f.inner.node(p("a/x.txt"))!!.data))
        assertNull(f.inner.node(p("a/z.txt")))
    }

    // ------------------------------------------------------------------------------------------ tabla de archivos abiertos

    private class Dummy(val name: String, val failSync: Boolean = false) : DocFile {
        val events = ArrayList<String>()
        override fun size() = 0L
        override fun read(pos: Long, buf: ByteArray, off: Int, len: Int) = 0
        override fun write(pos: Long, buf: ByteArray, off: Int, len: Int) = len
        override fun truncate(len: Long) {}
        override fun sync() {
            events.add("sync")
            if (failSync) throw StorageException("io_error", "no se pudo vaciar")
        }

        override fun close() {
            events.add("close")
        }
    }

    @Test
    fun tablaAbrirYCerrar() {
        val t = HandleTable()
        val a = Dummy("a")
        val w = Dummy("w")
        val ha = t.add("0123-4567", "/a", a, false, "cli")
        val hw = t.add("0123-4567", "/w", w, true, "cli")
        assertTrue(ha.id != hw.id)
        assertEquals(2, t.count())
        assertEquals(2, t.count("0123-4567"))
        assertEquals(2, t.count("0123-4567".lowercase()))
        assertEquals(0, t.count("otro"))
        assertTrue(t.get(ha.id) === ha)
        assertEquals("not_found", code { t.get("h999") })
        assertEquals("not_found", code { t.get(null) })
        assertTrue(t.close(hw.id))
        assertEquals(listOf("sync", "close"), w.events) // lo escrito se vacía antes de cerrar
        assertTrue(t.close(ha.id))
        assertEquals(listOf("close"), a.events) // lo de solo lectura no se vacía
        assertFalse(t.close(ha.id)) // ya estaba cerrado
        assertEquals(0, t.count())
    }

    @Test
    fun tablaLimites() {
        val t = HandleTable(maxTotal = 3, maxPerOwner = 2)
        val x = Dummy("x")
        t.add("v", "/1", Dummy("1"), false, "A")
        t.add("v", "/2", Dummy("2"), false, "A")
        val third = Dummy("3")
        assertEquals("limit", code { t.add("v", "/3", third, false, "A") }) // el tope por cliente
        assertEquals(listOf("close"), third.events) // y el archivo que no cupo se cierra
        t.add("v", "/4", x, false, "B")
        val fifth = Dummy("5")
        assertEquals("limit", code { t.add("v", "/5", fifth, false, "C") }) // el tope total
        assertEquals(listOf("close"), fifth.events)
        assertEquals(3, t.count())
    }

    @Test
    fun tablaCierraLosDeUnClienteYLosDeUnDisco() {
        val t = HandleTable()
        val a = Dummy("a")
        val b = Dummy("b")
        val c = Dummy("c")
        t.add("V1", "/a", a, true, "A")
        t.add("V1", "/b", b, true, "B")
        t.add("V2", "/c", c, true, "A")
        assertEquals(2, t.forOwner("A"))
        assertEquals(listOf("sync", "close"), a.events)
        assertEquals(listOf("sync", "close"), c.events)
        assertEquals(emptyList<String>(), b.events)
        assertEquals(1, t.forVolume("v1")) // sin distinguir mayúsculas
        assertEquals(listOf("sync", "close"), b.events)
        assertEquals(0, t.count())
        assertEquals(0, t.forOwner(null))
    }

    @Test
    fun siElVaciadoFallaSeCierraIgualYSePropaga() {
        val t = HandleTable()
        val f = Dummy("f", failSync = true)
        val h = t.add("V", "/f", f, true, "A")
        assertEquals("io_error", code { t.close(h.id) })
        assertEquals(listOf("sync", "close"), f.events) // se cerró aunque fallara
        assertEquals(0, t.count())
        // y al soltar un cliente o un disco el fallo no se propaga
        val g = Dummy("g", failSync = true)
        t.add("V", "/g", g, true, "B")
        assertEquals(1, t.forOwner("B"))
        assertEquals(listOf("sync", "close"), g.events)
    }

    @Test
    fun tablaVaciaAlDisco() {
        val t = HandleTable()
        val w1 = Dummy("w1")
        val w2 = Dummy("w2")
        val r = Dummy("r")
        t.add("V", "/w1", w1, true, "A")
        t.add("v", "/w2", w2, true, "A")
        t.add("V", "/r", r, false, "A")
        assertEquals(2, t.syncVolume("V"))
        assertEquals(listOf("sync"), w1.events)
        assertEquals(listOf("sync"), w2.events)
        assertEquals(emptyList<String>(), r.events)
        assertEquals(3, t.count())
    }

    // ------------------------------------------------------------------------------------------ volúmenes

    private class V(val uuid: String, val label: String, val scope: String = "")

    @Test
    fun elegirVolumen() {
        val vs = listOf(V("0123-4567", "KINGSTON"), V("89AB-CDEF", "Datos"), V("1111-2222", "Datos"), V("f4d1b0e2-0000-4444-8888-aaaabbbbcccc", "SSD"))
        fun pick(k: String?) = StorageSelect.pick(vs, k, { it.uuid }, { it.label })
        assertEquals("0123-4567", pick("0123-4567").uuid)
        assertEquals("0123-4567", pick("0123-4567".lowercase()).uuid)
        assertEquals("89AB-CDEF", pick("89ab-cdef").uuid)
        assertEquals("0123-4567", pick("kingston").uuid) // por etiqueta, sin distinguir mayúsculas
        assertEquals("0123-4567", pick("  KINGSTON ").uuid)
        assertEquals("f4d1b0e2-0000-4444-8888-aaaabbbbcccc", pick("ssd").uuid)
        assertEquals("bad_request", code { pick("Datos") }) // dos discos con la misma etiqueta
        assertEquals("not_found", code { pick("nada") })
        assertEquals("bad_request", code { pick("") })
        assertEquals("bad_request", code { pick(null) })
        assertEquals("not_found", code { StorageSelect.pick(emptyList<V>(), "x", { it.uuid }, { it.label }) })
        // el UUID gana a una etiqueta igual
        val tricky = listOf(V("AAAA-0001", "BBBB-0002"), V("BBBB-0002", "otra"))
        assertEquals("BBBB-0002", StorageSelect.pick(tricky, "BBBB-0002", { it.uuid }, { it.label }).uuid)
    }

    @Test
    fun laCarpetaMasAltaGana() {
        val gs = listOf(V("u", "", "Música/rock"), V("u", "", ""), V("u", "", "Música"))
        assertEquals("", StorageSelect.bestScope(gs) { it.scope }!!.scope)
        assertEquals("Música", StorageSelect.bestScope(listOf(V("u", "", "Música/rock"), V("u", "", "Música"))) { it.scope }!!.scope)
        assertNull(StorageSelect.bestScope(emptyList<V>()) { it.scope })
    }

    // ------------------------------------------------------------------------------------------ de punta a punta, como lo haría un cliente

    @Test
    fun copiarUnArchivoGrandeEnTrozos() {
        val fs = MemoryDocFs()
        val ops = StorageOps(fs)
        val table = HandleTable()
        val data = ByteArray(StorageLimits.WRITE_MAX * 3 + 123) { (it * 31 + it / 7).toByte() }
        // escribir
        assertEquals("not_found", code { ops.open(p("copia/grande.bin"), true, true, true, false) }) // la carpeta no existe aún
        ops.mkdir(p("copia"), false)
        val wf = ops.open(p("copia/grande.bin"), true, true, true, false)
        val hw = table.add("V", "/copia/grande.bin", wf, true, "c")
        var off = 0
        while (off < data.size) {
            val n = minOf(StorageLimits.WRITE_MAX, data.size - off)
            assertEquals(n, hw.file.write(off.toLong(), data, off, n))
            off += n
        }
        table.close(hw.id)
        // leer
        val rf = ops.open(p("copia/grande.bin"), false, false, false, false)
        val hr = table.add("V", "/copia/grande.bin", rf, false, "c")
        val back = java.io.ByteArrayOutputStream()
        var pos = 0L
        while (true) {
            val buf = ByteArray(StorageLimits.READ_MAX)
            val n = hr.file.read(pos, buf, 0, buf.size)
            if (n == 0) break
            back.write(buf, 0, n)
            pos += n
        }
        table.close(hr.id)
        assertArrayEquals(data, back.toByteArray())
        assertEquals(data.size.toLong(), ops.stat(p("copia/grande.bin")).size)
    }

    @Test
    fun limitesDelProtocolo() {
        // una línea del protocolo mide como mucho 64 KiB: el base64 de WRITE_MAX más el resto del JSON tiene que caber
        val b64 = (StorageLimits.WRITE_MAX + 2) / 3 * 4
        assertTrue(b64 + 300 < Protocol.MAX_LINE_BYTES)
        assertTrue(StorageLimits.READ_MAX >= StorageLimits.WRITE_MAX)
        assertTrue(StorageLimits.LIST_DEFAULT <= StorageLimits.LIST_MAX)
        assertTrue(StorageLimits.MAX_HANDLES_PER_OWNER <= StorageLimits.MAX_HANDLES)
    }
}
