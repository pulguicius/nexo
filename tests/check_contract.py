#!/usr/bin/env python3
"""Comprueba que la app Android (Kotlin), la app falsa (tests/fake_app.py) y docs/PROTOCOLO.md cuentan lo MISMO.

La app real no se puede ejecutar en CI ni en este entorno, así que se compara su código fuente con la «especificación
ejecutable» (fake_app.py): lista de comandos, temas, nombres de los campos de cada respuesta, códigos de error documentados,
versiones y el formato del instalador. Si alguien cambia uno y se olvida del otro, esto falla.

Uso: python3 -I tests/check_contract.py RAIZ_DEL_REPO      (imprime «OK …» o «FALLA …»; sale con 1 si algo falla)
"""
import argparse
import importlib.util
import os
import re
import sys

sys.dont_write_bytecode = True   # al cargar fake_app.py no dejar un __pycache__ en el repositorio

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
KT = os.path.join(ROOT, "android/app/src/main/java/org/nexo/bridge")
failed = 0


def rd(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8", newline="") as f:
        return f.read().replace("\r\n", "\n")


def kt(name):
    return rd("android/app/src/main/java/org/nexo/bridge", name)


def check(desc, cond, detail=""):
    global failed
    if cond:
        print("OK " + desc)
    else:
        failed += 1
        print("FALLA " + desc)
        if detail:
            print(detail)


def body(src, signature):
    """Cuerpo (entre llaves) de la función cuyo encabezado casa con `signature`, ignorando llaves dentro de textos."""
    m = re.search(signature, src)
    if not m:
        return None
    i = src.index("{", m.end() - 1 if src[m.end() - 1] == "{" else m.end())
    depth, j, in_str, esc = 0, i, False, False
    while j < len(src):
        c = src[j]
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return src[i:j + 1]
        j += 1
    return None


# Campos que solo aparecen dentro de los datos extra de un ERROR (permission_denied, needs_user_action): no son de la respuesta.
ERROR_EXTRAS = {"permission", "action", "opens", "needs_permission"}


def keys_in(text, keep=()):
    """Campos JSON que escribe un trozo de Kotlin: .put("campo", …) / .putOrNull("campo", …) / put("campo").
    Se descartan los campos extra de los errores (ERROR_EXTRAS), salvo los que se indican en `keep` (p. ej. el campo `permission` de un dispositivo USB)."""
    return set(re.findall(r'\.put(?:OrNull)?\(\s*"([a-z_]+)"', text or "")) - (ERROR_EXTRAS - set(keep))


# ---------------------------------------------------------------- la app falsa
spec = importlib.util.spec_from_file_location("fake_app", os.path.join(ROOT, "tests", "fake_app.py"))
fa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fa)
fa.ARGS = argparse.Namespace(old=False, listener=True, no_session=False, record=None, reqlog=None, minor2=False, minor3=False, minor4=False, minor5=False)

# ---------------------------------------------------------------- comandos y temas
commands_kt = kt("Commands.kt")
minor = int(re.search(r"const val MINOR = (\d+)", kt("Protocol.kt")).group(1))
m = re.search(r"val NAMES: List<String> = listOf\((.*?)\)\.sorted\(\)", commands_kt, re.S)
names = sorted(re.findall(r'"([a-z.]+)"', m.group(1))) if m else []
spec_names = sorted(fa.OLD_COMMANDS | fa.NEW_COMMANDS | (fa.V13_COMMANDS if minor >= 3 else set()) | (fa.V14_COMMANDS if minor >= 4 else set()) | (fa.V15_COMMANDS if minor >= 5 else set()))
check("la lista de comandos de la app (Commands.NAMES) es la de la app falsa", names == spec_names,
      "  solo en la app: %s\n  solo en la falsa: %s" % (sorted(set(names) - set(spec_names)), sorted(set(spec_names) - set(names))))

handle = body(commands_kt, r"fun handle\(cmd: String, req: JSONObject(?:, owner: Any\?(?: = null)?)?\): JSONObject = when \(cmd\) \{") or ""
handled = set(re.findall(r'"([a-z]+\.[a-z]+|logs)"', handle))
server_side = {"hello", "ping", "subscribe", "unsubscribe"} | ({"usb.attach"} if minor >= 3 else set())   # usb.attach lo atiende el servidor: la conexión pasa a ser de bytes
check("cada comando anunciado tiene su rama en Commands.handle (o en el servidor)",
      handled == set(names) - server_side,
      "  sin rama: %s\n  rama sin anunciar: %s" % (sorted(set(names) - server_side - handled), sorted(handled - set(names))))
server_kt = kt("BridgeServer.kt")
check("el servidor atiende hello, ping, subscribe, unsubscribe (y usb.attach)",
      all(('"%s" ->' % c) in server_kt for c in sorted(server_side)))

m = re.search(r"val TOPICS: List<String> = listOf\((.*?)\)", commands_kt, re.S)
topics = set(re.findall(r'"([a-z]+)"', m.group(1))) if m else set()
default_topics = {"wifi", "bt", "audio", "media", "usb"} | ({"storage"} if minor >= 4 else set())
check("los temas a los que se suscribe quien no indica ninguno son wifi, bt, audio, media, usb y storage", topics == default_topics, "  son: %s" % sorted(topics))
if minor >= 5:
    m = re.search(r"val OPTIONAL_TOPICS: List<String> = listOf\((.*?)\)", commands_kt, re.S)
    optional_topics = set(re.findall(r'"([a-z]+)"', m.group(1))) if m else set()
    check("…y los temas que hay que pedir expresamente (OPTIONAL_TOPICS) son net y notif", optional_topics == {"net", "notif"}, "  son: %s" % sorted(optional_topics))

# ---------------------------------------------------------------- versiones
proto_kt = kt("Protocol.kt")
major = int(re.search(r"const val VERSION = (\d+)", proto_kt).group(1))
hello_fake = fa.hello_data()
gradle = rd("android/app/build.gradle.kts")
version_name = re.search(r'versionName = "([^"]+)"', gradle).group(1)
client = rd("termux/bin/nexo")
client_version = re.search(r'^NEXO_VERSION="([^"]+)"', client, re.M).group(1)
check("protocolo: versión y revisión de la app = las de la app falsa", (major, minor) == (hello_fake["proto"], hello_fake["minor"]),
      "  app %s.%s, falsa %s.%s" % (major, minor, hello_fake["proto"], hello_fake["minor"]))
check("la versión de la app (build.gradle.kts) = la de la app falsa = la del cliente",
      version_name == hello_fake["version"] == client_version,
      "  gradle %s, falsa %s, cliente %s" % (version_name, hello_fake["version"], client_version))
doc = rd("docs/PROTOCOLO.md")
check("docs/PROTOCOLO.md habla de la misma revisión", ("(versión %d, revisión %d)" % (major, minor)) in doc)
check("targetSdk 28 y minSdk 26 (decisión de diseño: ver build.gradle.kts)",
      re.search(r"targetSdk = 28\b", gradle) is not None and re.search(r"minSdk = 26\b", gradle) is not None)

# ---------------------------------------------------------------- instalador (bootstrap)
bk = kt("Bootstrap.kt")
m = re.search(r'val head = "((?:[^"\\]|\\.)*)"', bk)
kt_head = re.sub(r"\$[A-Za-z0-9_]+", "%s", m.group(1)).replace("\\n", "\n") if m else None
fa_src = rd("tests/fake_app.py")
m2 = re.search(r'head = "((?:[^"\\]|\\.)*)" % \(', fa_src)
fa_head = m2.group(1).replace("\\n", "\n") if m2 else None
check("el instalador que sirve la app (Bootstrap.kt) empieza igual que el de la app falsa", kt_head is not None and kt_head == fa_head,
      "  app: %r\n  falsa: %r" % (kt_head, fa_head))
check("el instalador lleva el cliente, nexo-dbus, nexo-tools y nexo-usb, en ese orden, como variables de shell",
      kt_head is not None and re.findall(r"^(NEXO_[A-Z0-9_]+)=", kt_head, re.M) == ["NEXO_CLIENT_B64", "NEXO_DBUS_B64", "NEXO_TOOLS_B64", "NEXO_USB_B64"])
check("el instalador NO exporta las variables con los archivos (límite de 128 KiB por variable de entorno)",
      all(("export " + v) not in bk for v in ("NEXO_CLIENT_B64", "NEXO_DBUS_B64", "NEXO_TOOLS_B64", "NEXO_USB_B64")))
check("la app lee de sus assets bin/nexo, bin/nexo-dbus, bin/nexo-tools y bin/nexo-usb, y los cuatro existen en el repositorio",
      all(('readAsset(ctx, "bin/%s")' % n) in bk and os.path.isfile(os.path.join(ROOT, "termux", "bin", n)) for n in ("nexo", "nexo-dbus", "nexo-tools", "nexo-usb")))
inst = rd("termux/install.sh")
check("install.sh instala nexo-dbus desde NEXO_DBUS_B64 (o desde bin/nexo-dbus si se ejecuta desde el repositorio)",
      "NEXO_DBUS_B64" in inst and "$SRC_DIR/bin/nexo-dbus" in inst)
check("install.sh instala nexo-tools desde NEXO_TOOLS_B64 (o desde bin/nexo-tools) y lo quita con --uninstall",
      "NEXO_TOOLS_B64" in inst and "$SRC_DIR/bin/nexo-tools" in inst and 'rm -f "$BIN_DIR/nexo" "$BIN_DIR/nexo-dbus" "$BIN_DIR/nexo-tools"' in inst)
check("install.sh instala nexo-usb desde NEXO_USB_B64 (o desde bin/nexo-usb) y lo quita con --uninstall",
      "NEXO_USB_B64" in inst and "$SRC_DIR/bin/nexo-usb" in inst and '"$BIN_DIR/nexo-usb"' in inst and 'nexo-usb" stop --all' in inst)

# ---------------------------------------------------------------- campos de cada respuesta
wifi_kt, bt_kt, audio_kt, media_kt = kt("WifiHandler.kt"), kt("BluetoothHandler.kt"), kt("AudioHandler.kt"), kt("MediaHandler.kt")


def same(desc, kotlin_keys, spec_keys, optional=()):
    extra = set(kotlin_keys) - set(spec_keys) - set(optional)
    missing = set(spec_keys) - set(kotlin_keys)
    check("campos de %s: app = app falsa" % desc, not extra and not missing,
          "  solo en la app: %s\n  solo en la falsa: %s" % (sorted(extra), sorted(missing)))


same("hello", keys_in(body(commands_kt, r"fun hello\(\): JSONObject \{")), hello_fake.keys())
same("wifi.status", keys_in(body(wifi_kt, r"fun status\(\): JSONObject \{")), fa.wifi_status().keys())
same("wifi.scan (cada red)", keys_in(body(wifi_kt, r"fun scan\(req: JSONObject\): JSONObject \{")) - {"networks", "fresh", "hidden_count", "hint"},
     fa.NETWORKS[0].keys())
same("wifi.connect", keys_in(body(wifi_kt, r"fun connect\(req: JSONObject\): JSONObject \{")), fa.dispatch("wifi.connect", {"ssid": "MiCasa"}).keys(), optional={"hint"})
same("wifi.saved (cada red)", keys_in(body(wifi_kt, r"fun saved\(\): JSONObject \{")) - {"networks"}, fa.SAVED[0].keys() | {"current"})
same("wifi.forget", keys_in(body(wifi_kt, r"fun forget\(req: JSONObject\): JSONObject \{")), {"removed"})
same("wifi.reconnect", keys_in(body(wifi_kt, r"fun reconnect\(req: JSONObject\): JSONObject \{")), {"requested", "connected"}, optional={"hint"})
same("bt.status", keys_in(body(bt_kt, r"fun status\(\): JSONObject \{")), fa.bt_status().keys(), optional={"permission_missing"})
same("bt.paired (cada dispositivo)", keys_in(body(bt_kt, r"fun paired\(\): JSONObject \{")) - {"devices"}, fa.PAIRED[0].keys())
same("bt.forget", keys_in(body(bt_kt, r"fun forget\(req: JSONObject\): JSONObject \{")), {"removed"}, optional={"hint"})
same("bt.rename", keys_in(body(bt_kt, r"fun rename\(req: JSONObject\): JSONObject \{")), {"address", "alias"})
same("bt.info", keys_in(body(bt_kt, r"fun info\(req: JSONObject\): JSONObject \{")), fa.dispatch("bt.info", {"address": "AA:BB:CC:DD:EE:01"}).keys())
same("audio.status", keys_in(body(audio_kt, r"fun status\(\): JSONObject \{")), fa.audio_status().keys())
same("audio.outputs (cada salida)", keys_in(body(audio_kt, r"private fun outputJson\(.*?\): JSONObject \{")), fa.OUTPUTS[0].keys())
same("audio.status.output", keys_in(body(audio_kt, r"private fun outputJson\(.*?\): JSONObject \{")) - {"active"}, fa.audio_status()["output"].keys())
same("media.status", keys_in(body(media_kt, r"fun status\(\): JSONObject \{")), fa.media_status().keys())
same("media.art", keys_in(re.search(r"private fun artJson\(a: Art\): JSONObject =\n(.*?)\n\n", media_kt, re.S).group(1)),
     fa.dispatch("media.art", {}).keys())
same("media.seek", keys_in(body(media_kt, r"fun seek\(req: JSONObject\): JSONObject \{")), {"requested", "position_ms"})
same("media.play/pause/…", keys_in(body(media_kt, r"fun control\(cmd: String\): JSONObject \{")), {"requested", "state"})
same("logs", keys_in(body(commands_kt, r"private fun logs\(req: JSONObject\): JSONObject \{")), fa.dispatch("logs", {}).keys())

# protocolo 1.5: estado de la red del móvil y reenvío de notificaciones
if minor >= 5:
    net_kt, notif_kt = kt("NetHandler.kt"), kt("NotifBridge.kt")
    same("net.status (y el evento «net»)", keys_in(body(net_kt, r"fun status\(\): JSONObject \{")), fa.net_status().keys())
    same("notif.status", keys_in(body(notif_kt, r"fun status\(\): JSONObject \{")), fa.notif_status().keys())
    same("notif.list", keys_in(body(notif_kt, r"fun list\(\): JSONObject \{")), {"notifications"})
    same("notif.dismiss", keys_in(body(notif_kt, r"fun dismiss\(req: JSONObject\): JSONObject \{")), {"dismissed"})
    same("notif (cada notificación, en notif.list y en el evento «posted»)", keys_in(body(notif_kt, r"fun view\(.*?\): JSONObject \{")), fa.notif_view({}).keys())
    same("evento notif «posted» (además de los campos de la notificación)", keys_in(body(notif_kt, r"fun postedEvent\(.*?\): JSONObject \{")), {"op"})
    same("evento notif «removed»", keys_in(body(notif_kt, r"fun removedEvent\(.*?\): JSONObject \{")), {"op", "key", "reason"})
    notif_logic_kt = kt("NotifLogic.kt")
    reasons = ("clicked", "dismissed", "cancelled", "timeout", "other")
    check("los motivos de «removed» (%s) están en NotifLogic.kt y las operaciones (posted, removed) en NotifBridge.kt" % ", ".join(reasons),
          all(('"%s"' % r) in notif_logic_kt for r in reasons) and all(('"%s"' % r) in notif_kt for r in ("posted", "removed")))
    check("docs/PROTOCOLO.md documenta los temas net y notif", "`net`" in doc and "`notif`" in doc)
    check("docs/PROTOCOLO.md documenta los motivos de «removed»", all(("`%s`" % r) in doc for r in reasons),
          "  sin documentar: %s" % [r for r in reasons if ("`%s`" % r) not in doc])

check("docs/PROTOCOLO.md documenta todos los comandos de la app",
      all(("`%s`" % n) in doc for n in names), "  sin documentar: %s" % [n for n in names if ("`%s`" % n) not in doc])

# protocolo 1.3: USB serie
if minor >= 3:
    usb_kt = kt("UsbHandler.kt")
    plugged = fa.usb_plug("cp2102")          # sin hilos propios (el modelo «echo»); se desenchufa al terminar
    other = fa.usb_plug("cp2102")
    try:
        plugged["permission"] = True
        sess_spec = fa.usb_open({"device": plugged["id"]}, None)
        st_spec = fa.usb_status()
        perm_spec = fa.usb_permission({"device": other["id"]})
        same("usb.status", keys_in(body(usb_kt, r"fun status\(\): JSONObject \{")), st_spec.keys())
        dev_spec = st_spec["devices"][0]
        same("usb.status (cada dispositivo y cada interfaz)", keys_in(body(usb_kt, r"private fun view\(dev: UsbDevice\): JSONObject \{"), keep={"permission"}),
             set(dev_spec.keys()) | set(dev_spec["interfaces"][0].keys()))
        base_sess = set(st_spec["sessions"][0].keys())
        same("usb (cada sesión, en usb.status y en los eventos «usb»)", keys_in(body(usb_kt, r"private fun sessionView\(s: UsbSession\): JSONObject \{")), base_sess)
        same("usb.permission", keys_in(body(usb_kt, r"private fun permJson\(.*?\): JSONObject \{")), perm_spec.keys())
        same("usb.open (además de los campos de la sesión)", keys_in(body(usb_kt, r"fun open\(req: JSONObject, owner: Any\?\): JSONObject \{")), set(sess_spec.keys()) - base_sess)
        same("usb (cada paso de las órdenes al chip)", keys_in(body(usb_kt, r"private fun stepsJson\(steps: List<Step>\): JSONArray \{")), sess_spec["steps"][0].keys())
        same("usb.setup (además de los campos de la sesión)", keys_in(body(usb_kt, r"fun setup\(req: JSONObject\): JSONObject \{")), set(fa.usb_setup({"session": sess_spec["session"]}).keys()) - base_sess)
        same("usb.control (además de los campos de la sesión)", keys_in(body(usb_kt, r"fun control\(req: JSONObject\): JSONObject \{")), set(fa.usb_control({"session": sess_spec["session"]}).keys()) - base_sess)
        same("usb.close", keys_in(body(usb_kt, r"fun close\(req: JSONObject\): JSONObject \{")), fa.usb_close({"session": sess_spec["session"]}).keys())
        same("usb.attach (respuesta; después la conexión es de bytes)", keys_in(body(server_kt, r"private fun attachUsb\(.*?\): Boolean \{")), {"session", "raw"})
    finally:
        fa.usb_unplug("all")
    check("docs/PROTOCOLO.md documenta el tema usb y sus campos", "`usb`" in doc and all(("`%s`" % k) in doc for k in ("serial_capable", "ep_in", "needs_permission")))

# protocolo 1.4: almacenamiento USB
if minor >= 4:
    import shutil
    import tempfile
    st_kt, logic_kt = kt("StorageHandler.kt"), kt("StorageLogic.kt")
    fa.ST["dir"] = tempfile.mkdtemp(prefix="nexo-contrato-")
    try:
        fa.storage_add("Contrato", "0000-0001", set())
        disk = os.path.join(fa.ST["dir"], "0000-0001")
        os.makedirs(os.path.join(disk, "d"))
        with open(os.path.join(disk, "f.txt"), "wb") as f:
            f.write(b"x")
        vol = {"volume": "0000-0001"}
        stat_spec = fa.storage_status()
        same("storage.status", keys_in(body(st_kt, r"fun status\(\): JSONObject \{")), stat_spec.keys())
        same("storage.status (cada volumen, también en los eventos «storage»)",
             keys_in(body(st_kt, r"private fun volumeJson\(.*?\): JSONObject \{")), stat_spec["volumes"][0].keys())
        same("storage.access", keys_in(body(st_kt, r"fun access\(req: JSONObject\): JSONObject = guard \{")), fa.storage_access(vol).keys())
        lst = fa.storage_list(dict(vol, path="/"))
        same("storage.list", keys_in(body(st_kt, r"fun list\(req: JSONObject\): JSONObject = guard \{")), lst.keys())
        file_entry = [e for e in lst["entries"] if e["type"] == "file"][0]
        same("storage (cada entrada de una carpeta, en storage.list y storage.stat)",
             keys_in(body(st_kt, r"private fun entryJson\(e: DocEntry\): JSONObject \{")), file_entry.keys())
        same("storage.stat (además de los campos de la entrada)", keys_in(body(st_kt, r"fun stat\(req: JSONObject\): JSONObject = guard \{")),
             set(fa.storage_stat(dict(vol, path="/f.txt")).keys()) - set(file_entry.keys()))
        opened = fa.storage_open(dict(vol, path="/f.txt", mode="rw"), None)
        same("storage.open", keys_in(body(st_kt, r"fun open\(req: JSONObject, owner: Any\?\): JSONObject = guard \{")), opened.keys())
        same("storage.read", keys_in(body(st_kt, r"fun read\(req: JSONObject\): JSONObject = guard \{")), fa.storage_read({"handle": opened["handle"], "offset": 0}).keys())
        same("storage.write", keys_in(body(st_kt, r"fun write\(req: JSONObject\): JSONObject = guard \{")),
             fa.storage_write({"handle": opened["handle"], "offset": 0, "data": "eA=="}).keys())
        same("storage.sync", keys_in(body(st_kt, r"fun sync\(req: JSONObject\): JSONObject = guard \{")), fa.storage_sync({"handle": opened["handle"]}).keys())
        same("storage.close", keys_in(body(st_kt, r"fun close\(req: JSONObject\): JSONObject = guard \{")), fa.storage_close({"handle": opened["handle"]}).keys())
        same("storage.mkdir", keys_in(body(st_kt, r"fun mkdir\(req: JSONObject\): JSONObject = guard \{")), fa.storage_mkdir(dict(vol, path="/n")).keys())
        same("storage.rename", keys_in(body(st_kt, r"fun rename\(req: JSONObject\): JSONObject = guard \{")),
             fa.storage_rename(dict(vol, **{"from": "/n", "to": "/m"})).keys())
        same("storage.delete", keys_in(body(st_kt, r"fun delete\(req: JSONObject\): JSONObject = guard \{")), fa.storage_delete(dict(vol, path="/m")).keys())
        fa.ST["vols"][0]["eject"] = "silent"
        same("storage.eject (con el aviso de cuando Android no lo expulsa)", keys_in(body(st_kt, r"fun eject\(req: JSONObject\): JSONObject = guard \{")),
             fa.storage_eject(vol).keys())
        same("storage.revoke", keys_in(body(st_kt, r"fun revoke\(req: JSONObject\): JSONObject = guard \{")), fa.storage_revoke(vol).keys())

        def const(src, name):
            m = re.search(r"const val %s = ([0-9_]+)" % name, src)
            return int(m.group(1).replace("_", "")) if m else None
        limits = [("READ_MAX", fa.STORAGE_READ_MAX), ("WRITE_MAX", fa.STORAGE_WRITE_MAX), ("LIST_DEFAULT", fa.STORAGE_LIST_DEFAULT),
                  ("LIST_MAX", fa.STORAGE_LIST_MAX), ("MAX_HANDLES", fa.STORAGE_MAX_HANDLES),
                  ("MAX_HANDLES_PER_OWNER", fa.STORAGE_MAX_HANDLES_PER_OWNER), ("MAX_PATH", fa.STORAGE_MAX_PATH),
                  ("MAX_NAME_BYTES", fa.STORAGE_MAX_NAME_BYTES)]
        check("los límites del almacenamiento (trozos, listas, archivos abiertos, rutas) son los mismos en la app y en la app falsa",
              all(const(logic_kt, k) == v for k, v in limits), "  %s" % [(k, const(logic_kt, k), v) for k, v in limits])
        bad_kt = re.search(r'BAD_NEW_CHARS = "((?:[^"\\]|\\.)*)"', logic_kt).group(1).replace('\\"', '"').replace("\\\\", "\\")

        def refuses(name):
            try:
                fa.st_check_new_name(name)
                return False
            except fa.Err:
                return True
        bad_fake = set(chr(c) for c in range(32, 127) if refuses("a" + chr(c) + "b"))
        check("los caracteres que no se admiten en un nombre nuevo son los mismos en la app y en la app falsa", bad_fake == set(bad_kt),
              "  app: %r  falsa: %r" % (sorted(set(bad_kt)), sorted(bad_fake)))
        block = fa_src[fa_src.index("# ---------------------------------------------------------------- almacenamiento USB"):fa_src.index("def ctl_apply")]
        codes_fake = set(re.findall(r'Err\("([a-z_]+)"', block))
        codes_kt = set(re.findall(r'(?:StorageException|CmdException)\(\s*"([a-z_]+)"', logic_kt + kt("StorageSaf.kt") + st_kt))
        check("el almacenamiento de la app falsa y el de la app lanzan los mismos códigos de error", codes_fake == codes_kt,
              "  solo en la app: %s\n  solo en la falsa: %s" % (sorted(codes_kt - codes_fake), sorted(codes_fake - codes_kt)))
    finally:
        fa.st_handles_close_where(lambda h: True)
        fa.ST["vols"][:] = []
        fa.ST["grants"].clear()
        shutil.rmtree(fa.ST["dir"], ignore_errors=True)
    check("docs/PROTOCOLO.md documenta el tema storage y sus campos y errores",
          "`storage`" in doc and all(("`%s`" % k) in doc for k in ("mass_storage_devices", "no_access", "unavailable", "too_big", "no_space", "not_empty", "mtime_ms")))
    check("existe docs/USB-ALMACENAMIENTO.md y README, CHANGELOG y LIMITACIONES hablan del almacenamiento USB",
          os.path.isfile(os.path.join(ROOT, "docs", "USB-ALMACENAMIENTO.md")) and "nexo usb mounts" in rd("README.md")
          and "almacenamiento" in rd("CHANGELOG.md").lower() and "FAT32" in rd("docs/LIMITACIONES.md"))

# ---------------------------------------------------------------- errores y paneles documentados
all_kt = "\n".join(kt(f) for f in sorted(os.listdir(KT)) if f.endswith(".kt"))
codes = set(re.findall(r'CmdException\(\s*"([a-z_]+)"', all_kt)) | set(re.findall(r'Protocol\.error\([^,]+,\s*"([a-z_]+)"', all_kt)) \
    | set(re.findall(r'StorageException\(\s*"([a-z_]+)"', all_kt))
spec_codes = set(re.findall(r'Err\("([a-z_]+)"', fa_src))
table = doc[doc.index("### Códigos de error"):doc.index("## Comandos")]
documented = set(re.findall(r"`([a-z_]+)`", "\n".join(l.split("|")[1] for l in table.splitlines() if l.startswith("| `"))))
check("todo código de error que usa la app está en la tabla de docs/PROTOCOLO.md", codes <= documented,
      "  sin documentar: %s" % sorted(codes - documented))
check("todo código de error que usa la app falsa está en la tabla de docs/PROTOCOLO.md", spec_codes <= documented,
      "  sin documentar: %s" % sorted(spec_codes - documented))

opens_kt = set()
for line in all_kt.splitlines():
    if '"opens"' in line:
        opens_kt |= set(re.findall(r'"([a-z_]+)"', line.split('"opens"', 1)[1]))
opens_fake = set(re.findall(r'needs_user\([^)]*?,\s*"([a-z_]+)"\)', fa_src)) | set(re.findall(r'raise needs_user\(\s*"[^"]*",\s*"([a-z_]+)"', fa_src))
opens_fake |= set(re.findall(r'\n\s+"([a-z_]+_(?:settings|panel|enable))"\)', fa_src))
opens_doc = set(re.findall(r"`([a-z_]+)`", doc[doc.index("| `needs_user_action`"):].split("\n", 1)[0]))
check("los paneles (`opens`) que abre la app están todos documentados", opens_kt and opens_kt <= opens_doc,
      "  app: %s\n  doc: %s" % (sorted(opens_kt), sorted(opens_doc)))
if minor < 5:
    opens_fake -= fa.V15_OPENS      # los paneles del protocolo 1.5 los traerá la app cuando llegue a la revisión 5
check("…y los que usa la app falsa existen también en la app", opens_fake <= opens_kt, "  falsa: %s\n  app: %s" % (sorted(opens_fake), sorted(opens_kt)))

# ---------------------------------------------------------------- manifiesto
man = rd("android/app/src/main/AndroidManifest.xml")
check("el manifiesto declara el servicio de acceso a notificaciones con su permiso de enlace",
      "NexoNotificationListener" in man and "android.permission.BIND_NOTIFICATION_LISTENER_SERVICE" in man)
check("el manifiesto declara StartActivity (nexo start) como exportada", re.search(r'\.StartActivity"\s+android:exported="true"', man) is not None)
check("el servicio en primer plano es de tipo connectedDevice", 'android:foregroundServiceType="connectedDevice"' in man)
if minor >= 3:
    check("el manifiesto declara el modo anfitrión USB como no obligatorio (el móvil sin OTG sigue pudiendo instalar la app)",
          re.search(r'<uses-feature android:name="android.hardware.usb.host" android:required="false"', man) is not None)
    check("UsbAttachedActivity ofrece abrir Nexo al conectar un dispositivo (USB_DEVICE_ATTACHED + usb_device_filter), sin mostrar nada",
          re.search(r'\.UsbAttachedActivity"[^>]*android:exported="true"', man, re.S) is not None
          and "android.hardware.usb.action.USB_DEVICE_ATTACHED" in man and "@xml/usb_device_filter" in man
          and "finish()" in kt("UsbAttachedActivity.kt"))
    filt = rd("android/app/src/main/res/xml/usb_device_filter.xml")
    ids = re.findall(r'(?:vendor|product)-id="([^"]*)"', filt)
    check("res/xml/usb_device_filter.xml: hay dispositivos y los identificadores van en decimal", ids and all(i.isdigit() for i in ids), "  ids: %s" % ids)
    check("la app NO pide permisos de almacenamiento ni de cámara/micrófono para el USB (el permiso USB es el de Android, por dispositivo)",
          "android.permission.MANAGE_USB" not in man and "WRITE_EXTERNAL_STORAGE" not in man)
if minor >= 4:
    check("StorageGrantActivity (elegir el disco en el selector de Android) está declarada y NO exportada",
          re.search(r'\.StorageGrantActivity"[^>]*android:exported="false"', man, re.S) is not None
          and "ACTION_OPEN_DOCUMENT_TREE" in kt("StorageGrantActivity.kt"))
    check("el almacenamiento USB NO pide «acceso a todos los archivos» (MANAGE_EXTERNAL_STORAGE): usa solo el selector de carpetas de Android",
          "MANAGE_EXTERNAL_STORAGE" not in man and "MANAGE_EXTERNAL_STORAGE" not in "".join(kt(f) for f in sorted(os.listdir(KT)) if f.startswith("Storage")))
check("la app NO pide acceso a internet de verdad ni permisos de SMS/contactos/micrófono",
      not re.search(r"READ_SMS|READ_CONTACTS|RECORD_AUDIO|CAMERA|ACCESS_BACKGROUND_LOCATION|READ_EXTERNAL_STORAGE", man))

# ---------------------------------------------------------------- documentación de la revisión 5 (0.4.3: red y notificaciones)
if minor >= 5:
    readme, changelog, limites, roadmap = rd("README.md"), rd("CHANGELOG.md"), rd("docs/LIMITACIONES.md"), rd("docs/ROADMAP.md")
    check("README, CHANGELOG y LIMITACIONES hablan de `nexo net` y `nexo notif`, y dicen que el reenvío es opcional y viene apagado",
          "nexo net" in readme and "nexo notif" in readme and "Reenviar notificaciones a Linux" in readme and "apagado de fábrica" in readme
          and "nexo net" in changelog and "nexo notif" in changelog
          and "## Notificaciones (`nexo notif`)" in limites and "## Red del móvil (`nexo net`)" in limites and "apagado" in limites.lower())
    m_chg = re.search(r"^## (\S+)", changelog, re.M)
    check("el README (estado), el CHANGELOG (primera sección) y el ROADMAP dicen la versión de la app (%s)" % version_name,
          ("Estado: versión %s" % version_name) in readme and m_chg is not None and m_chg.group(1) == version_name
          and ("Estado: **v%s**" % version_name) in roadmap,
          "  README: %s  CHANGELOG: %s  ROADMAP: %s" % (("Estado: versión %s" % version_name) in readme, m_chg and m_chg.group(1), ("Estado: **v%s**" % version_name) in roadmap))
    left = [n for n, t in (("README.md", readme), ("CHANGELOG.md", changelog), ("docs/LIMITACIONES.md", limites), ("docs/ROADMAP.md", roadmap)) if "@@" in t]
    check("no queda ninguna marca de relleno (@@…@@) en README, CHANGELOG, LIMITACIONES ni ROADMAP", not left, "  quedan en: %s" % left)

sys.exit(1 if failed else 0)
