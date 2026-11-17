package org.nexo.bridge

/*
 * Lógica de los adaptadores USB↔serie, SIN ninguna clase de Android: así se puede probar en una JVM normal
 * (android/app/src/test/java/org/nexo/bridge/UsbSerialTest.kt). Aquí viven:
 *
 *   - cómo se reconoce un dispositivo (VID/PID y clases de interfaz), de qué tipo es y qué interfaces hay que reclamar;
 *   - las órdenes de control de cada chip (CDC-ACM, CP210x, FTDI, CH34x) y las cuentas de velocidad;
 *   - el filtro de lo que llega (el FTDI antepone 2 bytes de estado a cada paquete USB).
 *
 * UsbHandler.kt es el pegamento con Android (UsbManager, permisos, hilos, sesiones).
 *
 * HONESTIDAD: estas secuencias siguen la documentación de cada chip y el comportamiento de los controladores de Linux y de
 * usb-serial-for-android (referencias en docs/USB.md). Las pruebas de la JVM comprueban que el código hace lo que está
 * escrito aquí; NO se han probado con un Arduino, un ESP32 ni un adaptador real.
 */

// ------------------------------------------------------------------------------------------------ descripción del dispositivo

/** Un extremo (endpoint) USB. `type`: 0 control, 1 isócrono, 2 bulk, 3 interrupción. Bit 7 de la dirección = entrada. */
class UsbEp(val address: Int, val type: Int, val maxPacket: Int) {
    val isIn: Boolean get() = (address and 0x80) != 0
    val isBulk: Boolean get() = type == 2
}

/** Una interfaz USB (copia sin tipos de Android). */
class UsbIf(val id: Int, val cls: Int, val sub: Int, val proto: Int, val eps: List<UsbEp>) {
    fun bulkIn(): UsbEp? = eps.firstOrNull { it.isBulk && it.isIn }
    fun bulkOut(): UsbEp? = eps.firstOrNull { it.isBulk && !it.isIn }
    fun hasBulkPair(): Boolean = bulkIn() != null && bulkOut() != null
}

/** Lo que Android cuenta de un dispositivo sin abrirlo. `bcd`: versión del dispositivo (bcdDevice) o -1 si no se conoce. */
class UsbInfo(val vid: Int, val pid: Int, val devClass: Int, val ifaces: List<UsbIf>, val bcd: Int = -1)

enum class Chip(val tag: String) {
    CDC_ACM("cdc-acm"), CP210X("cp210x"), FTDI("ftdi"), CH34X("ch34x");
}

object UsbIds {
    const val VID_QINHENG = 0x1A86
    const val VID_SILABS = 0x10C4
    const val VID_FTDI = 0x0403
    const val VID_PROLIFIC = 0x067B

    private val CH34X_PIDS = setOf(0x7523, 0x7522, 0x5523)
    private val CP210X_PIDS = setOf(0xEA60, 0xEA70, 0xEA71)
    private val FTDI_PIDS = setOf(0x6001, 0x6010, 0x6011, 0x6014, 0x6015)

    /** La interfaz de control de un dispositivo CDC-ACM (clase 2, subclase 2), si la tiene. */
    fun acmControl(i: UsbInfo): UsbIf? = i.ifaces.firstOrNull { it.cls == 2 && it.sub == 2 }

    /** Qué controlador de Nexo sabe hablar con este dispositivo, o null. Primero por VID/PID, si no por la clase CDC-ACM. */
    fun chip(i: UsbInfo): Chip? = when {
        i.vid == VID_QINHENG && i.pid in CH34X_PIDS -> Chip.CH34X
        i.vid == VID_SILABS && i.pid in CP210X_PIDS -> Chip.CP210X
        i.vid == VID_FTDI && i.pid in FTDI_PIDS -> Chip.FTDI
        acmControl(i) != null -> Chip.CDC_ACM
        else -> null
    }

    /** Chips serie que se reconocen pero para los que Nexo todavía no tiene controlador. */
    fun knownUnsupportedSerial(i: UsbInfo): Boolean = i.vid == VID_PROLIFIC

    fun note(i: UsbInfo): String? =
        if (chip(i) == null && knownUnsupportedSerial(i)) "PL2303: Nexo todavía no tiene su controlador" else null

    /** serial, hub, storage, hid, audio, video, printer, net o other (para mostrar; no cambia lo que se puede hacer). */
    fun kind(i: UsbInfo): String {
        if (chip(i) != null || knownUnsupportedSerial(i)) return "serial"
        val cls = i.ifaces.map { it.cls }
        return when {
            i.devClass == 9 || 9 in cls -> "hub"
            8 in cls -> "storage"
            3 in cls -> "hid"
            1 in cls -> "audio"
            14 in cls -> "video"
            7 in cls -> "printer"
            i.ifaces.any { it.cls == 2 && it.sub in intArrayOf(6, 0x0D, 0x0E) } -> "net"
            else -> "other"
        }
    }
}

// ------------------------------------------------------------------------------------------------ qué reclamar y qué extremos usar

class UsbPlan(
    val chip: Chip,
    /** Interfaces que hay que reclamar (claimInterface). */
    val claim: List<Int>,
    /** Valor de wIndex para las órdenes de control (la interfaz de control en CDC, el puerto en CP210x/FTDI). */
    val index: Int,
    val epIn: UsbEp,
    val epOut: UsbEp,
)

object UsbPlanner {
    /** Lanza IllegalArgumentException, con un mensaje pensado para el usuario, si no se puede hablar con el dispositivo. */
    fun plan(i: UsbInfo): UsbPlan {
        val chip = UsbIds.chip(i)
            ?: throw IllegalArgumentException(UsbIds.note(i) ?: "No sé hablar con este dispositivo USB: no es un adaptador serie conocido")
        return when (chip) {
            Chip.CDC_ACM -> {
                val ctl = UsbIds.acmControl(i)!!
                val data = i.ifaces.filter { it.cls == 10 && it.hasBulkPair() }.let { l -> l.firstOrNull { it.id > ctl.id } ?: l.firstOrNull() }
                    ?: ctl.takeIf { it.hasBulkPair() }
                    ?: throw IllegalArgumentException("Este dispositivo CDC no tiene una interfaz de datos con extremos bulk")
                UsbPlan(chip, listOf(ctl.id, data.id).distinct(), ctl.id, data.bulkIn()!!, data.bulkOut()!!)
            }
            Chip.CP210X -> {
                val f = vendorIf(i)
                UsbPlan(chip, listOf(f.id), f.id, f.bulkIn()!!, f.bulkOut()!!)
            }
            Chip.FTDI -> {
                val f = vendorIf(i)
                UsbPlan(chip, listOf(f.id), f.id + 1, f.bulkIn()!!, f.bulkOut()!!)    // FTDI numera los puertos desde 1
            }
            Chip.CH34X -> {
                val f = vendorIf(i)
                UsbPlan(chip, listOf(f.id), 0, f.bulkIn()!!, f.bulkOut()!!)
            }
        }
    }

    private fun vendorIf(i: UsbInfo): UsbIf =
        i.ifaces.firstOrNull { it.cls == 255 && it.hasBulkPair() }
            ?: i.ifaces.firstOrNull { it.hasBulkPair() }
            ?: throw IllegalArgumentException("El dispositivo no tiene una interfaz con extremos bulk de entrada y salida")
}

// ------------------------------------------------------------------------------------------------ parámetros de línea

/** Velocidad y formato de la línea serie. Los valores se validan igual que en la app falsa de las pruebas. */
class Line(val baud: Int, val bits: Int, val parity: String, val stop: Double) {
    /** `stop` como lo lleva el JSON: 1, 1.5 o 2. */
    val stopJson: Any get() = if (stop == 1.0) 1 else if (stop == 2.0) 2 else stop

    companion object {
        val PARITIES: List<String> = listOf("none", "odd", "even", "mark", "space")
        val DEFAULT = Line(115200, 8, "none", 1.0)

        /** Lanza IllegalArgumentException (mensaje en español) si algún valor no es válido. */
        fun of(baud: Int, bits: Int, parity: String, stop: Double): Line {
            require(baud in 50..4_000_000) { "baud fuera de rango (50 a 4000000)" }
            require(bits in 5..8) { "bits debe ser 5, 6, 7 u 8" }
            require(parity in PARITIES) { "parity debe ser none, odd, even, mark o space" }
            require(stop == 1.0 || stop == 1.5 || stop == 2.0) { "stop debe ser 1, 1.5 o 2" }
            return Line(baud, bits, parity, stop)
        }
    }
}

/** Una orden de control enviada al chip y lo que devolvió Android (bytes transferidos, o <0 si falló). */
class Step(val op: String, val rc: Int, val fatal: Boolean = true) {
    val failed: Boolean get() = rc < 0
}

// ------------------------------------------------------------------------------------------------ enlace y controladores

/** Lo único que los controladores necesitan de Android (UsbDeviceConnection + los extremos). */
interface UsbLink {
    /** controlTransfer: bytes transferidos o <0 si falló. */
    fun control(type: Int, req: Int, value: Int, index: Int, data: ByteArray?, len: Int): Int

    /** bulkTransfer de entrada: bytes leídos; <0 si se agotó el plazo o falló (Android no distingue las dos cosas). */
    fun bulkIn(buf: ByteArray, len: Int, timeoutMs: Int): Int

    /** bulkTransfer de salida: bytes escritos o <0. */
    fun bulkOut(buf: ByteArray, off: Int, len: Int, timeoutMs: Int): Int
}

abstract class SerialDriver(protected val link: UsbLink) {
    abstract val chip: Chip

    /** Deja el chip listo (se llama una vez, al abrir). */
    abstract fun init(line: Line, dtr: Boolean, rts: Boolean): List<Step>
    abstract fun setLine(line: Line): List<Step>
    abstract fun setLines(dtr: Boolean, rts: Boolean): List<Step>
    abstract fun setBreak(on: Boolean): List<Step>

    /** Quita de lo recibido lo que no son datos (solo el FTDI). Trabaja sobre el propio búfer y devuelve cuántos bytes quedan. */
    open fun rx(buf: ByteArray, n: Int): Int = n

    protected fun ctl(op: String, type: Int, req: Int, value: Int, index: Int, data: ByteArray? = null, fatal: Boolean = true): Step =
        Step(op, link.control(type, req, value and 0xFFFF, index and 0xFFFF, data, data?.size ?: 0), fatal)

    protected fun le32(v: Int): ByteArray =
        byteArrayOf(v.toByte(), (v shr 8).toByte(), (v shr 16).toByte(), (v shr 24).toByte())
}

/** CDC-ACM (Arduino con ATmega16U2/32U4, ESP32-S2/S3/C3 con USB nativo, Pi Pico, CH9102, etc.). */
class CdcAcmDriver(link: UsbLink, private val ctlIf: Int) : SerialDriver(link) {
    override val chip: Chip get() = Chip.CDC_ACM

    private companion object {
        const val RT = 0x21               // clase, interfaz, host→dispositivo
        const val SET_LINE_CODING = 0x20
        const val SET_CONTROL_LINE_STATE = 0x22
        const val SEND_BREAK = 0x23
    }

    override fun init(line: Line, dtr: Boolean, rts: Boolean): List<Step> = setLine(line) + setLines(dtr, rts)

    override fun setLine(line: Line): List<Step> {
        val msg = le32(line.baud) + byteArrayOf(
            (if (line.stop == 1.0) 0 else if (line.stop == 1.5) 1 else 2).toByte(),
            Line.PARITIES.indexOf(line.parity).toByte(),
            line.bits.toByte(),
        )
        // Hay dispositivos CDC «de mentira» que no aceptan esta orden y aun así mueven datos: no es fatal.
        return listOf(ctl("set_line_coding", RT, SET_LINE_CODING, 0, ctlIf, msg, fatal = false))
    }

    override fun setLines(dtr: Boolean, rts: Boolean): List<Step> =
        listOf(ctl("set_control_line_state", RT, SET_CONTROL_LINE_STATE, (if (dtr) 1 else 0) or (if (rts) 2 else 0), ctlIf, fatal = false))

    override fun setBreak(on: Boolean): List<Step> =
        listOf(ctl("send_break", RT, SEND_BREAK, if (on) 0xFFFF else 0, ctlIf, fatal = false))
}

/** Silicon Labs CP2102/CP2104/CP2105/CP2108. */
class Cp210xDriver(link: UsbLink, private val port: Int) : SerialDriver(link) {
    override val chip: Chip get() = Chip.CP210X

    private companion object {
        const val RT = 0x41               // vendedor, interfaz, host→dispositivo
        const val IFC_ENABLE = 0x00
        const val SET_LINE_CTL = 0x03
        const val SET_BREAK = 0x05
        const val SET_MHS = 0x07
        const val SET_BAUDRATE = 0x1E
    }

    override fun init(line: Line, dtr: Boolean, rts: Boolean): List<Step> =
        listOf(ctl("ifc_enable", RT, IFC_ENABLE, 1, port)) + setLine(line) + setLines(dtr, rts)

    override fun setLine(line: Line): List<Step> {
        if (line.stop == 1.5) throw UnsupportedOperationException("El CP210x no admite 1,5 bits de parada")
        var v = line.bits shl 8
        v = v or when (line.parity) { "odd" -> 0x10; "even" -> 0x20; "mark" -> 0x30; "space" -> 0x40; else -> 0 }
        if (line.stop == 2.0) v = v or 2
        return listOf(
            ctl("set_baudrate", RT, SET_BAUDRATE, 0, port, le32(line.baud)),
            ctl("set_line_ctl", RT, SET_LINE_CTL, v, port),
        )
    }

    /** Los bits 0x0100 y 0x0200 dicen qué línea se está cambiando (DTR, RTS); los bajos, su valor. */
    override fun setLines(dtr: Boolean, rts: Boolean): List<Step> =
        listOf(ctl("set_mhs", RT, SET_MHS, (if (dtr) 0x101 else 0x100) or (if (rts) 0x202 else 0x200), port))

    override fun setBreak(on: Boolean): List<Step> = listOf(ctl("set_break", RT, SET_BREAK, if (on) 1 else 0, port))
}

/** Modelo de chip FTDI, según el byte alto de bcdDevice. Cambia la cuenta del divisor de velocidad. */
enum class FtdiType {
    BM, C2232, R, H2232, H4232, H232, X;

    companion object {
        fun fromBcd(bcd: Int): FtdiType = when (bcd shr 8) {
            5 -> C2232
            7 -> H2232
            8 -> H4232
            9 -> H232
            0x10 -> X
            2, 4 -> BM         // AM y BM: la misma cuenta
            else -> R          // 6 (R) y lo desconocido
        }
    }
}

/** La cuenta del divisor de velocidad del FTDI (la de libftdi). Función pura para poder probarla. */
object FtdiBaud {
    private val FRAC = intArrayOf(0, 3, 2, 4, 1, 5, 6, 7)

    /** ftdi_to_clkbits(): divisor codificado (14 bits enteros + 3 de fracción) para un reloj `clk` dividido entre `div`. */
    private fun clkbits(baud: Int, clk: Long, div: Int): Long {
        if (baud >= clk / div) return 0
        if (baud >= clk / (div + div / 2)) return 1
        if (baud >= clk / (2 * div)) return 2
        val divisor = (clk * 16 / div / baud).toInt()          // 3 bits de fracción y uno más para redondear
        var best = if ((divisor and 1) != 0) divisor / 2 + 1 else divisor / 2
        if (best > 0x20000) best = 0x1FFFF
        return (best shr 3).toLong() or (FRAC[best and 7].toLong() shl 14)
    }

    /** Devuelve (wValue, wIndex) de la orden SET_BAUD_RATE. `port` es el número de puerto FTDI (1 = el primero). */
    fun encode(baud: Int, type: FtdiType, port: Int): Pair<Int, Int> {
        var enc: Long
        if ((type == FtdiType.H2232 || type == FtdiType.H4232 || type == FtdiType.H232) && baud.toLong() * 10 > 120_000_000L / 0x3FFF) {
            enc = clkbits(baud, 120_000_000L, 10) or 0x20000L      // los «H» pueden usar el reloj de 120 MHz
        } else {
            enc = clkbits(baud, 48_000_000L, 16)
        }
        val value = (enc and 0xFFFF).toInt()
        val index = if (type == FtdiType.C2232 || type == FtdiType.H2232 || type == FtdiType.H4232)
            (((enc shr 8) and 0xFF00L).toInt() or port)
        else
            ((enc shr 16) and 0xFFFF).toInt()
        return Pair(value, index)
    }
}

/** FTDI FT232R/FT232H/FT231X/FT2232… (se usa el primer puerto). */
class FtdiDriver(link: UsbLink, private val port: Int, private val type: FtdiType, private val packet: Int) : SerialDriver(link) {
    override val chip: Chip get() = Chip.FTDI

    private companion object {
        const val OUT = 0x40
        const val RESET = 0
        const val MODEM_CTRL = 1
        const val SET_BAUD = 3
        const val SET_DATA = 4
    }

    /** Última configuración de datos (se reutiliza para activar/quitar la señal de ruptura). */
    private var dataValue = 8

    override fun init(line: Line, dtr: Boolean, rts: Boolean): List<Step> =
        listOf(ctl("reset", OUT, RESET, 0, port)) + setLine(line) + setLines(dtr, rts)

    override fun setLine(line: Line): List<Step> {
        val (value, index) = FtdiBaud.encode(line.baud, type, port)
        var data = line.bits
        data = data or when (line.parity) { "odd" -> 0x100; "even" -> 0x200; "mark" -> 0x300; "space" -> 0x400; else -> 0 }
        data = data or (if (line.stop == 1.5) 0x800 else if (line.stop == 2.0) 0x1000 else 0)
        dataValue = data
        return listOf(ctl("set_baudrate", OUT, SET_BAUD, value, index), ctl("set_data", OUT, SET_DATA, data, port))
    }

    override fun setLines(dtr: Boolean, rts: Boolean): List<Step> =
        listOf(ctl("set_modem_ctrl", OUT, MODEM_CTRL, (if (dtr) 0x0101 else 0x0100) or (if (rts) 0x0202 else 0x0200), port))

    override fun setBreak(on: Boolean): List<Step> = listOf(ctl("set_break", OUT, SET_DATA, dataValue or (if (on) 0x4000 else 0), port))

    /** Cada paquete USB (de `packet` bytes) empieza con 2 bytes de estado del módem y de la línea: no son datos. */
    override fun rx(buf: ByteArray, n: Int): Int {
        var out = 0
        var i = 0
        val p = if (packet < 3) 64 else packet
        while (i < n) {
            val end = minOf(i + p, n)
            val start = i + 2
            if (end > start) {
                System.arraycopy(buf, start, buf, out, end - start)
                out += end - start
            }
            i = end
        }
        return out
    }
}

/** La cuenta de velocidad del CH340/CH341. Función pura para poder probarla. */
object Ch34xBaud {
    /** Devuelve (valor para el registro 0x1312, valor para el 0x0F2C), o null si ese baud no se puede. */
    fun regs(baud: Int): Pair<Int, Int>? {
        var factor: Long
        var divisor: Int
        if (baud == 921600) {
            divisor = 7
            factor = 0xF300L
        } else {
            factor = 1_532_620_800L / baud
            divisor = 3
            while (factor > 0xFFF0 && divisor > 0) {
                factor = factor shr 3
                divisor--
            }
            if (factor > 0xFFF0) return null
            factor = 0x10000 - factor
        }
        divisor = divisor or 0x0080          // sin este bit el CH341A espera a juntar un paquete entero antes de entregar nada
        return Pair((((factor and 0xFF00) or divisor.toLong()).toInt()), (factor and 0xFF).toInt())
    }

    fun lcr(line: Line): Int {
        var lcr = 0x80 or 0x40                                    // recibir y transmitir
        lcr = lcr or when (line.bits) { 5 -> 0x00; 6 -> 0x01; 7 -> 0x02; else -> 0x03 }
        lcr = lcr or when (line.parity) {
            "odd" -> 0x08
            "even" -> 0x08 or 0x10
            "mark" -> 0x08 or 0x20
            "space" -> 0x08 or 0x20 or 0x10
            else -> 0
        }
        if (line.stop == 2.0) lcr = lcr or 0x04
        return lcr
    }
}

/** WCH CH340/CH341. */
class Ch34xDriver(link: UsbLink) : SerialDriver(link) {
    override val chip: Chip get() = Chip.CH34X

    private companion object {
        const val OUT = 0x40
        const val IN = 0xC0
        const val READ_VERSION = 0x5F
        const val READ_REG = 0x95
        const val WRITE_REG = 0x9A
        const val SERIAL_INIT = 0xA1
        const val MODEM_CTRL = 0xA4
    }

    /** Estado de DTR/RTS que se mandó por última vez (el CH34x usa lógica invertida: 0 = línea activa). */
    private var dtr = false
    private var rts = false

    private fun read(op: String, req: Int, value: Int): Step = ctl(op, IN, req, value, 0, ByteArray(2), fatal = false)

    private fun baud(line: Line): List<Step> {
        val r = Ch34xBaud.regs(line.baud) ?: throw UnsupportedOperationException("El CH34x no admite ${line.baud} baudios")
        return listOf(ctl("set_baudrate_1312", OUT, WRITE_REG, 0x1312, r.first), ctl("set_baudrate_0f2c", OUT, WRITE_REG, 0x0F2C, r.second))
    }

    override fun init(line: Line, dtr: Boolean, rts: Boolean): List<Step> {
        if (line.stop == 1.5) throw UnsupportedOperationException("El CH34x no admite 1,5 bits de parada")
        this.dtr = dtr
        this.rts = rts
        val steps = ArrayList<Step>()
        steps += read("read_version", READ_VERSION, 0)
        steps += ctl("serial_init", OUT, SERIAL_INIT, 0, 0)
        steps += baud(line)
        steps += read("read_lcr", READ_REG, 0x2518)
        steps += ctl("set_lcr", OUT, WRITE_REG, 0x2518, Ch34xBaud.lcr(line))
        steps += read("read_status", READ_REG, 0x0706)
        steps += ctl("init_extra", OUT, SERIAL_INIT, 0x501F, 0xD90A, fatal = false)
        steps += baud(line)
        steps += setLines(dtr, rts)
        return steps
    }

    override fun setLine(line: Line): List<Step> {
        if (line.stop == 1.5) throw UnsupportedOperationException("El CH34x no admite 1,5 bits de parada")
        return baud(line) + ctl("set_lcr", OUT, WRITE_REG, 0x2518, Ch34xBaud.lcr(line))
    }

    override fun setLines(dtr: Boolean, rts: Boolean): List<Step> {
        this.dtr = dtr
        this.rts = rts
        val v = ((if (dtr) 0x20 else 0) or (if (rts) 0x40 else 0)).inv()
        return listOf(ctl("set_modem_ctrl", OUT, MODEM_CTRL, v, 0))
    }

    override fun setBreak(on: Boolean): List<Step> {
        val req = ByteArray(2)
        val rd = link.control(IN, READ_REG, 0x1805, 0, req, 2)
        if (rd < 0) return listOf(Step("read_break", rd))
        if (on) {
            req[0] = (req[0].toInt() and 1.inv()).toByte()
            req[1] = (req[1].toInt() and 0x40.inv()).toByte()
        } else {
            req[0] = (req[0].toInt() or 1).toByte()
            req[1] = (req[1].toInt() or 0x40).toByte()
        }
        val v = ((req[1].toInt() and 0xFF) shl 8) or (req[0].toInt() and 0xFF)
        return listOf(Step("read_break", rd, false), ctl("set_break", OUT, WRITE_REG, 0x1805, v))
    }
}

/** El puerto serie ya abierto: lectura y escritura por los extremos bulk, con la limpieza de datos que pida el chip. */
class SerialPort(private val link: UsbLink, val drv: SerialDriver) {
    companion object {
        /** Android < 9 no acepta transferencias bulk mayores de 16 KiB. */
        const val CHUNK = 16384
    }

    /** Bytes recibidos (ya filtrados). 0 = nada útil; <0 = se agotó el plazo o hubo un error (Android no los distingue). */
    fun read(buf: ByteArray, timeoutMs: Int): Int {
        val n = link.bulkIn(buf, buf.size, timeoutMs)
        return if (n > 0) drv.rx(buf, n) else n
    }

    /** Escribe todo. false si Android devolvió un error o se agotó el plazo (el dispositivo ya no contesta). */
    fun write(data: ByteArray, off: Int, len: Int, timeoutMs: Int = 5000): Boolean {
        var o = off
        var left = len
        while (left > 0) {
            val rc = link.bulkOut(data, o, minOf(left, CHUNK), timeoutMs)
            if (rc <= 0) return false
            o += rc
            left -= rc
        }
        return true
    }
}

/** Crea el controlador del chip. `bcd` es el bcdDevice (solo lo necesita el FTDI). */
object SerialDrivers {
    fun create(plan: UsbPlan, link: UsbLink, bcd: Int): SerialDriver = when (plan.chip) {
        Chip.CDC_ACM -> CdcAcmDriver(link, plan.index)
        Chip.CP210X -> Cp210xDriver(link, plan.index)
        Chip.FTDI -> FtdiDriver(link, plan.index, FtdiType.fromBcd(bcd), plan.epIn.maxPacket)
        Chip.CH34X -> Ch34xDriver(link)
    }
}
