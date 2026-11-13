#!/usr/bin/env bash
# Pruebas del cliente «nexo» y del instalador contra una app Nexo FALSA (tests/fake_app.py).
# No hace falta móvil. Necesita: bash, python3, jq.    Uso:  bash tests/run_tests.sh
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
PASS=0
FAIL=0
APP_PIDS=()

# El cliente que se prueba es una COPIA ejecutable: así las pruebas no dependen del bit de ejecución del repositorio
# (en Windows, con core.filemode=false, git no lo conserva).
mkdir -p "$T/bin"
cp "$ROOT/termux/bin/nexo" "$T/bin/nexo"
chmod +x "$T/bin/nexo"
NEXO=$T/bin/nexo
CLIENT_VERSION=$(sed -n 's/^NEXO_VERSION="\(.*\)"/\1/p' "$ROOT/termux/bin/nexo")
APP_MINOR=$(sed -n 's/^APP_MINOR = \([0-9]*\).*/\1/p' "$ROOT/tests/fake_app.py")   # revisión del protocolo que habla la app falsa (= la real)

cleanup() {
    local p f
    for p in "${APP_PIDS[@]}"; do kill "$p" 2>/dev/null; done
    for f in "$T"/*.pid; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done
    pkill -f "$T/bin/nexo" 2>/dev/null
    rm -rf "$T"
}
trap cleanup EXIT

ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FALLA %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }
run() { OUT=$("$@" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err"); }
rc_is() { if [ "$RC" -eq "$2" ]; then ok "$1"; else bad "$1" "código $RC (se esperaba $2). out=[$OUT] err=[$ERR]"; fi; }
has()   { case "$OUT$ERR" in *"$2"*) ok "$1" ;; *) bad "$1" "no aparece «$2». out=[$OUT] err=[$ERR]" ;; esac; }
hasnt() { case "$OUT$ERR" in *"$2"*) bad "$1" "aparece «$2» y no debería. out=[$OUT] err=[$ERR]" ;; *) ok "$1" ;; esac; }
eq()    { if [ "$OUT" = "$2" ]; then ok "$1"; else bad "$1" "se esperaba [$2] y salió [$OUT] err=[$ERR]"; fi; }
jqok()  { if printf '%s' "$OUT" | jq -e "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1" "jq «$2» falló sobre [$OUT]"; fi; }
waitfor() { local i; for i in $(seq $(($3 * 10))); do grep -qF -- "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done; return 1; }
count() { grep -c -- "$2" "$1" 2>/dev/null; }   # count ARCHIVO PATRÓN → veces que aparece

# start_app NOMBRE [opciones…] → imprime el puerto de una app falsa nueva
start_app() {
    local name=$1 i
    shift
    python3 "$ROOT/tests/fake_app.py" --token "$TOKEN" --portfile "$T/$name.port" "$@" >/dev/null 2>&1 &
    APP_PIDS+=($!)
    echo $! > "$T/$name.pid"     # (start_app suele llamarse dentro de $(…): el array no sale de ahí, el archivo sí)
    for i in $(seq 50); do [ -s "$T/$name.port" ] && break; sleep 0.1; done
    cat "$T/$name.port" 2>/dev/null
}

for need in python3 jq; do
    command -v "$need" >/dev/null 2>&1 || { echo "Falta $need para correr las pruebas"; exit 2; }
done

echo "== Sintaxis"
for f in "$ROOT/termux/bin/nexo" "$ROOT/termux/bin/nexo-tools" "$ROOT/termux/install.sh" "$ROOT/tests/run_tests.sh" "$ROOT/tests/dbus_tests.sh" "$ROOT/tests/tools_tests.sh"; do
    if bash -n "$f" 2>"$T/err"; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")" "$(cat "$T/err")"; fi
done
for f in "$ROOT"/tests/*.py "$ROOT/termux/bin/nexo-dbus"; do
    if python3 -B -c 'import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")' "$f" 2>"$T/err"; then ok "python3 compila $(basename "$f")"; else bad "python3 compila $(basename "$f")" "$(cat "$T/err")"; fi
done
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -S error "$ROOT/termux/bin/nexo" "$ROOT/termux/install.sh" >"$T/sc" 2>&1; then ok "shellcheck (solo errores)"; else bad "shellcheck" "$(head -20 "$T/sc")"; fi
fi

echo "== Contrato: la app Android, la app falsa y docs/PROTOCOLO.md dicen lo mismo"
python3 -I "$ROOT/tests/check_contract.py" "$ROOT" >"$T/contract.out" 2>&1; CONTRACT_RC=$?
while IFS= read -r line; do
    case $line in
        "OK "*) ok "${line#OK }" ;;
        "FALLA "*) bad "${line#FALLA }" ;;
        *) printf '        %s\n' "$line" ;;
    esac
done < "$T/contract.out"
# si el comprobador se cae (no solo si una comprobación falla), eso también es un fallo
if [ "$CONTRACT_RC" -ne 0 ] && ! grep -q '^FALLA ' "$T/contract.out"; then bad "check_contract.py terminó con código $CONTRACT_RC sin llegar al final"; fi

# ---------------------------------------------------------------- app falsa
TOKEN=$(printf 'a1b2c3d4%.0s' 1 2 3 4 5 6)
PORT=$(start_app main --record "$T/rec" --reqlog "$T/main.req")
[ -n "$PORT" ] || { echo "No arrancó la app falsa"; exit 1; }

export HOME=$T/home
mkdir -p "$HOME"
unset XDG_CONFIG_HOME XDG_CACHE_HOME PREFIX NEXO_TOKEN NEXO_CONFIG NEXO_TRANSPORT NEXO_NO_JQ NEXO_ICONS NEXO_ALLOW_RAW NEXO_TIMEOUT NEXO_BIN
export NEXO_PORT=$PORT
export NEXO_CACHE_TTL=0     # sin caché salvo en las pruebas que la quieren

# Para iterar rápido: NEXO_TESTS_ONLY=dbus bash tests/run_tests.sh  (solo nexo-dbus), o =tools (solo nexo-tools)
if [ "${NEXO_TESTS_ONLY:-}" = dbus ] || [ "${NEXO_TESTS_ONLY:-}" = tools ]; then
    . "$ROOT/tests/${NEXO_TESTS_ONLY}_tests.sh"
    echo
    echo "Resultado: $PASS bien, $FAIL con fallos"
    [ "$FAIL" -eq 0 ]
    exit
fi

echo "== Enlace y token"
run "$NEXO" wifi status;                 rc_is "sin token falla con código 11" 11
has "…y explica cómo enlazar" "nexo pair"
run "$NEXO" pair "$(printf 'ff%.0s' $(seq 24))"; rc_is "un token equivocado se rechaza (11)" 11
[ ! -e "$HOME/.config/nexo/config" ] && ok "no guarda un token rechazado" || bad "no guarda un token rechazado"
run "$NEXO" pair "$TOKEN";               rc_is "pair con el token bueno" 0
has "…y confirma que la app responde" "todo listo"
[ "$(stat -c %a "$HOME/.config/nexo/config")" = 600 ] && ok "la configuración queda con modo 600" || bad "modo de la configuración"
run "$NEXO" doctor;                      rc_is "doctor" 0
has "doctor ve el enlace" "enlace     OK"
has "doctor muestra la versión de la app" "app        $CLIENT_VERSION · protocolo 1.$APP_MINOR"
has "doctor avisa del acceso a notificaciones" "acceso a notificaciones: sí"
hasnt "doctor no enseña el token" "$TOKEN"
run "$NEXO" unpair;                      rc_is "unpair" 0
[ ! -e "$HOME/.config/nexo/config" ] && ok "unpair borra el archivo" || bad "unpair borra el archivo"
printf '%s\n' "$TOKEN" | "$NEXO" pair --token-stdin >"$T/o" 2>&1; RC=$?; OUT=$(cat "$T/o"); ERR=""
rc_is "pair --token-stdin (el token no pasa por la línea de comandos)" 0
[ "$(stat -c %a "$HOME/.config/nexo/config")" = 600 ] && ok "…y queda con modo 600" || bad "modo tras --token-stdin"
run "$NEXO" wifi status --short;         eq "…y el enlace funciona" "MiCasa"
printf 'zz\n' | "$NEXO" pair --token-stdin >"$T/o" 2>&1; RC=$?; OUT=$(cat "$T/o"); ERR=""
rc_is "--token-stdin con basura → uso (2)" 2
printf '%s\n' "$(printf 'ee%.0s' $(seq 24))" | "$NEXO" pair --token-stdin >"$T/o" 2>&1; RC=$?; OUT=$(cat "$T/o"); ERR=""
rc_is "--token-stdin con token equivocado → 11" 11
run "$NEXO" wifi status --short;         eq "…y no pisó el enlace bueno" "MiCasa"
run "$NEXO" pair </dev/null;             rc_is "pair sin token y sin terminal → uso (2)" 2
run "$NEXO" rekey "$TOKEN";              rc_is "rekey con el token bueno" 0
run "$NEXO" rekey "$(printf 'dd%.0s' $(seq 24))"; rc_is "rekey con un token malo se rechaza (11)" 11
run "$NEXO" wifi status --short;         eq "…y el enlace anterior sigue funcionando" "MiCasa"

echo "== WiFi"
run "$NEXO" wifi status;                 has "wifi status (texto)" "WiFi: conectado a MiCasa · -55 dBm · 5GHz · 192.168.1.23"
run "$NEXO" wifi status --json;          jqok "wifi status --json" '.enabled == true and .ssid == "MiCasa"'
jqok "…con puerta de enlace, máscara, prefijo y DNS" '.gateway == "192.168.1.1" and .netmask == "255.255.255.0" and .prefix == 24 and .dns == ["192.168.1.1","8.8.8.8"]'
run "$NEXO" wifi status --short;         eq "wifi status --short" "MiCasa"
run "$NEXO" wifi status --waybar;        jqok "wifi status --waybar" '.class == "connected" and .percentage == 75'
run "$NEXO" wifi status --env
( eval "$OUT"; [ "$NEXO_WIFI_SSID" = MiCasa ] && [ "$NEXO_WIFI_ENABLED" = 1 ] && [ "$NEXO_WIFI_RSSI" = -55 ] && [ "$NEXO_WIFI_GATEWAY" = 192.168.1.1 ] && [ "$NEXO_WIFI_PREFIX" = 24 ] ) && ok "wifi status --env (eval)" || bad "wifi status --env" "$OUT"
run "$NEXO" wifi off;                    has "wifi off" "WiFi: apagado"
run "$NEXO" wifi status --short;         eq "tras apagar: --short" "apagado"
run "$NEXO" wifi on;                     has "wifi on" "conectado a MiCasa"
run "$NEXO" wifi toggle;                 has "wifi toggle apaga" "WiFi: apagado"
run "$NEXO" wifi toggle;                 has "wifi toggle enciende" "conectado a MiCasa"
run "$NEXO" wifi scan;                   has "wifi scan: nombre con comillas y acentos" 'Café "Luz"'
has "wifi scan: la / no sale escapada" "Wi-Fi/Invitados"
: > "$T/main.req"
run "$NEXO" wifi scan --cached;          rc_is "wifi scan --cached" 0
grep -q '"fresh":false' "$T/main.req" && ok "…pide a la app que no escanee de nuevo" || bad "scan --cached no mandó fresh:false" "$(cat "$T/main.req")"
: > "$T/main.req"
run "$NEXO" wifi scan --rescan;          rc_is "wifi scan --rescan" 0
grep -q '"fresh":true' "$T/main.req" && ok "…y --rescan fuerza el escaneo" || bad "scan --rescan no mandó fresh:true"
run "$NEXO" wifi scan --csv
eq "wifi scan --csv (4 columnas: ssid,signal,secure,band)" $'ssid,signal,secure,band\n"MiCasa",-52,true,"5GHz"\n"Café ""Luz""",-70,true,"2.4GHz"\n"Wi-Fi/Invitados",-81,false,"2.4GHz"'
run "$NEXO" wifi scan --json;            jqok "wifi scan --json" '.networks | length == 3'
run "$NEXO" wifi scan --raro;            rc_is "wifi scan con una opción rara → uso (2)" 2
run "$NEXO" wifi saved
has "wifi saved: lista las redes" "Oficina"
has "…marca la actual" "◀ conectada"
has "…y las ocultas" "sí"
python3 - "$OUT" <<'PY' && ok "wifi saved: las columnas quedan alineadas con tildes y comillas" || bad "alineación de wifi saved" "$OUT"
import sys
lines = sys.argv[1].split("\n")[1:]
cols = [l.index("WPA2") for l in lines if "WPA2" in l]
sys.exit(0 if len(set(cols)) == 1 and len(cols) == 4 else 1)
PY
run "$NEXO" wifi saved --csv
has "wifi saved --csv" 'ssid,security,hidden,current'
has "…con la red actual marcada" '"MiCasa","WPA2",false,true'
run "$NEXO" wifi saved --json;           jqok "wifi saved --json" '.networks | length == 4 and (.[0].network_id == 0)'
run "$NEXO" wifi forget Oficina;         rc_is "wifi forget" 0
has "…lo confirma" "red «Oficina» olvidada"
run "$NEXO" wifi saved --short;          hasnt "…y ya no está en la lista" "Oficina"
run "$NEXO" wifi forget Oficina;         rc_is "olvidar una red que no existe → error (1)" 1
run "$NEXO" wifi forget --id 5;          rc_is "wifi forget --id" 0
run "$NEXO" wifi forget;                 rc_is "wifi forget sin nombre → uso (2)" 2
run "$NEXO" wifi forget --id abc;        rc_is "wifi forget --id con basura → uso (2)" 2
run "$NEXO" wifi reconnect;              rc_is "wifi reconnect" 0
has "…lo confirma" "WiFi: reconectado"
run "$NEXO" wifi hotspot on;             rc_is "wifi hotspot explica por qué no existe (1)" 1
has "…y apunta a LIMITACIONES" "LIMITACIONES"
SSID_RARO='Red "rara" \ con ñ'
PASS_RARA=$'clave con "comillas", \\ y\nsalto de línea'
run "$NEXO" wifi connect "$SSID_RARO" "$PASS_RARA"; rc_is "wifi connect con caracteres raros" 0
LAST=$(tail -n 1 "$T/rec")
if printf '%s' "$LAST" | jq -e --arg s "$SSID_RARO" --arg p "$PASS_RARA" '.ssid == $s and .password == $p' >/dev/null; then
    ok "…la app recibe SSID y clave exactos"
else
    bad "SSID/clave exactos" "$LAST"
fi
printf 'secreta\n' | "$NEXO" wifi connect Casa2 --pass-stdin >/dev/null 2>&1
[ "$(tail -n 1 "$T/rec" | jq -r .password)" = secreta ] && ok "wifi connect --pass-stdin" || bad "wifi connect --pass-stdin"
: > "$T/main.req"
run "$NEXO" wifi connect Oculta2 clave --hidden; rc_is "wifi connect --hidden" 0
grep -q '"hidden":true' "$T/main.req" && ok "…manda hidden:true" || bad "connect --hidden no mandó hidden:true" "$(cat "$T/main.req")"
run "$NEXO" wifi connect Mala;           rc_is "conexión no confirmada → código 3" 3
run "$NEXO" wifi connect MiCasa clave12345; rc_is "wifi connect normal (y vuelve a MiCasa)" 0
has "…y lo confirma" "WiFi: conectado a MiCasa"
run "$NEXO" wifi nada;                   rc_is "subcomando desconocido → uso (2)" 2

echo "== Bluetooth"
run "$NEXO" bt status;                   has "bt status" "Bluetooth: encendido · con dispositivos conectados · 2 emparejados"
run "$NEXO" bt paired;                   has "bt paired: nombre con ñ" "Auriculares ñandú"
has "bt paired: dispositivo sin nombre" "(sin nombre)"
run "$NEXO" bt paired --csv;             has "bt paired --csv" 'Auriculares ñandú","AA:BB:CC:DD:EE:01",true,"a2dp;headset"'
run "$NEXO" bt connect AA:BB:CC:DD:EE:01; rc_is "bt connect → hace falta un toque (3)" 3
has "…y dice por qué" "Android no permite"
run "$NEXO" bt info aa:bb:cc:dd:ee:01;   rc_is "bt info (acepta minúsculas)" 0
has "…con el alias" "Auriculares ñandú  (AA:BB:CC:DD:EE:01)"
has "…los perfiles" "a2dp, headset"
has "…y la batería" "batería    80 %"
run "$NEXO" bt info AA:BB:CC:DD:EE:01 --json; jqok "bt info --json" '.bond_state == "bonded" and .battery == 80 and (.uuids | length) == 1'
run "$NEXO" bt info AA:BB:CC:DD:EE:02;   has "bt info de uno sin batería" "no informada"
run "$NEXO" bt info xx:yy;               rc_is "dirección inválida → uso (2)" 2
run "$NEXO" bt info AA:BB:CC:DD:EE:99;   rc_is "bt info de uno no emparejado → error (1)" 1
run "$NEXO" bt rename AA:BB:CC:DD:EE:01 Mis buds nuevos; rc_is "bt rename (el nombre puede llevar espacios)" 0
has "…lo confirma" "ahora se llama «Mis buds nuevos»"
run "$NEXO" bt info AA:BB:CC:DD:EE:01;   has "…y bt info lo refleja" "Mis buds nuevos  (AA:BB:CC:DD:EE:01)"
run "$NEXO" bt rename AA:BB:CC:DD:EE:01; has "bt rename sin nombre quita el alias" "ya no tiene alias"
run "$NEXO" bt forget AA:BB:CC:DD:EE:02; rc_is "bt forget bloqueado por el sistema → hace falta un toque (3)" 3
run "$NEXO" bt forget AA:BB:CC:DD:EE:99; rc_is "bt forget de uno no emparejado → error (1)" 1
run "$NEXO" bt forget AA:BB:CC:DD:EE:01; rc_is "bt forget" 0
has "…lo confirma" "AA:BB:CC:DD:EE:01 desemparejado"
run "$NEXO" bt status;                   has "…y baja el contador de emparejados" "1 emparejados"
run "$NEXO" bt off;                      has "bt off" "Bluetooth: apagado"
run "$NEXO" bt toggle;                   has "bt toggle enciende" "Bluetooth: encendido"
run "$NEXO" bt toggle;                   has "bt toggle apaga" "Bluetooth: apagado"
run "$NEXO" bt on;                       has "bt on" "encendido"
run "$NEXO" bt rename;                   rc_is "bt rename sin dirección → uso (2)" 2

echo "== Audio"
run "$NEXO" audio status;                has "audio status" "Volumen: 60% (9/15) · Auriculares ñandú"
run "$NEXO" audio status --json;         jqok "audio status --json" '.volume == 60 and .level == 9 and .output.type == "bluetooth_a2dp"'
run "$NEXO" audio volume 30;             has "audio volume 30" "Volumen: 33% (5/15)"
run "$NEXO" audio volume 40%;            has "audio volume 40%" "Volumen: 40% (6/15)"
run "$NEXO" audio volume +20;            has "audio volume +20 (puntos de porcentaje)" "Volumen: 60%"
run "$NEXO" audio volume -20;            has "audio volume -20" "Volumen: 40%"
run "$NEXO" audio volume +1;             has "audio volume +1 siempre mueve al menos un escalón" "Volumen: 47%"
run "$NEXO" audio volume mute;           has "audio volume mute" "silenciado"
run "$NEXO" audio status --short;        eq "…y --short lo dice" "mute"
run "$NEXO" audio volume unmute;         has "audio volume unmute" "Volumen: 47%"
run "$NEXO" audio volume toggle;         has "audio volume toggle silencia" "silenciado"
run "$NEXO" audio toggle;                has "audio toggle (atajo) quita el silencio" "Volumen: 47%"
run "$NEXO" volume 100;                  has "nexo volume (atajo) 100" "Volumen: 100% (15/15)"
run "$NEXO" audio volume 150;            rc_is "volumen fuera de rango → uso (2)" 2
run "$NEXO" audio volume abc;            rc_is "volumen con basura → uso (2)" 2
run "$NEXO" audio volume +;              rc_is "«+» solo → uso (2)" 2
run "$NEXO" audio volume 60;             rc_is "audio volume 60 (restablece)" 0
run "$NEXO" audio outputs;               has "audio outputs" "bluetooth_a2dp"
has "…marca la salida activa" "◀ suena aquí"
run "$NEXO" audio outputs --csv;         has "audio outputs --csv" '7,"bluetooth_a2dp","Auriculares ñandú","AA:BB:CC:DD:EE:01",true'
run "$NEXO" audio outputs --json;        jqok "audio outputs --json" '.outputs | length == 3'
run "$NEXO" audio switch bluetooth;      rc_is "audio switch (alias bluetooth) → hace falta un toque (3)" 3
has "…y explica por qué" "Android no deja"
run "$NEXO" audio switch speaker;        rc_is "audio switch por tipo" 3
run "$NEXO" audio switch 9;              rc_is "audio switch por id" 3
run "$NEXO" audio switch usb;            rc_is "audio switch (alias usb)" 3
run "$NEXO" audio switch Altavoz;        rc_is "audio switch por parte del nombre" 3
run "$NEXO" audio switch 99;             rc_is "audio switch de una salida que no existe → error (1)" 1
run "$NEXO" audio switch Nada;           rc_is "audio switch por un nombre que no existe → error (1)" 1
run "$NEXO" audio switch;                rc_is "audio switch sin argumento → uso (2)" 2
run "$NEXO" audio cosa;                  rc_is "audio: subcomando desconocido → uso (2)" 2

echo "== Música (media)"
run "$NEXO" media status;                has "media status" "Reproduciendo: Canción ñandú — Artista (Álbum) · Reproductor falso"
run "$NEXO" media status --json;         jqok "media status --json" '.state == "playing" and .can_seek and .track_id == "t1"'
run "$NEXO" media pause;                 has "media pause" "Media: en pausa"
run "$NEXO" media status --short;        eq "…y status --short" "Canción ñandú — Artista"
run "$NEXO" media play;                  has "media play" "Media: reproduciendo"
run "$NEXO" media playpause;             has "media playpause pausa" "Media: en pausa"
run "$NEXO" media playpause;             has "media playpause reanuda" "Media: reproduciendo"
run "$NEXO" media next;                  rc_is "media next" 0
run "$NEXO" media status --short;        eq "…cambia la canción" "Otra canción — Otro artista"
run "$NEXO" media prev;                  rc_is "media prev" 0
run "$NEXO" media status --short;        eq "…y vuelve" "Canción ñandú — Artista"
run "$NEXO" media seek 1:30 --json;      jqok "media seek 1:30 (posición absoluta)" '.position_ms == 90000'
run "$NEXO" media seek +10s --json;      jqok "media seek +10s" '.position_ms >= 100000 and .position_ms < 105000'
run "$NEXO" media seek -10s --json;      jqok "media seek -10s" '.position_ms >= 90000 and .position_ms < 95000'
run "$NEXO" media seek 45;               has "media seek 45 (segundos)" "posición 45 s"
run "$NEXO" media seek 1500ms --json;    jqok "media seek 1500ms" '.position_ms == 1500'
run "$NEXO" media seek abc;              rc_is "media seek con basura → uso (2)" 2
run "$NEXO" media seek;                  rc_is "media seek sin argumento → uso (2)" 2
run "$NEXO" media art "$T/caratula.jpg"; rc_is "media art" 0
eq "…devuelve la ruta" "$T/caratula.jpg"
[ "$(head -c 2 "$T/caratula.jpg" | od -An -tx1 | tr -d ' \n')" = ffd8 ] && ok "…y el archivo es un JPEG" || bad "carátula no es un JPEG"
run "$NEXO" media stop;                  has "media stop" "Media: detenido"
run "$NEXO" media status --waybar;       jqok "…y el estado sale en waybar" '.class == "stopped"'
run "$NEXO" media baila;                 rc_is "media: subcomando desconocido → uso (2)" 2
NL=$(start_app nolistener --no-listener)
NEXO_PORT=$NL run "$NEXO" media status; has "sin acceso a notificaciones: media status lo explica" "falta el acceso a notificaciones"
NEXO_PORT=$NL run "$NEXO" media play;    rc_is "…y media play pide un toque (3)" 3
NEXO_PORT=$NL run "$NEXO" doctor;        has "doctor avisa de que falta el acceso a notificaciones" "acceso a notificaciones: NO"
NS=$(start_app nosession --no-session)
NEXO_PORT=$NS run "$NEXO" media status;  has "sin nada sonando" "nada en reproducción"
NEXO_PORT=$NS run "$NEXO" media play;    rc_is "…media play dice que no hay sesión (1)" 1
NEXO_PORT=$NS run "$NEXO" media status --starship; eq "…y starship no muestra nada" ""
NEXO_PORT=$NS run "$NEXO" status;        has "status también funciona sin sesión" "Media: nada en reproducción"

echo "== Formatos para barras y prompts"
run "$NEXO" wifi status --polybar
has "polybar: color del estado" '%{F#7BD88F}'
has "polybar: clic para reconectar" '%{A1:'
has "polybar: texto" 'MiCasa'
has "polybar: se cierra bien" '%{A}%{F-}'
run "$NEXO" wifi status --i3status;      jqok "i3status: name, full_text y color" '.name == "wifi" and (.full_text | endswith("MiCasa")) and .color == "#7BD88F" and .short_text == "MiCasa"'
run "$NEXO" wifi status --qml;           jqok "qml: text, icon, active y tooltip" '.text == "MiCasa" and .icon == "network-wireless-signal-good-symbolic" and .active == true and (.tooltip | contains("-55")) and .percentage == 75'
run "$NEXO" wifi status --dunst;         has "dunst: texto con icono" "WiFi: conectado a MiCasa"
run "$NEXO" wifi status --tmux;          has "tmux: texto corto" "MiCasa"
run "$NEXO" wifi status --starship;      has "starship: texto corto" "MiCasa"
run "$NEXO" wifi status --csv
eq "csv de status" $'connected,ssid,signal,band,ip\ntrue,"MiCasa",-55,"5GHz","192.168.1.23"'
run "$NEXO" wifi off >/dev/null 2>&1
run "$NEXO" wifi status --starship;      eq "starship no muestra nada con el WiFi apagado" ""
run "$NEXO" wifi status --waybar;        jqok "waybar con el WiFi apagado" '.class == "off" and .text == "off"'
run "$NEXO" wifi status --i3status;      jqok "i3status con el WiFi apagado" '.color == "#9A9FA8"'
run "$NEXO" wifi on >/dev/null 2>&1
run "$NEXO" audio status --polybar
has "polybar de audio: el % se escapa (%%)" '60%%'
has "…y trae clics de volumen" '%{A4:'
run "$NEXO" audio volume 60 >/dev/null 2>&1
run "$NEXO" audio volume mute --qml;     jqok "qml de audio silenciado" '.state == "muted" and .active == false and .icon == "audio-volume-muted-symbolic"'
run "$NEXO" audio volume unmute >/dev/null 2>&1
run "$NEXO" media status --polybar;      has "polybar de media: clic de play/pausa" 'media playpause'
run "$NEXO" media play --json >/dev/null 2>&1
run "$NEXO" media status --i3status;     jqok "i3status de media" '.name == "media" and (.full_text | contains("Canción ñandú — Artista"))'
run "$NEXO" bt status --qml;             jqok "qml de bluetooth" '.state == "connected" and .icon == "bluetooth-active-symbolic"'
run "$NEXO" bt status --polybar;         has "polybar de bluetooth: clic para alternar" 'bt toggle'
run "$NEXO" status --tmux;               has "status --tmux junta todo en una línea" "MiCasa"
case $OUT in *$'\n'*) bad "status --tmux ocupa una sola línea" "$OUT" ;; *) ok "status --tmux ocupa una sola línea" ;; esac
run "$NEXO" status --waybar
[ "$(printf '%s\n' "$OUT" | wc -l)" -eq 4 ] && ok "status --waybar: un JSON por tema" || bad "status --waybar" "$OUT"
NEXO_ICONS=none run "$NEXO" wifi status --dunst
eq "NEXO_ICONS=none quita el icono" "WiFi: conectado a MiCasa · -55 dBm · 5GHz · 192.168.1.23"
run "$NEXO" wifi status --dunst
case $OUT in *$'\357\207\253'*) ok "con iconos: el icono Nerd Font va en UTF-8" ;; *) bad "falta el icono Nerd Font" "$OUT" ;; esac
run "$NEXO" wifi status --env;           has "wifi status --env" "NEXO_WIFI_SSID='MiCasa'"
run "$NEXO" audio status --env;          has "audio status --env" "NEXO_AUDIO_VOLUME=60"
run "$NEXO" media status --env;          has "media status --env" "NEXO_MEDIA_STATE='playing'"

echo "== Las barras nunca fallan (y la caché)"
rm -rf "$HOME/.cache"
NEXO_PORT=1 run "$NEXO" wifi status --waybar;  rc_is "waybar con la app apagada: código 0" 0
jqok "…y muestra «offline»" '.class == "offline" and .text == "offline"'
NEXO_PORT=1 run "$NEXO" media status --polybar; rc_is "polybar con la app apagada: código 0" 0
has "…y lo dice en rojo" '%{F#F28B82}'
NEXO_PORT=1 run "$NEXO" status --tmux;         rc_is "status --tmux con la app apagada: código 0" 0
NEXO_PORT=1 run "$NEXO" wifi status --short;   rc_is "sin barra, el fallo SÍ se avisa (10)" 10
NEXO_TOKEN= NEXO_CONFIG=/nonexistent run env -u NEXO_TOKEN HOME="$T/vacio" NEXO_PORT=$PORT "$NEXO" wifi status --waybar
rc_is "sin token, una barra tampoco falla" 0
has "…y explica que falta el token" "sin token"
rm -rf "$HOME/.cache"
NEXO_CACHE_TTL=0 run "$NEXO" wifi status --waybar; rc_is "una consulta buena rellena la caché" 0
[ -s "$HOME/.cache/nexo/last.json" ] && ok "la caché está en ~/.cache/nexo/last.json" || bad "no hay caché"
[ "$(stat -c %a "$HOME/.cache/nexo/last.json")" = 600 ] && ok "…con modo 600" || bad "modo de la caché" "$(stat -c %a "$HOME/.cache/nexo/last.json")"
jq -e '.wifi.data.ssid == "MiCasa" and (.wifi.t | type == "number")' "$HOME/.cache/nexo/last.json" >/dev/null && ok "…con el último estado y la hora" || bad "contenido de la caché" "$(cat "$HOME/.cache/nexo/last.json")"
NEXO_PORT=1 NEXO_CACHE_TTL=0 run "$NEXO" wifi status --waybar
jqok "app apagada: la barra enseña el último dato conocido" '.class == "connected" and (.tooltip | contains("último dato"))'
NEXO_PORT=1 NEXO_CACHE_TTL=0 run "$NEXO" wifi status --waybar
jqok "…y sigue enseñándolo sin volver a insistir" '.class == "connected"'
rm -rf "$HOME/.cache"
CP=$(start_app cached --reqlog "$T/cached.req")
NEXO_PORT=$CP NEXO_CACHE_TTL=30 run "$NEXO" audio status --waybar; rc_is "primera barra con caché de 30 s" 0
NEXO_PORT=$CP NEXO_CACHE_TTL=30 run "$NEXO" audio status --waybar; rc_is "segunda barra" 0
[ "$(count "$T/cached.req" '"audio.status"')" -eq 1 ] && ok "la segunda se sirve de la caché (la app solo recibió una consulta)" || bad "la caché no evitó la consulta" "$(cat "$T/cached.req")"
NEXO_PORT=$CP run "$NEXO" audio status --waybar --cache 30; rc_is "--cache SEGUNDOS" 0
[ "$(count "$T/cached.req" '"audio.status"')" -eq 1 ] && ok "--cache 30 también usa la caché" || bad "--cache no evitó la consulta"
NEXO_PORT=$CP NEXO_CACHE_TTL=0 run "$NEXO" audio status --waybar
[ "$(count "$T/cached.req" '"audio.status"')" -eq 2 ] && ok "con TTL 0 no se usa la caché" || bad "TTL 0 usó la caché"
NEXO_PORT=$CP run "$NEXO" status --cache abc; rc_is "--cache con basura → uso (2)" 2
rm -rf "$HOME/.cache"

echo "== Reintento, app congelada y app vieja"
D1=$(start_app drop1 --drop-first 1 --reqlog "$T/drop1.req")
NEXO_PORT=$D1 run "$NEXO" wifi status --short; eq "si la app no contesta el hello, reintenta una vez (0,5 s después)" "MiCasa"
D2=$(start_app drop2 --drop-first 2)
NEXO_PORT=$D2 run "$NEXO" wifi status --short; rc_is "dos fallos seguidos → 12" 12
has "…y explica lo de Xiaomi/HyperOS" "HyperOS"
has "…y propone nexo start" "nexo start"
H1=$(start_app hello1 --drop-after-hello 1 --reqlog "$T/hello1.req")
NEXO_PORT=$H1 run "$NEXO" wifi status --short; eq "si se pierde la respuesta de un comando que se puede repetir, reintenta" "MiCasa"
[ "$(count "$T/hello1.req" '"wifi.status"')" -eq 2 ] && ok "…(la app vio la consulta dos veces)" || bad "reintento de wifi.status" "$(cat "$T/hello1.req")"
H2=$(start_app hello2 --drop-after-hello 1 --reqlog "$T/hello2.req")
NEXO_PORT=$H2 run "$NEXO" media next;    rc_is "si se pierde la respuesta de «media next» NO se repite (12)" 12
[ "$(count "$T/hello2.req" '"media.next"')" -eq 1 ] && ok "…la app recibió «next» una sola vez" || bad "media next se repitió" "$(cat "$T/hello2.req")"
H3=$(start_app hello3 --drop-after-hello 1 --reqlog "$T/hello3.req")
NEXO_PORT=$H3 run "$NEXO" audio volume +5; rc_is "el volumen relativo (+5) tampoco se repite" 12
[ "$(count "$T/hello3.req" '"audio.volume"')" -eq 1 ] && ok "…solo un intento" || bad "audio volume +5 se repitió"
H4=$(start_app hello4 --drop-after-hello 1 --reqlog "$T/hello4.req")
NEXO_PORT=$H4 run "$NEXO" audio volume 30; rc_is "el volumen absoluto sí se repite" 0
FZ=$(start_app freeze --freeze)
SECONDS=0
NEXO_PORT=$FZ NEXO_TIMEOUT=1 run timeout 20 "$NEXO" wifi status --short; rc_is "app congelada con NEXO_TIMEOUT=1 → 12" 12
[ "$SECONDS" -le 6 ] && ok "…y termina pronto (${SECONDS} s)" || bad "tardó demasiado con la app congelada (${SECONDS} s)"
run timeout 20 "$NEXO" --port "$FZ" --timeout 1 ping; rc_is "--timeout 1 también" 12
rm -rf "$HOME/.cache"
NEXO_PORT=$FZ run timeout 20 "$NEXO" wifi status --waybar --timeout 1; rc_is "una barra con la app congelada no falla (0)" 0
jqok "…y muestra «offline»" '.class == "offline"'
OLD=$(start_app old --old)
NEXO_PORT=$OLD run "$NEXO" status;       rc_is "con una app 0.1.x, status funciona (0)" 0
has "…con WiFi" "WiFi: conectado a MiCasa"
hasnt "…sin audio (la app vieja no lo tiene)" "Volumen"
NEXO_PORT=$OLD run "$NEXO" audio status; rc_is "audio con una app vieja → error (1)" 1
has "…y explica que la app es antigua" "más antigua"
NEXO_PORT=$OLD run "$NEXO" media status --short; rc_is "media con una app vieja → error (1)" 1
NEXO_PORT=$OLD run "$NEXO" audio status --waybar; rc_is "…pero una barra no falla (0)" 0
jqok "…y dice que no está disponible" '.class == "unavailable"'
NEXO_PORT=$OLD run "$NEXO" version --check; rc_is "version --check con una app vieja → 1" 1
has "…dice qué falta" "más antigua"
has "…y muestra la versión de la app" "app        0.1.0 (protocolo 1.1)"
NEXO_PORT=$OLD run "$NEXO" wifi status --short; eq "los comandos viejos siguen funcionando" "MiCasa"
NEXO_PORT=$OLD run "$NEXO" status --json; jqok "status --json con app vieja solo trae wifi y bt" 'keys == ["bt","wifi"]'

echo "== Versión, configuración, registro y raw"
run "$NEXO" version;                     eq "version" "nexo $CLIENT_VERSION"
run "$NEXO" --version;                   eq "--version" "nexo $CLIENT_VERSION"
run "$NEXO" version --check;             rc_is "version --check con la app nueva" 0
has "…compatibles" "compatibles"
has "…y enseña las dos versiones" "cliente    nexo $CLIENT_VERSION"
run "$NEXO" logs;                        rc_is "logs" 0
has "logs: lo que anotó la app" "Cliente conectado: nexo-cli/$CLIENT_VERSION"
run "$NEXO" logs 3 --json;               jqok "logs N --json" '.count <= 3 and (.lines | type == "array")'
run "$NEXO" logs abc;                    rc_is "logs con basura → uso (2)" 2
LK=$(start_app leak --leak-token)
NEXO_PORT=$LK run "$NEXO" logs;          hasnt "logs nunca enseña el token (aunque la app lo filtrara)" "$TOKEN"
has "…lo tapa" "<token>"
run "$NEXO" config list;                 has "config list" "NEXO_PORT=$PORT"
hasnt "config list no enseña el token" "$TOKEN"
has "…lo oculta" "NEXO_TOKEN=********"
run "$NEXO" config get NEXO_TOKEN;       eq "config get NEXO_TOKEN lo oculta" "********"
run "$NEXO" config get NEXO_TOKEN --show; eq "…salvo con --show" "$TOKEN"
run "$NEXO" config set NEXO_TIMEOUT 5;   rc_is "config set NEXO_TIMEOUT" 0
grep -q '^NEXO_TIMEOUT=5$' "$HOME/.config/nexo/config" && ok "…se guarda en el archivo" || bad "config set no escribió" "$(cat "$HOME/.config/nexo/config")"
grep -q "^NEXO_TOKEN=$TOKEN$" "$HOME/.config/nexo/config" && ok "…sin tocar el token" || bad "config set rompió el token"
[ "$(stat -c %a "$HOME/.config/nexo/config")" = 600 ] && ok "…ni el modo 600" || bad "config set cambió el modo"
run "$NEXO" config get NEXO_TIMEOUT;     eq "config get NEXO_TIMEOUT" "5"
run "$NEXO" config set NEXO_ICONS none;  rc_is "config set NEXO_ICONS none" 0
run "$NEXO" wifi status --dunst;         eq "…y se aplica: sin iconos" "WiFi: conectado a MiCasa · -55 dBm · 5GHz · 192.168.1.23"
run "$NEXO" config set NEXO_ICONS emoji; rc_is "config set con un valor raro → uso (2)" 2
run "$NEXO" config set NEXO_TOKEN abc;   rc_is "config set NEXO_TOKEN se niega (usa pair) (2)" 2
run "$NEXO" config set NEXO_PORT abc;    rc_is "config set NEXO_PORT con basura → uso (2)" 2
run "$NEXO" config set COSA 1;           rc_is "config set de una clave que no existe → uso (2)" 2
run "$NEXO" config set NEXO_ICONS nerd >/dev/null 2>&1
run "$NEXO" config set NEXO_TIMEOUT 8 >/dev/null 2>&1
run "$NEXO" config path;                 eq "config path" "$HOME/.config/nexo/config"
run "$NEXO" raw '{"cmd":"nope"}';        rc_is "raw sin NEXO_ALLOW_RAW → uso (2)" 2
has "…y explica cómo activarlo" "NEXO_ALLOW_RAW=1"
NEXO_ALLOW_RAW=1 run "$NEXO" raw '{"cmd":"nope"}'; has "raw con NEXO_ALLOW_RAW=1: comando desconocido" "unknown_command"
NEXO_ALLOW_RAW=1 run "$NEXO" raw '{"cmd":"wifi.status"}'; has "raw con NEXO_ALLOW_RAW=1: respuesta cruda" '"ok":true'
NEXO_ALLOW_RAW=1 run "$NEXO" raw;        rc_is "raw sin JSON → uso (2)" 2
run "$NEXO" ping;                        has "ping" "Nexo responde"
run "$NEXO" help;                        has "help menciona los formatos de barras" "--polybar"
run "$NEXO" cosa;                        rc_is "comando desconocido → uso (2)" 2

echo "== Estado general"
run "$NEXO" status;                      has "status junta WiFi y Bluetooth" "Bluetooth: encendido"
has "…y el audio" "Volumen: 60%"
has "…y la música" "Reproduciendo:"
run "$NEXO" status --json;               jqok "status --json" '.wifi.enabled and .bt.enabled and .audio.volume == 60 and .media.state == "playing"'
run "$NEXO" status --short;              eq "status --short (sin la música)" "MiCasa · conectado · 60%"
run "$NEXO" status --env;                has "status --env junta los cuatro" "NEXO_MEDIA_STATE"
has "…y el audio" "NEXO_AUDIO_VOLUME"

echo "== Transportes y sin jq"
NEXO_TRANSPORT=python run "$NEXO" wifi status --short; eq "transporte python3" "MiCasa"
NEXO_TRANSPORT=python run "$NEXO" status --json; jqok "transporte python3 con varias peticiones (status)" '.wifi.ssid == "MiCasa" and .audio.volume == 60'
NEXO_NO_JQ=1 run "$NEXO" wifi status;    has "sin jq: JSON crudo" '"ssid":"MiCasa"'
has "sin jq: avisa" "instala jq"
NEXO_NO_JQ=1 run "$NEXO" status;         has "sin jq: status también" '"volume":60'
NEXO_NO_JQ=1 run "$NEXO" wifi status --waybar; rc_is "sin jq: una barra no falla (0)" 0

echo "== Eventos en vivo (watch)"
"$NEXO" watch --pretty >"$T/watch.out" 2>&1 &
waitfor "$T/watch.out" "wifi  → conectado a MiCasa" 5 && ok "watch: llega el estado inicial" || bad "watch: estado inicial" "$(cat "$T/watch.out")"
waitfor "$T/watch.out" "audio → volumen 60%" 5 && ok "watch: también el audio" || bad "watch: audio inicial" "$(cat "$T/watch.out")"
waitfor "$T/watch.out" "media → playing: Canción ñandú — Artista" 5 && ok "watch: y la música" || bad "watch: media inicial" "$(cat "$T/watch.out")"
"$NEXO" wifi off >/dev/null 2>&1
waitfor "$T/watch.out" "wifi  → apagado" 5 && ok "watch: llega el cambio al apagar" || bad "watch: cambio" "$(cat "$T/watch.out")"
"$NEXO" wifi on >/dev/null 2>&1
"$NEXO" audio volume 20 >/dev/null 2>&1
waitfor "$T/watch.out" "audio → volumen 20%" 5 && ok "watch: cambio de volumen" || bad "watch: volumen" "$(cat "$T/watch.out")"
"$NEXO" media next >/dev/null 2>&1
waitfor "$T/watch.out" "Otra canción — Otro artista" 5 && ok "watch: cambio de canción" || bad "watch: canción" "$(cat "$T/watch.out")"
pkill -f "$T/bin/nexo watch" 2>/dev/null
"$NEXO" audio volume 60 >/dev/null 2>&1
"$NEXO" media prev >/dev/null 2>&1
"$NEXO" watch media >"$T/watch2.out" 2>&1 &
waitfor "$T/watch2.out" '"event":"media"' 5 && ok "watch media: llega el estado" || bad "watch media" "$(cat "$T/watch2.out")"
"$NEXO" wifi off >/dev/null 2>&1
sleep 0.8
"$NEXO" wifi on >/dev/null 2>&1
sleep 0.3
grep -q '"event":"wifi"' "$T/watch2.out" && bad "watch media no debe traer eventos de WiFi" "$(cat "$T/watch2.out")" || ok "watch media: solo trae eventos de media"
pkill -f "$T/bin/nexo watch" 2>/dev/null
"$NEXO" watch --event >"$T/watch3.out" 2>&1 &
waitfor "$T/watch3.out" '"type":"media","event":"track"' 5 && ok "watch --event: eventos sueltos" || bad "watch --event" "$(cat "$T/watch3.out")"
jq -e -s 'any(.[]; .type == "wifi" and .event == "connected" and .initial == true and .ssid == "MiCasa")' "$T/watch3.out" >/dev/null 2>&1 && ok "watch --event: WiFi conectado (inicial)" || bad "evento wifi inicial" "$(cat "$T/watch3.out")"
jq -e -s 'any(.[]; .type == "audio" and .event == "volume" and .volume == 60)' "$T/watch3.out" >/dev/null 2>&1 && ok "watch --event: volumen" || bad "evento de volumen"
jq -e -s 'any(.[]; .type == "bt" and .event == "connected")' "$T/watch3.out" >/dev/null 2>&1 && ok "watch --event: Bluetooth conectado" || bad "evento de bt"
"$NEXO" wifi off >/dev/null 2>&1
waitfor "$T/watch3.out" '"type":"wifi","event":"disabled"' 5 && ok "watch --event: WiFi apagado" || bad "evento disabled" "$(cat "$T/watch3.out")"
"$NEXO" wifi on >/dev/null 2>&1
waitfor "$T/watch3.out" '"event":"connected","ssid":"MiCasa","ip"' 5 && ok "watch --event: vuelve a conectarse" || bad "evento connected" "$(cat "$T/watch3.out")"
"$NEXO" audio volume mute >/dev/null 2>&1
waitfor "$T/watch3.out" '"type":"audio","event":"muted"' 5 && ok "watch --event: silencio" || bad "evento muted"
"$NEXO" audio volume unmute >/dev/null 2>&1
"$NEXO" media pause >/dev/null 2>&1
waitfor "$T/watch3.out" '"type":"media","event":"state","state":"paused"' 5 && ok "watch --event: pausa" || bad "evento de pausa" "$(cat "$T/watch3.out")"
"$NEXO" media play >/dev/null 2>&1
"$NEXO" media next >/dev/null 2>&1
waitfor "$T/watch3.out" '"title":"Otra canción"' 5 && ok "watch --event: canción nueva" || bad "evento track nuevo"
"$NEXO" media prev >/dev/null 2>&1
pkill -f "$T/bin/nexo watch" 2>/dev/null
NEXO_PORT=$OLD "$NEXO" watch audio >"$T/watch4.out" 2>&1 &
waitfor "$T/watch4.out" "no ofrece eventos" 5 && ok "watch con una app vieja avisa de lo que no ofrece" || bad "watch en app vieja" "$(cat "$T/watch4.out")"
pkill -f "$T/bin/nexo watch" 2>/dev/null
NEXO_PORT=1 "$NEXO" watch >"$T/watch5.out" 2>&1 &
waitfor "$T/watch5.out" "reintento en 2 s" 6 && ok "watch: la espera entre reintentos va creciendo (1 s, 2 s…)" || bad "backoff de watch" "$(cat "$T/watch5.out")"
grep -q "reintento en 1 s" "$T/watch5.out" && ok "…empezando por 1 s" || bad "backoff empieza por 1 s"
pkill -f "$T/bin/nexo watch" 2>/dev/null
run "$NEXO" watch cosas;                 rc_is "watch con un tema raro → uso (2)" 2

echo "== Errores de conexión"
NEXO_PORT=1 run "$NEXO" ping;            rc_is "sin nadie escuchando → 10" 10
NEXO_TOKEN=00ff run "$NEXO" ping;        rc_is "token equivocado en el entorno → 11" 11
NEXO_PORT=1 run "$NEXO" status;          rc_is "status sin nadie escuchando → 10" 10
NEXO_TOKEN=00ff run "$NEXO" status;      rc_is "status con token malo → 11" 11

echo "== start (despertar la app) y doctor --fix"
mkdir -p "$T/fakebin"
cat > "$T/fakebin/am" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/am.log"
EOF
chmod +x "$T/fakebin/am"
PATH="$T/fakebin:$PATH" run "$NEXO" start; rc_is "start (con «am»)" 0
has "…y espera a que la app responda" "Nexo responde"
grep -q 'start --user 0 -n org.nexo.bridge/.StartActivity' "$T/am.log" && ok "…abre la actividad de arranque de Nexo" || bad "start no llamó a am como se esperaba" "$(cat "$T/am.log" 2>/dev/null)"
run env PATH="/usr/bin:/bin" HOME="$HOME" NEXO_PORT="$PORT" "$NEXO" start; rc_is "start sin «am» (distro de proot) → 1" 1
has "…y explica por qué" "proot"
chmod 644 "$HOME/.config/nexo/config"
run "$NEXO" doctor --fix;                rc_is "doctor --fix" 0
[ "$(stat -c %a "$HOME/.config/nexo/config")" = 600 ] && ok "…arregla los permisos del enlace (600)" || bad "doctor --fix no arregló el modo"
has "…y lo cuenta" "permisos de"
rm -f "$T/am.log"
PATH="$T/fakebin:$PATH" NEXO_PORT=1 run "$NEXO" doctor --fix; rc_is "doctor --fix con la app apagada sigue fallando (10)" 10
has "…pero intenta abrirla" "intento abrirla"
grep -q 'StartActivity' "$T/am.log" && ok "…con «am start»" || bad "doctor --fix no llamó a am"
run "$NEXO" doctor --raro;               rc_is "doctor con una opción rara → uso (2)" 2

echo "== Instalación con el comando de una línea (Termux con OTRO nombre de paquete)"
SHA=$(python3 "$ROOT/tests/fake_app.py" --print-bundle-sha)
ONE=$(cat "$ROOT/termux/oneliner.tpl")
mk_one() { local s=$ONE; s=${s//@PORT@/$1}; s=${s//@SHA256@/$2}; s=${s//@TOKEN@/$3}; printf '%s' "$s"; }
mkfork() { local p=$T/$1/data/data/org.otro.termux/files/usr; mkdir -p "$p/bin" "$T/$1/home" "$T/$1/tmp"; printf '%s' "$p"; }
fenv() { local d=$1; shift; env -i PATH="$PATH" HOME="$T/$d/home" PREFIX="$T/$d/data/data/org.otro.termux/files/usr" TMPDIR="$T/$d/tmp" "$@"; }

FP=$(mkfork a)
run fenv a bash -c "$(mk_one "$PORT" "$SHA" "$TOKEN")"
has "instala el cliente" "Cliente instalado en $FP/bin/nexo"
has "enlaza con la app" "La app responde"
has "…y avisa de que instaló nexo-dbus (el reproductor MPRIS)" "nexo-dbus instalado en $FP/bin/nexo-dbus"
[ -x "$FP/bin/nexo-dbus" ] && ok "nexo-dbus queda ejecutable en \$PREFIX/bin" || bad "nexo-dbus ejecutable"
cmp -s "$FP/bin/nexo-dbus" "$ROOT/termux/bin/nexo-dbus" && ok "…e idéntico al del repositorio" || bad "nexo-dbus instalado distinto"
has "…y de que instaló nexo-tools (archivos entre móviles)" "nexo-tools instalado en $FP/bin/nexo-tools"
[ -x "$FP/bin/nexo-tools" ] && cmp -s "$FP/bin/nexo-tools" "$ROOT/termux/bin/nexo-tools" && ok "nexo-tools queda ejecutable en \$PREFIX/bin e idéntico al del repositorio" || bad "nexo-tools instalado"
[ -x "$FP/bin/nexo" ] && ok "el cliente queda ejecutable en \$PREFIX/bin" || bad "cliente ejecutable"
[ "$(stat -c %a "$T/a/home/.config/nexo/config")" = 600 ] && ok "config con modo 600 en \$HOME/.config/nexo" || bad "config de la instalación"
run fenv a "$FP/bin/nexo" wifi status --short; eq "el cliente instalado funciona sin variables de entorno" "MiCasa"
cmp -s "$FP/bin/nexo" "$ROOT/termux/bin/nexo" && ok "el cliente instalado es idéntico al del repositorio" || bad "cliente instalado distinto"
bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT; echo '{\"cmd\":\"bootstrap\"}' >&3; cat <&3" > "$T/bundle.sh" 2>/dev/null
if [ -s "$T/bundle.sh" ] && ! sed -n '1,4p' "$T/bundle.sh" | grep -q '^export'; then
    ok "el script de instalación no exporta el cliente en base64 (límite de 128 KiB por variable de entorno)"
else
    bad "el bundle exporta NEXO_CLIENT_B64"
fi
[ "$(sed -n 2p "$T/bundle.sh" | cut -c1-17)" = "NEXO_CLIENT_B64='" ] && [ "$(sed -n 3p "$T/bundle.sh" | cut -c1-15)" = "NEXO_DBUS_B64='" ] && [ "$(sed -n 4p "$T/bundle.sh" | cut -c1-16)" = "NEXO_TOOLS_B64='" ] && ok "…y lleva el cliente, nexo-dbus y nexo-tools en las líneas 2, 3 y 4" || bad "formato del bundle"

FP2=$(mkfork b)
run fenv b bash -c "$(mk_one "$PORT" "$(printf '0%.0s' $(seq 64))" "$TOKEN")"
[ ! -e "$FP2/bin/nexo" ] && ok "con un hash que no coincide NO se instala nada" || bad "hash incorrecto instaló algo"
has "…y avisa" "no se pudo instalar"

python3 "$ROOT/tests/fake_app.py" --evil --portfile "$T/eport" >/dev/null 2>&1 &
APP_PIDS+=($!)
for _ in $(seq 50); do [ -s "$T/eport" ] && break; sleep 0.1; done
EPORT=$(cat "$T/eport")
env NEXO_EVIL_MARK="$T/PWNED1" bash -c "exec 3<>/dev/tcp/127.0.0.1/$EPORT; echo '{\"cmd\":\"bootstrap\"}' >&3; cat <&3 | bash" >/dev/null 2>&1
[ -e "$T/PWNED1" ] && ok "(control) sin comprobar el hash, la app impostora SÍ ejecutaría código" || bad "control de la app impostora"
FP3=$(mkfork c)
run fenv c env NEXO_EVIL_MARK="$T/PWNED2" bash -c "$(mk_one "$EPORT" "$SHA" "$TOKEN")"
[ ! -e "$T/PWNED2" ] && ok "con el comando de la app, el script impostor NO se ejecuta" || bad "se ejecutó el script impostor"
[ ! -e "$FP3/bin/nexo" ] && ok "…y no se instala nada" || bad "se instaló algo desde la app impostora"

echo "== setup-guests (distros de proot-distro)"
G=$FP/var/lib/proot-distro/installed-rootfs
mkdir -p "$G/debian/usr/bin" "$G/alpine/bin"
: > "$G/debian/usr/bin/bash"; chmod +x "$G/debian/usr/bin/bash"
sed -i '1s|.*|#!/data/data/org.otro.termux/files/usr/bin/bash|' "$FP/bin/nexo"   # como si termux-fix-shebang lo hubiera tocado
run fenv a bash "$FP/bin/nexo" setup-guests --list
has "--list: aún sin nexo" "- debian  (sin nexo)"
run fenv a bash "$FP/bin/nexo" setup-guests
has "copia a debian" "✔ debian"
has "copia a alpine" "✔ alpine"
has "avisa de que a alpine le falta bash" "a alpine le falta bash"
hasnt "no avisa de bash en debian" "a debian le falta bash"
[ "$(head -n 1 "$G/debian/usr/local/bin/nexo")" = '#!/usr/bin/env bash' ] && ok "el shebang dentro de la distro es el normal" || bad "shebang en la distro"
[ "$(stat -c %a "$G/debian/etc/nexo/config")" = 644 ] && ok "la config de la distro la leen todos sus usuarios (644)" || bad "modo de config en la distro"
mkdir -p "$T/d/home"
run env -i PATH="$PATH" HOME="$T/d/home" NEXO_CONFIG="$G/debian/etc/nexo/config" "$G/debian/usr/local/bin/nexo" wifi status --short
eq "el cliente copiado a la distro funciona" "MiCasa"
run fenv a bash "$FP/bin/nexo" setup-guests --list
has "--list: ya con nexo" "✔ debian  (nexo instalado)"
run fenv a bash "$FP/bin/nexo" setup-guests --private debian
[ "$(stat -c %a "$G/debian/etc/nexo/config")" = 600 ] && ok "--private deja el enlace solo para root (600)" || bad "--private"
has "…y lo explica" "modo 600"
run fenv a bash "$FP/bin/nexo" setup-guests --raro; rc_is "setup-guests con una opción rara → uso (2)" 2
run bash "$ROOT/termux/bin/nexo" setup-guests; rc_is "setup-guests fuera de Termux → uso (2)" 2
run fenv a bash "$FP/bin/nexo" setup-guests --uninstall alpine
[ ! -e "$G/alpine/usr/local/bin/nexo" ] && [ ! -e "$G/alpine/etc/nexo/config" ] && ok "--uninstall limpia una distro" || bad "--uninstall de una distro"
[ -x "$G/debian/usr/local/bin/nexo" ] && ok "…y no toca las demás" || bad "--uninstall tocó otra distro"
run fenv a bash "$FP/bin/nexo" rekey "$TOKEN"
rc_is "rekey en Termux actualiza también las distros" 0
has "…lo cuenta" "Actualizando tus distros"
has "…y las copia" "✔ debian"

echo "== setup-guests --with-dbus (nexo-dbus dentro de las distros)"
: > "$G/debian/usr/bin/python3"; chmod +x "$G/debian/usr/bin/python3"     # debian tiene python3; alpine no
[ ! -e "$G/debian/usr/local/bin/nexo-dbus" ] && ok "(antes) sin --with-dbus no hay nexo-dbus en las distros" || bad "nexo-dbus apareció solo"
run fenv a bash "$FP/bin/nexo" setup-guests --with-dbus
rc_is "--with-dbus copia nexo-dbus a las distros" 0
has "a debian (que tiene python3) le dice qué hacer" "Dentro de debian:  nexo setup-dbus"
has "a alpine (sin python3) le avisa" "a alpine le falta python3"
has "al final explica para qué sirve" "reproductor"
[ -x "$G/debian/usr/local/bin/nexo-dbus" ] && ok "nexo-dbus queda ejecutable en usr/local/bin de la distro" || bad "nexo-dbus en la distro"
[ "$(head -n 1 "$G/debian/usr/local/bin/nexo-dbus")" = '#!/usr/bin/env python3' ] && ok "…con el shebang normal de python3" || bad "shebang de nexo-dbus en la distro"
cmp -s <(tail -n +2 "$G/debian/usr/local/bin/nexo-dbus") <(tail -n +2 "$ROOT/termux/bin/nexo-dbus") && ok "…y el mismo contenido que el del repositorio" || bad "contenido de nexo-dbus en la distro"
run fenv a bash "$FP/bin/nexo" setup-guests --list
has "--list dice qué distros llevan nexo-dbus" "✔ debian  (nexo instalado) · con nexo-dbus"
run env -i PATH="$PATH" HOME="$T/d/home" "$G/debian/usr/local/bin/nexo-dbus" version
eq "el nexo-dbus copiado funciona dentro de la distro" "nexo-dbus $CLIENT_VERSION"
echo "# versión vieja" >> "$G/debian/usr/local/bin/nexo-dbus"
run fenv a bash "$FP/bin/nexo" setup-guests debian
cmp -s <(tail -n +2 "$G/debian/usr/local/bin/nexo-dbus") <(tail -n +2 "$ROOT/termux/bin/nexo-dbus") && ok "sin --with-dbus, una distro que ya lo tenía recibe la versión nueva" || bad "no se actualizó nexo-dbus"
mkdir -p "$G/fedora/usr/bin"
run fenv a bash "$FP/bin/nexo" setup-guests fedora
[ -x "$G/fedora/usr/local/bin/nexo" ] && [ ! -e "$G/fedora/usr/local/bin/nexo-dbus" ] && ok "sin --with-dbus, una distro nueva no recibe nexo-dbus" || bad "nexo-dbus en una distro que no lo pidió"
mkdir -p "$T/solo/bin"
cp "$ROOT/termux/bin/nexo" "$T/solo/bin/nexo"
run fenv a bash "$T/solo/bin/nexo" setup-guests --with-dbus
rc_is "--with-dbus sin nexo-dbus a mano → error (1)" 1
has "…y dice cómo conseguirlo" "No encuentro nexo-dbus en Termux"
mkdir -p "$G/debian/root/.config/autostart" "$G/debian/home/ana/.config/systemd/user" "$G/debian/home/ana/.config/nexo"
: > "$G/debian/root/.config/autostart/nexo-dbus.desktop"
: > "$G/debian/home/ana/.config/systemd/user/nexo-dbus.service"
: > "$G/debian/home/ana/.config/autostart-otro.desktop"
run fenv a bash "$FP/bin/nexo" setup-guests --uninstall debian
[ ! -e "$G/debian/usr/local/bin/nexo-dbus" ] && [ ! -e "$G/debian/usr/local/bin/nexo" ] && ok "--uninstall quita nexo y nexo-dbus de la distro" || bad "--uninstall dejó archivos"
[ ! -e "$G/debian/root/.config/autostart/nexo-dbus.desktop" ] && [ ! -e "$G/debian/home/ana/.config/systemd/user/nexo-dbus.service" ] && ok "…y el arranque automático que dejó setup-dbus (root y usuarios)" || bad "--uninstall dejó el arranque automático"
[ -e "$G/debian/home/ana/.config/autostart-otro.desktop" ] && ok "…sin tocar otros archivos de los usuarios" || bad "--uninstall borró un archivo ajeno"

echo "== setup-guests con proot-distro 5 (containers/NOMBRE/rootfs), copias viejas y comprobación"
GB=$T/gb
GC=$GB/containers
for d in quantum_os ubuntu; do
    mkdir -p "$GC/$d/rootfs/usr/bin" "$GC/$d/rootfs/usr/local/bin"
    ln -sf "$(type -P bash)" "$GC/$d/rootfs/usr/bin/bash"        # un bash de verdad: los programas de Nexo lo usan (#!/usr/bin/env bash)
done
mkdir -p "$GB/installed-rootfs/ubuntu/usr/bin" "$GB/installed-rootfs/debian/usr/bin"     # disposición vieja; ubuntu está repetida
ln -sf "$(type -P bash)" "$GB/installed-rootfs/debian/usr/bin/bash"
old_nexo() { sed "s/^NEXO_VERSION=.*/NEXO_VERSION=\"$1\"/" "$ROOT/termux/bin/nexo"; }
old_nexo 0.3.0 > "$GC/ubuntu/rootfs/usr/local/bin/nexo"        # la vieja que dejó setup-guests y que GANA en el PATH…
cp "$ROOT/termux/bin/nexo" "$GC/ubuntu/rootfs/usr/bin/nexo"      # …frente a la que se copió a mano a /usr/bin
old_nexo 0.2.0 > "$GC/quantum_os/rootfs/usr/bin/nexo"            # quantum_os: solo hay una, en /usr/bin
chmod +x "$GC/ubuntu/rootfs/usr/local/bin/nexo" "$GC/quantum_os/rootfs/usr/bin/nexo"
gen() { fenv a env NEXO_GUESTS_BASE="$GB" PATH="$FP/bin:$PATH" "$@"; }
run gen bash "$FP/bin/nexo" setup-guests --list
has "--list reconoce las distros de containers/NOMBRE/rootfs" "✔ quantum_os  (nexo instalado)"
has "…y las de installed-rootfs" "- debian  (sin nexo)"
has "…enseña la versión de cada copia" "/usr/local/bin/nexo  0.3.0"
has "…y avisa de que las copias de ubuntu no son iguales" "no son iguales"
[ "$(printf '%s\n' "$OUT" | grep -c ' ubuntu  (')" = 1 ] && ok "ubuntu sale una sola vez (gana containers/ sobre installed-rootfs/)" || bad "ubuntu duplicada" "$OUT"

# un proot-distro FALSO: «login NOMBRE -- sh -lc 'ORDEN'» ejecuta ORDEN con el PATH de esa distro (FAKE_GUEST_PATH; por omisión
# /usr/local/bin primero, como el de proot-distro) y le quita a la salida la ruta de la raíz, como si corriera dentro.
cat > "$FP/bin/proot-distro" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = login ] || exit 2
name=$2; shift 2
base=${NEXO_GUESTS_BASE:?}
if [ -d "$base/containers/$name/rootfs" ]; then r=$base/containers/$name/rootfs
elif [ -d "$base/installed-rootfs/$name" ]; then r=$base/installed-rootfs/$name
else echo "proot-distro: no existe $name" >&2; exit 1; fi
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
[ "${1:-}" = sh ] && [ "${2:-}" = -lc ] || exit 2
np=""; IFS=: read -ra ds <<<"${FAKE_GUEST_PATH:-/usr/local/bin:/usr/bin:/bin}"
for d in "${ds[@]}"; do np+="$r$d:"; done
out=$(PATH="${np}/usr/bin:/bin" sh -c "$3" 2>&1); rc=$?
printf '%s\n' "$out" | sed "s|$r||g"
exit $rc
EOF
chmod +x "$FP/bin/proot-distro"
run gen bash "$FP/bin/nexo" setup-guests
rc_is "setup-guests con las dos disposiciones a la vez" 0
has "ubuntu: la copia vieja de /usr/local/bin (la que gana) pasa a la versión nueva" "↳ /usr/local/bin/nexo: 0.3.0 → $CLIENT_VERSION"
has "…y cuenta que había dos copias y las actualizó todas" "había 2 copias de nexo (/usr/local/bin/nexo /usr/bin/nexo): las actualicé todas"
has "quantum_os: su copia vieja de /usr/bin" "↳ /usr/bin/nexo: 0.2.0 → $CLIENT_VERSION"
has "debian (disposición vieja) también" "✔ debian"
n=0
for f in "$GC/ubuntu/rootfs/usr/local/bin/nexo" "$GC/ubuntu/rootfs/usr/bin/nexo" "$GC/quantum_os/rootfs/usr/bin/nexo" "$GB/installed-rootfs/debian/usr/local/bin/nexo"; do
    cmp -s <(tail -n +2 "$f") <(tail -n +2 "$ROOT/termux/bin/nexo") && n=$((n + 1))
done
[ "$n" = 4 ] && ok "las cuatro copias quedan iguales al cliente de Termux" || bad "copias distintas ($n de 4 iguales)"
has "comprueba ejecutando la distro: ubuntu" "✔ comprobado: dentro de ubuntu, «nexo» es /usr/local/bin/nexo (nexo $CLIENT_VERSION)"
has "…y quantum_os, donde solo había /usr/bin" "✔ comprobado: dentro de quantum_os, «nexo» es /usr/bin/nexo (nexo $CLIENT_VERSION)"
[ ! -e "$GB/installed-rootfs/ubuntu/usr/local/bin/nexo" ] && ok "la carpeta vieja repetida de ubuntu no se toca" || bad "se tocó installed-rootfs/ubuntu"
[ "$(head -n 1 "$GC/quantum_os/rootfs/usr/bin/nexo")" = '#!/usr/bin/env bash' ] && ok "la copia actualizada lleva el shebang normal" || bad "shebang"
[ ! -e "$GC/quantum_os/rootfs/usr/local/bin/nexo" ] && ok "si ya había copia en /usr/bin, no crea otra en /usr/local/bin" || bad "creó una copia de más"
run gen bash "$FP/bin/nexo" setup-guests --list
hasnt "--list ya no avisa de copias distintas" "no son iguales"
mkdir -p "$GC/ubuntu/rootfs/opt/stale"; old_nexo 0.1.0 > "$GC/ubuntu/rootfs/opt/stale/nexo"; chmod +x "$GC/ubuntu/rootfs/opt/stale/nexo"
run gen env FAKE_GUEST_PATH=/opt/stale:/usr/local/bin:/usr/bin bash "$FP/bin/nexo" setup-guests ubuntu
has "si gana otra copia que setup-guests no mira (en /opt), lo detecta ejecutando la distro" "⚠ dentro de ubuntu se ejecuta /opt/stale/nexo y dice «nexo 0.1.0»"
has "…y explica cómo encontrarla" "type -a nexo"
run gen env FAKE_GUEST_PATH=/nada bash "$FP/bin/nexo" setup-guests ubuntu
has "si «nexo» no está en el PATH de la distro, lo dice" "el comando «nexo» no se encuentra en su PATH"
rm -rf "$GC/ubuntu/rootfs/opt"
mkdir -p "$GC/ubuntu/rootfs/home/ana/.config/nexo" "$GC/ubuntu/rootfs/root/.config/nexo"
printf 'NEXO_PORT=8765\nNEXO_TOKEN=00112233\n' > "$GC/ubuntu/rootfs/home/ana/.config/nexo/config"; chmod 600 "$GC/ubuntu/rootfs/home/ana/.config/nexo/config"
printf 'NEXO_TOKEN=%s\n' "$TOKEN" > "$GC/ubuntu/rootfs/root/.config/nexo/config"          # este ya está al día
run gen bash "$FP/bin/nexo" setup-guests --no-verify ubuntu
has "el enlace propio de un usuario de la distro con el token viejo se actualiza (si no, ganaría al de /etc/nexo)" "también puse el token nuevo en el enlace propio de /home/ana"
grep -q "^NEXO_TOKEN=$TOKEN\$" "$GC/ubuntu/rootfs/home/ana/.config/nexo/config" && ok "…con el token que usa Termux" || bad "token de ana"
[ "$(stat -c %a "$GC/ubuntu/rootfs/home/ana/.config/nexo/config")" = 600 ] && ok "…sin cambiar su modo (600)" || bad "modo del enlace de ana"
hasnt "…y el de root, que ya estaba al día, no se menciona" "enlace propio de /root"
hasnt "--no-verify no ejecuta la distro" "comprobado"
run gen bash "$FP/bin/nexo" setup-guests --no-verify --with-tools ubuntu
has "--with-tools copia nexo-tools a la distro" "nexo-tools copiado"
[ -x "$GC/ubuntu/rootfs/usr/local/bin/nexo-tools" ] && cmp -s <(tail -n +2 "$GC/ubuntu/rootfs/usr/local/bin/nexo-tools") <(tail -n +2 "$ROOT/termux/bin/nexo-tools") && ok "…igual que el de Termux" || bad "nexo-tools en la distro"
[ "$(head -n 1 "$GC/ubuntu/rootfs/usr/local/bin/nexo-tools")" = '#!/usr/bin/env bash' ] && ok "…con el shebang normal" || bad "shebang de nexo-tools en la distro"
has "…y avisa de que a esa distro le faltan python3 y openssl" "le falta python3 u openssl"
run gen bash "$FP/bin/nexo" setup-guests --list
has "--list dice qué distros llevan nexo-tools" "· con nexo-tools"
echo "# vieja" >> "$GC/ubuntu/rootfs/usr/local/bin/nexo-tools"
run gen bash "$FP/bin/nexo" setup-guests --no-verify ubuntu quantum_os
cmp -s <(tail -n +2 "$GC/ubuntu/rootfs/usr/local/bin/nexo-tools") <(tail -n +2 "$ROOT/termux/bin/nexo-tools") && ok "sin --with-tools, una distro que ya tenía nexo-tools lo recibe nuevo" || bad "no se actualizó nexo-tools"
[ ! -e "$GC/quantum_os/rootfs/usr/local/bin/nexo-tools" ] && ok "…y una que no lo tenía, no lo recibe" || bad "nexo-tools en una distro que no lo pidió"
mkdir -p "$T/cwd"
pushd "$T/cwd" >/dev/null
run gen bash "$FP/bin/nexo" setup-guests noexiste
popd >/dev/null
rc_is "una distro que no existe → error (1)" 1
has "…y dice cómo ver las que hay" "setup-guests --list"
[ ! -e "$T/cwd/noexiste" ] && ok "…sin crear carpetas sueltas donde estés" || bad "creó una carpeta suelta"
run gen bash "$FP/bin/nexo" setup-guests --no-verify "$GC/ubuntu"
has "acepta la carpeta containers/NOMBRE de una distro" "✔ ubuntu"
run gen bash "$FP/bin/nexo" setup-guests --no-verify "$GC/quantum_os/rootfs"
has "…y la raíz de la distro (…/rootfs)" "✔ quantum_os"
run gen bash "$FP/bin/nexo" rekey "$TOKEN"
rc_is "rekey actualiza también las distros de containers/" 0
has "…las copia" "✔ quantum_os"
hasnt "…sin ejecutarlas para comprobar (sería lento)" "comprobado"
run gen bash "$FP/bin/nexo" setup-guests --uninstall ubuntu
n=0
for f in "$GC/ubuntu/rootfs/usr/local/bin/nexo" "$GC/ubuntu/rootfs/usr/bin/nexo" "$GC/ubuntu/rootfs/usr/local/bin/nexo-tools"; do [ ! -e "$f" ] && n=$((n + 1)); done
[ "$n" = 3 ] && ok "--uninstall quita TODAS las copias (también la de /usr/bin) y nexo-tools" || bad "--uninstall dejó copias ($n de 3 quitadas)"
[ ! -e "$GC/ubuntu/rootfs/home/ana/.config/nexo/config" ] && ok "…y el enlace propio de los usuarios (lleva el token)" || bad "--uninstall dejó el enlace de ana"
[ -x "$GC/quantum_os/rootfs/usr/bin/nexo" ] && ok "…sin tocar las demás distros" || bad "--uninstall tocó otra distro"

echo "== nexo update (lo que antes era copiar a mano)"
U=$T/upd; rm -rf "$U"; mkdir -p "$U/repo/termux/bin" "$U/home/.config/nexo" "$U/tmp"
TOOLS_VER=$(sed -n 's/^NEXO_TOOLS_VERSION="\(.*\)"/\1/p' "$ROOT/termux/bin/nexo-tools")
UP=$U/data/data/com.termux/files/usr; mkdir -p "$UP/bin"
for f in nexo nexo-dbus nexo-tools; do cp "$ROOT/termux/bin/$f" "$U/repo/termux/bin/$f"; done
sed -i 's/^NEXO_VERSION=.*/NEXO_VERSION="9.9.9-test"/' "$U/repo/termux/bin/nexo"
old_nexo 0.3.0 > "$UP/bin/nexo"; chmod +x "$UP/bin/nexo"                      # Termux con el cliente viejo, sin nexo-dbus ni nexo-tools
printf 'NEXO_PORT=%s\nNEXO_TOKEN=%s\n' "$PORT" "$TOKEN" > "$U/home/.config/nexo/config"
UG=$U/gb
mkdir -p "$UG/containers/ubuntu/rootfs/usr/bin" "$UG/containers/ubuntu/rootfs/usr/local/bin"
old_nexo 0.3.0 > "$UG/containers/ubuntu/rootfs/usr/local/bin/nexo"; chmod +x "$UG/containers/ubuntu/rootfs/usr/local/bin/nexo"
# PATH aislado (solo el «Termux» de prueba y enlaces a las herramientas): update toca TODAS las copias de nexo que ve en el PATH,
# y las pruebas no deben llegar jamás a un nexo de verdad que tengas instalado.
UT=$U/tbin; mkdir -p "$UT"
for c in bash sh sed grep tail head cmp readlink mktemp dirname basename cat cp mv rm mkdir rmdir chmod stat id tr cut env python3 unzip ls sleep timeout date uname wc sort touch ln awk jq tee; do
    p=$(type -P "$c" 2>/dev/null) && [ -n "$p" ] && ln -sf "$p" "$UT/$c"
done
uenv() { env -i PATH="$UP/bin:$UT" HOME="$U/home" PREFIX="$UP" TMPDIR="$U/tmp" NEXO_GUESTS_BASE="$UG" "$@"; }
rm -f "$FP/bin/proot-distro"
run uenv bash "$UP/bin/nexo" update --check "$U/repo"
rc_is "update --check" 0
has "…dice qué cambiaría" "nexo        0.3.0 → 9.9.9-test"
has "…y que instalaría los que faltan (en Termux se instalan los tres)" "nexo-tools  nuevo → $TOOLS_VER"
[ "$(sed -n 's/^NEXO_VERSION="\(.*\)"/\1/p' "$UP/bin/nexo")" = 0.3.0 ] && [ ! -e "$UP/bin/nexo-tools" ] && ok "…sin cambiar nada" || bad "--check cambió algo"
[ "$(sed -n 's/^NEXO_VERSION="\(.*\)"/\1/p' "$UG/containers/ubuntu/rootfs/usr/local/bin/nexo")" = 0.3.0 ] && ok "…ni en las distros" || bad "--check cambió una distro"
run uenv bash "$UP/bin/nexo" update "$U/repo"
rc_is "update desde la carpeta del repositorio (…/termux/bin se encuentra sola)" 0
has "…instala el cliente nuevo" "nexo        0.3.0 → 9.9.9-test"
has "…y pasa a las distros" "Distros de proot-distro:"
run uenv "$UP/bin/nexo" version
eq "…y el nexo de Termux ya es el nuevo" "nexo 9.9.9-test"
[ -x "$UP/bin/nexo-dbus" ] && [ -x "$UP/bin/nexo-tools" ] && cmp -s <(tail -n +2 "$UP/bin/nexo-tools") <(tail -n +2 "$ROOT/termux/bin/nexo-tools") && ok "…y trae nexo-dbus y nexo-tools, ejecutables e iguales a los del origen" || bad "nexo-dbus / nexo-tools tras update"
[ "$(head -n 1 "$UP/bin/nexo")" = '#!/usr/bin/env bash' ] && ok "…con el shebang normal (termux-fix-shebang lo cambia en un Termux de verdad)" || bad "shebang tras update"
[ "$(sed -n 's/^NEXO_VERSION="\(.*\)"/\1/p' "$UG/containers/ubuntu/rootfs/usr/local/bin/nexo")" = 9.9.9-test ] && ok "…la copia vieja de ubuntu queda en la versión nueva" || bad "update no actualizó la distro"
run uenv bash "$UP/bin/nexo" update "$U/repo"
has "una segunda vez no cambia nada" "Todo estaba al día."
has "…y lo dice por programa" "al día (9.9.9-test)"
old_nexo 0.3.0 > "$UP/bin/nexo"
run uenv bash "$UP/bin/nexo" update --no-guests "$U/repo/termux"
rc_is "update desde la carpeta termux/ y con --no-guests" 0
has "…no toca las distros y lo dice" "No toqué las distros"
old_nexo 0.3.0 > "$UP/bin/nexo"
python3 - "$U" <<'EOF'
import sys, os, zipfile
u = sys.argv[1]
with zipfile.ZipFile(os.path.join(u, "nexo.zip"), "w") as z:
    for f in ("nexo", "nexo-dbus", "nexo-tools"):
        z.write(os.path.join(u, "repo", "termux", "bin", f), "nexo/termux/bin/" + f)
EOF
run uenv bash "$UP/bin/nexo" update --no-guests "$U/nexo.zip"
rc_is "update desde un .zip" 0
run uenv "$UP/bin/nexo" version
eq "…y el cliente queda nuevo" "nexo 9.9.9-test"
[ -z "$(ls -A "$U/tmp")" ] && ok "…sin dejar carpetas temporales" || bad "update dejó basura en TMPDIR: $(ls "$U/tmp")"
old_nexo 0.3.0 > "$UP/bin/nexo"
run uenv env NEXO_REPO="$U/repo" bash "$UP/bin/nexo" update --no-guests
rc_is "update sin RUTA usa NEXO_REPO" 0
run uenv "$UP/bin/nexo" version
eq "…y actualiza" "nexo 9.9.9-test"
mkdir -p "$U/vacio"
run uenv env NEXO_REPO="$U/vacio" bash "$UP/bin/nexo" update --no-guests
rc_is "update con NEXO_REPO apuntando a una carpeta sin nexo → error (1)" 1
has "…y dice cómo indicar otra" "nexo update RUTA"
old_nexo 0.3.0 > "$UP/bin/nexo"
pushd "$U/repo" >/dev/null
run uenv bash "$UP/bin/nexo" update --no-guests
popd >/dev/null
rc_is "update sin RUTA, estando dentro de la carpeta del repositorio" 0
run uenv "$UP/bin/nexo" version
eq "…usa la carpeta donde estás" "nexo 9.9.9-test"
mkdir -p "$U/roto/termux/bin"; cp "$U/repo/termux/bin/"* "$U/roto/termux/bin/"; echo 'if then' >> "$U/roto/termux/bin/nexo"
old_nexo 0.3.0 > "$UP/bin/nexo"
run uenv bash "$UP/bin/nexo" update "$U/roto"
rc_is "un nexo nuevo que no es un script válido → error (1)" 1
has "…lo rechaza" "no es un script válido"
[ "$(sed -n 's/^NEXO_VERSION="\(.*\)"/\1/p' "$UP/bin/nexo")" = 0.3.0 ] && ok "…y no toca el instalado" || bad "update instaló un script roto"
run uenv bash "$UP/bin/nexo" update "$U/no-existe";   rc_is "update con una ruta que no existe → error (1)" 1
run uenv bash "$UP/bin/nexo" update --raro;            rc_is "update con una opción rara → uso (2)" 2
# dentro de una distro (sin PREFIX): actualiza lo que hay en su PATH y no instala por su cuenta nexo-dbus ni nexo-tools
GP=$U/guest/usr/local/bin; mkdir -p "$GP"; old_nexo 0.3.0 > "$GP/nexo"; chmod +x "$GP/nexo"
run env -i PATH="$GP:$UT" HOME="$U/home" TMPDIR="$U/tmp" bash "$GP/nexo" update "$U/repo"
rc_is "update dentro de una distro (sin PREFIX)" 0
run env -i PATH="$GP:$UT" HOME="$U/home" "$GP/nexo" version
eq "…actualiza el nexo de su PATH" "nexo 9.9.9-test"
[ ! -e "$GP/nexo-dbus" ] && [ ! -e "$GP/nexo-tools" ] && ok "…sin instalar nexo-dbus ni nexo-tools si no los pides" || bad "update instaló de más en una distro"
run env -i PATH="$GP:$UT" HOME="$U/home" TMPDIR="$U/tmp" bash "$GP/nexo" update --with-tools "$U/repo"
[ -x "$GP/nexo-tools" ] && ok "…y con --with-tools sí instala nexo-tools" || bad "update --with-tools en una distro"

echo "== nexo tools (todo lo que sigue a «tools» es de nexo-tools)"
run fenv a bash "$FP/bin/nexo" tools --version
eq "nexo tools --version es la de nexo-tools (y no la del cliente)" "NEXO-TOOLS $TOOLS_VER"
run fenv a bash "$FP/bin/nexo" tools help
has "nexo tools help enseña la ayuda de nexo-tools" "NEXO-TOOLS"
has "…con lo de descubrir y emparejar" "discover"
run fenv a bash "$FP/bin/nexo" help
has "la ayuda de nexo habla de tools" "tools send ARCHIVO"
has "…y de update" "update [RUTA|ARCHIVO.zip]"
mkdir -p "$T/solo2/bin"; cp "$ROOT/termux/bin/nexo" "$T/solo2/bin/nexo"
run env -i PATH="$UT" HOME="$T/a/home" bash "$T/solo2/bin/nexo" tools --version
rc_is "sin nexo-tools instalado → error (1)" 1
has "…y dice cómo conseguirlo" "No encuentro nexo-tools"
mkdir -p "$T/stub"
printf '#!%s\necho "[${NEXO_TOOLS_DEVICE:-}] $*"\n' "$(type -P bash)" > "$T/stub/nexo-tools"; chmod +x "$T/stub/nexo-tools"
run env -i PATH="$T/stub:$UT" HOME="$T/a/home" NEXO_PORT="$PORT" NEXO_TOKEN="$TOKEN" bash "$ROOT/termux/bin/nexo" tools server --rw --port 9
eq "dentro de una distro (sin getprop), «tools server» se anuncia con el nombre del móvil que da la app, y le pasa sus opciones" "[Fake Phone] server --rw --port 9"
run env -i PATH="$T/stub:$UT" HOME="$T/a/home" NEXO_PORT="$PORT" NEXO_TOKEN="$TOKEN" NEXO_TOOLS_DEVICE=Mio bash "$ROOT/termux/bin/nexo" tools server
eq "…si ya pusiste NEXO_TOOLS_DEVICE, manda el tuyo" "[Mio] server"
run env -i PATH="$T/stub:$UT" HOME="$T/a/home" NEXO_PORT="$PORT" NEXO_TOKEN="$TOKEN" bash "$ROOT/termux/bin/nexo" tools ls pepe
eq "…y con otros subcomandos no le pregunta nada a la app" "[] ls pepe"
run env -i PATH="$T/stub:$UT" HOME="$T/a/home" NEXO_PORT=1 NEXO_TOKEN="$TOKEN" bash "$ROOT/termux/bin/nexo" tools server
eq "…y si la app no contesta, no se queda esperando: sigue sin nombre" "[] server"
run fenv a bash "$FP/bin/nexo" doctor
has "doctor muestra nexo-tools y su versión" "nexo-tools $FP/bin/nexo-tools $TOOLS_VER"


echo "== Desinstalar"
run fenv a bash "$ROOT/termux/install.sh" --uninstall
[ ! -e "$FP/bin/nexo" ] && [ ! -e "$T/a/home/.config/nexo/config" ] && ok "--uninstall quita cliente y enlace" || bad "--uninstall"
[ ! -e "$FP/bin/nexo-dbus" ] && ok "…y nexo-dbus" || bad "--uninstall no quitó nexo-dbus"
[ ! -e "$FP/bin/nexo-tools" ] && ok "…y nexo-tools" || bad "--uninstall no quitó nexo-tools"
echo "== Instalador: --uninstall y lo que guarda nexo-tools"
mkdir -p "$T/a/home/.local/state/nexo-tools"; : > "$T/a/home/.local/state/nexo-tools/known.json"
run fenv a bash "$ROOT/termux/install.sh" --uninstall
has "--uninstall avisa de lo que deja guardado nexo-tools (certificado, emparejamientos)" "Dejé lo que guarda nexo-tools"
[ -e "$T/a/home/.local/state/nexo-tools/known.json" ] && ok "…y no lo borra sin que lo pidas" || bad "--uninstall borró el estado de nexo-tools"
run fenv a bash "$ROOT/termux/install.sh" --uninstall --purge
[ ! -e "$T/a/home/.local/state/nexo-tools" ] && ok "--uninstall --purge sí lo borra" || bad "--purge no borró el estado"

echo "== Instalador desde el repositorio (bash termux/install.sh)"
mkdir -p "$T/ri/home"
run env -i PATH="$PATH" HOME="$T/ri/home" NEXO_BIN_DIR="$T/ri/bin" NEXO_NO_DEPS=1 bash "$ROOT/termux/install.sh"
rc_is "instala desde el repositorio" 0
[ -x "$T/ri/bin/nexo" ] && [ -x "$T/ri/bin/nexo-dbus" ] && [ -x "$T/ri/bin/nexo-tools" ] && ok "…y deja nexo, nexo-dbus y nexo-tools ejecutables" || bad "instalación desde el repositorio"
cmp -s "$T/ri/bin/nexo-dbus" "$ROOT/termux/bin/nexo-dbus" && ok "…con el nexo-dbus del repositorio" || bad "nexo-dbus distinto"
cmp -s "$T/ri/bin/nexo-tools" "$ROOT/termux/bin/nexo-tools" && ok "…y con el nexo-tools del repositorio" || bad "nexo-tools distinto"
has "…y sugiere nexo setup-dbus" "nexo setup-dbus"
run env -i PATH="$PATH" HOME="$T/ri/home" NEXO_BIN_DIR="$T/ri/bin" NEXO_NO_DEPS=1 bash "$ROOT/termux/install.sh" --uninstall
[ ! -e "$T/ri/bin/nexo" ] && [ ! -e "$T/ri/bin/nexo-dbus" ] && [ ! -e "$T/ri/bin/nexo-tools" ] && ok "--uninstall desde el repositorio quita los tres" || bad "--uninstall desde el repositorio"
mkdir -p "$T/ri2/src/bin"
cp "$ROOT/termux/install.sh" "$T/ri2/src/install.sh"; cp "$ROOT/termux/bin/nexo" "$T/ri2/src/bin/nexo"
run env -i PATH="$PATH" HOME="$T/ri/home" NEXO_BIN_DIR="$T/ri2/bin" NEXO_NO_DEPS=1 bash "$T/ri2/src/install.sh"
[ -x "$T/ri2/bin/nexo" ] && [ ! -e "$T/ri2/bin/nexo-dbus" ] && [ ! -e "$T/ri2/bin/nexo-tools" ] && ok "sin nexo-dbus ni nexo-tools en el origen, instala solo el cliente (y no se queja)" || bad "instalación sin nexo-dbus"

# nexo-dbus (necesita dbus-daemon, busctl y gdbus; si faltan, esas pruebas se omiten con un aviso)
. "$ROOT/tests/dbus_tests.sh"

# nexo-tools: servidor HTTPS, emparejamiento, explorador, escritura, send/fetch (necesita openssl)
# (NEXO_TESTS_TOOLS=skip las omite: en la integración continua van en su propio trabajo, que no bloquea)
if [ "${NEXO_TESTS_TOOLS:-}" = skip ]; then
    echo "== nexo-tools (omitido: NEXO_TESTS_TOOLS=skip)"
else
    . "$ROOT/tests/tools_tests.sh"
fi

echo
echo "Resultado: $PASS bien, $FAIL con fallos"
[ "$FAIL" -eq 0 ]
