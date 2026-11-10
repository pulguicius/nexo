#!/usr/bin/env python3
"""Sonda de tipos D-Bus para tests/dbus_tests.sh.

Carga el código de nexo-dbus, exporta en el bus la interfaz org.nexo.Test (un «eco» de muchos tipos D-Bus, incluidos
los que usarán BlueZ y NetworkManager) y se queda esperando. Las pruebas la llaman con busctl —un cliente
independiente, el de systemd— y comprueban que lo que vuelve es lo que se mandó: así se sabe que el empaquetado de
mensajes de nexo-dbus es el de la especificación y no solo «lo que él mismo entiende».

Uso: dbus_probe.py RUTA_DE_nexo-dbus DIRECCIÓN_DEL_BUS
"""
import importlib.machinery
import importlib.util
import sys
import time

sys.dont_write_bytecode = True


def load(path):
    loader = importlib.machinery.SourceFileLoader("nexo_dbus", path)
    spec = importlib.util.spec_from_loader("nexo_dbus", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def main():
    nd = load(sys.argv[1])
    bus = nd.Bus(sys.argv[2], "sonda")
    bus.connect()
    it = nd.Interface("org.nexo.Test")

    def echo(sig):
        name = "Echo_" + sig.replace("{", "D").replace("}", "E").replace("(", "S").replace(")", "T")
        n = len(nd.split_sig(sig))
        it.method(name, sig, sig, fn=(lambda *a: a) if n > 1 else (lambda a: a))

    for sig in ["y", "b", "n", "q", "i", "u", "x", "t", "d", "s", "o", "g", "v", "ai", "as", "ay", "ad", "at",
                "a{sv}", "a{ss}", "(si)", "a(si)", "aai", "ao", "a{sa{sv}}", "a(sa{sv})", "(ysa{sv}as)",
                "a{oa{sa{sv}}}", "(yyy)"]:
        echo(sig)
    it.method("Multi", "su", "sub", fn=lambda s, u: (s + "!", u + 1, True))
    bus.export("/org/nexo/Test", it)
    bus.request_name("org.nexo.Test")
    while not bus.closed.is_set():
        time.sleep(0.5)


if __name__ == "__main__":
    main()
