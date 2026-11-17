#!/usr/bin/env python3
"""Referencia independiente para las velocidades (baudios) de los chips FTDI y CH34x.

Es una transcripción en Python de:
  · libftdi: ftdi_to_clkbits() y ftdi_convert_baudrate()  (src/ftdi.c),
  · el cálculo de la velocidad del controlador de Linux  drivers/usb/serial/ch341.c.
No comparte código con el controlador Kotlin (android/app/src/main/java/org/nexo/bridge/UsbSerial.kt): sirve para comprobar que lo
que esa clase manda al chip sale de la misma fórmula que el original y que no cambia sin querer. Los valores de FTDI de 9600, 19200,
38400 y 115200 coinciden además con la nota técnica AN232B-05 de FTDI (los prueba UsbSerialTest.kt por su lado).

  python3 tests/ref_baud.py                  imprime las tablas
  python3 tests/ref_baud.py --check ARCHIVO  compara las tablas que lleva ARCHIVO (UsbSerialTest.kt) con esta referencia:
                                             sale con 0 si coinciden y con 1 si alguna fila difiere o falta
"""
import re
import sys

FRAC = [0, 3, 2, 4, 1, 5, 6, 7]
BAUDS = [300, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 74880, 115200, 230400, 250000, 460800, 500000, 921600,
         1000000, 1500000, 2000000, 3000000]


def clkbits(baud, clk, div):
    """ftdi_to_clkbits(): el divisor de 14 bits + 3 de fracción que entiende el chip."""
    if baud >= clk // div:
        return 0
    if baud >= clk // (div + div // 2):
        return 1
    if baud >= clk // (2 * div):
        return 2
    divisor = clk * 16 // div // baud
    best = divisor // 2 + 1 if divisor & 1 else divisor // 2
    if best > 0x20000:
        best = 0x1ffff
    return (best >> 3) | (FRAC[best & 7] << 14)


def ftdi(baud, kind, port=1):
    """(value, index) de la orden SET_BAUDRATE para un tipo de chip FTDI."""
    h = kind in ("2232h", "4232h", "232h")
    if h and baud * 10 > 120000000 // 0x3fff:
        enc = clkbits(baud, 120000000, 10) | 0x20000
    else:
        enc = clkbits(baud, 48000000, 16)
    value = enc & 0xffff
    if kind in ("2232c", "2232h", "4232h"):
        index = ((enc >> 8) & 0xff00) | port
    else:
        index = (enc >> 16) & 0xffff
    return value, index


def ch34x(baud):
    """(registros 0x1312, 0x1313) del CH340/CH341, o None si la velocidad no cabe."""
    if baud == 921600:
        div, factor = 7, 0xf300
    else:
        factor = 1532620800 // baud
        div = 3
        while factor > 0xfff0 and div > 0:
            factor >>= 3
            div -= 1
        if factor > 0xfff0:
            return None
        factor = 0x10000 - factor
    div |= 0x80
    return (factor & 0xff00) | div, factor & 0xff


def table():
    ft = [(b,) + ftdi(b, "r") + ftdi(b, "232h") + ftdi(b, "2232c", 1) for b in BAUDS]
    ch = [(b,) + (ch34x(b) or (None, None)) for b in BAUDS]
    return ft, ch


def check(path):
    """Compara las filas de intArrayOf(...) de UsbSerialTest.kt con la referencia."""
    src = open(path, encoding="utf-8").read()
    hx = r"0x([0-9a-fA-F]+)"
    ft_rows = {}
    for m in re.finditer(r"intArrayOf\((\d+), %s, (\d+), %s, (\d+), %s, (\d+)\)" % (hx, hx, hx), src):
        g = m.groups()
        ft_rows[int(g[0])] = (int(g[1], 16), int(g[2]), int(g[3], 16), int(g[4]), int(g[5], 16), int(g[6]))
    ch_rows = {}
    for m in re.finditer(r"intArrayOf\((\d+), %s, %s\)" % (hx, hx), src):
        g = m.groups()
        ch_rows[int(g[0])] = (int(g[1], 16), int(g[2], 16))
    ft, ch = table()
    bad = 0
    for row in ft:
        if ft_rows.get(row[0]) != tuple(row[1:]):
            bad += 1
            print("FTDI %d: el test lleva %s y la referencia da %s" % (row[0], ft_rows.get(row[0]), tuple(row[1:])))
    for row in ch:
        if ch_rows.get(row[0]) != tuple(row[1:]):
            bad += 1
            print("CH34x %d: el test lleva %s y la referencia da %s" % (row[0], ch_rows.get(row[0]), tuple(row[1:])))
    extra = (set(ft_rows) | set(ch_rows)) - set(BAUDS)
    if extra:
        bad += 1
        print("el test lleva velocidades que la referencia no calcula: %s" % sorted(extra))
    print("%d filas de FTDI y %d de CH34x comparadas, %d diferencias" % (len(ft), len(ch), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--check":
        sys.exit(check(sys.argv[2]))
    if len(sys.argv) != 1:
        print(__doc__)
        sys.exit(2)
    f, c = table()
    for b, *r in f:
        print("ftdi %7d r=(0x%04x,0x%04x) 232h=(0x%04x,0x%04x) 2232c=(0x%04x,0x%04x)" % ((b,) + tuple(r)))
    for b, *r in c:
        print("ch34x %7d %s" % (b, "None" if r[0] is None else "(0x%04x,0x%02x)" % tuple(r)))
