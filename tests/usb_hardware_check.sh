#!/usr/bin/env bash
# Prueba REAL de «nexo usb» con un dispositivo enchufado al móvil (Arduino, ESP32 o un adaptador USB↔serie).
#
# QUÉ ES: las pruebas automáticas (tests/usb_tests.sh) hablan con una app FALSA: prueban el protocolo y la lógica de nexo-usb,
# no que el chip de TU placa conteste. Esto es lo que solo se puede hacer con el hardware delante. Se ejecuta en Termux (o en una
# distro) con la app Nexo en marcha y nexo-usb instalado, y al final imprime un informe que puedes copiar y pegar (no lleva tu token).
# No modifica el dispositivo: no escribe en su memoria ni cambia su programa (la prueba del cargador solo le pregunta «¿estás ahí?»).
#
# USO:   bash tests/usb_hardware_check.sh [DISPOSITIVO] [--arduino] [--loopback] [--esp32] [--unplug] [--baud N] [--yes]
#   DISPOSITIVO  lo mismo que en «nexo usb list» (id, VID:PID o parte del nombre); sin él, el único adaptador serie conectado
#   --arduino    reinicio automático + sincronía con el cargador de arranque (STK500: Uno, Nano, Mega, Pro Mini con su cargador de fábrica)
#   --loopback   une TX con RX del adaptador con un cable y comprueba que lo que sale vuelve (texto y los 256 valores de byte)
#   --esp32      lee el chip con esptool por RFC 2217 (hace falta esptool: pip install esptool)
#   --unplug     te pide desenchufar y volver a enchufar, y comprueba que el puente se recupera
#   --baud N     velocidad de las pruebas (115200; un Nano con el cargador antiguo usa 57600)
#   --yes        no espera a que pulses Enter (para automatizar)
# Siempre hace las básicas: Android ve el dispositivo, permiso, abrir el puerto y leer 3 s.
# Códigos de salida: 0 todo bien · 1 alguna prueba falló · 2 uso incorrecto.

set -u
NX=${NEXO_CHECK_BIN:-nexo}                       # (las pruebas automáticas lo apuntan a su copia)
DEV=""; DO_ARD=0; DO_LOOP=0; DO_ESP=0; DO_UNP=0; BAUD=115200; YES=0
while [ $# -gt 0 ]; do
    case $1 in
        --arduino) DO_ARD=1 ;;
        --loopback) DO_LOOP=1 ;;
        --esp32) DO_ESP=1 ;;
        --unplug) DO_UNP=1 ;;
        --baud) BAUD=${2:-}; shift ;;
        --yes|-y) YES=1 ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "Opción desconocida: $1 (mira --help)" >&2; exit 2 ;;
        *) if [ -z "$DEV" ]; then DEV=$1; else echo "Solo se puede probar un dispositivo a la vez." >&2; exit 2; fi ;;
    esac
    shift
done
case $BAUD in ''|*[!0-9]*) echo "--baud pide un número (por ejemplo 115200)." >&2; exit 2 ;; esac
command -v python3 >/dev/null 2>&1 || { echo "Falta python3 (Termux: pkg install python)." >&2; exit 2; }
command -v "$NX" >/dev/null 2>&1 || { echo "No encuentro «$NX». Instala Nexo (el comando de instalación de la app) y vuelve a probar." >&2; exit 2; }

W=$(mktemp -d "${TMPDIR:-/tmp}/nexo-usb-check.XXXXXX") || exit 1
PASS=0; FAIL=0; SKIP=0
REPORT=$W/report; : > "$REPORT"
BRIDGES="chk-ard chk-esp chk-unp"
cleanup() {
    local b
    for b in $BRIDGES; do "$NX" usb stop "$b" >/dev/null 2>&1; done
    rm -rf "$W"
}
trap cleanup EXIT

say()  { printf '%s\n' "$*"; }
note() { printf '           %s\n' "$*"; printf '           %s\n' "$*" >> "$REPORT"; }
ok()   { PASS=$((PASS + 1)); printf '  ok        %s\n' "$1"; printf 'ok        %s\n' "$1" >> "$REPORT"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FALLA     %s\n' "$1"; printf 'FALLA     %s\n' "$1" >> "$REPORT"; [ -n "${2:-}" ] && note "$2"; return 0; }
skip() { SKIP=$((SKIP + 1)); printf '  omitido   %s\n' "$1"; printf 'omitido   %s\n' "$1" >> "$REPORT"; [ -n "${2:-}" ] && note "$2"; return 0; }

# pause MENSAJE [ORDEN]: espera a que hagas algo en el móvil. Con ORDEN (solo para las pruebas automáticas) la ejecuta en vez de esperar.
pause() {
    say "  →  $1"
    if [ -n "${2:-}" ]; then eval "$2"
    elif [ "$YES" = 0 ]; then read -r -p "     (pulsa Enter cuando lo hayas hecho) " _ || true
    fi
}

# bstatus NOMBRE → el estado (JSON) de un puente en marcha
bstatus() { "$NX" usb status --json 2>/dev/null | python3 -c 'import json,sys; print(json.dumps(next((b for b in json.load(sys.stdin) if b.get("name") == sys.argv[1]), {}), ensure_ascii=False))' "$1" 2>/dev/null; }

# pj ARCHIVO EXPRESIÓN → evalúa una expresión de Python sobre el JSON del archivo (d). Las expresiones las escribe este script, no el usuario.
pj() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null; }

short() { printf '%s' "$1" | head -c "${2:-200}" | tr '\n\r' '  '; }

# ---------------------------------------------------------------------------------------------------------------- 1. Entorno
say "== 1. Entorno"
{
    echo "fecha        $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "sistema      $(uname -srm 2>/dev/null)"
    echo "python3      $(python3 --version 2>&1)"
    echo "nexo         $("$NX" version --check 2>&1 | head -n 3 | tr '\n' ' ')"
    echo "nexo-usb     $("$NX" usb version 2>&1 | head -n 1)"
} > "$W/env.txt"
cat "$W/env.txt" | sed 's/^/     /'

"$NX" usb list --json > "$W/list.json" 2> "$W/list.err"; rc=$?
if [ "$rc" -ne 0 ]; then
    bad "«nexo usb list» falló (código $rc)" "$(short "$(cat "$W/list.err")" 300)"
    note "10 = la app no responde (¿está encendido el puente?) · 11 = token · mira «nexo doctor»"
    FAIL_EARLY=1
else
    FAIL_EARLY=0
    if [ "$(pj "$W/list.json" 'd.get("host")')" = True ]; then ok "este móvil tiene USB host (OTG)"; else bad "Android dice que este móvil NO tiene USB host: no hay nada que probar"; FAIL_EARLY=1; fi
fi

DEVID=""
if [ "$FAIL_EARLY" = 0 ]; then
    python3 - "$W/list.json" "$DEV" "$W/dev.json" > "$W/pick.txt" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
sel = sys.argv[2].strip().lower()
devs = d.get("devices", [])
def name(x):
    return " · ".join(s for s in (x.get("product"), x.get("vendor")) if s) or "(sin nombre)"
if sel:
    c = [x for x in devs if sel == str(x["id"]) or sel == "%s:%s" % (x["vid"], x["pid"]) or
         any(sel in (x.get(k) or "").lower() for k in ("product", "vendor", "serial"))]
else:
    c = [x for x in devs if x.get("serial_capable")]
if len(c) == 1:
    x = c[0]
    json.dump(x, open(sys.argv[3], "w"), ensure_ascii=False)
    print("\t".join(["ok", str(x["id"]), "%s:%s" % (x["vid"], x["pid"]), name(x), x.get("driver") or "ninguno", str(bool(x.get("serial_capable")))]))
elif not c:
    print("\t".join(["none", "ningún dispositivo coincide con «%s»" % sel if sel else "no hay ningún adaptador serie conectado"]))
else:
    print("\t".join(["many", "; ".join("%s %s:%s %s" % (x["id"], x["vid"], x["pid"], name(x)) for x in c)]))
PY
    IFS=$'\t' read -r st f1 f2 f3 f4 f5 < "$W/pick.txt"
    case $st in
        ok)
            DEVID=$f1
            ok "Android ve el dispositivo $f1: $f2 ($f3)"
            note "controlador: $f4 · sirve como puerto serie: $f5"
            if [ "$f5" != True ]; then bad "Nexo no tiene controlador para este dispositivo (ver docs/USB.md)"; FAIL_EARLY=1; fi
            ;;
        none) bad "no encuentro el dispositivo: $f1"; note "enchúfalo (cable OTG) y mira «nexo usb list»"; FAIL_EARLY=1 ;;
        many) bad "hay varios dispositivos: indica cuál (id o VID:PID)"; note "$f1"; FAIL_EARLY=1 ;;
        *) bad "no pude elegir el dispositivo"; FAIL_EARLY=1 ;;
    esac
fi

# --------------------------------------------------------------------------------------------------------------- 2. Permiso
if [ "$FAIL_EARLY" = 0 ]; then
    say "== 2. Permiso de Android"
    pause "Va a salir un aviso de Android: «¿Permitir que Nexo acceda al dispositivo USB?». Elige Aceptar (y marca «Usar siempre»)." ""
    "$NX" usb permit "$DEVID" > "$W/permit.out" 2>&1; rc=$?
    if [ "$rc" -eq 0 ]; then ok "permiso concedido"; else bad "«nexo usb permit» salió con $rc" "$(short "$(cat "$W/permit.out")" 300)"; FAIL_EARLY=1; fi
fi

# ----------------------------------------------------------------------------------------------------- 3. Abrir el puerto y leer
if [ "$FAIL_EARLY" = 0 ]; then
    say "== 3. Abrir el puerto ($BAUD 8N1) y leer 3 s"
    "$NX" usb monitor "$DEVID" -b "$BAUD" --no-input --seconds 3 --json > "$W/mon.out" 2> "$W/mon.err"; rc=$?
    if [ "$rc" -eq 0 ]; then
        n=$(pj "$W/mon.out" 'd["bytes"]'); hx=$(pj "$W/mon.out" 'd["hex"][:64]')
        ok "el puerto abre con esa configuración y se lee ($n bytes en 3 s)"
        [ "${n:-0}" -gt 0 ] && note "primeros bytes (hex): $hx"
        [ "${n:-0}" -eq 0 ] && note "0 bytes no es un error: una placa sin programa que hable no manda nada"
    else
        bad "«nexo usb monitor» salió con $rc" "$(short "$(cat "$W/mon.err")" 300)"
        case $rc in
            3) note "falta el permiso: repite «nexo usb permit»" ;;
            4) note "no hay dispositivo, o es de un tipo que Nexo no sabe abrir" ;;
            5) note "se desenchufó durante la prueba" ;;
        esac
    fi
fi

# ----------------------------------------------------------------------------------------------------------- 4. Eco (loopback)
if [ "$DO_LOOP" = 1 ] && [ "$FAIL_EARLY" = 0 ]; then
    say "== 4. Eco: lo que sale por TX tiene que volver por RX"
    pause "Une los pines TX y RX del adaptador con un cable (puente)." ""
    "$NX" usb monitor "$DEVID" -b "$BAUD" --no-reset --no-input --send 'nexo-usb-eco-0123456789\n' --until 'nexo-usb-eco-0123456789' --seconds 5 --json > "$W/eco.out" 2> "$W/eco.err"; rc=$?
    if [ "$rc" -eq 0 ] && [ "$(pj "$W/eco.out" 'd["matched"]')" = True ]; then ok "el texto vuelve igual"; else bad "el texto no volvió (código $rc)" "$(short "$(cat "$W/eco.out" "$W/eco.err" 2>/dev/null)" 300)"; fi
    all=$(python3 -c 'print("".join("\\x%02x" % i for i in range(256)), end="")')
    "$NX" usb monitor "$DEVID" -b "$BAUD" --no-reset --no-input --send "$all" --eol none --seconds 3 --json > "$W/eco2.out" 2> "$W/eco2.err"; rc=$?
    want=$(python3 -c 'print(bytes(range(256)).hex(), end="")')
    got=$(pj "$W/eco2.out" 'd["hex"]')
    if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then ok "los 256 valores de byte vuelven iguales y en orden"
    else bad "los 256 valores de byte no volvieron iguales (código $rc, volvieron $(( ${#got} / 2 )) de 256)"; fi
elif [ "$DO_LOOP" = 1 ]; then
    skip "eco (no se pudo con lo anterior)"
fi

# ----------------------------------------------------------------------------------------- 5. Arduino: reinicio y cargador (STK500)
if [ "$DO_ARD" = 1 ] && [ "$FAIL_EARLY" = 0 ]; then
    say "== 5. Arduino: reinicio automático y cargador de arranque (STK500)"
    "$NX" usb bridge "$DEVID" --name chk-ard --link "$W/ard.tty" -b "$BAUD" --detach > "$W/ard.out" 2>&1; rc=$?
    if [ "$rc" -ne 0 ]; then
        bad "no pude abrir el puente (código $rc)" "$(short "$(cat "$W/ard.out")" 300)"
    else
        ok "el puente abre el puerto serie falso"
        python3 - "$W/ard.tty" "$BAUD" > "$W/ard.json" 2> "$W/ard.err" <<'PY'
# Abre el puerto como lo haría avrdude (eso reinicia la placa) y le pregunta al cargador «¿estás ahí?» (STK500 GET_SYNC: 30 20 → 14 10).
import json, os, select, sys, termios, time
path, baud = sys.argv[1], int(sys.argv[2])
fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
t = termios.tcgetattr(fd)
t[0] = t[1] = t[3] = 0
t[2] = (t[2] & ~(termios.CSIZE | termios.PARENB | termios.CSTOPB)) | termios.CS8 | termios.CREAD | termios.CLOCAL
t[4] = t[5] = getattr(termios, "B%d" % baud)
t[6][termios.VMIN] = 0
t[6][termios.VTIME] = 0
termios.tcsetattr(fd, termios.TCSANOW, t)
t0 = time.time()
rx = b""
ms = None
while time.time() - t0 < 3.0 and ms is None:
    os.write(fd, b"\x30\x20")
    end = time.time() + 0.05
    while time.time() < end:
        if select.select([fd], [], [], 0.01)[0]:
            try:
                rx += os.read(fd, 256)
            except OSError:
                break
    if b"\x14\x10" in rx:
        ms = int((time.time() - t0) * 1000)
print(json.dumps({"synced": ms is not None, "ms": ms, "rx": rx[:48].hex()}))
PY
        if [ "$(pj "$W/ard.json" 'd["synced"]')" = True ]; then
            ok "el cargador contestó 14 10 (la placa se reinició al abrir el puerto) a los $(pj "$W/ard.json" 'd["ms"]') ms"
        else
            bad "el cargador no contestó a 30 20 en 3 s a $BAUD baudios" "$(short "$(cat "$W/ard.json" "$W/ard.err" 2>/dev/null)" 300)"
            note "¿placa sin cargador STK500 (Leonardo/Pro Micro/ESP32 no lo usan)? ¿un Nano antiguo? prueba --baud 57600"
        fi
        bstatus chk-ard > "$W/ard.status"
        "$NX" usb stop chk-ard > /dev/null 2>&1
    fi
elif [ "$DO_ARD" = 1 ]; then
    skip "Arduino (no se pudo con lo anterior)"
fi

# --------------------------------------------------------------------------------------------------------------- 6. ESP32
if [ "$DO_ESP" = 1 ] && [ "$FAIL_EARLY" = 0 ]; then
    say "== 6. ESP32: esptool por RFC 2217"
    ESPT=""
    for c in esptool esptool.py; do command -v "$c" >/dev/null 2>&1 && { ESPT=$c; break; }; done
    if [ -z "$ESPT" ]; then
        skip "esptool no está instalado" "instálalo: pip install esptool (Termux: pkg install python; después pip install esptool)"
    else
        "$NX" usb bridge "$DEVID" --name chk-esp -b "$BAUD" --no-pty --rfc2217 0 --detach > "$W/esp.out" 2>&1; rc=$?
        url=$(sed -n 's/.*\(rfc2217:\/\/[0-9.]*:[0-9]*\).*/\1/p' "$W/esp.out" | head -n 1)
        if [ "$rc" -ne 0 ] || [ -z "$url" ]; then
            bad "no pude abrir el puente RFC 2217 (código $rc)" "$(short "$(cat "$W/esp.out")" 300)"
        else
            ok "el puente ofrece $url"
            timeout 90 "$ESPT" --port "$url" chip_id > "$W/esp.log" 2>&1; rc=$?
            if [ "$rc" -ne 0 ]; then timeout 90 "$ESPT" --port "$url" chip-id > "$W/esp.log" 2>&1; rc=$?; fi
            if [ "$rc" -eq 0 ]; then
                ok "esptool leyó el chip: $(grep -i -m1 -E 'chip (is|type)|Detecting chip' "$W/esp.log" | sed 's/^ *//' | head -c 120)"
            else
                bad "esptool salió con $rc" "$(short "$(tail -n 6 "$W/esp.log")" 400)"
                note "no cambies de cable ni de puerto mientras prueba; si dice «Failed to connect», mantén pulsado BOOT y repite"
            fi
            cp "$W/esp.log" "$W/esp.report.log"
        fi
        "$NX" usb stop chk-esp > /dev/null 2>&1
    fi
elif [ "$DO_ESP" = 1 ]; then
    skip "ESP32 (no se pudo con lo anterior)"
fi

# ------------------------------------------------------------------------------------------ 7. Desenchufar y volver a enchufar
if [ "$DO_UNP" = 1 ] && [ "$FAIL_EARLY" = 0 ]; then
    say "== 7. Desenchufar y volver a enchufar"
    "$NX" usb bridge "$DEVID" --name chk-unp --link "$W/unp.tty" -b "$BAUD" --detach > "$W/unp.out" 2>&1; rc=$?
    if [ "$rc" -ne 0 ]; then
        bad "no pude abrir el puente (código $rc)" "$(short "$(cat "$W/unp.out")" 300)"
    else
        st() { "$NX" usb status --json 2>/dev/null | python3 -c 'import json,sys; print(next((b.get("state", "") for b in json.load(sys.stdin) if b.get("name") == "chk-unp"), ""))' 2>/dev/null; }
        waitst() { local want=$1 secs=$2 i; for i in $(seq $((secs * 2))); do [ "$(st)" = "$want" ] && return 0; sleep 0.5; done; return 1; }
        [ "$(st)" = conectado ] && ok "el puente está conectado" || bad "el puente no está «conectado»" "estado: $(st)"
        pause "DESENCHUFA el cable del dispositivo (o el hub)." "${NEXO_CHECK_HOOK_UNPLUG:-}"
        if waitst esperando 20; then ok "al desenchufar, el puente lo nota y se queda «esperando»"; else bad "el puente no notó que lo desenchufaste en 20 s" "estado: $(st)"; fi
        [ -e "$W/unp.tty" ] && ok "…y el puerto serie sigue donde estaba" || bad "…pero el puerto serie desapareció"
        pause "Vuelve a ENCHUFARLO. Si Android pregunta otra vez, elige Aceptar." "${NEXO_CHECK_HOOK_PLUG:-}"
        if waitst conectado 60; then ok "al volver a enchufarlo, el puente lo recupera solo"; else bad "el puente no volvió a conectarse en 60 s" "estado: $(st)"; fi
        bstatus chk-unp > "$W/unp.status"
        "$NX" usb stop chk-unp > /dev/null 2>&1
    fi
elif [ "$DO_UNP" = 1 ]; then
    skip "desenchufar (no se pudo con lo anterior)"
fi

# --------------------------------------------------------------------------------------------------------------------- Informe
say
say "== Resultado: $PASS bien · $FAIL con fallos · $SKIP omitidas"
say
say "== Informe (copia desde aquí si algo falla; no lleva tu token)"
{
    cat "$W/env.txt"
    echo "opciones     dispositivo=${DEV:-auto} baud=$BAUD arduino=$DO_ARD loopback=$DO_LOOP esp32=$DO_ESP unplug=$DO_UNP"
    echo "--- dispositivo (nexo usb list --json)"
    [ -s "$W/dev.json" ] && cat "$W/dev.json" && echo
    echo "--- pruebas"
    cat "$REPORT"
    for f in ard esp unp; do
        [ -s "$W/$f.status" ] && { echo "--- puente chk-$f (nexo usb status --json)"; cat "$W/$f.status"; }
    done
    [ -s "$W/esp.report.log" ] && { echo "--- esptool (final)"; tail -n 12 "$W/esp.report.log"; }
    echo "--- app (nexo logs 25)"
    "$NX" logs 25 2>&1 | head -n 40
    for b in chk-ard chk-esp chk-unp; do
        for lf in "${NEXO_USB_DIR:-${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/nexo/usb}/$b.log"; do
            [ -s "$lf" ] && { echo "--- registro del puente $b (últimas líneas)"; tail -n 15 "$lf"; }
        done
    done
} 2>&1 | sed 's/^/  /'
[ "$FAIL" -eq 0 ] || exit 1
exit 0
