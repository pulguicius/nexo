#!/usr/bin/env python3
"""App Nexo FALSA, para probar el cliente (y nexo-dbus) sin un móvil, y en CI.

Imita el protocolo de docs/PROTOCOLO.md (versión 1, revisión 3): JSON por línea sobre TCP en 127.0.0.1,
con token, eventos en vivo y el comando `bootstrap` que entrega el instalador (igual que Bootstrap.kt).
Es la «especificación ejecutable» del protocolo: si la app real y este archivo difieren, uno de los dos tiene un fallo.

Uso:  fake_app.py --token HEX --termux-dir ../termux --portfile /tmp/p [--record /tmp/r.jsonl]
      fake_app.py --evil ...          hace de "otra app" que ocupó el puente y sirve un script malicioso
      fake_app.py --old ...           se comporta como la app 0.1.x (sin audio, media ni comandos nuevos)
      fake_app.py --freeze ...        acepta conexiones y nunca contesta (como una app congelada por HyperOS)
      fake_app.py --drop-first N ...  cierra sin contestar las N primeras conexiones
      fake_app.py --slow-ms N ...     tarda N ms en contestar cada comando
      fake_app.py --no-listener ...   sin «acceso a notificaciones» (media.* pide un toque)
      fake_app.py --no-session ...    con acceso a notificaciones pero sin nada reproduciéndose
      fake_app.py --reqlog FILE       anota cada comando recibido (un JSON por línea; sin token)
      fake_app.py --drop-after-hello N  las N primeras conexiones contestan el hello y se cortan al recibir el primer comando
      fake_app.py --leak-token        mete el token en el registro (para probar que el cliente lo oculta)
"""
import argparse
import base64
import collections
import json
import os
import socketserver
import sys
import threading
import time

LOCK = threading.Lock()
SUBS = []  # (handler, topics)
ARGS = None
STARTED = time.monotonic()
LOGLINES = collections.deque(maxlen=200)
CONN_COUNT = [0]

STATE = {"wifi_on": True, "ssid": "MiCasa", "bt_on": True}
NET = {"override": None, "vpn": False, "captive": False}  # --ctl «net cellular|ethernet|none|auto», «net vpn on|off», «net captive on|off»
NOTIF = {"access": True, "forwarding": True}              # permiso de acceso a notificaciones y el interruptor de la app
NOTIFS = []                                               # las notificaciones activas del «móvil»
AUDIO = {"level": 9, "min": 0, "max": 15, "muted": False, "ringer": "normal"}

NETWORKS = [
    {"ssid": "MiCasa", "bssid": "aa:bb:cc:00:00:01", "rssi": -52, "level": 4, "frequency": 5180, "band": "5GHz", "security": "WPA2", "secured": True},
    {"ssid": 'Café "Luz"', "bssid": "aa:bb:cc:00:00:02", "rssi": -70, "level": 2, "frequency": 2437, "band": "2.4GHz", "security": "WPA2", "secured": True},
    {"ssid": "Wi-Fi/Invitados", "bssid": "aa:bb:cc:00:00:03", "rssi": -81, "level": 1, "frequency": 2412, "band": "2.4GHz", "security": "OPEN", "secured": False},
]
SAVED = [
    {"network_id": 0, "ssid": "MiCasa", "security": "WPA2", "hidden": False},
    {"network_id": 1, "ssid": "Oficina", "security": "WPA2", "hidden": False},
    {"network_id": 2, "ssid": 'Café "Luz"', "security": "WPA2", "hidden": False},
    {"network_id": 5, "ssid": "Oculta", "security": "WPA2", "hidden": True},
]
PAIRED = [
    {"name": "Auriculares ñandú", "address": "AA:BB:CC:DD:EE:01", "connected": True, "profiles": ["a2dp", "headset"], "type": "classic", "class": "audio"},
    {"name": None, "address": "AA:BB:CC:DD:EE:02", "connected": False, "profiles": [], "type": "le", "class": "unknown"},
]
ALIASES = {}
BATTERY = {}   # dirección → % (las pruebas lo cambian con --ctl)
OUTPUTS = [
    {"id": 2, "type": "speaker", "name": "Altavoz del teléfono", "address": "", "active": False},
    {"id": 7, "type": "bluetooth_a2dp", "name": "Auriculares ñandú", "address": "AA:BB:CC:DD:EE:01", "active": True},
    {"id": 9, "type": "usb_headset", "name": "USB-C", "address": "", "active": False},
]
TRACKS = [
    {"title": "Canción ñandú", "artist": "Artista", "album": "Álbum", "album_artist": "Artista", "duration_ms": 200000, "track_id": "t1"},
    {"title": "Otra canción", "artist": "Otro artista", "album": "Otro álbum", "album_artist": "Otro artista", "duration_ms": 180000, "track_id": "t2"},
]
MEDIA = {"idx": 0, "state": "playing", "pos0": 30000, "t0": time.monotonic(), "speed": 1.0}
# Un JPEG mínimo: el cliente solo lo decodifica de base64, no lo interpreta.
TINY_JPEG = ("/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////"
             "wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=")

V14_COMMANDS = {"net.status", "notif.status", "notif.list", "notif.dismiss"}     # protocolo 1.4 (red del móvil y notificaciones: la app real los traerá en la 0.4.3)
V14_OPENS = {"nexo_app"}                                                         # paneles (`opens`) que solo existen desde el 1.4


APP_MINOR = 3          # revisión del protocolo que habla la app REAL (Protocol.MINOR en Kotlin): 1.3 = USB serie (0.4.1); súbela a 4 cuando llegue net/notif a la app


def level():
    """Revisión del protocolo que habla esta app falsa. Por defecto, la de la app real (APP_MINOR).
    --old = 0.1.x · --minor2 = 1.2 (0.4.0-beta2: sin usb.*) · --minor3 = 1.3 (con USB) · --minor4 = 1.4 (con USB, net.status y notif.*)."""
    if getattr(ARGS, "old", False):
        return 1
    for n in (2, 3, 4):
        if getattr(ARGS, "minor%d" % n, False):
            return n
    return APP_MINOR


def v13():
    """¿Habla el protocolo 1.3 (usb.*, tema usb)?"""
    return level() >= 3


def v14():
    """¿Habla el protocolo 1.4 (net.status, notif.*, temas net y notif)?"""
    return level() >= 4


NEW_COMMANDS = {"wifi.saved", "wifi.forget", "wifi.reconnect", "bt.forget", "bt.rename", "bt.info", "audio.status", "audio.volume",
                "audio.outputs", "audio.switch", "media.status", "media.play", "media.pause", "media.playpause", "media.stop",
                "media.next", "media.prev", "media.seek", "media.art", "logs"}
OLD_COMMANDS = {"hello", "ping", "subscribe", "unsubscribe", "wifi.status", "wifi.enable", "wifi.disable", "wifi.scan", "wifi.connect",
                "wifi.disconnect", "bt.status", "bt.enable", "bt.disable", "bt.paired", "bt.connect", "bt.disconnect"}


def dumps(o):
    # Igual que org.json de Android: compacto y con "/" escapada.
    return json.dumps(o, separators=(",", ":"), ensure_ascii=False).replace("/", "\\/")


def uptime():
    return int(time.monotonic() - STARTED)


# ---------------------------------------------------------------- estados

def wifi_status():
    base = {"available": True, "permission_location": True, "location_enabled": True}
    nulls = dict(ssid=None, bssid=None, rssi=None, level=None, frequency=None, band=None, link_speed=None, ip=None)
    if not ARGS.old:
        nulls.update(gateway=None, netmask=None, prefix=None, dns=None)
    if not STATE["wifi_on"]:
        base.update(enabled=False, state="disabled", connected=False, ssid_hidden=False, **nulls)
    elif STATE["ssid"] is None:
        base.update(enabled=True, state="enabled", connected=False, ssid_hidden=False, **nulls)
    else:
        base.update(enabled=True, state="enabled", connected=True, ssid=STATE["ssid"], ssid_hidden=False,
                    bssid="aa:bb:cc:00:00:01", rssi=-55, level=3, frequency=5180, band="5GHz",
                    link_speed=433, ip="192.168.1.23")
        if not ARGS.old:
            base.update(gateway="192.168.1.1", netmask="255.255.255.0", prefix=24, dns=["192.168.1.1", "8.8.8.8"])
    return base


def bt_status():
    return {"available": True, "enabled": STATE["bt_on"], "state": "on" if STATE["bt_on"] else "off",
            "name": "Redmi 15C", "connected": STATE["bt_on"], "bonded_count": len(PAIRED)}


def pct(level):
    span = AUDIO["max"] - AUDIO["min"]
    return int(100 * (level - AUDIO["min"]) / span + 0.5)


def audio_status():
    out = next((o for o in OUTPUTS if o["active"]), None)
    return {"available": True, "stream": "music", "level": AUDIO["level"], "min": AUDIO["min"], "max": AUDIO["max"],
            "volume": pct(AUDIO["level"]), "muted": AUDIO["muted"],
            "output": ({k: out[k] for k in ("id", "type", "name", "address")} if out else None), "ringer": AUDIO["ringer"]}


def position_ms():
    if MEDIA["state"] != "playing":
        return MEDIA["pos0"]
    return int(MEDIA["pos0"] + (time.monotonic() - MEDIA["t0"]) * 1000 * MEDIA["speed"])


def has_session():
    return ARGS.listener and not ARGS.no_session


def media_status():
    if not ARGS.listener:
        return {"listener": False, "available": False, "state": "none"}
    if ARGS.no_session:
        return {"listener": True, "available": False, "state": "none"}
    t = TRACKS[MEDIA["idx"]]
    return {"listener": True, "available": True, "package": "org.fake.player", "app": "Reproductor falso",
            "title": t["title"], "artist": t["artist"], "album": t["album"], "album_artist": t["album_artist"],
            "state": MEDIA["state"], "position_ms": position_ms(), "duration_ms": t["duration_ms"], "speed": MEDIA["speed"],
            "track_id": t["track_id"], "art_hash": "art-" + t["track_id"],
            "can_play": True, "can_pause": True, "can_next": True, "can_prev": True, "can_seek": True, "can_stop": True}


def net_status():
    t = NET["override"]
    if t is None:
        t = "wifi" if (STATE["wifi_on"] and STATE["ssid"] is not None) else "none"
    if t == "none":
        return {"available": True, "type": "none", "internet": False, "validated": False, "metered": False, "vpn": False, "captive": False}
    cap = NET["captive"]          # portal cautivo: hay red con internet «declarado», pero Android no ha podido validarla
    return {"available": True, "type": t, "internet": True, "validated": not cap, "metered": t == "cellular", "vpn": NET["vpn"], "captive": cap}


def notif_view(n):
    return {k: n.get(k) for k in ("key", "package", "app", "title", "text", "time", "category", "importance", "ongoing", "clearable")}


def notif_status():
    return {"access": NOTIF["access"], "forwarding": NOTIF["forwarding"], "active": len(NOTIFS)}


def status_for(topic):
    return {"wifi": wifi_status, "bt": bt_status, "audio": audio_status, "media": media_status,
            "net": net_status, "usb": usb_status}[topic]()


class Err(Exception):
    def __init__(self, code, message, extra=None):
        super().__init__(message)
        self.code, self.message, self.extra = code, message, extra or {}


def wifi_changed():
    broadcast("wifi")
    broadcast("net")


def broadcast(topic, data=None):
    line = (dumps({"event": topic, "data": status_for(topic) if data is None else data}) + "\n").encode()
    for h, topics in list(SUBS):
        if topic in topics:
            try:
                h.write(line)
            except OSError:
                pass


def needs_user(message, opens):
    return Err("needs_user_action", message, {"action": "notification", "opens": opens})


# ---------------------------------------------------------------- comandos

def norm_addr(req):
    addr = str(req.get("address", "")).upper()
    parts = addr.split(":")
    if len(parts) != 6 or any(len(p) != 2 or any(c not in "0123456789ABCDEF" for c in p) for p in parts):
        raise Err("bad_request", "Falta address (formato AA:BB:CC:DD:EE:FF)")
    return addr


def paired_dev(req):
    addr = norm_addr(req)
    if not STATE["bt_on"]:
        raise Err("bluetooth_disabled", "El Bluetooth está apagado")
    dev = next((d for d in PAIRED if d["address"] == addr), None)
    if dev is None:
        raise Err("not_paired", "Ese dispositivo no está emparejado en Android")
    return dev


def need_listener():
    if not ARGS.listener:
        raise needs_user("Falta el acceso a notificaciones: concédeselo a Nexo en los ajustes de Android.",
                         "notification_listener_settings")
    if ARGS.no_session:
        raise Err("not_found", "No hay ninguna app reproduciendo medios")


def audio_volume(req):
    keys = [k for k in ("percent", "level", "delta", "mute") if k in req]
    if len(keys) != 1:
        raise Err("bad_request", "Indica exactamente uno de: percent, level, delta, mute")
    k, v = keys[0], req[keys[0]]
    lo, hi = AUDIO["min"], AUDIO["max"]
    if k == "mute":
        if v == "toggle":
            AUDIO["muted"] = not AUDIO["muted"]
        elif isinstance(v, bool):
            AUDIO["muted"] = v
        else:
            raise Err("bad_request", "mute debe ser true, false o \"toggle\"")
    elif k == "percent":
        if not isinstance(v, (int, float)) or isinstance(v, bool) or not 0 <= v <= 100:
            raise Err("bad_request", "percent debe estar entre 0 y 100")
        AUDIO["level"] = int(v / 100 * (hi - lo) + 0.5) + lo
        AUDIO["muted"] = False
    elif k == "level":
        if not isinstance(v, int) or isinstance(v, bool):
            raise Err("bad_request", "level debe ser un entero")
        AUDIO["level"] = max(lo, min(hi, v))
        AUDIO["muted"] = False
    else:
        if not isinstance(v, (int, float)) or isinstance(v, bool):
            raise Err("bad_request", "delta debe ser un número")
        new = int((pct(AUDIO["level"]) + v) / 100 * (hi - lo) + 0.5) + lo
        if v != 0 and new == AUDIO["level"]:
            new += 1 if v > 0 else -1
        AUDIO["level"] = max(lo, min(hi, new))
        if v > 0:
            AUDIO["muted"] = False
    broadcast("audio")
    return audio_status()


def dispatch(cmd, req, owner=None):
    old = ARGS.old
    if (old and cmd not in OLD_COMMANDS) or (cmd in V13_COMMANDS and not v13()) or (cmd in V14_COMMANDS and not v14()):
        raise Err("unknown_command", "Comando desconocido: " + cmd)

    if cmd == "usb.status":
        return usb_status()
    if cmd == "usb.permission":
        return usb_permission(req)
    if cmd == "usb.open":
        return usb_open(req, owner)
    if cmd == "usb.setup":
        return usb_setup(req)
    if cmd == "usb.control":
        return usb_control(req)
    if cmd == "usb.close":
        return usb_close(req)

    if cmd == "wifi.status":
        return wifi_status()
    if cmd in ("wifi.enable", "wifi.disable"):
        STATE["wifi_on"] = cmd == "wifi.enable"
        wifi_changed()
        return wifi_status()
    if cmd == "wifi.scan":
        if not STATE["wifi_on"]:
            raise Err("wifi_disabled", "El WiFi está apagado")
        return {"networks": NETWORKS, "fresh": bool(req.get("fresh", True)), "hidden_count": 0}
    if cmd == "wifi.connect":
        if ARGS.record:
            with open(ARGS.record, "a", encoding="utf-8") as f:
                f.write(json.dumps({"ssid": req.get("ssid"), "password": req.get("password")}, ensure_ascii=False) + "\n")
        ok = req.get("ssid") != "Mala"
        if not STATE["wifi_on"]:
            raise Err("wifi_disabled", "El WiFi está apagado")
        if req.get("ssid") == "SoloWpa3":
            raise needs_user("Esta red solo usa WPA3: Android no deja a una app crearla; hazlo en los ajustes de WiFi", "wifi_panel")
        if ok:
            STATE["ssid"] = req["ssid"]
            if not any(n["ssid"] == req["ssid"] for n in SAVED):
                SAVED.append({"network_id": 3, "ssid": req["ssid"], "security": "WPA2" if req.get("password") else "OPEN",
                              "hidden": bool(req.get("hidden"))})
            wifi_changed()
        data = {"requested": True, "network_id": 3, "ssid": req.get("ssid"), "connected": ok}
        if not ok:
            data["hint"] = "Android no confirmó la conexión: ¿la clave es correcta?"
        return data
    if cmd == "wifi.disconnect":
        if STATE["ssid"] is not None:
            STATE["ssid"] = None
            wifi_changed()
        return {"requested": True}
    if cmd == "wifi.saved":
        return {"networks": [dict(n, current=(n["ssid"] == STATE["ssid"] and STATE["wifi_on"])) for n in SAVED]}
    if cmd == "wifi.forget":
        if "ssid" not in req and "network_id" not in req:
            raise Err("bad_request", "Indica ssid o network_id")
        gone = [n for n in SAVED if n["ssid"] == req.get("ssid") or n["network_id"] == req.get("network_id")]
        if not gone:
            raise Err("not_found", "No hay ninguna red guardada con ese nombre")
        for n in gone:
            SAVED.remove(n)
            if n["ssid"] == STATE["ssid"]:
                STATE["ssid"] = None
        wifi_changed()
        return {"removed": len(gone)}
    if cmd == "net.status":
        return net_status()
    if cmd == "notif.status":
        return notif_status()
    if cmd in ("notif.list", "notif.dismiss"):
        if not NOTIF["access"]:
            raise needs_user("Da a Nexo el acceso a las notificaciones en los ajustes de Android", "notification_listener_settings")
        if not NOTIF["forwarding"]:
            raise needs_user("Activa «Reenviar notificaciones a Linux» en la app Nexo", "nexo_app")
        if cmd == "notif.list":
            return {"notifications": [notif_view(n) for n in NOTIFS]}
        gone = [n for n in NOTIFS if n["key"] == req.get("key")]
        if not gone:
            raise Err("not_found", "No hay ninguna notificación con esa clave")
        NOTIFS.remove(gone[0])
        broadcast("notif", {"op": "removed", "key": gone[0]["key"], "reason": "dismissed"})
        return {"dismissed": True}
    if cmd == "wifi.reconnect":
        if not STATE["wifi_on"]:
            raise Err("wifi_disabled", "El WiFi está apagado")
        return {"requested": True, "connected": STATE["ssid"] is not None}

    if cmd == "bt.status":
        return bt_status()
    if cmd in ("bt.enable", "bt.disable"):
        STATE["bt_on"] = cmd == "bt.enable"
        broadcast("bt")
        return bt_status()
    if cmd == "bt.paired":
        return {"devices": PAIRED}
    if cmd in ("bt.connect", "bt.disconnect"):
        raise needs_user("Android no permite que una app normal conecte o desconecte dispositivos Bluetooth.", "bluetooth_settings")
    if cmd == "bt.forget":
        dev = paired_dev(req)
        if dev["address"].endswith(":02"):  # simula que el sistema bloquea removeBond()
            raise needs_user("Android no dejó que Nexo desempareje el dispositivo.", "bluetooth_settings")
        PAIRED.remove(dev)
        broadcast("bt")
        return {"removed": True}
    if cmd == "bt.rename":
        dev = paired_dev(req)
        name = str(req.get("name", ""))
        if name:
            ALIASES[dev["address"]] = name
        else:
            ALIASES.pop(dev["address"], None)
        return {"address": dev["address"], "alias": ALIASES.get(dev["address"], dev["name"])}
    if cmd == "bt.info":
        dev = paired_dev(req)
        return {"address": dev["address"], "name": dev["name"], "alias": ALIASES.get(dev["address"], dev["name"]),
                "type": dev["type"], "class": dev["class"], "bond_state": "bonded", "connected": dev["connected"],
                "profiles": dev["profiles"], "uuids": ["0000110b-0000-1000-8000-00805f9b34fb"],
                "battery": BATTERY.get(dev["address"], 80 if dev["connected"] else None)}

    if cmd == "audio.status":
        return audio_status()
    if cmd == "audio.volume":
        return audio_volume(req)
    if cmd == "audio.outputs":
        return {"outputs": OUTPUTS}
    if cmd == "audio.switch":
        found = [o for o in OUTPUTS if o["id"] == req.get("id") or ("type" in req and o["type"] == req.get("type"))]
        if "id" not in req and "type" not in req:
            raise Err("bad_request", "Indica id o type")
        if not found:
            raise Err("not_found", "Esa salida de audio no existe")
        raise needs_user("Android no deja que una app normal cambie la salida de audio del sistema.", "volume_panel")

    if cmd == "media.status":
        return media_status()
    if cmd in ("media.play", "media.pause", "media.playpause", "media.stop", "media.next", "media.prev", "media.seek", "media.art"):
        need_listener()
        if cmd == "media.art":
            t = TRACKS[MEDIA["idx"]]
            return {"hash": "art-" + t["track_id"], "mime": "image/jpeg", "width": 1, "height": 1, "data": TINY_JPEG}
        pos = position_ms()
        if cmd == "media.seek":
            if "delta_ms" in req:
                new = pos + int(req["delta_ms"])
            elif "position_ms" in req:
                new = int(req["position_ms"])
            else:
                raise Err("bad_request", "Indica delta_ms o position_ms")
            MEDIA["pos0"] = max(0, min(TRACKS[MEDIA["idx"]]["duration_ms"], new))
            MEDIA["t0"] = time.monotonic()
            broadcast("media")
            return {"requested": True, "position_ms": MEDIA["pos0"]}
        if cmd in ("media.next", "media.prev"):
            MEDIA["idx"] = (MEDIA["idx"] + (1 if cmd == "media.next" else -1)) % len(TRACKS)
            MEDIA["pos0"], MEDIA["t0"] = 0, time.monotonic()
        else:
            new_state = {"media.play": "playing", "media.pause": "paused", "media.stop": "stopped"}.get(cmd)
            if cmd == "media.playpause":
                new_state = "paused" if MEDIA["state"] == "playing" else "playing"
            MEDIA["pos0"] = 0 if new_state == "stopped" else pos
            MEDIA["t0"] = time.monotonic()
            MEDIA["state"] = new_state
        broadcast("media")
        return {"requested": True, "state": MEDIA["state"]}

    if cmd == "logs":
        n = max(1, min(200, int(req.get("n", 50))))
        lines = list(LOGLINES)[-n:]
        return {"lines": lines, "count": len(lines), "uptime_s": uptime()}

    raise Err("unknown_command", "Comando desconocido: " + cmd)


# ---------------------------------------------------------------- USB (protocolo 1.3)

V13_COMMANDS = {"usb.status", "usb.permission", "usb.open", "usb.close", "usb.setup", "usb.control", "usb.attach"}

USB = {"devices": [], "sessions": {}, "next_id": 1001, "next_sess": 1, "auto": "grant", "delay_ms": 0}
USB_LOCK = threading.RLock()

# `usb plug TIPO`: (vid, pid, fabricante, producto, serie, clase, tipo, controlador, interfaces[(id, clase, subclase, protocolo, extremos)], nota, modelo del chip)
USB_KINDS = {
    "arduino": ("2341", "0043", "Arduino (www.arduino.cc)", "Arduino Uno", "85735313437351E0E1E1", 2, "serial", "cdc-acm",
                [(0, 2, 2, 1, 1), (1, 10, 0, 0, 2)], None, "arduino"),
    "ch340": ("1a86", "7523", None, "USB Serial", None, 255, "serial", "ch34x", [(0, 255, 1, 2, 3)], None, "arduino"),
    "cp2102": ("10c4", "ea60", "Silicon Labs", "CP2102 USB to UART Bridge Controller", "0001", 0, "serial", "cp210x", [(0, 255, 0, 0, 2)], None, "echo"),
    "ftdi": ("0403", "6001", "FTDI", "FT232R USB UART", "A50285BI", 0, "serial", "ftdi", [(0, 255, 255, 255, 2)], None, "echo"),
    "esp32s3": ("303a", "1001", "Espressif", "USB JTAG/serial debug unit", "7C:DF:A1:00:00:00", 239, "serial", "cdc-acm",
                [(0, 2, 2, 1, 1), (1, 10, 0, 0, 2), (2, 255, 255, 1, 2)], None, "echo"),
    "pl2303": ("067b", "2303", "Prolific Technology, Inc.", "USB-Serial Controller", None, 0, "serial", None, [(0, 255, 0, 0, 3)],
               "PL2303: Nexo todavía no tiene su controlador", "silent"),
    "keyboard": ("046d", "c31c", "Logitech", "USB Keyboard", None, 0, "hid", None, [(0, 3, 1, 1, 1)], None, "silent"),
    "mouse": ("046d", "c077", "Logitech", "USB Optical Mouse", None, 0, "hid", None, [(0, 3, 1, 2, 1)], None, "silent"),
    "disk": ("0781", "5581", "SanDisk", "Ultra", "4C530001230101112345", 0, "storage", None, [(0, 8, 6, 80, 2)], None, "silent"),
    "hub": ("05e3", "0610", "GenesysLogic", "USB2.0 Hub", None, 9, "hub", None, [(0, 9, 0, 1, 1)], None, "silent"),
}


class FakeChip(object):
    """El «chip» de un dispositivo serie: guarda el estado de línea que le pone el móvil y se comporta como el modelo elegido.
    echo: devuelve lo que recibe · arduino: se reinicia al activar DTR (cargador tipo Optiboot ~1 s, luego un «sketch» que
    escribe a 9600) · silent: no hace nada."""
    BANNER = b"Hola desde el Arduino\r\n"

    def __init__(self, model):
        self.model = model
        self.cv = threading.Condition()
        self.rx = bytearray()      # lo que el dispositivo le manda al móvil
        self.tx = bytearray()      # todo lo que el móvil le escribió
        self.baud, self.bits, self.parity, self.stop = 9600, 8, "none", 1.0
        self.dtr = self.rts = self.brk = False
        self.ops = []
        self.resets = 0
        self.mode = "sketch"
        self.boot_until = 0.0
        self.next_banner = time.monotonic() + 0.2
        self.stk = bytearray()
        self.closed = False
        if model == "arduino":
            threading.Thread(target=self._tick, daemon=True).start()

    def _op(self, *a):
        self.ops.append((round(time.monotonic(), 3),) + a)

    def set_line(self, baud, bits, parity, stop):
        with self.cv:
            self.baud, self.bits, self.parity, self.stop = baud, bits, parity, stop
            self._op("line", baud, bits, parity, stop)

    def set_lines(self, dtr, rts):
        with self.cv:
            edge = bool(dtr) and not self.dtr
            self.dtr, self.rts = bool(dtr), bool(rts)
            self._op("lines", self.dtr, self.rts)
            if self.model == "arduino" and edge:
                self.resets += 1
                self.mode = "boot"
                self.boot_until = time.monotonic() + 1.0
                self.stk.clear()
                self.rx.clear()
            self.cv.notify_all()

    def set_break(self, on):
        with self.cv:
            self.brk = bool(on)
            self._op("break", self.brk)

    def host_write(self, data):
        with self.cv:
            self.tx += data
            if self.model == "echo":
                self.rx += data
            elif self.model == "arduino" and self.mode == "boot" and time.monotonic() < self.boot_until and self.baud == 115200:
                self.stk += data
                while len(self.stk) >= 2:              # cargador mínimo: órdenes de 2 bytes (orden + 0x20)
                    c, e = self.stk[0], self.stk[1]
                    del self.stk[:2]
                    if e != 0x20:
                        continue
                    if c in (0x30, 0x50, 0x51):        # GET_SYNC, ENTER_PROGMODE, LEAVE_PROGMODE
                        self.rx += b"\x14\x10"
                    elif c == 0x75:                    # READ_SIGN: ATmega328P
                        self.rx += b"\x14\x1e\x95\x0f\x10"
            self.cv.notify_all()

    def read(self, maxn, timeout):
        end = time.monotonic() + timeout
        with self.cv:
            while not self.rx and not self.closed:
                left = end - time.monotonic()
                if left <= 0:
                    return b""
                self.cv.wait(left)
            data = bytes(self.rx[:maxn])
            del self.rx[:maxn]
            return data

    def close(self):
        with self.cv:
            self.closed = True
            self.cv.notify_all()

    def _tick(self):
        while not self.closed:
            time.sleep(0.05)
            with self.cv:
                now = time.monotonic()
                if self.mode == "boot" and now >= self.boot_until:
                    self.mode = "sketch"
                    self.next_banner = now + 0.1
                if self.mode == "sketch" and now >= self.next_banner:
                    self.rx += self.BANNER if self.baud == 9600 else b"\xfe" * len(self.BANNER)
                    self.next_banner = now + 0.15
                    self.cv.notify_all()

    def dump(self):
        with self.cv:
            return {"model": self.model, "baud": self.baud, "bits": self.bits, "parity": self.parity, "stop": self.stop,
                    "dtr": self.dtr, "rts": self.rts, "brk": self.brk, "resets": self.resets, "mode": self.mode,
                    "tx_hex": bytes(self.tx).hex(), "ops": self.ops}


def usb_plug(kind):
    vid, pid, vendor, product, serial, cls, tipo, driver, ifaces, note, model = USB_KINDS[kind]
    with USB_LOCK:
        n = USB["next_id"]
        USB["next_id"] += 1
        d = {"id": n, "bus": 1, "address": n - 1000 + 1, "vid": vid, "pid": pid, "vendor": vendor, "product": product, "serial": serial,
             "class": cls, "kind": tipo, "driver": driver, "permission": False, "note": note, "ifaces": ifaces, "chip": FakeChip(model)}
        d["path"] = "/dev/bus/usb/%03d/%03d" % (d["bus"], d["address"])
        USB["devices"].append(d)
    broadcast("usb")
    return d


def usb_unplug(which):
    with USB_LOCK:
        gone = [d for d in USB["devices"] if which == "all" or str(d["id"]) == which]
        for d in gone:
            USB["devices"].remove(d)
            d["chip"].close()
            for sid, s in list(USB["sessions"].items()):
                if s["device"] == d["id"]:
                    s["closed"] = True
                    del USB["sessions"][sid]
    if gone:
        broadcast("usb")


def usb_dev_view(d):
    return {"id": d["id"], "path": d["path"], "bus": d["bus"], "address": d["address"], "vid": d["vid"], "pid": d["pid"],
            "vendor": d["vendor"], "product": d["product"], "serial": d["serial"], "class": d["class"], "kind": d["kind"],
            "driver": d["driver"], "serial_capable": d["driver"] is not None, "permission": d["permission"], "note": d["note"],
            "interfaces": [{"id": i, "class": c, "subclass": sc, "protocol": p, "endpoints": e} for (i, c, sc, p, e) in d["ifaces"]]}


def usb_sess_view(s):
    return {"session": s["id"], "device": s["device"], "driver": s["driver"], "baud": s["baud"], "bits": s["bits"], "parity": s["parity"],
            "stop": s["stop"], "dtr": s["dtr"], "rts": s["rts"], "attached": s["attached"], "rx": s["rx"], "tx": s["tx"]}


def usb_status():
    with USB_LOCK:
        return {"host": True, "devices": [usb_dev_view(d) for d in USB["devices"]],
                "sessions": [usb_sess_view(s) for s in USB["sessions"].values()]}


def usb_find(req):
    try:
        want = int(req.get("device"))
    except (TypeError, ValueError):
        raise Err("bad_request", "Falta «device» (el id que da usb.status)")
    with USB_LOCK:
        for d in USB["devices"]:
            if d["id"] == want:
                return d
    raise Err("not_found", "No hay ningún dispositivo USB con id %s (¿lo desenchufaste?)" % want)


def usb_sess(req):
    with USB_LOCK:
        s = USB["sessions"].get(str(req.get("session", "")))
    if s is None:
        raise Err("not_found", "Esa sesión USB no existe (¿se cerró o desenchufaste el dispositivo?)")
    return s


def usb_line_args(req, cur):
    baud = int(req.get("baud", cur["baud"]))
    bits = int(req.get("bits", cur["bits"]))
    parity = str(req.get("parity", cur["parity"]))
    stop = float(req.get("stop", cur["stop"]))
    if not 50 <= baud <= 4000000:
        raise Err("bad_request", "baud fuera de rango (50 a 4000000)")
    if bits not in (5, 6, 7, 8):
        raise Err("bad_request", "bits debe ser 5, 6, 7 u 8")
    if parity not in ("none", "odd", "even", "mark", "space"):
        raise Err("bad_request", "parity debe ser none, odd, even, mark o space")
    if stop not in (1.0, 1.5, 2.0):
        raise Err("bad_request", "stop debe ser 1, 1.5 o 2")
    return baud, bits, parity, (int(stop) if stop in (1.0, 2.0) else stop)


def usb_permission(req):
    d = usb_find(req)
    wait = max(0, min(int(req.get("wait_ms", 0)), 30000)) / 1000.0
    if d["permission"]:
        return {"device": d["id"], "granted": True, "requested": False, "denied": False}
    mode, delay = USB["auto"], USB["delay_ms"] / 1000.0

    def grant():
        d["permission"] = True
        broadcast("usb")
    if mode == "ignore":
        time.sleep(wait)
        return {"device": d["id"], "granted": False, "requested": True, "denied": False}
    if wait >= delay:
        time.sleep(delay)
        if mode == "grant":
            grant()
            return {"device": d["id"], "granted": True, "requested": True, "denied": False}
        return {"device": d["id"], "granted": False, "requested": True, "denied": True}
    if mode == "grant":
        threading.Timer(delay, grant).start()
    return {"device": d["id"], "granted": False, "requested": True, "denied": False}


def usb_open(req, owner):
    d = usb_find(req)
    if not d["permission"]:
        raise Err("permission_denied", "Falta el permiso de Android para este dispositivo USB (usb.permission)", {"needs_permission": True})
    if d["driver"] is None:
        raise Err("unsupported", "No sé hablar con este dispositivo USB (%s:%s): %s" % (d["vid"], d["pid"], d["note"] or "no es un adaptador serie conocido"))
    base = {"baud": 115200, "bits": 8, "parity": "none", "stop": 1}
    baud, bits, parity, stop = usb_line_args(req, base)
    dtr, rts = bool(req.get("dtr", True)), bool(req.get("rts", True))
    with USB_LOCK:
        if any(s["device"] == d["id"] for s in USB["sessions"].values()):
            raise Err("busy", "Ese dispositivo USB ya está abierto por otra sesión")
        sid = "s%d" % USB["next_sess"]
        USB["next_sess"] += 1
        s = {"id": sid, "device": d["id"], "driver": d["driver"], "baud": baud, "bits": bits, "parity": parity, "stop": stop,
             "dtr": dtr, "rts": rts, "attached": False, "rx": 0, "tx": 0, "chip": d["chip"], "owner": owner, "closed": False}
        USB["sessions"][sid] = s
    s["chip"].set_line(baud, bits, parity, stop)
    s["chip"].set_lines(dtr, rts)
    broadcast("usb")
    out = usb_sess_view(s)
    out.update({"ep_in": 129, "ep_out": 2, "packet": 64, "steps": [{"op": "set_line_coding", "rc": 7}, {"op": "set_control_line_state", "rc": 0}]})
    return out


def usb_setup(req):
    s = usb_sess(req)
    baud, bits, parity, stop = usb_line_args(req, s)
    s.update(baud=baud, bits=bits, parity=parity, stop=stop)
    s["chip"].set_line(baud, bits, parity, stop)
    out = usb_sess_view(s)
    out["steps"] = [{"op": "set_line_coding", "rc": 7}]
    return out


def usb_control(req):
    s = usb_sess(req)
    if "dtr" in req:
        s["dtr"] = bool(req["dtr"])
    if "rts" in req:
        s["rts"] = bool(req["rts"])
    steps = []
    if "dtr" in req or "rts" in req:
        s["chip"].set_lines(s["dtr"], s["rts"])
        steps.append({"op": "set_control_line_state", "rc": 0})
    if "brk" in req:
        s["chip"].set_break(bool(req["brk"]))
        steps.append({"op": "send_break", "rc": 0})
    out = usb_sess_view(s)
    out["steps"] = steps
    return out


def usb_close(req):
    s = usb_sess(req)
    usb_end(s)
    return {"closed": True}


def usb_end(s):
    with USB_LOCK:
        USB["sessions"].pop(s["id"], None)
    s["closed"] = True
    broadcast("usb")


def usb_owner_gone(owner):
    with USB_LOCK:
        mine = [s for s in USB["sessions"].values() if s["owner"] is owner]
    for s in mine:
        usb_end(s)


def usb_attach_check(req):
    s = usb_sess(req)
    if s["attached"]:
        raise Err("busy", "Esa sesión USB ya tiene un flujo conectado")
    return s


def usb_pump(h, s):
    """Tras usb.attach la conexión deja de ser JSON: son bytes crudos del dispositivo ↔ cliente, hasta que alguno se vaya."""
    chip = s["chip"]
    s["attached"] = True
    broadcast("usb")
    done = threading.Event()

    def rx_loop():
        while not done.is_set() and not s["closed"] and not chip.closed:
            data = chip.read(4096, 0.1)
            if data and (done.is_set() or s["closed"]):
                with chip.cv:                      # la sesión ya se cerró: lo leído es de la siguiente, que se lo quede
                    chip.rx[:0] = data
                break
            if data:
                s["rx"] += len(data)
                try:
                    h.write(data)
                except OSError:
                    break
        try:
            h.request.shutdown(2)
        except OSError:
            pass
    t = threading.Thread(target=rx_loop, daemon=True)
    t.start()
    try:
        while True:
            data = h.rfile.read1(65536)
            if not data:
                break
            s["tx"] += len(data)
            chip.host_write(data)
    except OSError:
        pass
    finally:
        done.set()
        s["attached"] = False
        broadcast("usb")


def ctl_apply(line):
    """Órdenes de prueba (--ctl ARCHIVO): cambian el estado del «móvil» y avisan a los suscritos, como haría Android.
       bt connect|disconnect|remove DIRECCIÓN · bt add NOMBRE DIRECCIÓN [clase] [tipo] · bt battery DIRECCIÓN N|none
       wifi on|off · wifi connect NOMBRE · wifi disconnect · wifi add NOMBRE BSSID DBM [SEGURIDAD [MHZ]] · wifi remove NOMBRE
       net wifi|cellular|ethernet|none|auto
       usb plug arduino|ch340|cp2102|ftdi|esp32s3|pl2303|keyboard|mouse|disk|hub [echo|arduino|silent] · usb unplug ID|all
       usb perm ID on|off · usb auto grant|deny|ignore [MS] · usb dump ID ARCHIVO
       notif post CLAVE APP TÍTULO|TEXTO · notif remove CLAVE · notif forwarding on|off · notif access on|off"""
    w = line.split()
    if not w:
        return
    if w[0] == "wifi" and len(w) >= 2:
        if w[1] in ("on", "off"):
            STATE["wifi_on"] = w[1] == "on"
        elif w[1] == "connect" and len(w) >= 3:
            STATE["ssid"] = line.split(None, 2)[2]
        elif w[1] == "disconnect":
            STATE["ssid"] = None
        elif w[1] == "add" and len(w) >= 5:
            freq = int(w[6]) if len(w) > 6 else 2437
            sec = w[5].upper() if len(w) > 5 else "WPA2"
            NETWORKS.append({"ssid": w[2], "bssid": w[3].lower(), "rssi": int(w[4]), "level": 2, "frequency": freq,
                             "band": "5GHz" if freq > 3000 else "2.4GHz", "security": sec, "secured": sec != "OPEN"})
            return
        elif w[1] == "remove" and len(w) >= 3:
            NETWORKS[:] = [n for n in NETWORKS if n["ssid"] != w[2]]
            return
        else:
            return
        wifi_changed()
        return
    if w[0] == "usb" and len(w) >= 2:
        if w[1] == "plug" and len(w) >= 3 and w[2] in USB_KINDS:
            d = usb_plug(w[2])
            if len(w) >= 4:                       # usb plug TIPO MODELO: cambia el comportamiento del chip (echo|arduino|silent)
                d["chip"].model = w[3]
        elif w[1] == "unplug" and len(w) >= 3:
            usb_unplug(w[2])
        elif w[1] == "perm" and len(w) >= 4:
            for d in USB["devices"]:
                if str(d["id"]) == w[2]:
                    d["permission"] = w[3] == "on"
            broadcast("usb")
        elif w[1] == "auto" and len(w) >= 3:      # usb auto grant|deny|ignore [MS]: qué hace el «usuario» ante el aviso de permiso
            USB["auto"] = w[2]
            USB["delay_ms"] = int(w[3]) if len(w) > 3 else 0
        elif w[1] == "dump" and len(w) >= 4:      # usb dump ID ARCHIVO: vuelca lo que ve el chip (para las pruebas)
            for d in USB["devices"]:
                if str(d["id"]) == w[2]:
                    tmp = w[3] + ".tmp"
                    with open(tmp, "w", encoding="utf-8") as f:
                        json.dump(d["chip"].dump(), f)
                    os.replace(tmp, w[3])
        return
    if w[0] == "net" and len(w) >= 2:
        if w[1] in ("vpn", "captive") and len(w) >= 3:
            NET[w[1]] = w[2] == "on"
        else:
            NET["override"] = None if w[1] == "auto" else w[1]
        broadcast("net")
        return
    if w[0] == "notif" and len(w) >= 2:
        if w[1] == "post" and len(w) >= 5:
            # notif post CLAVE APP TÍTULO|TEXTO [@category=call] [@importance=4] [@ongoing=1] [@clearable=0]
            rest = line.split(None, 4)[4]
            extra = {}
            while True:
                head, _, last = rest.rpartition(" ")
                if last.startswith("@") and "=" in last and head:
                    k, _, v = last[1:].partition("=")
                    extra[k] = v
                    rest = head
                else:
                    break
            title, _, text = rest.partition("|")
            n = {"key": w[2], "package": "org.fake." + w[3].lower(), "app": w[3], "title": title, "text": text,
                 "time": int(time.time() * 1000), "category": extra.get("category", "msg"), "importance": int(extra.get("importance", 3)),
                 "ongoing": extra.get("ongoing", "0") == "1", "clearable": extra.get("clearable", "1") == "1"}
            NOTIFS[:] = [x for x in NOTIFS if x["key"] != n["key"]] + [n]
            if NOTIF["forwarding"] and NOTIF["access"]:
                broadcast("notif", dict(notif_view(n), op="posted"))
        elif w[1] == "remove" and len(w) >= 3:
            gone = [x for x in NOTIFS if x["key"] == w[2]]
            NOTIFS[:] = [x for x in NOTIFS if x["key"] != w[2]]
            if gone and NOTIF["forwarding"] and NOTIF["access"]:
                broadcast("notif", {"op": "removed", "key": w[2], "reason": "cancelled"})
        elif w[1] in ("forwarding", "access") and len(w) >= 3:
            NOTIF[w[1]] = w[2] == "on"
        return
    if w[0] == "bt" and len(w) >= 3:
        addr = w[2].upper() if w[1] != "add" else (w[3].upper() if len(w) > 3 else "")
        dev = next((d for d in PAIRED if d["address"] == addr), None)
        if w[1] in ("connect", "disconnect") and dev:
            dev["connected"] = w[1] == "connect"
            if dev["connected"] and not dev["profiles"]:
                dev["profiles"] = ["a2dp"]
        elif w[1] == "remove" and dev:
            PAIRED.remove(dev)
        elif w[1] == "add" and addr and not dev:
            PAIRED.append({"name": w[2] if w[2] != "-" else None, "address": addr, "connected": False, "profiles": [],
                           "type": w[5] if len(w) > 5 else "classic", "class": w[4] if len(w) > 4 else "unknown"})
        elif w[1] == "battery" and dev:
            if w[3].lower() == "none":
                BATTERY[addr] = None
            else:
                BATTERY[addr] = int(w[3])
            addr = None
        else:
            return
        broadcast("bt")
        return
    sys.stderr.write("ctl: orden desconocida: %s\n" % line)


def ctl_watch(path):
    pos = 0
    while True:
        time.sleep(0.1)
        try:
            with open(path, "rb") as f:
                f.seek(pos)
                data = f.read()
                pos += len(data)
        except OSError:
            continue
        for ln in data.decode("utf-8", "replace").splitlines():
            try:
                ctl_apply(ln.strip())
            except Exception as e:
                sys.stderr.write("ctl: %r en %r\n" % (e, ln))


def hello_data():
    if ARGS.old:
        return {"app": "nexo", "version": "0.1.0", "proto": 1, "android_sdk": 35, "target_sdk": 28, "device": "Fake Phone",
                "wifi": True, "bluetooth": True}
    return {"app": "nexo", "version": "0.4.1", "proto": 1, "minor": level(), "android_sdk": 35, "target_sdk": 28,
            "device": "Fake Phone", "wifi": True, "bluetooth": True, "listener": ARGS.listener, "uptime_s": uptime(),
            **({"usb": True} if v13() else {}),
            "commands": sorted((OLD_COMMANDS | NEW_COMMANDS) | (V13_COMMANDS if v13() else set()) | (V14_COMMANDS if v14() else set()))}


def bundle():
    """Igual que Bootstrap.build() de la app."""
    def rd(*p):
        with open(os.path.join(ARGS.termux_dir, *p), encoding="utf-8", newline="") as f:
            return f.read().replace("\r\n", "\n")
    client64 = base64.b64encode(rd("bin", "nexo").encode()).decode("ascii")
    dbus64 = base64.b64encode(rd("bin", "nexo-dbus").encode()).decode("ascii")
    tools64 = base64.b64encode(rd("bin", "nexo-tools").encode()).decode("ascii")
    usb64 = base64.b64encode(rd("bin", "nexo-usb").encode()).decode("ascii")
    head = "#!/usr/bin/env bash\nNEXO_CLIENT_B64='%s'\nNEXO_DBUS_B64='%s'\nNEXO_TOOLS_B64='%s'\nNEXO_USB_B64='%s'\n" % (client64, dbus64, tools64, usb64)
    return (head + rd("install.sh")).encode()


class Handler(socketserver.StreamRequestHandler):
    def write(self, data):
        with self.wlock:
            self.wfile.write(data)
            self.wfile.flush()

    def send(self, o):
        self.write((dumps(o) + "\n").encode())

    def note(self, line):
        LOGLINES.append(time.strftime("%H:%M:%S") + "  " + line)

    def handle(self):
        self.wlock = threading.Lock()
        authed = False
        with LOCK:
            CONN_COUNT[0] += 1
            nth = CONN_COUNT[0]
        try:
            if ARGS.freeze:
                for _ in self.rfile:
                    pass
                return
            for raw in self.rfile:
                if nth <= ARGS.drop_first:
                    return  # cierra sin contestar
                try:
                    req = json.loads(raw.decode("utf-8"))
                except ValueError:
                    self.send({"id": None, "ok": False, "error": "bad_request", "message": "JSON inválido"})
                    if not authed:
                        return
                    continue
                rid, cmd = req.get("id"), req.get("cmd", "")
                if cmd == "bootstrap":
                    if ARGS.evil:
                        self.write(b'#!/usr/bin/env bash\ntouch "$NEXO_EVIL_MARK"\n')
                    else:
                        self.write(bundle())
                    return
                if ARGS.evil:
                    return
                if not authed:
                    if cmd != "hello" or req.get("token") != ARGS.token:
                        self.send({"id": rid, "ok": False, "error": "unauthorized", "message": "Token incorrecto"})
                        return
                    authed = True
                    self.note("Cliente conectado: " + str(req.get("client", "?"))[:40])
                    if ARGS.leak_token:
                        self.note("depuración: token=" + ARGS.token)
                    self.send({"id": rid, "ok": True, "data": hello_data()})
                    continue
                if ARGS.reqlog:
                    with open(ARGS.reqlog, "a", encoding="utf-8") as f:
                        f.write(json.dumps({k: v for k, v in req.items() if k not in ("id", "token")}, ensure_ascii=False, separators=(",", ":")) + "\n")
                if nth <= ARGS.drop_after_hello:
                    return  # recibió el comando, pero la respuesta se pierde
                if ARGS.slow_ms:
                    time.sleep(ARGS.slow_ms / 1000)
                if cmd == "usb.attach" and v13() and not ARGS.old:
                    try:
                        sess = usb_attach_check(req)
                    except Err as e:
                        self.send({"id": rid, "ok": False, "error": e.code, "message": e.message, **e.extra})
                        continue
                    self.note("> usb.attach " + sess["id"])
                    self.send({"id": rid, "ok": True, "data": {"session": sess["id"], "raw": True}})
                    usb_pump(self, sess)
                    return
                if cmd == "hello":
                    self.send({"id": rid, "ok": True, "data": hello_data()})
                elif cmd == "ping":
                    self.send({"id": rid, "ok": True, "data": {"pong": True, "t": int(time.time() * 1000)}})
                elif cmd == "unsubscribe":
                    with LOCK:
                        SUBS[:] = [s for s in SUBS if s[0] is not self]
                    self.send({"id": rid, "ok": True})
                elif cmd == "subscribe":
                    default = {"wifi", "bt"} if ARGS.old else {"wifi", "bt", "audio", "media"} | ({"usb"} if v13() else set())
                    allowed = default | {"net", "notif"} if v14() and not ARGS.old else default
                    topics = {t for t in (req.get("topics") or sorted(default)) if t in allowed}
                    with LOCK:
                        SUBS.append((self, topics))
                    self.send({"id": rid, "ok": True, "data": {"topics": sorted(topics)}})
                    for t in sorted(topics - {"notif"}):         # «notif» no tiene estado inicial: solo avisa de lo que pasa
                        self.send({"event": t, "data": status_for(t)})
                else:
                    self.note("> " + cmd)
                    try:
                        self.send({"id": rid, "ok": True, "data": dispatch(cmd, req, self)})
                    except Err as e:
                        self.note("x " + cmd + ": " + e.code)
                        self.send({"id": rid, "ok": False, "error": e.code, "message": e.message, **e.extra})
        except OSError:
            pass
        finally:
            with LOCK:
                SUBS[:] = [s for s in SUBS if s[0] is not self]
            usb_owner_gone(self)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--token", default="0" * 48)
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--portfile")
    ap.add_argument("--termux-dir", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "termux"))
    ap.add_argument("--record")
    ap.add_argument("--reqlog")
    ap.add_argument("--evil", action="store_true")
    ap.add_argument("--old", action="store_true")
    ap.add_argument("--minor2", action="store_true", help="protocolo 1.2 (como la 0.4.0-beta2): sin usb.*, net.status ni notif.*")
    ap.add_argument("--minor3", action="store_true", help="fuerza el protocolo 1.3: con USB, sin net.status ni notif.*")
    ap.add_argument("--minor4", action="store_true", help="fuerza el protocolo 1.4: USB, net.status, notif.* y los temas net y notif")
    ap.add_argument("--freeze", action="store_true")
    ap.add_argument("--drop-first", type=int, default=0)
    ap.add_argument("--drop-after-hello", type=int, default=0)
    ap.add_argument("--leak-token", action="store_true")
    ap.add_argument("--slow-ms", type=int, default=0)
    ap.add_argument("--no-listener", dest="listener", action="store_false")
    ap.add_argument("--no-session", action="store_true")
    ap.add_argument("--print-bundle-sha", action="store_true")
    ap.add_argument("--ctl", help="archivo del que se leen órdenes de prueba (ver ctl_apply)")
    ARGS = ap.parse_args()
    if ARGS.print_bundle_sha:
        import hashlib
        print(hashlib.sha256(bundle()).hexdigest())
        return
    srv = Server(("127.0.0.1", ARGS.port), Handler)
    if ARGS.ctl:
        threading.Thread(target=ctl_watch, args=(ARGS.ctl,), daemon=True).start()
    if ARGS.portfile:
        with open(ARGS.portfile, "w") as f:
            f.write(str(srv.server_address[1]))
    srv.serve_forever()


if __name__ == "__main__":
    main()
