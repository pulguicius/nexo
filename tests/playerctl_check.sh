#!/usr/bin/env bash
# Prueba nexo-dbus con playerctl DE VERDAD, el cliente MPRIS más usado en Linux.
#
# Las pruebas normales (tests/run_tests.sh) usan busctl y gdbus como clientes. Aquí se comprueba además que playerctl
# ve el reproductor, lee sus metadatos y lo controla. Usa la app Nexo FALSA (tests/fake_app.py) y un bus de sesión propio.
# Necesita: dbus-run-session, playerctl, python3. En GitHub Actions corre en el trabajo «dbus» (que no bloquea nada).
#
#   bash tests/playerctl_check.sh
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)

if [ "${NEXO_PLAYERCTL_INNER:-}" != 1 ]; then
    command -v dbus-run-session >/dev/null 2>&1 || { echo "Falta dbus-run-session (paquete dbus-daemon o dbus)"; exit 2; }
    command -v playerctl >/dev/null 2>&1 || { echo "Falta playerctl (apt install playerctl · pacman -S playerctl)"; exit 2; }
    export NEXO_PLAYERCTL_INNER=1
    exec dbus-run-session -- bash "$0" "$@"
fi

T=$(mktemp -d)
PASS=0
FAIL=0
APP=""
DD=""
cleanup() { [ -n "$APP" ] && kill "$APP" 2>/dev/null; [ -n "$DD" ] && kill "$DD" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FALLA %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }
# poll 'COMANDO' SEGUNDOS → espera (hasta SEGUNDOS) a que el comando salga bien
poll() { local i; for i in $(seq $(($2 * 10))); do eval "$1" >/dev/null 2>&1 && return 0; sleep 0.1; done; return 1; }
# near VALOR ESPERADO TOLERANCIA → ¿están a esa distancia o menos?
near() { awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= t) }'; }
pc() { playerctl -p nexo "$@" 2>&1; }

TOKEN=a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4
python3 "$ROOT/tests/fake_app.py" --token "$TOKEN" --portfile "$T/port" --reqlog "$T/req" >/dev/null 2>&1 &
APP=$!
poll '[ -s "$T/port" ]' 5 || { echo "No arrancó la app falsa"; exit 1; }
PORT=$(cat "$T/port")

mkdir -p "$T/home" "$T/run" "$T/cache"
env HOME="$T/home" XDG_RUNTIME_DIR="$T/run" XDG_CACHE_HOME="$T/cache" NEXO_PORT="$PORT" NEXO_TOKEN="$TOKEN" NEXO_DBUS_GRACE=1 \
    python3 "$ROOT/termux/bin/nexo-dbus" run -v >"$T/dd.log" 2>&1 &
DD=$!

echo "== playerctl $(playerctl --version 2>&1 | head -1) contra nexo-dbus"
if poll 'playerctl -l | grep -qx nexo' 10; then
    ok "playerctl -l lista el reproductor «nexo»"
else
    bad "playerctl -l no lista «nexo»" "$(playerctl -l 2>&1) | $(tail -5 "$T/dd.log")"
    echo "Resultado: $PASS bien, $FAIL con fallos"
    exit 1
fi

OUT=$(pc status);                                                         [ "$OUT" = Playing ] && ok "status = Playing" || bad "status" "$OUT"
OUT=$(pc metadata --format '{{ title }}|{{ artist }}|{{ album }}');       [ "$OUT" = 'Canción ñandú|Artista|Álbum' ] && ok "título, artista y álbum (con acentos y ñ)" || bad "metadatos" "$OUT"
OUT=$(pc metadata mpris:length);                                          [ "$OUT" = 200000000 ] && ok "mpris:length = 200000000 µs" || bad "mpris:length" "$OUT"
OUT=$(pc metadata mpris:artUrl);                                          case $OUT in file://*) ok "mpris:artUrl es una dirección file://" ;; *) bad "mpris:artUrl" "$OUT" ;; esac
OUT=$(pc metadata --format '{{ playerName }}');                           [ "$OUT" = nexo ] && ok "playerName = nexo" || bad "playerName" "$OUT"
OUT=$(pc volume);                                                         near "$OUT" 0.6 0.02 && ok "volume ≈ 0.6 (el volumen de música de Android)" || bad "volume" "$OUT"
OUT=$(pc position);                                                       near "$OUT" 30 5 && ok "position parte de donde va la canción (≈ 30 s)" || bad "position" "$OUT"

: > "$T/req"
pc next >/dev/null
poll 'grep -q "media.next" "$T/req"' 4 && ok "next llega a la app como media.next" || bad "next no llegó a la app" "$(cat "$T/req")"
pc previous >/dev/null
poll 'grep -q "media.prev" "$T/req"' 4 && ok "previous llega a la app como media.prev" || bad "previous no llegó a la app" "$(cat "$T/req")"

pc pause >/dev/null
poll '[ "$(pc status)" = Paused ]' 5 && ok "pause → status = Paused" || bad "pause" "$(pc status)"
pc play-pause >/dev/null
poll '[ "$(pc status)" = Playing ]' 5 && ok "play-pause → status = Playing" || bad "play-pause" "$(pc status)"

# (el volumen de Android va por pasos —15 en la app falsa—: 0.4 es justo el paso 6; con 0.3 quedaría en 0.33)
pc volume 0.4 >/dev/null
poll 'near "$(pc volume)" 0.4 0.02' 5 && ok "volume 0.4 cambia el volumen de Android" || bad "volume 0.4" "$(pc volume)"
pc position 90 >/dev/null
poll 'near "$(pc position)" 90 3' 5 && ok "position 90 salta a los 90 s (SetPosition)" || bad "position 90" "$(pc position)"
pc position 10+ >/dev/null
poll 'near "$(pc position)" 100 4' 5 && ok "position 10+ adelanta 10 s (Seek)" || bad "position 10+" "$(pc position)"

echo
echo "Resultado: $PASS bien, $FAIL con fallos"
[ "$FAIL" -eq 0 ]
