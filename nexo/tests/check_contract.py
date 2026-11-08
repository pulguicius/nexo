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
ERROR_EXTRAS = {"permission", "action", "opens"}


def keys_in(text):
    """Campos JSON que escribe un trozo de Kotlin: .put("campo", …) / .putOrNull("campo", …) / put("campo")."""
    return set(re.findall(r'\.put(?:OrNull)?\(\s*"([a-z_]+)"', text or "")) - ERROR_EXTRAS


# ---------------------------------------------------------------- la app falsa
spec = importlib.util.spec_from_file_location("fake_app", os.path.join(ROOT, "tests", "fake_app.py"))
fa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fa)
fa.ARGS = argparse.Namespace(old=False, listener=True, no_session=False, record=None, reqlog=None)

# ---------------------------------------------------------------- comandos y temas
commands_kt = kt("Commands.kt")
m = re.search(r"val NAMES: List<String> = listOf\((.*?)\)\.sorted\(\)", commands_kt, re.S)
names = sorted(re.findall(r'"([a-z.]+)"', m.group(1))) if m else []
spec_names = sorted(fa.OLD_COMMANDS | fa.NEW_COMMANDS)
check("la lista de comandos de la app (Commands.NAMES) es la de la app falsa", names == spec_names,
      "  solo en la app: %s\n  solo en la falsa: %s" % (sorted(set(names) - set(spec_names)), sorted(set(spec_names) - set(names))))

handle = body(commands_kt, r"fun handle\(cmd: String, req: JSONObject\): JSONObject = when \(cmd\) \{") or ""
handled = set(re.findall(r'"([a-z]+\.[a-z]+|logs)"', handle))
server_side = {"hello", "ping", "subscribe", "unsubscribe"}
check("cada comando anunciado tiene su rama en Commands.handle (o en el servidor)",
      handled == set(names) - server_side,
      "  sin rama: %s\n  rama sin anunciar: %s" % (sorted(set(names) - server_side - handled), sorted(handled - set(names))))
server_kt = kt("BridgeServer.kt")
check("el servidor atiende hello, ping, subscribe y unsubscribe",
      all(('"%s" ->' % c) in server_kt for c in sorted(server_side)))

m = re.search(r"val TOPICS: List<String> = listOf\((.*?)\)", commands_kt, re.S)
topics = set(re.findall(r'"([a-z]+)"', m.group(1))) if m else set()
check("los temas de eventos de la app son wifi, bt, audio y media", topics == {"wifi", "bt", "audio", "media"}, "  son: %s" % sorted(topics))

# ---------------------------------------------------------------- versiones
proto_kt = kt("Protocol.kt")
minor = int(re.search(r"const val MINOR = (\d+)", proto_kt).group(1))
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
check("el instalador lleva el cliente y nexo-dbus, en ese orden, como variables de shell",
      kt_head is not None and re.findall(r"^(NEXO_[A-Z0-9_]+)=", kt_head, re.M) == ["NEXO_CLIENT_B64", "NEXO_DBUS_B64"])
check("el instalador NO exporta las variables con los archivos (límite de 128 KiB por variable de entorno)",
      "export NEXO_CLIENT_B64" not in bk and "export NEXO_DBUS_B64" not in bk)
check("la app lee de sus assets bin/nexo y bin/nexo-dbus, y ambos existen en el repositorio",
      'readAsset(ctx, "bin/nexo")' in bk and 'readAsset(ctx, "bin/nexo-dbus")' in bk
      and os.path.isfile(os.path.join(ROOT, "termux", "bin", "nexo")) and os.path.isfile(os.path.join(ROOT, "termux", "bin", "nexo-dbus")))
inst = rd("termux/install.sh")
check("install.sh instala nexo-dbus desde NEXO_DBUS_B64 (o desde bin/nexo-dbus si se ejecuta desde el repositorio)",
      "NEXO_DBUS_B64" in inst and "$SRC_DIR/bin/nexo-dbus" in inst)

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

# ---------------------------------------------------------------- errores y paneles documentados
all_kt = "\n".join(kt(f) for f in sorted(os.listdir(KT)) if f.endswith(".kt"))
codes = set(re.findall(r'CmdException\(\s*"([a-z_]+)"', all_kt)) | set(re.findall(r'Protocol\.error\([^,]+,\s*"([a-z_]+)"', all_kt))
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
check("…y los que usa la app falsa existen también en la app", opens_fake <= opens_kt, "  falsa: %s\n  app: %s" % (sorted(opens_fake), sorted(opens_kt)))

# ---------------------------------------------------------------- manifiesto
man = rd("android/app/src/main/AndroidManifest.xml")
check("el manifiesto declara el servicio de acceso a notificaciones con su permiso de enlace",
      "NexoNotificationListener" in man and "android.permission.BIND_NOTIFICATION_LISTENER_SERVICE" in man)
check("el manifiesto declara StartActivity (nexo start) como exportada", re.search(r'\.StartActivity"\s+android:exported="true"', man) is not None)
check("el servicio en primer plano es de tipo connectedDevice", 'android:foregroundServiceType="connectedDevice"' in man)
check("la app NO pide acceso a internet de verdad ni permisos de SMS/contactos/micrófono",
      not re.search(r"READ_SMS|READ_CONTACTS|RECORD_AUDIO|CAMERA|ACCESS_BACKGROUND_LOCATION|READ_EXTERNAL_STORAGE", man))

sys.exit(1 if failed else 0)
