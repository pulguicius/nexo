#!/usr/bin/env python3
"""Demonio de notificaciones FALSO para tests/dbus_tests.sh (org.freedesktop.Notifications).

Hace lo que hacen dunst, mako, swaync, GNOME o KDE de cara a un programa que les manda avisos: ofrece GetCapabilities,
Notify, CloseNotification y GetServerInformation, y apunta cada llamada —una por línea, en JSON— en el archivo --log. Así las
pruebas comprueban QUÉ recibe un demonio de verdad de nexo-dbus (el texto, el reemplazo de los avisos que se repiten, la
urgencia, la categoría, que no se cuele marcado…) sin mirar las entrañas de nexo-dbus. Usa el código de nexo-dbus solo como
cliente D-Bus (para no depender de dunst ni de GLib en las pruebas): es el mismo empaquetado de mensajes que ya valida
tests/dbus_probe.py contra busctl.

Uso: fake_notifd.py RUTA_DE_nexo-dbus DIRECCIÓN_DEL_BUS --log ARCHIVO [opciones]
  --ctl ARCHIVO     órdenes de prueba, una por línea (se van leyendo según se añaden):
                      closed ID MOTIVO   cierra el aviso ID como si el usuario lo hubiera cerrado (2), caducara (1) u otro (4):
                                         emite NotificationClosed(ID, MOTIVO)
                      action ID CLAVE    emite ActionInvoked(ID, CLAVE) (el usuario pulsó un botón)
                      release            suelta el nombre: como si el demonio se cerrara
                      own                vuelve a pedir el nombre
                      restart            lo suelta, olvida todos los avisos y los números (empiezan otra vez en 1) y lo pide
                      quit               termina
  --caps A,B,C      lo que contesta GetCapabilities (por omisión «body,body-markup»; «-» = nada)
  --name N --vendor V --version X   lo que contesta GetServerInformation
  --no-info         no ofrece GetServerInformation (algunos demonios raros)
  --fail-notify     Notify siempre da un error (un demonio roto)
Líneas del --log:
  {"op":"notify","id":N,"app":…,"replaces":N,"icon":…,"summary":…,"body":…,"actions":[…],"hints":{"urgency":["y",1]},"expire":-1}
  {"op":"close","id":N,"known":true|false}   ·   {"op":"emit","signal":"NotificationClosed","id":N,"reason":2}
  {"op":"caps"}   ·   {"op":"info"}   ·   {"op":"ctl","line":"…"}
"""
import argparse
import importlib.machinery
import importlib.util
import json
import os
import sys
import threading
import time

sys.dont_write_bytecode = True

NAME = "org.freedesktop.Notifications"
PATH = "/org/freedesktop/Notifications"


def load(path):
    loader = importlib.machinery.SourceFileLoader("nexo_dbus", path)
    spec = importlib.util.spec_from_loader("nexo_dbus", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("nexo_dbus")
    ap.add_argument("address")
    ap.add_argument("--log", required=True)
    ap.add_argument("--ctl")
    ap.add_argument("--caps", default="body,body-markup")
    ap.add_argument("--name", default="fakenotifd")
    ap.add_argument("--vendor", default="nexo-tests")
    ap.add_argument("--version", default="1.0")
    ap.add_argument("--no-info", action="store_true")
    ap.add_argument("--fail-notify", action="store_true")
    a = ap.parse_args()

    nd = load(a.nexo_dbus)
    bus = nd.Bus(a.address, "notifd")
    bus.connect()
    lock = threading.Lock()
    state = {"next": 0}
    live = {}                                   # número → título de los avisos que están en pantalla
    caps = [] if a.caps == "-" else [c for c in a.caps.split(",") if c]

    def note(**kw):
        with lock:
            with open(a.log, "a", encoding="utf-8") as f:
                f.write(json.dumps(kw, ensure_ascii=False, separators=(",", ":")) + "\n")

    def get_caps():
        note(op="caps")
        return list(caps)

    def info():
        note(op="info")
        return (a.name, a.vendor, a.version, "1.2")

    def notify(app, replaces, icon, summary, body, actions, hints, expire):
        if a.fail_notify:
            raise nd.DBusError("org.freedesktop.Notifications.Error.Fake", "demonio roto a propósito")
        with lock:
            if replaces and replaces in live:       # reemplaza uno que existe: sigue siendo el mismo número
                nid = replaces
            else:
                state["next"] += 1
                nid = state["next"]
            live[nid] = summary
        note(op="notify", id=nid, app=app, replaces=replaces, icon=icon, summary=summary, body=body, actions=list(actions),
             hints=dict((k, [v.sig, v.value]) for k, v in hints.items()), expire=expire)
        return nid

    def close(nid):
        with lock:
            known = live.pop(nid, None) is not None
        note(op="close", id=nid, known=known)
        if not known:                               # como pide la especificación: error si ya no existe
            raise nd.DBusError("org.freedesktop.DBus.Error.Failed", "no existe el aviso %d" % nid)
        note(op="emit", signal="NotificationClosed", id=nid, reason=3)
        bus.emit(PATH, NAME, "NotificationClosed", "uu", (nid, 3))

    it = nd.Interface(NAME)
    it.method("GetCapabilities", "", "as", fn=get_caps, outs=("capabilities",))
    it.method("Notify", "susssasa{sv}i", "u", fn=notify,
              args=("app_name", "replaces_id", "app_icon", "summary", "body", "actions", "hints", "expire_timeout"), outs=("id",))
    it.method("CloseNotification", "u", "", fn=close, args=("id",))
    if not a.no_info:
        it.method("GetServerInformation", "", "ssss", fn=info, outs=("name", "vendor", "version", "spec_version"))
    it.signal("NotificationClosed", "uu", ("id", "reason"))
    it.signal("ActionInvoked", "us", ("id", "action_key"))
    bus.export(PATH, it)
    r = bus.request_name(NAME)
    if r not in (1, 4):
        sys.stderr.write("no pude quedarme con %s (respuesta %s): ¿ya hay otro demonio?\n" % (NAME, r))
        return 3

    def ctl(line):
        w = line.split()
        if not w:
            return
        note(op="ctl", line=line)
        if w[0] == "closed" and len(w) >= 3:
            nid, reason = int(w[1]), int(w[2])
            with lock:
                live.pop(nid, None)
            note(op="emit", signal="NotificationClosed", id=nid, reason=reason)
            bus.emit(PATH, NAME, "NotificationClosed", "uu", (nid, reason))
        elif w[0] == "action" and len(w) >= 3:
            bus.emit(PATH, NAME, "ActionInvoked", "us", (int(w[1]), w[2]))
        elif w[0] == "release":
            bus.release_name(NAME)
        elif w[0] == "own":
            bus.request_name(NAME)
        elif w[0] == "restart":
            bus.release_name(NAME)
            with lock:
                live.clear()
                state["next"] = 0
            time.sleep(0.2)
            bus.request_name(NAME)
        elif w[0] == "quit":
            os._exit(0)

    pos = 0
    while not bus.closed.is_set():
        time.sleep(0.1)
        if not a.ctl:
            continue
        try:
            with open(a.ctl, "rb") as f:
                f.seek(pos)
                data = f.read()
                pos += len(data)
        except OSError:
            continue
        for ln in data.decode("utf-8", "replace").splitlines():
            try:
                ctl(ln.strip())
            except Exception as e:
                sys.stderr.write("ctl: %r en %r\n" % (e, ln))
    return 0


if __name__ == "__main__":
    sys.exit(main())
