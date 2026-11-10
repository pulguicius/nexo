#!/usr/bin/env python3
"""Un «dueño» de un nombre de bus para tests/dbus_system_tests.sh: hace de BlueZ (o de lo que sea) «de verdad» para ver
cómo reacciona nexo-dbus: modo pasivo, NEXO_DBUS_FORCE=1, que alguien le reclame el nombre…

Uso: dbus_hold.py RUTA_DE_nexo-dbus DIRECCIÓN NOMBRE [--replace] [--no-replacement]
Escribe en la salida estándar «OWNER <nombre único> <código>» al arrancar y «LOST <nombre>» si se lo quitan."""
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
    addr, name = sys.argv[2], sys.argv[3]
    bus = nd.Bus(addr, "dueño")
    bus.connect()
    bus.on_name_lost = lambda n: print("LOST", n, flush=True)
    r = bus.request_name(name, allow_replacement="--no-replacement" not in sys.argv, replace="--replace" in sys.argv)
    print("OWNER", bus.unique_name, r, flush=True)
    while True:
        time.sleep(1)


if __name__ == "__main__":
    main()
