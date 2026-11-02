#!/usr/bin/env python3
"""App Nexo FALSA, para probar el cliente sin un móvil (y en CI).

Imita el protocolo de docs/PROTOCOLO.md: JSON por línea sobre TCP en 127.0.0.1, con token,
eventos en vivo y el comando `bootstrap` que entrega el instalador (igual que Bootstrap.kt).

Uso:  fake_app.py --token HEX --termux-dir ../termux --portfile /tmp/p [--record /tmp/r.jsonl]
      fake_app.py --evil ...    hace de "otra app" que ocupó el puerto y sirve un script malicioso
"""
import argparse
import base64
import json
import os
import socketserver
import threading

LOCK = threading.Lock()
SUBS = []  # (handler, topics)
STATE = {"wifi_on": True, "ssid": "MiCasa", "bt_on": True}
ARGS = None

NETWORKS = [
    {"ssid": "MiCasa", "bssid": "aa:bb:cc:00:00:01", "rssi": -52, "level": 4, "frequency": 5180, "band": "5GHz", "security": "WPA2", "secured": True},
    {"ssid": 'Café "Luz"', "bssid": "aa:bb:cc:00:00:02", "rssi": -70, "level": 2, "frequency": 2437, "band": "2.4GHz", "security": "WPA2", "secured": True},
    {"ssid": "Wi-Fi/Invitados", "bssid": "aa:bb:cc:00:00:03", "rssi": -81, "level": 1, "frequency": 2412, "band": "2.4GHz", "security": "OPEN", "secured": False},
]
PAIRED = [
    {"name": "Auriculares ñandú", "address": "AA:BB:CC:DD:EE:01", "connected": True, "profiles": ["a2dp", "headset"], "type": "classic", "class": "audio"},
    {"name": None, "address": "AA:BB:CC:DD:EE:02", "connected": False, "profiles": [], "type": "le", "class": "unknown"},
]


def dumps(o):
    # Igual que org.json de Android: compacto y con "/" escapada.
    return json.dumps(o, separators=(",", ":"), ensure_ascii=False).replace("/", "\\/")


def wifi_status():
    base = {"available": True, "permission_location": True, "location_enabled": True}
    if not STATE["wifi_on"]:
        base.update(enabled=False, state="disabled", connected=False, ssid=None, ssid_hidden=False, bssid=None,
                    rssi=None, level=None, frequency=None, band=None, link_speed=None, ip=None)
    else:
        base.update(enabled=True, state="enabled", connected=True, ssid=STATE["ssid"], ssid_hidden=False,
                    bssid="aa:bb:cc:00:00:01", rssi=-55, level=3, frequency=5180, band="5GHz",
                    link_speed=433, ip="192.168.1.23")
    return base


def bt_status():
    return {"available": True, "enabled": STATE["bt_on"], "state": "on" if STATE["bt_on"] else "off",
            "name": "Redmi 15C", "connected": STATE["bt_on"], "bonded_count": len(PAIRED)}


class Err(Exception):
    def __init__(self, code, message, extra=None):
        super().__init__(message)
        self.code, self.message, self.extra = code, message, extra or {}


def broadcast(topic):
    data = wifi_status() if topic == "wifi" else bt_status()
    line = (dumps({"event": topic, "data": data}) + "\n").encode()
    for h, topics in list(SUBS):
        if topic in topics:
            try:
                h.write(line)
            except OSError:
                pass


def dispatch(cmd, req):
    if cmd == "wifi.status":
        return wifi_status()
    if cmd in ("wifi.enable", "wifi.disable"):
        STATE["wifi_on"] = cmd == "wifi.enable"
        broadcast("wifi")
        return wifi_status()
    if cmd == "wifi.scan":
        if not STATE["wifi_on"]:
            raise Err("wifi_disabled", "El WiFi está apagado")
        return {"networks": NETWORKS, "fresh": True, "hidden_count": 0}
    if cmd == "wifi.connect":
        if ARGS.record:
            with open(ARGS.record, "a", encoding="utf-8") as f:
                f.write(json.dumps({"ssid": req.get("ssid"), "password": req.get("password")}, ensure_ascii=False) + "\n")
        ok = req.get("ssid") != "Mala"
        if ok:
            STATE["ssid"] = req["ssid"]
        return {"requested": True, "network_id": 3, "ssid": req.get("ssid"), "connected": ok}
    if cmd == "wifi.disconnect":
        return {"requested": True}
    if cmd == "bt.status":
        return bt_status()
    if cmd in ("bt.enable", "bt.disable"):
        STATE["bt_on"] = cmd == "bt.enable"
        broadcast("bt")
        return bt_status()
    if cmd == "bt.paired":
        return {"devices": PAIRED}
    if cmd in ("bt.connect", "bt.disconnect"):
        raise Err("needs_user_action",
                  "Android no permite que una app normal conecte o desconecte dispositivos Bluetooth.",
                  {"action": "notification", "opens": "bluetooth_settings"})
    raise Err("unknown_command", "Comando desconocido: " + cmd)


def bundle():
    """Igual que Bootstrap.build() de la app."""
    def rd(*p):
        with open(os.path.join(ARGS.termux_dir, *p), encoding="utf-8", newline="") as f:
            return f.read().replace("\r\n", "\n")
    b64 = base64.b64encode(rd("bin", "nexo").encode()).decode("ascii")
    head = "#!/usr/bin/env bash\nNEXO_CLIENT_B64='%s'\nexport NEXO_CLIENT_B64\n" % b64
    return (head + rd("install.sh")).encode()


class Handler(socketserver.StreamRequestHandler):
    def write(self, data):
        with self.wlock:
            self.wfile.write(data)
            self.wfile.flush()

    def send(self, o):
        self.write((dumps(o) + "\n").encode())

    def handle(self):
        self.wlock = threading.Lock()
        authed = False
        try:
            for raw in self.rfile:
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
                    self.send({"id": rid, "ok": True, "data": {"app": "nexo", "version": "0.1.0", "proto": 1,
                                                               "android_sdk": 35, "target_sdk": 28, "device": "Fake Phone"}})
                    continue
                if cmd == "ping":
                    self.send({"id": rid, "ok": True, "data": {"pong": True}})
                elif cmd == "subscribe":
                    topics = set(req.get("topics") or ["wifi", "bt"])
                    with LOCK:
                        SUBS.append((self, topics))
                    self.send({"id": rid, "ok": True, "data": {"topics": sorted(topics)}})
                    for t in sorted(topics):
                        self.send({"event": t, "data": wifi_status() if t == "wifi" else bt_status()})
                else:
                    try:
                        self.send({"id": rid, "ok": True, "data": dispatch(cmd, req)})
                    except Err as e:
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
    ap.add_argument("--termux-dir", default=os.path.join(os.path.dirname(__file__), "..", "termux"))
    ap.add_argument("--record")
    ap.add_argument("--evil", action="store_true")
    ap.add_argument("--print-bundle-sha", action="store_true")
    ARGS = ap.parse_args()
    if ARGS.print_bundle_sha:
        import hashlib
        print(hashlib.sha256(bundle()).hexdigest())
        return
    srv = Server(("127.0.0.1", ARGS.port), Handler)
    if ARGS.portfile:
        with open(ARGS.portfile, "w") as f:
            f.write(str(srv.server_address[1]))
    srv.serve_forever()


if __name__ == "__main__":
    main()
