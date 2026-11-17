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
 * Pruebas de la lógica de UsbSerial.kt en una JVM normal (sin Android, sin dispositivo): comprueban que el código manda las
 * órdenes de control y hace las cuentas tal como están escritas en las especificaciones de cada chip.
 * NO prueban hardware real: eso solo se puede probar con un Arduino/ESP32/adaptador conectado (docs/USB.md).
 *
 * Los valores de velocidad de FTDI y CH34x se calcularon con una transcripción independiente en Python (tests/ref_baud.py) de
 * ftdi_to_clkbits() de libftdi y del cálculo de ch341.c; «python3 tests/ref_baud.py --check» comprueba que las tablas de más abajo
 * son las que salen de ella (ver docs/USB.md). Los de FTDI de 9600/19200/38400/115200 coinciden además con la nota técnica
 * AN232B-05 de FTDI.
 */
class UsbSerialTest {

    // ------------------------------------------------------------------------------------------- dispositivos de ejemplo

    private fun ep(addr: Int, type: Int, max: Int = 64) = UsbEp(addr, type, max)
    private val bulkIn = ep(0x81, 2)
    private val bulkOut = ep(0x02, 2)
    private fun cdcCtl(id: Int) = UsbIf(id, 2, 2, 1, listOf(ep(0x80 or (id + 3), 3, 8)))
    private fun cdcData(id: Int) = UsbIf(id, 10, 0, 0, listOf(ep(0x80 or (id + 1), 2), ep(id + 1, 2)))
    private fun vendor(id: Int, sub: Int = 0, proto: Int = 0) = UsbIf(id, 255, sub, proto, listOf(bulkIn, bulkOut))

    private val arduino = UsbInfo(0x2341, 0x0043, 2, listOf(cdcCtl(0), cdcData(1)))
    private val esp32s3 = UsbInfo(0x303A, 0x1001, 239, listOf(cdcCtl(0), cdcData(1), vendor(2, 255, 1)))
    private val ch340 = UsbInfo(0x1A86, 0x7523, 255, listOf(UsbIf(0, 255, 1, 2, listOf(bulkIn, bulkOut, ep(0x82, 3, 8)))))
    private val cp2102 = UsbInfo(0x10C4, 0xEA60, 0, listOf(vendor(0)))
    private val ft232r = UsbInfo(0x0403, 0x6001, 0, listOf(vendor(0, 255, 255)), bcd = 0x0600)
    private val pl2303 = UsbInfo(0x067B, 0x2303, 0, listOf(UsbIf(0, 255, 0, 0, listOf(ep(0x81, 3, 10), bulkIn, bulkOut))))
    private val keyboard = UsbInfo(0x046D, 0xC31C, 0, listOf(UsbIf(0, 3, 1, 1, listOf(ep(0x81, 3, 8)))))
    private val mouse = UsbInfo(0x046D, 0xC077, 0, listOf(UsbIf(0, 3, 1, 2, listOf(ep(0x81, 3, 4)))))
    private val disk = UsbInfo(0x0781, 0x5581, 0, listOf(UsbIf(0, 8, 6, 80, listOf(bulkIn, bulkOut))))
    private val hub = UsbInfo(0x05E3, 0x0610, 9, listOf(UsbIf(0, 9, 0, 1, listOf(ep(0x81, 3, 1)))))

    // ------------------------------------------------------------------------------------------- reconocimiento

    @Test
    fun recognisesChips() {
        assertEquals(Chip.CDC_ACM, UsbIds.chip(arduino))
        assertEquals(Chip.CDC_ACM, UsbIds.chip(esp32s3))
        assertEquals(Chip.CH34X, UsbIds.chip(ch340))
        assertEquals(Chip.CP210X, UsbIds.chip(cp2102))
        assertEquals(Chip.FTDI, UsbIds.chip(ft232r))
        assertNull(UsbIds.chip(pl2303))
        assertNull(UsbIds.chip(keyboard))
        assertNull(UsbIds.chip(disk))
        assertNull(UsbIds.chip(hub))
    }

    @Test
    fun vidPidWinsOverClass() {
        // Un CH340 cuya interfaz parece CDC sigue siendo un CH340 (usa órdenes propias, no las de CDC)
        val odd = UsbInfo(0x1A86, 0x7523, 2, listOf(cdcCtl(0), cdcData(1)))
        assertEquals(Chip.CH34X, UsbIds.chip(odd))
    }

    @Test
    fun otherChipPidsAreNotClaimed() {
        // Mismo fabricante pero otro producto (p. ej. un CP2110, que es HID) → no es un adaptador serie conocido
        assertNull(UsbIds.chip(UsbInfo(0x10C4, 0xEA80, 0, listOf(UsbIf(0, 3, 0, 0, listOf(ep(0x81, 3, 64)))))))
        assertEquals(Chip.CP210X, UsbIds.chip(UsbInfo(0x10C4, 0xEA70, 0, listOf(vendor(0)))))
        assertEquals(Chip.CP210X, UsbIds.chip(UsbInfo(0x10C4, 0xEA71, 0, listOf(vendor(0)))))
        for (pid in intArrayOf(0x6001, 0x6010, 0x6011, 0x6014, 0x6015)) assertEquals(Chip.FTDI, UsbIds.chip(UsbInfo(0x0403, pid, 0, listOf(vendor(0)))))
        for (pid in intArrayOf(0x7523, 0x7522, 0x5523)) assertEquals(Chip.CH34X, UsbIds.chip(UsbInfo(0x1A86, pid, 255, listOf(vendor(0)))))
    }

    @Test
    fun kinds() {
        assertEquals("serial", UsbIds.kind(arduino))
        assertEquals("serial", UsbIds.kind(esp32s3))
        assertEquals("serial", UsbIds.kind(ch340))
        assertEquals("serial", UsbIds.kind(cp2102))
        assertEquals("serial", UsbIds.kind(ft232r))
        assertEquals("serial", UsbIds.kind(pl2303))          // se reconoce como serie aunque no haya controlador
        assertEquals("hid", UsbIds.kind(keyboard))
        assertEquals("hid", UsbIds.kind(mouse))
        assertEquals("storage", UsbIds.kind(disk))
        assertEquals("hub", UsbIds.kind(hub))
        assertEquals("audio", UsbIds.kind(UsbInfo(0x1234, 1, 0, listOf(UsbIf(0, 1, 1, 0, emptyList())))))
        assertEquals("video", UsbIds.kind(UsbInfo(0x1234, 2, 239, listOf(UsbIf(0, 14, 1, 0, emptyList())))))
        assertEquals("printer", UsbIds.kind(UsbInfo(0x1234, 3, 0, listOf(UsbIf(0, 7, 1, 2, emptyList())))))
        assertEquals("net", UsbIds.kind(UsbInfo(0x1234, 4, 2, listOf(UsbIf(0, 2, 6, 0, emptyList())))))
        assertEquals("other", UsbIds.kind(UsbInfo(0x1234, 5, 255, listOf(UsbIf(0, 255, 66, 1, emptyList())))))
    }

    @Test
    fun notes() {
        assertNotNull(UsbIds.note(pl2303))
        assertTrue(UsbIds.note(pl2303)!!.contains("PL2303"))
        assertNull(UsbIds.note(arduino))
        assertNull(UsbIds.note(keyboard))
    }

    // ------------------------------------------------------------------------------------------- plan (qué reclamar)

    @Test
    fun planArduino() {
        val p = UsbPlanner.plan(arduino)
        assertEquals(Chip.CDC_ACM, p.chip)
        assertEquals(listOf(0, 1), p.claim)
        assertEquals(0, p.index)
        assertEquals(0x82, p.epIn.address)
        assertEquals(0x02, p.epOut.address)
    }

    @Test
    fun planEsp32UsesOnlyTheCdcPair() {
        val p = UsbPlanner.plan(esp32s3)
        assertEquals(listOf(0, 1), p.claim)       // la interfaz 2 (JTAG, vendedor) no se toca
    }

    @Test
    fun planCdcWithoutDataInterfaceUsesTheControlOne() {
        val single = UsbInfo(0x1234, 9, 2, listOf(UsbIf(0, 2, 2, 1, listOf(bulkIn, bulkOut, ep(0x83, 3, 8)))))
        val p = UsbPlanner.plan(single)
        assertEquals(listOf(0), p.claim)
    }

    @Test
    fun planCdcPrefersDataInterfaceAfterControl() {
        // Dos puertos CDC (control 0 + datos 1, control 2 + datos 3): el primero
        val two = UsbInfo(0x1234, 10, 2, listOf(cdcCtl(0), cdcData(1), cdcCtl(2), cdcData(3)))
        assertEquals(listOf(0, 1), UsbPlanner.plan(two).claim)
    }

    @Test
    fun planVendorChips() {
        val c = UsbPlanner.plan(cp2102)
        assertEquals(Chip.CP210X, c.chip); assertEquals(listOf(0), c.claim); assertEquals(0, c.index)
        val f = UsbPlanner.plan(ft232r)
        assertEquals(Chip.FTDI, f.chip); assertEquals(listOf(0), f.claim); assertEquals(1, f.index)        // FTDI numera los puertos desde 1
        val w = UsbPlanner.plan(ch340)
        assertEquals(Chip.CH34X, w.chip); assertEquals(listOf(0), w.claim); assertEquals(0, w.index)
        // FTDI de dos puertos: el primero
        val ft2 = UsbInfo(0x0403, 0x6010, 0, listOf(vendor(0), vendor(1)))
        assertEquals(1, UsbPlanner.plan(ft2).index)
    }

    @Test
    fun planRefusesWhatItCannotDrive() {
        for (d in listOf(keyboard, mouse, disk, hub)) {
            try {
                UsbPlanner.plan(d)
                fail("debió rechazar ${d.vid}:${d.pid}")
            } catch (e: IllegalArgumentException) {
                assertTrue(e.message!!.isNotEmpty())
            }
        }
        try {
            UsbPlanner.plan(pl2303)
            fail()
        } catch (e: IllegalArgumentException) {
            assertTrue(e.message!!.contains("PL2303"))
        }
        // Un CP210x sin extremos bulk no es utilizable
        try {
            UsbPlanner.plan(UsbInfo(0x10C4, 0xEA60, 0, listOf(UsbIf(0, 255, 0, 0, listOf(ep(0x81, 3, 8))))))
            fail()
        } catch (e: IllegalArgumentException) {
            assertTrue(e.message!!.contains("bulk"))
        }
    }

    // ------------------------------------------------------------------------------------------- Line

    @Test
    fun lineValidation() {
        val l = Line.of(115200, 8, "none", 1.0)
        assertEquals(1, l.stopJson)
        assertEquals(2, Line.of(9600, 7, "even", 2.0).stopJson)
        assertEquals(1.5, Line.of(9600, 5, "odd", 1.5).stopJson)
        for (bad in listOf<() -> Line>(
            { Line.of(49, 8, "none", 1.0) }, { Line.of(4_000_001, 8, "none", 1.0) }, { Line.of(9600, 4, "none", 1.0) },
            { Line.of(9600, 9, "none", 1.0) }, { Line.of(9600, 8, "weird", 1.0) }, { Line.of(9600, 8, "none", 3.0) },
        )) {
            try {
                bad()
                fail()
            } catch (e: IllegalArgumentException) {
                assertTrue(e.message!!.isNotEmpty())
            }
        }
        assertEquals(listOf("none", "odd", "even", "mark", "space"), Line.PARITIES)
    }

    // ------------------------------------------------------------------------------------------- enlace de mentira

    private class Call(val type: Int, val req: Int, val value: Int, val index: Int, val data: ByteArray?, val len: Int)

    private class FakeLink : UsbLink {
        val calls = ArrayList<Call>()
        val reads = HashMap<Int, ByteArray>()      // lo que devuelve una lectura de control, por petición
        var failFrom = Int.MAX_VALUE               // desde la llamada N todas fallan con -1
        val incoming = ArrayDeque<ByteArray>()
        val written = ArrayList<IntArray>()        // (offset, len) de cada escritura
        var outLimit = Int.MAX_VALUE               // máximo de bytes que acepta cada escritura (para probar escrituras parciales)
        var outFail = false

        override fun control(type: Int, req: Int, value: Int, index: Int, data: ByteArray?, len: Int): Int {
            calls.add(Call(type, req, value, index, data?.copyOf(), len))
            if (calls.size > failFrom) return -1
            if ((type and 0x80) != 0 && data != null) {
                reads[req]?.let { System.arraycopy(it, 0, data, 0, minOf(it.size, data.size)) }
            }
            return len
        }

        override fun bulkIn(buf: ByteArray, len: Int, timeoutMs: Int): Int {
            val b = incoming.removeFirstOrNull() ?: return -1
            System.arraycopy(b, 0, buf, 0, b.size)
            return b.size
        }

        override fun bulkOut(buf: ByteArray, off: Int, len: Int, timeoutMs: Int): Int {
            if (outFail) return -1
            val n = minOf(len, outLimit)
            written.add(intArrayOf(off, n))
            return n
        }
    }

    private fun bytes(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }

    // ------------------------------------------------------------------------------------------- CDC-ACM

    @Test
    fun cdcInit() {
        val link = FakeLink()
        val steps = CdcAcmDriver(link, 0).init(Line.DEFAULT, dtr = true, rts = true)
        assertEquals(listOf("set_line_coding", "set_control_line_state"), steps.map { it.op })
        assertEquals(2, link.calls.size)
        val a = link.calls[0]
        assertEquals(0x21, a.type); assertEquals(0x20, a.req); assertEquals(0, a.value); assertEquals(0, a.index)
        assertArrayEquals(bytes(0x00, 0xC2, 0x01, 0x00, 0, 0, 8), a.data)          // 115200 8N1
        val b = link.calls[1]
        assertEquals(0x21, b.type); assertEquals(0x22, b.req); assertEquals(3, b.value); assertEquals(0, b.index)
        assertFalse(steps.any { it.fatal })
    }

    @Test
    fun cdcLineFormats() {
        val link = FakeLink()
        val d = CdcAcmDriver(link, 2)
        d.setLine(Line.of(9600, 7, "even", 2.0))
        assertArrayEquals(bytes(0x80, 0x25, 0, 0, 2, 2, 7), link.calls[0].data)       // 9600 = 0x2580; 2 stop; paridad par; 7 bits
        assertEquals(2, link.calls[0].index)                                          // wIndex = interfaz de control
        d.setLine(Line.of(57600, 5, "space", 1.5))
        assertArrayEquals(bytes(0x00, 0xE1, 0, 0, 1, 4, 5), link.calls[1].data)       // 57600 = 0xE100; 1,5 stop; space; 5 bits
        d.setLines(dtr = false, rts = true)
        assertEquals(2, link.calls[2].value)
        d.setLines(dtr = true, rts = false)
        assertEquals(1, link.calls[3].value)
        d.setLines(dtr = false, rts = false)
        assertEquals(0, link.calls[4].value)
        d.setBreak(true); d.setBreak(false)
        assertEquals(0x23, link.calls[5].req); assertEquals(0xFFFF, link.calls[5].value)
        assertEquals(0, link.calls[6].value)
    }

    // ------------------------------------------------------------------------------------------- CP210x

    @Test
    fun cp210xInit() {
        val link = FakeLink()
        val steps = Cp210xDriver(link, 0).init(Line.DEFAULT, dtr = true, rts = true)
        assertEquals(listOf("ifc_enable", "set_baudrate", "set_line_ctl", "set_mhs"), steps.map { it.op })
        val c = link.calls
        assertEquals(listOf(0x41, 0x00, 1, 0), listOf(c[0].type, c[0].req, c[0].value, c[0].index))
        assertEquals(listOf(0x41, 0x1E, 0, 0), listOf(c[1].type, c[1].req, c[1].value, c[1].index))
        assertArrayEquals(bytes(0x00, 0xC2, 0x01, 0x00), c[1].data)
        assertEquals(listOf(0x41, 0x03, 0x0800, 0), listOf(c[2].type, c[2].req, c[2].value, c[2].index))
        assertEquals(listOf(0x41, 0x07, 0x0303, 0), listOf(c[3].type, c[3].req, c[3].value, c[3].index))
    }

    @Test
    fun cp210xFormatsAndLines() {
        val link = FakeLink()
        val d = Cp210xDriver(link, 1)
        d.setLine(Line.of(19200, 7, "even", 2.0))
        assertEquals(0x0722, link.calls[1].value)
        assertEquals(1, link.calls[1].index)
        d.setLine(Line.of(19200, 8, "odd", 1.0)); assertEquals(0x0810, link.calls[3].value)
        d.setLine(Line.of(19200, 8, "mark", 1.0)); assertEquals(0x0830, link.calls[5].value)
        d.setLine(Line.of(19200, 8, "space", 1.0)); assertEquals(0x0840, link.calls[7].value)
        d.setLines(dtr = false, rts = false); assertEquals(0x0300, link.calls[8].value)
        d.setLines(dtr = true, rts = false); assertEquals(0x0301, link.calls[9].value)
        d.setLines(dtr = false, rts = true); assertEquals(0x0302, link.calls[10].value)
        d.setBreak(true); assertEquals(1, link.calls[11].value); assertEquals(0x05, link.calls[11].req)
        d.setBreak(false); assertEquals(0, link.calls[12].value)
        try {
            d.setLine(Line.of(9600, 8, "none", 1.5))
            fail()
        } catch (e: UnsupportedOperationException) {
            assertTrue(e.message!!.contains("1,5"))
        }
    }

    // ------------------------------------------------------------------------------------------- FTDI

    @Test
    fun ftdiBaudKnownValues() {
        // Notas técnicas de FTDI (AN232B-05): 9600 → 0x4138, 19200 → 0x809C, 38400 → 0xC04E, 115200 → 0x001A
        assertEquals(Pair(0x4138, 0), FtdiBaud.encode(9600, FtdiType.R, 1))
        assertEquals(Pair(0x809C, 0), FtdiBaud.encode(19200, FtdiType.R, 1))
        assertEquals(Pair(0xC04E, 0), FtdiBaud.encode(38400, FtdiType.R, 1))
        assertEquals(Pair(0x001A, 0), FtdiBaud.encode(115200, FtdiType.R, 1))
        // Casos especiales del divisor
        assertEquals(Pair(0, 0), FtdiBaud.encode(3_000_000, FtdiType.R, 1))
        assertEquals(Pair(1, 0), FtdiBaud.encode(2_000_000, FtdiType.R, 1))
        assertEquals(Pair(2, 0), FtdiBaud.encode(1_500_000, FtdiType.R, 1))
    }

    @Test
    fun ftdiBaudAgainstIndependentPythonPort() {
        // (baud, R: value, index) (232H: value, index) (2232C puerto 1: value, index): salida de ref_baud.py
        val rows = arrayOf(
            intArrayOf(300, 0x2710, 0, 0x2710, 0, 0x2710, 1),
            intArrayOf(1200, 0x09c4, 0, 0x2710, 2, 0x09c4, 1),
            intArrayOf(2400, 0x04e2, 0, 0x1388, 2, 0x04e2, 1),
            intArrayOf(4800, 0x0271, 0, 0x09c4, 2, 0x0271, 1),
            intArrayOf(9600, 0x4138, 0, 0x04e2, 2, 0x4138, 1),
            intArrayOf(19200, 0x809c, 0, 0x0271, 2, 0x809c, 1),
            intArrayOf(38400, 0xc04e, 0, 0x4138, 2, 0xc04e, 1),
            intArrayOf(57600, 0xc034, 0, 0x00d0, 3, 0xc034, 1),
            intArrayOf(74880, 0xc028, 0, 0x80a0, 2, 0xc028, 1),
            intArrayOf(115200, 0x001a, 0, 0xc068, 2, 0x001a, 1),
            intArrayOf(230400, 0x000d, 0, 0xc034, 2, 0x000d, 1),
            intArrayOf(250000, 0x000c, 0, 0x0030, 2, 0x000c, 1),
            intArrayOf(460800, 0x4006, 0, 0x001a, 2, 0x4006, 1),
            intArrayOf(500000, 0x0006, 0, 0x0018, 2, 0x0006, 1),
            intArrayOf(921600, 0x8003, 0, 0x000d, 2, 0x8003, 1),
            intArrayOf(1000000, 0x0003, 0, 0x000c, 2, 0x0003, 1),
            intArrayOf(1500000, 0x0002, 0, 0x0008, 2, 0x0002, 1),
            intArrayOf(2000000, 0x0001, 0, 0x0006, 2, 0x0001, 1),
            intArrayOf(3000000, 0x0000, 0, 0x0004, 2, 0x0000, 1),
        )
        for (r in rows) {
            assertEquals("R ${r[0]}", Pair(r[1], r[2]), FtdiBaud.encode(r[0], FtdiType.R, 1))
            assertEquals("232H ${r[0]}", Pair(r[3], r[4]), FtdiBaud.encode(r[0], FtdiType.H232, 1))
            assertEquals("2232C ${r[0]}", Pair(r[5], r[6]), FtdiBaud.encode(r[0], FtdiType.C2232, 1))
        }
    }

    @Test
    fun ftdiTypeFromBcd() {
        assertEquals(FtdiType.R, FtdiType.fromBcd(0x0600))
        assertEquals(FtdiType.BM, FtdiType.fromBcd(0x0400))
        assertEquals(FtdiType.BM, FtdiType.fromBcd(0x0200))
        assertEquals(FtdiType.C2232, FtdiType.fromBcd(0x0500))
        assertEquals(FtdiType.H2232, FtdiType.fromBcd(0x0700))
        assertEquals(FtdiType.H4232, FtdiType.fromBcd(0x0800))
        assertEquals(FtdiType.H232, FtdiType.fromBcd(0x0900))
        assertEquals(FtdiType.X, FtdiType.fromBcd(0x1000))
        assertEquals(FtdiType.R, FtdiType.fromBcd(-1))              // no se sabe: se trata como FT232R
    }

    @Test
    fun ftdiInitAndLine() {
        val link = FakeLink()
        val d = FtdiDriver(link, 1, FtdiType.R, 64)
        val steps = d.init(Line.DEFAULT, dtr = true, rts = true)
        assertEquals(listOf("reset", "set_baudrate", "set_data", "set_modem_ctrl"), steps.map { it.op })
        val c = link.calls
        assertEquals(listOf(0x40, 0, 0, 1), listOf(c[0].type, c[0].req, c[0].value, c[0].index))
        assertEquals(listOf(0x40, 3, 0x001A, 0), listOf(c[1].type, c[1].req, c[1].value, c[1].index))
        assertEquals(listOf(0x40, 4, 0x0008, 1), listOf(c[2].type, c[2].req, c[2].value, c[2].index))
        assertEquals(listOf(0x40, 1, 0x0303, 1), listOf(c[3].type, c[3].req, c[3].value, c[3].index))
    }

    @Test
    fun ftdiFormatsLinesAndBreak() {
        val link = FakeLink()
        val d = FtdiDriver(link, 1, FtdiType.R, 64)
        d.setLine(Line.of(9600, 7, "even", 2.0)); assertEquals(0x1207, link.calls[1].value)
        d.setLine(Line.of(9600, 8, "odd", 1.0)); assertEquals(0x0108, link.calls[3].value)
        d.setLine(Line.of(9600, 8, "mark", 1.5)); assertEquals(0x0B08, link.calls[5].value)
        d.setLine(Line.of(9600, 8, "space", 1.0)); assertEquals(0x0408, link.calls[7].value)
        d.setBreak(true); assertEquals(0x4408, link.calls[8].value); assertEquals(4, link.calls[8].req)
        d.setBreak(false); assertEquals(0x0408, link.calls[9].value)
        d.setLines(dtr = true, rts = false); assertEquals(0x0301, link.calls[10].value)
        d.setLines(dtr = false, rts = true); assertEquals(0x0302, link.calls[11].value)
        d.setLines(dtr = false, rts = false); assertEquals(0x0300, link.calls[12].value)
    }

    @Test
    fun ftdiStripsStatusBytesFromEveryPacket() {
        val d = FtdiDriver(FakeLink(), 1, FtdiType.R, 64)
        // Dos paquetes: uno de 64 bytes (2 de estado + 62 de datos) y otro de 5 (2 + 3)
        val buf = ByteArray(128)
        buf[0] = 0x01; buf[1] = 0x60
        for (i in 2 until 64) buf[i] = i.toByte()
        buf[64] = 0x01; buf[65] = 0x60; buf[66] = 'a'.code.toByte(); buf[67] = 'b'.code.toByte(); buf[68] = 'c'.code.toByte()
        val n = d.rx(buf, 69)
        assertEquals(65, n)
        for (i in 0 until 62) assertEquals((i + 2).toByte(), buf[i])
        assertEquals("abc", String(buf, 62, 3, Charsets.US_ASCII))
    }

    @Test
    fun ftdiStatusOnlyPacketsGiveNoData() {
        val d = FtdiDriver(FakeLink(), 1, FtdiType.R, 64)
        val buf = bytes(0x01, 0x60, 0, 0)
        assertEquals(0, d.rx(buf, 2))
        assertEquals(0, d.rx(bytes(0x01, 0x60), 1))
        // Un paquete de máxima longitud de alta velocidad (512)
        val hs = FtdiDriver(FakeLink(), 1, FtdiType.H232, 512)
        val big = ByteArray(1024)
        for (i in 0 until 512) big[i] = if (i < 2) 0x01 else 0x55
        for (i in 512 until 1024) big[i] = if (i < 514) 0x01 else 0x66
        assertEquals(1020, hs.rx(big, 1024))
        assertEquals(0x55.toByte(), big[0]); assertEquals(0x55.toByte(), big[509])
        assertEquals(0x66.toByte(), big[510]); assertEquals(0x66.toByte(), big[1019])
    }

    // ------------------------------------------------------------------------------------------- CH34x

    @Test
    fun ch34xBaudAgainstIndependentPythonPort() {
        val rows = arrayOf(
            intArrayOf(300, 0xd980, 0x06),
            intArrayOf(1200, 0xb281, 0x0c),
            intArrayOf(2400, 0xd981, 0x06),
            intArrayOf(4800, 0x6482, 0x18),
            intArrayOf(9600, 0xb282, 0x0c),
            intArrayOf(19200, 0xd982, 0x06),
            intArrayOf(38400, 0x6483, 0x18),
            intArrayOf(57600, 0x9883, 0x10),
            intArrayOf(74880, 0xb083, 0x0d),
            intArrayOf(115200, 0xcc83, 0x08),
            intArrayOf(230400, 0xe683, 0x04),
            intArrayOf(250000, 0xe883, 0x0e),
            intArrayOf(460800, 0xf383, 0x02),
            intArrayOf(500000, 0xf483, 0x07),
            intArrayOf(921600, 0xf387, 0x00),
            intArrayOf(1000000, 0xfa83, 0x04),
            intArrayOf(1500000, 0xfc83, 0x03),
            intArrayOf(2000000, 0xfd83, 0x02),
            intArrayOf(3000000, 0xfe83, 0x02),
        )
        for (r in rows) assertEquals("baud ${r[0]}", Pair(r[1], r[2]), Ch34xBaud.regs(r[0]))
    }

    @Test
    fun ch34xLcr() {
        assertEquals(0xC3, Ch34xBaud.lcr(Line.DEFAULT))                                     // 8N1: RX|TX|CS8
        assertEquals(0xC0 or 0x02 or 0x08 or 0x10 or 0x04, Ch34xBaud.lcr(Line.of(9600, 7, "even", 2.0)))
        assertEquals(0xC0 or 0x03 or 0x08, Ch34xBaud.lcr(Line.of(9600, 8, "odd", 1.0)))
        assertEquals(0xC0 or 0x03 or 0x08 or 0x20, Ch34xBaud.lcr(Line.of(9600, 8, "mark", 1.0)))
        assertEquals(0xC0 or 0x03 or 0x08 or 0x20 or 0x10, Ch34xBaud.lcr(Line.of(9600, 8, "space", 1.0)))
        assertEquals(0xC0, Ch34xBaud.lcr(Line.of(9600, 5, "none", 1.0)))
        assertEquals(0xC1, Ch34xBaud.lcr(Line.of(9600, 6, "none", 1.0)))
    }

    @Test
    fun ch34xInitSequence() {
        val link = FakeLink()
        val steps = Ch34xDriver(link).init(Line.DEFAULT, dtr = true, rts = true)
        assertEquals(
            listOf("read_version", "serial_init", "set_baudrate_1312", "set_baudrate_0f2c", "read_lcr", "set_lcr", "read_status",
                "init_extra", "set_baudrate_1312", "set_baudrate_0f2c", "set_modem_ctrl"),
            steps.map { it.op },
        )
        val c = link.calls
        assertEquals(listOf(0xC0, 0x5F), listOf(c[0].type, c[0].req))
        assertEquals(listOf(0x40, 0xA1, 0, 0), listOf(c[1].type, c[1].req, c[1].value, c[1].index))
        assertEquals(listOf(0x40, 0x9A, 0x1312, 0xCC83), listOf(c[2].type, c[2].req, c[2].value, c[2].index))
        assertEquals(listOf(0x40, 0x9A, 0x0F2C, 0x0008), listOf(c[3].type, c[3].req, c[3].value, c[3].index))
        assertEquals(listOf(0xC0, 0x95, 0x2518), listOf(c[4].type, c[4].req, c[4].value))
        assertEquals(listOf(0x40, 0x9A, 0x2518, 0xC3), listOf(c[5].type, c[5].req, c[5].value, c[5].index))
        assertEquals(listOf(0xC0, 0x95, 0x0706), listOf(c[6].type, c[6].req, c[6].value))
        assertEquals(listOf(0x40, 0xA1, 0x501F, 0xD90A), listOf(c[7].type, c[7].req, c[7].value, c[7].index))
        assertEquals(listOf(0x40, 0xA4, 0xFF9F, 0), listOf(c[10].type, c[10].req, c[10].value, c[10].index))   // lógica invertida: ~(DTR|RTS)
        // Lecturas y el paso extra no son obligatorios; el resto sí
        assertEquals(listOf(false, true, true, true, false, true, false, false, true, true, true), steps.map { it.fatal })
    }

    @Test
    fun ch34xLinesAreInverted() {
        val link = FakeLink()
        val d = Ch34xDriver(link)
        d.setLines(dtr = false, rts = false); assertEquals(0xFFFF, link.calls[0].value)
        d.setLines(dtr = true, rts = false); assertEquals(0xFFDF, link.calls[1].value)
        d.setLines(dtr = false, rts = true); assertEquals(0xFFBF, link.calls[2].value)
        d.setLines(dtr = true, rts = true); assertEquals(0xFF9F, link.calls[3].value)
    }

    @Test
    fun ch34xBreak() {
        val link = FakeLink()
        link.reads[0x95] = bytes(0x01, 0x40)             // estado actual: sin ruptura (bit 0 del byte 0 y bit 6 del 1 puestos)
        val d = Ch34xDriver(link)
        d.setBreak(true)
        val on = link.calls[1]
        assertEquals(listOf(0x40, 0x9A, 0x1805, 0x0000), listOf(on.type, on.req, on.value, on.index))
        link.reads[0x95] = bytes(0x00, 0x00)
        d.setBreak(false)
        val off = link.calls[3]
        assertEquals(0x4001, off.index)
    }

    @Test
    fun ch34xBreakFailsIfRegisterCannotBeRead() {
        val link = FakeLink()
        link.failFrom = 0
        val s = Ch34xDriver(link).setBreak(true)
        assertEquals(1, s.size)
        assertTrue(s[0].failed && s[0].fatal)
    }

    @Test
    fun ch34xRejectsOneAndAHalfStopBits() {
        try {
            Ch34xDriver(FakeLink()).setLine(Line.of(9600, 5, "none", 1.5))
            fail()
        } catch (e: UnsupportedOperationException) {
            assertTrue(e.message!!.contains("1,5"))
        }
    }

    // ------------------------------------------------------------------------------------------- fallos de control

    @Test
    fun failedControlTransfersAreReported() {
        val link = FakeLink()
        link.failFrom = 1                                  // la 1.ª orden va bien; las siguientes fallan
        val steps = Cp210xDriver(link, 0).init(Line.DEFAULT, dtr = true, rts = true)
        assertFalse(steps[0].failed)
        assertTrue(steps.drop(1).all { it.failed && it.fatal })
    }

    // ------------------------------------------------------------------------------------------- SerialPort

    @Test
    fun portReadAppliesDriverFilter() {
        val link = FakeLink()
        val p = SerialPort(link, FtdiDriver(link, 1, FtdiType.R, 64))
        link.incoming.add(bytes(0x01, 0x60, 'h'.code, 'i'.code))
        val buf = ByteArray(64)
        assertEquals(2, p.read(buf, 10))
        assertEquals("hi", String(buf, 0, 2, Charsets.US_ASCII))
        assertTrue(p.read(buf, 10) < 0)                    // nada: plazo agotado
        link.incoming.add(bytes(0x01, 0x60))
        assertEquals(0, p.read(buf, 10))                   // solo estado
    }

    @Test
    fun portReadPassesDataThroughOtherChips() {
        val link = FakeLink()
        val p = SerialPort(link, CdcAcmDriver(link, 0))
        link.incoming.add(bytes(1, 2, 3))
        val buf = ByteArray(16)
        assertEquals(3, p.read(buf, 10))
        assertArrayEquals(bytes(1, 2, 3), buf.copyOf(3))
    }

    @Test
    fun portWriteChunksAtSixteenKiB() {
        val link = FakeLink()
        val p = SerialPort(link, CdcAcmDriver(link, 0))
        assertTrue(p.write(ByteArray(40000), 0, 40000))
        assertEquals(listOf(16384, 16384, 7232), link.written.map { it[1] })
        assertEquals(listOf(0, 16384, 32768), link.written.map { it[0] })
    }

    @Test
    fun portWriteHandlesPartialWrites() {
        val link = FakeLink()
        link.outLimit = 64
        val p = SerialPort(link, CdcAcmDriver(link, 0))
        assertTrue(p.write(ByteArray(200), 10, 150))
        assertEquals(listOf(64, 64, 22), link.written.map { it[1] })
        assertEquals(listOf(10, 74, 138), link.written.map { it[0] })
    }

    @Test
    fun portWriteReportsFailure() {
        val link = FakeLink()
        link.outFail = true
        val p = SerialPort(link, CdcAcmDriver(link, 0))
        assertFalse(p.write(ByteArray(10), 0, 10))
        assertTrue(p.write(ByteArray(10), 0, 0))           // nada que escribir: bien
    }

    @Test
    fun driverFactory() {
        val link = FakeLink()
        assertEquals(Chip.CDC_ACM, SerialDrivers.create(UsbPlanner.plan(arduino), link, -1).chip)
        assertEquals(Chip.CP210X, SerialDrivers.create(UsbPlanner.plan(cp2102), link, -1).chip)
        assertEquals(Chip.FTDI, SerialDrivers.create(UsbPlanner.plan(ft232r), link, 0x0600).chip)
        assertEquals(Chip.CH34X, SerialDrivers.create(UsbPlanner.plan(ch340), link, -1).chip)
    }
}
