#!/usr/bin/env python3
"""App Nexo FALSA, para probar el cliente (y nexo-dbus) sin un móvil, y en CI.

Imita el protocolo de docs/PROTOCOLO.md (versión 1, revisión 2): JSON por línea sobre TCP en 127.0.0.1,
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

V13_COMMANDS = {"net.status", "notif.status", "notif.list", "notif.dismiss"}     # protocolo 1.3 (la app real los trae desde la 0.4.0-beta2)
V13_OPENS = {"nexo_app"}                                                         # paneles (`opens`) que solo existen desde el 1.3


APP_MINOR = 2          # revisión del protocolo que habla la app REAL (Protocol.MINOR en Kotlin); súbela a 3 cuando llegue net/notif a la app


def v13():
    """¿Habla el protocolo 1.3 (net.status, notif.*, temas net y notif)? Por defecto, lo mismo que la app real (APP_MINOR).
    --minor3 fuerza el 1.3 y --minor2 el 1.2 (para probar el cliente y nexo-dbus contra una app más nueva o más vieja)."""
    if getattr(ARGS, "minor2", False):
        return False
    return bool(getattr(ARGS, "minor3", False)) or APP_MINOR >= 3


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
            "net": net_status}[topic]()


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


def dispatch(cmd, req):
    old = ARGS.old
    if (old and cmd not in OLD_COMMANDS) or (cmd in V13_COMMANDS and not v13()):
        raise Err("unknown_command", "Comando desconocido: " + cmd)

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


def ctl_apply(line):
    """Órdenes de prueba (--ctl ARCHIVO): cambian el estado del «móvil» y avisan a los suscritos, como haría Android.
       bt connect|disconnect|remove DIRECCIÓN · bt add NOMBRE DIRECCIÓN [clase] [tipo] · bt battery DIRECCIÓN N|none
       wifi on|off · wifi connect NOMBRE · wifi disconnect · wifi add NOMBRE BSSID DBM [SEGURIDAD [MHZ]] · wifi remove NOMBRE
       net wifi|cellular|ethernet|none|auto
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
    return {"app": "nexo", "version": "0.4.0-beta2", "proto": 1, "minor": 3 if v13() else 2, "android_sdk": 35, "target_sdk": 28,
            "device": "Fake Phone", "wifi": True, "bluetooth": True, "listener": ARGS.listener, "uptime_s": uptime(),
            "commands": sorted((OLD_COMMANDS | NEW_COMMANDS) | (V13_COMMANDS if v13() else set()))}


def bundle():
    """Igual que Bootstrap.build() de la app."""
    def rd(*p):
        with open(os.path.join(ARGS.termux_dir, *p), encoding="utf-8", newline="") as f:
            return f.read().replace("\r\n", "\n")
    client64 = base64.b64encode(rd("bin", "nexo").encode()).decode("ascii")
    dbus64 = base64.b64encode(rd("bin", "nexo-dbus").encode()).decode("ascii")
    tools64 = base64.b64encode(rd("bin", "nexo-tools").encode()).decode("ascii")
    head = "#!/usr/bin/env bash\nNEXO_CLIENT_B64='%s'\nNEXO_DBUS_B64='%s'\nNEXO_TOOLS_B64='%s'\n" % (client64, dbus64, tools64)
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
                if cmd == "hello":
                    self.send({"id": rid, "ok": True, "data": hello_data()})
                elif cmd == "ping":
                    self.send({"id": rid, "ok": True, "data": {"pong": True, "t": int(time.time() * 1000)}})
                elif cmd == "unsubscribe":
                    with LOCK:
                        SUBS[:] = [s for s in SUBS if s[0] is not self]
                    self.send({"id": rid, "ok": True})
                elif cmd == "subscribe":
                    default = {"wifi", "bt"} if ARGS.old else {"wifi", "bt", "audio", "media"}
                    allowed = default | {"net", "notif"} if v13() and not ARGS.old else default
                    topics = {t for t in (req.get("topics") or sorted(default)) if t in allowed}
                    with LOCK:
                        SUBS.append((self, topics))
                    self.send({"id": rid, "ok": True, "data": {"topics": sorted(topics)}})
                    for t in sorted(topics - {"notif"}):         # «notif» no tiene estado inicial: solo avisa de lo que pasa
                        self.send({"event": t, "data": status_for(t)})
                else:
                    self.note("> " + cmd)
                    try:
                        self.send({"id": rid, "ok": True, "data": dispatch(cmd, req)})
                    except Err as e:
                        self.note("x " + cmd + ": " + e.code)
                        self.send({"id": rid, "ok": False, "error": e.code, "message": e.message, **e.extra})
        except OSError:
            pass
        finally:
            with LOCK:
                SUBS[:] = [s for s in SUBS if s[0] is not self]


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
    ap.add_argument("--minor2", action="store_true", help="protocolo 1.2 (como la 0.4.0-beta1): sin net.status, notif.* ni los temas net y notif")
    ap.add_argument("--minor3", action="store_true", help="fuerza el protocolo 1.3: net.status, notif.* y los temas net y notif")
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
