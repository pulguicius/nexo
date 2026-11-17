#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Clientes de PRUEBA para tests/usb_tests.sh.

Hacen, contra lo que ofrece «nexo usb bridge», lo que harían avrdude, esptool o un programa cualquiera:

  pty  RUTA            abre el puerto serie falso (un PTY), fija la velocidad en crudo, escribe y lee
  tcp  HOST:PUERTO     el TCP crudo (avrdude -c arduino -P net:HOST:PUERTO)
  rfc  HOST:PUERTO     RFC 2217 (lo que usan esptool y pyserial con rfc2217://)
  echo RUTA|HOST:PUERTO --via pty|tcp|rfc --bytes N   manda N bytes (todos los valores de 0 a 255) y comprueba que vuelven iguales

Escriben UNA línea de JSON en la salida estándar. No son esas herramientas: el cliente RFC 2217 está escrito a partir del
RFC (pyserial no está disponible en el entorno de pruebas) y se comporta como pyserial al abrir (pide ECHO, ofrece y pide
COM-PORT, acepta BINARY, y cada SET-* espera la respuesta que repite el valor). Si algún día falla contra pyserial de verdad,
la prueba que hay que corregir es esta.
"""

import argparse
import json
import os
import select
import socket
import struct
import sys
import termios
import threading
import time

IAC, DONT, DO, WONT, WILL, SB, SE = 255, 254, 253, 252, 251, 250, 240
BINARY, ECHO, SGA, COM = 0, 1, 3, 44


def pattern(n):
    """n bytes que recorren los 256 valores (con un desplazamiento distinto en cada vuelta, para que un byte perdido se note)."""
    return bytes(((i * 7) + (i >> 8)) & 0xFF for i in range(n))


def hostport(s):
    h, _, p = s.rpartition(":")
    return h or "127.0.0.1", int(p)


# ---------------------------------------------------------------------------------------------------------- PTY


def pty_open(path, baud, delay):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
    t = termios.tcgetattr(fd)
    t[0] = 0
    t[1] = 0
    t[3] = 0
    t[2] = (t[2] & ~(termios.CSIZE | termios.PARENB | termios.CSTOPB)) | termios.CS8 | termios.CREAD | termios.CLOCAL
    t[4] = t[5] = getattr(termios, "B%d" % baud)
    t[6][termios.VMIN] = 0
    t[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, t)
    time.sleep(delay)
    return fd


def read_fd(fd, secs):
    end = time.time() + secs
    got = b""
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                d = os.read(fd, 65536)
            except OSError:
                break
            if not d:
                break
            got += d
    return got


def cmd_pty(a):
    fd = pty_open(a.target, a.baud, a.delay)
    if a.flush:
        read_fd(fd, 0.3)
    if a.write:
        os.write(fd, bytes.fromhex(a.write))
    got = read_fd(fd, a.read)
    out = {"rx": got.hex()}
    sys.stdout.write(json.dumps(out) + "\n")
    sys.stdout.flush()
    if a.hold:
        time.sleep(a.hold)
    os.close(fd)
    return 0


# ---------------------------------------------------------------------------------------------------------- TCP crudo


def cmd_tcp(a):
    host, port = hostport(a.target)
    s = socket.create_connection((host, port), timeout=5)
    time.sleep(a.delay)
    if a.flush:
        s.settimeout(0.3)
        try:
            while s.recv(65536):
                pass
        except (socket.timeout, OSError):
            pass
    if a.write:
        s.sendall(bytes.fromhex(a.write))
    got = b""
    end = time.time() + a.read
    s.settimeout(0.1)
    while time.time() < end:
        try:
            d = s.recv(65536)
        except socket.timeout:
            continue
        except OSError:
            break
        if not d:
            break
        got += d
    sys.stdout.write(json.dumps({"rx": got.hex()}) + "\n")
    sys.stdout.flush()
    if a.hold:
        time.sleep(a.hold)
    s.close()
    return 0


# ---------------------------------------------------------------------------------------------------------- RFC 2217


class RfcClient(object):
    def __init__(self, host, port, timeout=3.0):
        self.s = socket.create_connection((host, port), timeout=5)
        self.s.settimeout(0.2)
        self.timeout = timeout
        self.rx = bytearray()
        self.cv = threading.Condition()
        self.opts = {}            # (orden, opción) recibidos
        self.answers = {}         # código de respuesta → valor
        self.st = 0
        self.cmd = 0
        self.sb = bytearray()
        self.alive = True
        self.t = threading.Thread(target=self._run, daemon=True)
        self.t.start()
        # como pyserial: ECHO y COM-PORT en las dos direcciones
        self._opt(DO, ECHO)
        self._opt(WILL, COM)
        self._opt(DO, COM)
        end = time.time() + timeout
        while time.time() < end:
            with self.cv:
                if (DO, COM) in self.opts:
                    break
            time.sleep(0.02)
        else:
            raise RuntimeError("el servidor no acepta RFC2217: %r" % (sorted(self.opts),))

    def _opt(self, cmd, opt):
        self.s.sendall(bytes([IAC, cmd, opt]))

    def _run(self):
        while self.alive:
            try:
                d = self.s.recv(65536)
            except socket.timeout:
                continue
            except OSError:
                break
            if not d:
                break
            self._feed(d)
        with self.cv:
            self.alive = False
            self.cv.notify_all()

    def _feed(self, data):
        for b in data:
            if self.st == 0:
                if b == IAC:
                    self.st = 1
                else:
                    with self.cv:
                        self.rx.append(b)
                        self.cv.notify_all()
            elif self.st == 1:
                if b == IAC:
                    with self.cv:
                        self.rx.append(255)
                        self.cv.notify_all()
                    self.st = 0
                elif b in (WILL, WONT, DO, DONT):
                    self.cmd = b
                    self.st = 2
                elif b == SB:
                    self.sb = bytearray()
                    self.st = 3
                else:
                    self.st = 0
            elif self.st == 2:
                self._got_opt(self.cmd, b)
                self.st = 0
            elif self.st == 3:
                if b == IAC:
                    self.st = 4
                else:
                    self.sb.append(b)
            else:
                if b == IAC:
                    self.sb.append(255)
                    self.st = 3
                elif b == SE:
                    self._got_sub(bytes(self.sb))
                    self.st = 0
                else:
                    self.st = 0

    def _got_opt(self, cmd, opt):
        with self.cv:
            self.opts[(cmd, opt)] = True
            self.cv.notify_all()
        if opt == BINARY:
            if cmd == WILL and not getattr(self, "_do_bin", False):
                self._do_bin = True
                self._opt(DO, BINARY)
            elif cmd == DO and not getattr(self, "_will_bin", False):
                self._will_bin = True
                self._opt(WILL, BINARY)
        elif opt in (COM, ECHO):
            pass
        else:                         # lo desconocido se rechaza, como hace pyserial
            if cmd == WILL:
                self._opt(DONT, opt)
            elif cmd == DO:
                self._opt(WONT, opt)

    def _got_sub(self, p):
        if len(p) >= 2 and p[0] == COM:
            with self.cv:
                self.answers[p[1] - 100] = p[2:]
                self.cv.notify_all()

    def sub(self, cmd, value=b""):
        body = bytes([COM, cmd]) + value
        with self.cv:
            self.answers.pop(cmd, None)
        self.s.sendall(bytes([IAC, SB]) + body.replace(b"\xff", b"\xff\xff") + bytes([IAC, SE]))
        end = time.time() + self.timeout
        with self.cv:
            while cmd not in self.answers:
                left = end - time.time()
                if left <= 0:
                    return None
                self.cv.wait(left)
            return self.answers[cmd]

    def write(self, data):
        self.s.sendall(data.replace(b"\xff", b"\xff\xff"))

    def read(self, secs=0.5, n=None):
        end = time.time() + secs
        with self.cv:
            while time.time() < end and (n is None or len(self.rx) < n):
                self.cv.wait(max(0.01, min(0.1, end - time.time())))
            out = bytes(self.rx)
            self.rx.clear()
        return out

    def close(self):
        self.alive = False
        try:
            self.s.close()
        except OSError:
            pass


def onoff(s):
    return s.lower() in ("1", "on", "si", "yes", "true")


def cmd_rfc(a):
    host, port = hostport(a.target)
    c = RfcClient(host, port)
    res = {"opts": sorted("%d,%d" % k for k in c.opts)}
    time.sleep(a.delay)
    if a.baud is not None:
        v = c.sub(1, struct.pack("!I", a.baud))
        res["baud"] = struct.unpack("!I", v)[0] if v and len(v) == 4 else None
    if a.size is not None:
        v = c.sub(2, bytes([a.size]))
        res["size"] = v[0] if v else None
    if a.parity is not None:
        v = c.sub(3, bytes([a.parity]))
        res["parity"] = v[0] if v else None
    if a.stop is not None:
        v = c.sub(4, bytes([a.stop]))
        res["stop"] = v[0] if v else None
    for flag, name, on, off in ((a.dtr, "dtr", 8, 9), (a.rts, "rts", 11, 12)):
        if flag is not None:
            v = c.sub(5, bytes([on if onoff(flag) else off]))
            res[name] = v[0] if v else None
    if a.flush:
        c.read(0.4)
    if a.write:
        c.write(bytes.fromhex(a.write))
    res["rx"] = c.read(a.read).hex()
    sys.stdout.write(json.dumps(res) + "\n")
    sys.stdout.flush()
    if a.hold:
        time.sleep(a.hold)
    c.close()
    return 0


# ---------------------------------------------------------------------------------------------------------- eco


def cmd_echo(a):
    data = pattern(a.bytes)
    got = bytearray()
    t0 = time.time()
    if a.via == "pty":
        fd = pty_open(a.target, a.baud, a.delay)
        os.set_blocking(fd, False)
        sent = 0
        while len(got) < len(data) and time.time() - t0 < a.timeout:
            w = [fd] if sent < len(data) else []
            r, w, _ = select.select([fd], w, [], 0.1)
            if r:
                try:
                    got += os.read(fd, 65536)
                except (BlockingIOError, InterruptedError):
                    pass
                except OSError:
                    break
            if w:
                try:
                    sent += os.write(fd, data[sent:sent + 4096])
                except (BlockingIOError, InterruptedError):
                    pass
                except OSError:
                    break
        os.close(fd)
    elif a.via == "tcp":
        host, port = hostport(a.target)
        s = socket.create_connection((host, port), timeout=5)
        time.sleep(a.delay)
        s.setblocking(False)
        sent = 0
        while len(got) < len(data) and time.time() - t0 < a.timeout:
            w = [s] if sent < len(data) else []
            r, w, _ = select.select([s], w, [], 0.1)
            if r:
                try:
                    d = s.recv(65536)
                except (BlockingIOError, InterruptedError):
                    d = None
                except OSError:
                    break
                if d == b"":                  # el otro lado cerró
                    break
                if d:
                    got += d
            if w:
                try:
                    sent += s.send(data[sent:sent + 4096])
                except (BlockingIOError, InterruptedError):
                    pass
        s.close()
    else:
        host, port = hostport(a.target)
        c = RfcClient(host, port)
        time.sleep(a.delay)
        sent = 0
        while len(got) < len(data) and time.time() - t0 < a.timeout:
            if sent < len(data):
                c.write(data[sent:sent + 2048])
                sent += min(2048, len(data) - sent)
            got += c.read(0.02)
        got += c.read(0.3)
        c.close()
    got = bytes(got)
    first = next((i for i in range(min(len(got), len(data))) if got[i] != data[i]), None)
    out = {"sent": len(data), "got": len(got), "equal": got == data, "first_diff": first,
           "seconds": round(time.time() - t0, 2)}
    sys.stdout.write(json.dumps(out) + "\n")
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd")
    for name in ("pty", "tcp", "rfc", "echo"):
        p = sub.add_parser(name)
        p.add_argument("target")
        p.add_argument("--baud", type=int, default=None)
        p.add_argument("--write", default="")
        p.add_argument("--read", type=float, default=1.0)
        p.add_argument("--delay", type=float, default=0.3)
        p.add_argument("--hold", type=float, default=0.0)
        p.add_argument("--flush", action="store_true")
        if name == "rfc":
            p.add_argument("--size", type=int, default=None)
            p.add_argument("--parity", type=int, default=None)
            p.add_argument("--stop", type=int, default=None)
            p.add_argument("--dtr", default=None)
            p.add_argument("--rts", default=None)
        if name == "echo":
            p.add_argument("--via", choices=("pty", "tcp", "rfc"), default="pty")
            p.add_argument("--bytes", type=int, default=65536)
            p.add_argument("--timeout", type=float, default=30.0)
    a = ap.parse_args()
    if a.cmd in ("pty", "echo") and a.baud is None:
        a.baud = 115200
    if a.cmd == "pty":
        return cmd_pty(a)
    if a.cmd == "tcp":
        return cmd_tcp(a)
    if a.cmd == "rfc":
        return cmd_rfc(a)
    if a.cmd == "echo":
        return cmd_echo(a)
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
