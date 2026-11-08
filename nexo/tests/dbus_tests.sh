# Pruebas de nexo-dbus (MPRIS sobre D-Bus). No se ejecuta solo: lo carga tests/run_tests.sh (usa sus ok/bad/run/has/…).
# Usa un dbus-daemon de verdad y, como CLIENTES independientes, busctl (sd-bus) y gdbus (GLib): si ellos entienden
# lo que dice nexo-dbus, lo entenderán playerctl, Waybar, KDE y GNOME. La app Nexo es la app falsa de siempre.

echo "== nexo-dbus: sintaxis, versión y ayuda"
DD=$T/bin/nexo-dbus
cp "$ROOT/termux/bin/nexo-dbus" "$DD"
chmod +x "$DD"
if python3 - "$ROOT/termux/bin/nexo-dbus" 2>"$T/err" <<'PY'
import ast, sys
ast.parse(open(sys.argv[1], encoding="utf-8").read(), feature_version=(3, 7))
PY
then ok "nexo-dbus usa solo sintaxis de Python 3.7 (el de las distros más viejas)"; else bad "sintaxis de Python 3.7" "$(cat "$T/err")"; fi
CLIENT_VERSION=$(sed -n 's/^NEXO_VERSION="\(.*\)"/\1/p' "$ROOT/termux/bin/nexo")
run python3 "$DD" version;               eq "nexo-dbus version = la del cliente" "nexo-dbus $CLIENT_VERSION"
run python3 "$DD" help;                  has "help explica qué es" "reproductor MPRIS"
run python3 "$DD";                       rc_is "sin argumentos enseña la ayuda (0)" 0
run python3 "$DD" cosas;                 rc_is "comando desconocido → uso (2)" 2
run python3 "$DD" run --raro;            rc_is "opción desconocida → uso (2)" 2
run python3 "$DD" run --bus;             rc_is "--bus sin valor → uso (2)" 2
run env -i PATH="$PATH" HOME="$T/nohome" XDG_RUNTIME_DIR="$T/nohome" python3 "$DD" run
rc_is "sin token ni enlace → 11" 11
has "…y dice cómo enlazar" "nexo pair"
# nexo-dbus también mira /run/user/UID/bus: en un PC con escritorio ese bus existe y las pruebas de «sin bus» no valen
if [ -S "/run/user/$(id -u)/bus" ]; then
    NOBUS=0
    echo "  --    esta máquina tiene un bus de sesión real en /run/user/$(id -u)/bus: se omiten las pruebas de «sin bus»"
else
    NOBUS=1
fi
if [ "$NOBUS" = 1 ]; then
run env -i PATH="$PATH" HOME="$T/nohome" XDG_RUNTIME_DIR="$T/nohome" NEXO_TOKEN=00ff python3 "$DD" run
rc_is "con token pero sin bus de sesión → 3" 3
has "…y explica qué hacer" "dbus-run-session"
run env -i PATH="$PATH" HOME="$T/nohome" XDG_RUNTIME_DIR="$T/nohome" python3 "$DD" env
rc_is "env sin bus → 3" 3
fi
run env -i PATH="$PATH" HOME="$T/nohome" XDG_RUNTIME_DIR="$T/nohome" DBUS_SESSION_BUS_ADDRESS="unix:path=/x'y" python3 "$DD" env
eq "env imprime una línea para eval (con comillas a salvo)" "export DBUS_SESSION_BUS_ADDRESS='unix:path=/x'\\''y'"

# ------------------------------------------------------------------------------ nexo setup-dbus / nexo dbus
echo "== nexo setup-dbus y nexo dbus (arranque automático; sin bus real)"
SD=$T/sd
mkdir -p "$SD/bin" "$SD/home" "$SD/stubs" "$SD/solo"
cp "$ROOT/termux/bin/nexo" "$SD/bin/nexo"
cp "$ROOT/termux/bin/nexo-dbus" "$SD/bin/nexo-dbus"
cp "$ROOT/termux/bin/nexo" "$SD/solo/nexo"
chmod +x "$SD/bin/nexo" "$SD/bin/nexo-dbus" "$SD/solo/nexo"
# systemctl falso: «show-environment» dice si hay gestor de usuario (SD_SYSTEMD=1 → sí); lo demás se anota
cat > "$SD/stubs/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${SD_LOG:-/dev/null}"
[ "${2:-}" = show-environment ] && [ "${SD_SYSTEMD:-0}" != 1 ] && exit 1
exit 0
STUB
chmod +x "$SD/stubs/systemctl"
sdn() { env -i PATH="$SD/stubs:$SD/bin:$PATH" HOME="$SD/home" XDG_CACHE_HOME="$SD/cache" XDG_RUNTIME_DIR="$SD/run" SD_LOG="$SD/systemctl.log" "$@"; }
DK=$SD/home/.config/autostart/nexo-dbus.desktop
UN=$SD/home/.config/systemd/user/nexo-dbus.service
: > "$SD/systemctl.log"

run sdn NEXO_TOKEN="$TOKEN" "$SD/bin/nexo" setup-dbus --no-start
rc_is "setup-dbus (sin systemd de usuario) termina bien" 0
has "…usa el arranque automático del escritorio" "arranque automático del escritorio"
[ -f "$DK" ] && ok "…y deja el .desktop en ~/.config/autostart" || bad ".desktop" "$OUT $ERR"
grep -qx "Exec=$SD/bin/nexo-dbus start" "$DK" && ok "…que lo arranca con su ruta completa" || bad "Exec del .desktop" "$(cat "$DK" 2>/dev/null)"
[ ! -e "$UN" ] && ok "…sin crear un servicio de systemd" || bad "creó el servicio sin systemd"
run sdn "$SD/bin/nexo-dbus" status;               rc_is "--no-start no lo arranca" 1

: > "$SD/systemctl.log"
run sdn SD_SYSTEMD=1 NEXO_TOKEN="$TOKEN" "$SD/bin/nexo" setup-dbus --no-start
rc_is "setup-dbus con systemd de usuario termina bien" 0
has "…lo cuenta" "systemd (usuario)"
[ -f "$UN" ] && ok "…y deja el servicio en ~/.config/systemd/user" || bad "servicio de systemd" "$OUT $ERR"
grep -qx "ExecStart=$SD/bin/nexo-dbus run" "$UN" && ok "…que ejecuta «nexo-dbus run» con su ruta completa" || bad "ExecStart" "$(cat "$UN" 2>/dev/null)"
grep -qx 'Restart=on-failure' "$UN" && grep -qx 'WantedBy=default.target' "$UN" && ok "…con reinicio si falla y arranque con la sesión" || bad "unidad" "$(cat "$UN" 2>/dev/null)"
[ ! -e "$DK" ] && ok "…y quita el .desktop de antes (el arranque es uno solo)" || bad "quedó el .desktop"
grep -q -- '--user daemon-reload' "$SD/systemctl.log" && ok "…y le pide a systemd que relea las unidades" || bad "daemon-reload" "$(cat "$SD/systemctl.log")"
grep -q -- ' enable \| restart ' "$SD/systemctl.log" && bad "--no-start no debería activar ni arrancar nada" "$(cat "$SD/systemctl.log")" || ok "con --no-start no activa ni arranca el servicio"

: > "$SD/systemctl.log"
run sdn SD_SYSTEMD=1 NEXO_TOKEN="$TOKEN" "$SD/bin/nexo" setup-dbus
rc_is "sin --no-start lo deja en marcha" 0
has "…con systemd" "nexo-dbus en marcha (systemd)"
grep -q -- '--user enable nexo-dbus.service' "$SD/systemctl.log" && grep -q -- '--user restart nexo-dbus.service' "$SD/systemctl.log" && ok "…activándolo y (re)arrancándolo" || bad "enable/restart" "$(cat "$SD/systemctl.log")"
has "…y dice cómo probarlo" "playerctl -l"

printf '#!/bin/sh\necho antes\nexec startx\n' > "$SD/xstartup"
run sdn SD_SYSTEMD=1 NEXO_TOKEN="$TOKEN" "$SD/bin/nexo" setup-dbus --no-start --launcher "$SD/xstartup"
rc_is "--launcher añade el arranque a un script tuyo" 0
has "…y dice dónde lo puso" "antes de su línea «exec» (la 3)"
[ "$(sed -n 1,2p "$SD/xstartup" | tr '\n' '|')" = '#!/bin/sh|echo antes|' ] && [ "$(tail -n 1 "$SD/xstartup")" = 'exec startx' ] && ok "…antes del «exec» (lo que viene después de un exec no se ejecuta)" || bad "posición del bloque" "$(cat "$SD/xstartup")"
grep -qx "$SD/bin/nexo-dbus start >/dev/null 2>&1" "$SD/xstartup" && ok "…con la orden «nexo-dbus start»" || bad "orden del bloque" "$(cat "$SD/xstartup")"
[ ! -e "$UN" ] && ok "…y quita el servicio de systemd de antes" || bad "quedó el servicio"
run sdn NEXO_TOKEN="$TOKEN" "$SD/bin/nexo" setup-dbus --no-start --launcher "$SD/xstartup"
[ "$(grep -c '^# >>> nexo-dbus' "$SD/xstartup")" = 1 ] && ok "repetirlo no duplica el bloque (idempotente)" || bad "bloque duplicado" "$(cat "$SD/xstartup")"
run sdn NEXO_TOKEN="$TOKEN" "$SD/bin/nexo" setup-dbus --uninstall
rc_is "--uninstall" 0
has "…cuenta que quitó el bloque" "quité el bloque de nexo-dbus de $SD/xstartup"
printf '#!/bin/sh\necho antes\nexec startx\n' | cmp -s - "$SD/xstartup" && ok "…y el script queda exactamente como estaba" || bad "el script no quedó igual" "$(cat "$SD/xstartup")"
[ ! -e "$SD/home/.config/nexo/dbus-launchers" ] && ok "…sin dejar su registro" || bad "quedó el registro de launchers"

printf 'echo uno' > "$SD/sin-exec"
run sdn NEXO_TOKEN="$TOKEN" "$SD/bin/nexo" setup-dbus --no-start --launcher "$SD/sin-exec"
has "un script sin «exec» recibe el bloque al final" "al final"
[ "$(head -n 1 "$SD/sin-exec")" = 'echo uno' ] && [ "$(sed -n 2p "$SD/sin-exec")" = "# >>> nexo-dbus (lo añadió «nexo setup-dbus --launcher»; se quita con «nexo setup-dbus --uninstall») >>>" ] && ok "…sin comerse la última línea aunque no acabara en salto de línea" || bad "script sin salto final" "$(cat "$SD/sin-exec")"
run sdn NEXO_TOKEN="$TOKEN" "$SD/bin/nexo" setup-dbus --no-start --launcher "$SD/nuevo/dir/arranque.sh"
[ "$(grep -c '^# >>> nexo-dbus' "$SD/nuevo/dir/arranque.sh" 2>/dev/null)" = 1 ] && ok "con un archivo que no existe lo crea (solo con el bloque)" || bad "launcher nuevo"
run sdn NEXO_TOKEN="$TOKEN" "$SD/bin/nexo" setup-dbus --uninstall
[ "$(cat "$SD/sin-exec")" = 'echo uno' ] && ! grep -q 'nexo-dbus' "$SD/nuevo/dir/arranque.sh" && ok "--uninstall limpia todos los archivos a los que se había añadido" || bad "--uninstall de varios launchers" "$(cat "$SD/sin-exec")"

run sdn SD_SYSTEMD=1 NEXO_TOKEN="$TOKEN" "$SD/bin/nexo" setup-dbus --no-start
: > "$SD/systemctl.log"
run sdn SD_SYSTEMD=1 NEXO_TOKEN="$TOKEN" "$SD/bin/nexo" setup-dbus --uninstall
[ ! -e "$UN" ] && ok "--uninstall quita el servicio de systemd" || bad "quedó el servicio"
grep -q 'disable --now nexo-dbus.service' "$SD/systemctl.log" && ok "…después de pararlo y desactivarlo" || bad "disable --now" "$(cat "$SD/systemctl.log")"

run sdn "$SD/bin/nexo" setup-dbus --no-start;                           rc_is "sin enlace con la app → 11" 11
run sdn NEXO_TOKEN="$TOKEN" "$SD/bin/nexo" setup-dbus --raro;           rc_is "una opción rara → uso (2)" 2
run sdn NEXO_TOKEN="$TOKEN" "$SD/bin/nexo" setup-dbus --launcher;       rc_is "--launcher sin archivo → uso (2)" 2
run env -i PATH="/usr/bin:/bin" HOME="$SD/home" NEXO_TOKEN="$TOKEN" "$SD/solo/nexo" setup-dbus --no-start
rc_is "sin nexo-dbus a la vista → error (1)" 1
has "…y dice cómo conseguirlo" "No encuentro nexo-dbus"

run sdn "$SD/bin/nexo" dbus version;                                    eq "«nexo dbus version» pasa la orden a nexo-dbus" "nexo-dbus $CLIENT_VERSION"
run sdn "$SD/bin/nexo" dbus status;                                     rc_is "«nexo dbus status» con nexo-dbus parado → 1" 1
has "…y lo dice" "parado"
run env -i PATH="/usr/bin:/bin" HOME="$SD/home" "$SD/solo/nexo" dbus status
rc_is "«nexo dbus» sin nexo-dbus → error (1)" 1

# python3 y dbus-daemon que faltan: se instalan con el gestor de la distro (aquí, uno FALSO que solo anota)
mkdir -p "$SD/mini" "$SD/pystubs"
for t in bash env cat sed grep mkdir rm dirname basename readlink tail head mktemp id stat tr sleep timeout chmod mv cp date wc sort cut ln ls touch tee uname true false; do
    p=$(command -v "$t" 2>/dev/null); case $p in /*) ln -sf "$p" "$SD/mini/$t" ;; esac
done
cat > "$SD/pystubs/sudo" <<'STUB'
#!/usr/bin/env bash
exec "$@"
STUB
cat > "$SD/pystubs/apt-get" <<'STUB'
#!/usr/bin/env bash
echo "apt-get $*" >> "$SD_LOG"
case " $* " in *" install "*python3*) ln -sf "$SD_REAL_PY" "$SD_PYDIR/python3" ;; esac
exit 0
STUB
cat > "$SD/pystubs/pacman" <<'STUB'
#!/usr/bin/env bash
echo "pacman $*" >> "$SD_LOG"
case " $* " in *" python "*) ln -sf "$SD_REAL_PY" "$SD_PYDIR/python3" ;; esac
exit 0
STUB
chmod +x "$SD/pystubs/sudo" "$SD/pystubs/apt-get" "$SD/pystubs/pacman"
sdm() { env -i PATH="$SD/pystubs:$SD/mini" HOME="$SD/home" SD_LOG="$SD/pkg.log" SD_REAL_PY="$(command -v python3)" SD_PYDIR="$SD/pystubs" "$@"; }
: > "$SD/pkg.log"
mv "$SD/pystubs/pacman" "$SD/pacman.off"
run sdm NEXO_TOKEN="$TOKEN" "$SD/bin/nexo" setup-dbus --no-start
rc_is "sin python3, setup-dbus lo instala con el gestor de la distro" 0
has "…lo cuenta" "Instalando python3"
grep -q 'apt-get install -y -qq python3' "$SD/pkg.log" && ok "…con apt-get y el paquete «python3»" || bad "apt-get" "$(cat "$SD/pkg.log")"
run sdn NEXO_TOKEN="$TOKEN" "$SD/bin/nexo" setup-dbus --uninstall
rm -f "$SD/pystubs/python3" "$SD/pystubs/apt-get"; mv "$SD/pacman.off" "$SD/pystubs/pacman"
: > "$SD/pkg.log"
run sdm NEXO_TOKEN="$TOKEN" "$SD/bin/nexo" setup-dbus --no-start
rc_is "(Arch) sin python3 lo instala con pacman" 0
grep -q 'pacman -S --needed --noconfirm python$' "$SD/pkg.log" && ok "…y el paquete se llama «python», no «python3»" || bad "pacman" "$(cat "$SD/pkg.log")"
run sdn NEXO_TOKEN="$TOKEN" "$SD/bin/nexo" setup-dbus --uninstall
rm -f "$SD/pystubs/python3" "$SD/pystubs/pacman"
run sdm NEXO_TOKEN="$TOKEN" "$SD/bin/nexo" setup-dbus --no-start
rc_is "sin python3 y sin gestor de paquetes → error (1)" 1
has "…y dice qué paquete instalar" "paquete «python3»"
[ ! -e "$DK" ] && ok "…sin dejar nada a medias" || bad "dejó el .desktop"
ln -sf "$(command -v python3)" "$SD/pystubs/python3"
run sdm NEXO_TOKEN="$TOKEN" "$SD/bin/nexo" setup-dbus --no-start --own-bus
rc_is "--own-bus sin dbus-daemon ni gestor de paquetes → error (1)" 1
has "…y dice qué paquete instalar" "paquete «dbus»"
printf '#!/bin/sh\nexit 0\n' > "$SD/pystubs/dbus-daemon"; chmod +x "$SD/pystubs/dbus-daemon"
run sdm NEXO_TOKEN="$TOKEN" "$SD/bin/nexo" setup-dbus --no-start --own-bus
rc_is "--own-bus con dbus-daemon" 0
grep -qx "Exec=$SD/bin/nexo-dbus start --own-bus" "$DK" && ok "…guarda --own-bus en el arranque automático" || bad "--own-bus en el .desktop" "$(cat "$DK" 2>/dev/null)"
run sdn NEXO_TOKEN="$TOKEN" "$SD/bin/nexo" setup-dbus --uninstall

# doctor
mkdir -p "$SD/old/bin"
cp "$SD/bin/nexo" "$SD/old/bin/nexo"
sed 's/^VERSION = ".*"/VERSION = "0.0.9"/' "$ROOT/termux/bin/nexo-dbus" > "$SD/old/bin/nexo-dbus"
chmod +x "$SD/old/bin/nexo" "$SD/old/bin/nexo-dbus"
run sdn NEXO_TOKEN="$TOKEN" NEXO_PORT=1 "$SD/bin/nexo" doctor
has "doctor cuenta el estado de nexo-dbus" "nexo-dbus  $SD/bin/nexo-dbus $CLIENT_VERSION — parado"
run env -i PATH="$SD/stubs:$PATH" HOME="$SD/home" XDG_CACHE_HOME="$SD/cache" XDG_RUNTIME_DIR="$SD/run" NEXO_TOKEN="$TOKEN" NEXO_PORT=1 "$SD/old/bin/nexo" doctor
has "…y avisa si es de otra versión que el cliente" "es de otra versión que el cliente"
run env -i PATH="/usr/bin:/bin" HOME="$SD/home" NEXO_TOKEN="$TOKEN" NEXO_PORT=1 "$SD/solo/nexo" doctor
has "…o que no está instalado" "nexo-dbus  no instalado"

if [ "${NEXO_TESTS_DBUS:-}" = skip ]; then
    echo "  --    NEXO_TESTS_DBUS=skip: se omiten las pruebas con un bus D-Bus real (corren en el trabajo «dbus» de GitHub Actions)"
elif ! command -v dbus-daemon >/dev/null 2>&1 || ! command -v busctl >/dev/null 2>&1 || ! command -v gdbus >/dev/null 2>&1; then
    echo "  --    faltan dbus-daemon, busctl o gdbus: se omiten las pruebas con un bus real (el trabajo «dbus» de GitHub Actions sí las corre)"
else

DB=$T/dbus
mkdir -p "$DB/run" "$DB/cache" "$DB/home"
BUS_SOCK=$DB/bus
BUS_PID=""
DD_PID=""
MP=org.mpris.MediaPlayer2.nexo
MPP=/org/mpris/MediaPlayer2
MPI=org.mpris.MediaPlayer2.Player
MPR=org.mpris.MediaPlayer2
export DBUS_SESSION_BUS_ADDRESS="unix:path=$BUS_SOCK"
DD_OPTS=(-v)

bus_start() {
    local i
    rm -f "$BUS_SOCK"
    cat > "$DB/bus.conf" <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path=$BUS_SOCK</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
EOF
    dbus-daemon --config-file="$DB/bus.conf" --nofork --nopidfile >"$DB/bus.log" 2>&1 &
    BUS_PID=$!
    APP_PIDS+=("$BUS_PID")
    for i in $(seq 50); do [ -S "$BUS_SOCK" ] && return 0; sleep 0.1; done
    return 1
}
bus_stop() { [ -n "$BUS_PID" ] && { kill "$BUS_PID" 2>/dev/null; wait "$BUS_PID" 2>/dev/null; }; BUS_PID=""; rm -f "$BUS_SOCK"; }

# dd_start NOMBRE PUERTO [VAR=VAL…] → nexo-dbus run en segundo plano, con un entorno limpio y esperas cortas
dd_start() {
    local name=$1 port=$2
    shift 2
    env -i PATH="$PATH" HOME="$DB/home" XDG_RUNTIME_DIR="$DB/run" XDG_CACHE_HOME="$DB/cache" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$BUS_SOCK" NEXO_PORT="$port" NEXO_TOKEN="${DD_TOKEN:-$TOKEN}" \
        NEXO_DBUS_GRACE=1 NEXO_DBUS_GRACE_DOWN=2 "$@" python3 "$DD" run "${DD_OPTS[@]}" >"$DB/$name.log" 2>&1 &
    DD_PID=$!
    APP_PIDS+=("$DD_PID")
}
dd_stop() {
    [ -n "$DD_PID" ] && { kill "$DD_PID" 2>/dev/null; wait "$DD_PID" 2>/dev/null; }
    DD_PID=""
    rm -f "$DB/run/nexo-dbus.pid"
}

has_name() { busctl --user --no-legend list 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }
# poll 'COMANDO' SEGUNDOS → espera (hasta SEGUNDOS) a que el comando salga bien
poll() { local i; for i in $(seq $(($2 * 10))); do eval "$1" >/dev/null 2>&1 && return 0; sleep 0.1; done; return 1; }
wait_name() { poll "has_name $1" "${2:-6}"; }
wait_gone() { poll "! has_name $1" "${2:-8}"; }
# pj INTERFAZ PROPIEDAD → el valor de la propiedad en JSON
pj() { busctl --user --json=short get-property "$MP" "$MPP" "$1" "$2" 2>/dev/null | jq -c '.data | if type == "number" then . + 0 else . end'; }
pl() { pj "$MPI" "$1"; }                                   # propiedad del reproductor
md() { busctl --user --json=short get-property "$MP" "$MPP" "$MPI" Metadata 2>/dev/null; }
mcall() { busctl --user call "$MP" "$MPP" "$MPI" "$@" 2>&1; }   # llamada a un método de Player
app() { NEXO_PORT=$1 NEXO_TOKEN=$TOKEN "$NEXO" "${@:2}"; }                     # el cliente contra una app falsa concreta
nmon() { grep -c -- "$2" "$1" 2>/dev/null || true; }

bus_start && ok "arranca un dbus-daemon de pruebas" || bad "dbus-daemon de pruebas"

# ------------------------------------------------------------------------------ la sonda de tipos D-Bus
echo "== nexo-dbus: los tipos D-Bus los entiende un cliente de verdad (busctl)"
python3 "$ROOT/tests/dbus_probe.py" "$ROOT/termux/bin/nexo-dbus" "$DBUS_SESSION_BUS_ADDRESS" >"$DB/probe.log" 2>&1 &
PROBE_PID=$!
APP_PIDS+=("$PROBE_PID")
if poll "has_name org.nexo.Test" 6; then
    bc() { busctl --user --json=short call org.nexo.Test /org/nexo/Test org.nexo.Test "$@" 2>&1; }
    # bcj MÉTODO FIRMA ARGS… ESPERADO(jq) → llama y comprueba el JSON de la respuesta
    bcj() {
        local m=$1 expect=${!#}
        local args=("${@:2:$#-2}")
        OUT=$(bc "$m" "${args[@]}")
        if printf '%s' "$OUT" | jq -e "$expect" >/dev/null 2>&1; then ok "tipo $m"; else bad "tipo $m" "salió [$OUT]"; fi
    }
    bcj Echo_y y 200 '.data == [200]'
    bcj Echo_b b true '.data == [true]'
    bcj Echo_n n -- -5 '.data == [-5]'
    bcj Echo_q q 65535 '.data == [65535]'
    bcj Echo_i i -- -123456 '.data == [-123456]'
    bcj Echo_u u 4000000000 '.data == [4000000000]'
    bcj Echo_x x -- -9000000000 '.data == [-9000000000]'
    bcj Echo_d d 3.5 '.data == [3.5]'
    bcj Echo_s s "Canción ñandú ✓" '.data == ["Canción ñandú ✓"]'
    bcj Echo_s s "" '.data == [""]'
    bcj Echo_o o /a/b '.data == ["/a/b"]'
    bcj Echo_g g "a{sv}" '.data == ["a{sv}"]'
    bcj Echo_v v s hola '.data == [{"type":"s","data":"hola"}]'
    bcj Echo_ai ai 3 1 2 3 '.data == [[1,2,3]]'
    bcj Echo_as as 2 hola mundo '.data == [["hola","mundo"]]'
    bcj Echo_ay ay 4 1 2 3 4 '.data == [[1,2,3,4]]'
    bcj Echo_ad ad 3 1.5 2.5 3.5 '.data == [[1.5,2.5,3.5]]'
    bcj Echo_at at 2 1 2 '.data == [[1,2]]'
    bcj Echo_aDsvE "a{sv}" 2 x s uno y i 5 '.data == [{"x":{"type":"s","data":"uno"},"y":{"type":"i","data":5}}]'
    bcj Echo_aDssE "a{ss}" 2 k1 v1 k2 v2 '.data == [{"k1":"v1","k2":"v2"}]'
    bcj Echo_SsiT "(si)" hola 7 '.data == [["hola",7]]'
    bcj Echo_aSsiT "a(si)" 2 a 1 b 2 '.data == [[["a",1],["b",2]]]'
    bcj Echo_aai aai 2 2 1 2 1 9 '.data == [[[1,2],[9]]]'
    bcj Echo_ao ao 2 /x /y/z '.data == [["/x","/y/z"]]'
    bcj Echo_aDsaDsvEE "a{sa{sv}}" 1 iface 1 prop s val '.data == [{"iface":{"prop":{"type":"s","data":"val"}}}]'
    bcj Echo_aSsaDsvET "a(sa{sv})" 1 hola 1 k b true '.data == [[["hola",{"k":{"type":"b","data":true}}]]]'
    bcj Echo_SysaDsvEasT "(ysa{sv}as)" 5 hola 1 k i 3 2 a b '.data == [[5,"hola",{"k":{"type":"i","data":3}},["a","b"]]]'
    bcj Echo_aDoaDsaDsvEEE "a{oa{sa{sv}}}" 1 /org/x 1 org.i 1 p s v '.data == [{"/org/x":{"org.i":{"p":{"type":"s","data":"v"}}}}]'
    bcj Multi su hola 41 '.type == "sub" and .data == ["hola!",42,true]'
    BIG=$(python3 -c "print('ñ' * 50000)")
    OUT=$(bc Echo_s s "$BIG")
    printf '%s' "$OUT" | jq -e --arg b "$BIG" '.data == [$b]' >/dev/null 2>&1 && ok "una cadena de 50 000 letras (100 KB)" || bad "cadena grande"
    OUT=$(bc Echo_at at 20000 $(seq 0 19999))
    printf '%s' "$OUT" | jq -e '.data[0] | length == 20000 and .[19999] == 19999' >/dev/null 2>&1 && ok "un array de 20 000 enteros de 64 bits" || bad "array grande"
    OUT=$(bc Echo_s)
    case $OUT in *"Too few"*|*"parameters"*|*"rror"*) ok "una llamada con argumentos de menos la rechaza el cliente, no rompe nada" ;; *) ok "llamada sin argumentos tolerada" ;; esac
    OUT=$(busctl --user call org.nexo.Test /org/nexo/Test org.nexo.Test Echo_s i 5 2>&1)
    case $OUT in *"espera"*) ok "una firma equivocada da un error D-Bus claro (InvalidArgs)" ;; *) bad "firma equivocada" "$OUT" ;; esac
    OUT=$(gdbus call --session --dest org.nexo.Test --object-path /org/nexo/Test --method org.freedesktop.DBus.Peer.Ping 2>&1)
    [ $? -eq 0 ] && ok "Peer.Ping (gdbus)" || bad "Peer.Ping" "$OUT"
    OUT=$(gdbus call --session --dest org.nexo.Test --object-path /org/nexo/Test --method org.freedesktop.DBus.Peer.GetMachineId 2>&1)
    case $OUT in "('"*"',)") ok "Peer.GetMachineId (gdbus)" ;; *) bad "GetMachineId" "$OUT" ;; esac
    OUT=$(gdbus introspect --session --dest org.nexo.Test --object-path / 2>&1)
    case $OUT in *"node org {"*) ok "la raíz «/» se puede explorar y muestra el nodo hijo «org»" ;; *) bad "introspección de la raíz" "$OUT" ;; esac
else
    bad "arranca la sonda de tipos" "$(cat "$DB/probe.log")"
fi
kill "$PROBE_PID" 2>/dev/null; wait "$PROBE_PID" 2>/dev/null

# ------------------------------------------------------------------------------ escenario A: todo en marcha
echo "== nexo-dbus: el reproductor MPRIS (busctl y gdbus como clientes)"
APORT=$(start_app dbusA)
dd_start A "$APORT"
A_PID=$DD_PID
if wait_name "$MP" 8; then
    ok "el reproductor aparece en el bus de sesión como $MP"
else
    bad "el reproductor no aparece" "$(cat "$DB/A.log")"
fi
[ "$(pl PlaybackStatus)" = '"Playing"' ] && ok "PlaybackStatus = Playing" || bad "PlaybackStatus" "$(pl PlaybackStatus)"
md | jq -e '.data["xesam:title"].data == "Canción ñandú" and .data["xesam:artist"].data == ["Artista"] and .data["xesam:album"].data == "Álbum" and .data["xesam:albumArtist"].data == ["Artista"]' >/dev/null 2>&1 \
    && ok "Metadata: título, artista y álbum (con acentos y ñ)" || bad "Metadata" "$(md)"
md | jq -e '.data["mpris:length"].type == "x" and .data["mpris:length"].data == 200000000' >/dev/null 2>&1 && ok "Metadata: mpris:length en microsegundos (tipo x)" || bad "mpris:length"
md | jq -e '.data["mpris:trackid"].type == "o" and (.data["mpris:trackid"].data | test("^/org/nexo/track/[0-9a-f]+$"))' >/dev/null 2>&1 && ok "Metadata: mpris:trackid es una ruta de objeto válida" || bad "mpris:trackid"
md | jq -e '.data["xesam:artist"].type == "as"' >/dev/null 2>&1 && ok "Metadata: xesam:artist es una lista de cadenas (as)" || bad "tipo de xesam:artist"
ART=$(md | jq -r '.data["mpris:artUrl"].data // empty')
case $ART in file://*) ok "Metadata: mpris:artUrl es una dirección file://" ;; *) bad "mpris:artUrl" "[$ART]" ;; esac
[ -s "${ART#file://}" ] && [ "$(od -An -tx1 -N3 "${ART#file://}" | tr -d ' \n')" = ffd8ff ] && ok "…y apunta a la carátula guardada (un JPEG)" || bad "archivo de la carátula" "${ART#file://}"
[ "$(stat -c %a "$DB/cache/nexo/art")" = 700 ] && ok "…en un directorio solo del usuario (700)" || bad "modo del directorio de carátulas"
[ "$(pj "$MPR" Identity)" = '"Reproductor falso"' ] && ok "Identity = el nombre de la app que suena" || bad "Identity" "$(pj "$MPR" Identity)"
[ "$(pj "$MPR" CanQuit)" = false ] && [ "$(pj "$MPR" CanRaise)" = false ] && [ "$(pj "$MPR" HasTrackList)" = false ] && ok "CanQuit, CanRaise y HasTrackList = false" || bad "propiedades de la raíz"
[ "$(pl CanControl)" = true ] && [ "$(pl CanPlay)" = true ] && [ "$(pl CanPause)" = true ] && [ "$(pl CanSeek)" = true ] && [ "$(pl CanGoNext)" = true ] && [ "$(pl CanGoPrevious)" = true ] && ok "CanControl, CanPlay, CanPause, CanSeek, CanGoNext y CanGoPrevious = true" || bad "propiedades Can*"
[ "$(pl Rate)" = 1 ] && [ "$(pl MinimumRate)" = 1 ] && [ "$(pl MaximumRate)" = 1 ] && ok "Rate, MinimumRate y MaximumRate = 1" || bad "Rate" "$(pl Rate)"
[ "$(pl Volume)" = 0.6 ] && ok "Volume = el volumen de música de Android (0.6)" || bad "Volume" "$(pl Volume)"
P1=$(pl Position); sleep 1; P2=$(pl Position)
[ "$P1" -ge 30000000 ] 2>/dev/null && ok "Position parte de donde va la canción ($P1 µs)" || bad "Position inicial" "$P1"
[ $((P2 - P1)) -ge 800000 ] && [ $((P2 - P1)) -le 1500000 ] && ok "…y avanza con el reloj mientras suena (+$((P2 - P1)) µs en 1 s)" || bad "Position no avanza" "$P1 → $P2"
OUT=$(gdbus call --session --dest "$MP" --object-path "$MPP" --method org.freedesktop.DBus.Properties.GetAll "$MPI" 2>&1)
case $OUT in *"'PlaybackStatus': <'Playing'>"*"'CanControl': <true>"*) ok "Properties.GetAll (gdbus) devuelve el estado completo" ;; *) bad "GetAll" "$OUT" ;; esac
n=$(printf '%s' "$OUT" | grep -o "'[A-Za-z]*': <" | wc -l)
[ "$n" -eq 13 ] && ok "…las 13 obligatorias de MPRIS (LoopStatus y Shuffle son opcionales y Nexo no las ofrece)" || bad "número de propiedades" "$n"
OUT=$(gdbus call --session --dest "$MP" --object-path "$MPP" --method org.freedesktop.DBus.Properties.GetAll "" 2>&1)
case $OUT in *"'Identity'"*"'PlaybackStatus'"*) ok "GetAll con interfaz vacía junta todas" ;; *) bad "GetAll con interfaz vacía" "$OUT" ;; esac
OUT=$(gdbus introspect --session --dest "$MP" --object-path "$MPP" 2>&1)
case $OUT in *"interface org.mpris.MediaPlayer2.Player"*"PlayPause"*"readwrite Volume"*|*"interface org.mpris.MediaPlayer2.Player"*"PlayPause"*"Volume"*) ok "gdbus introspect muestra la interfaz Player con sus métodos" ;; *) bad "introspección" "$OUT" ;; esac
case $OUT in *"interface org.mpris.MediaPlayer2 "*|*"interface org.mpris.MediaPlayer2 {"*) ok "…y la interfaz raíz org.mpris.MediaPlayer2" ;; *) bad "interfaz raíz" "$OUT" ;; esac
OUT=$(gdbus introspect --session --dest "$MP" --object-path / 2>&1)
case $OUT in *"node org {"*) ok "el árbol de objetos se puede recorrer desde «/»" ;; *) bad "árbol desde la raíz" "$OUT" ;; esac

: > "$DB/mon.txt"
gdbus monitor --session --dest "$MP" >"$DB/mon.txt" 2>&1 &
MON_PID=$!
APP_PIDS+=("$MON_PID")
sleep 0.5

OUT=$(mcall PlayPause); [ $? -eq 0 ] && ok "PlayPause (llamada D-Bus) responde" || bad "PlayPause" "$OUT"
poll '[ "$(pl PlaybackStatus)" = "\"Paused\"" ]' 3 && ok "…y la canción queda en pausa" || bad "tras PlayPause" "$(pl PlaybackStatus)"
OUT=$(app "$APORT" media status --json); printf '%s' "$OUT" | jq -e '.state == "paused"' >/dev/null 2>&1 && ok "…de verdad, en la app (la orden llegó a Nexo)" || bad "estado en la app tras PlayPause" "$OUT"
waitfor "$DB/mon.txt" "'PlaybackStatus': <'Paused'>" 3 && ok "se emite PropertiesChanged con PlaybackStatus = Paused" || bad "PropertiesChanged de la pausa" "$(cat "$DB/mon.txt")"
OUT=$(mcall Play); [ "$(pl PlaybackStatus)" = '"Playing"' ] && ok "Play" || bad "Play" "$OUT"
OUT=$(mcall Pause); poll '[ "$(pl PlaybackStatus)" = "\"Paused\"" ]' 3 && ok "Pause" || bad "Pause" "$OUT"
OUT=$(mcall Play)
OUT=$(mcall Next); [ $? -eq 0 ] && ok "Next responde" || bad "Next" "$OUT"
poll 'md | jq -e ".data[\"xesam:title\"].data == \"Otra canción\"" ' 3 && ok "…y cambian los metadatos (Otra canción)" || bad "metadatos tras Next" "$(md)"
poll 'md | jq -e ".data[\"mpris:artUrl\"].data | test(\"^file://\")" ' 4 && ok "…y llega la carátula nueva (segundo PropertiesChanged)" || bad "carátula tras Next" "$(md)"
md | jq -e '.data["mpris:length"].data == 180000000' >/dev/null 2>&1 && ok "…con su duración (180 s)" || bad "duración tras Next"
waitfor "$DB/mon.txt" "'xesam:title': <'Otra canci" 3 && ok "se emite PropertiesChanged con Metadata" || bad "PropertiesChanged de Metadata"
OUT=$(mcall Previous); poll 'md | jq -e ".data[\"xesam:title\"].data == \"Canción ñandú\"" ' 3 && ok "Previous" || bad "Previous" "$OUT"

S0=$(nmon "$DB/mon.txt" 'Seeked (int64')
OUT=$(mcall Seek x 10000000); [ $? -eq 0 ] && ok "Seek +10 s" || bad "Seek" "$OUT"
sleep 1
S1=$(nmon "$DB/mon.txt" 'Seeked (int64')
[ $((S1 - S0)) -eq 1 ] && ok "…emite la señal Seeked una sola vez (no repetida)" || bad "Seeked repetida o ausente" "$((S1 - S0)) señales"
TID=$(md | jq -r '.data["mpris:trackid"].data')
OUT=$(mcall SetPosition ox "$TID" 5000000); [ $? -eq 0 ] && ok "SetPosition con el trackid actual" || bad "SetPosition" "$OUT"
sleep 0.5
POS=$(pl Position)
[ "$POS" -ge 5000000 ] && [ "$POS" -lt 8000000 ] && ok "…la posición pasa a ~5 s ($POS µs)" || bad "posición tras SetPosition" "$POS"
OUT=$(mcall SetPosition ox /org/otro 100000000)
sleep 0.3
POS2=$(pl Position)
[ "$POS2" -lt 9000000 ] && ok "SetPosition con otro trackid se ignora (como pide la especificación)" || bad "SetPosition con otro trackid movió la canción" "$POS2"
OUT=$(app "$APORT" media status --json); printf '%s' "$OUT" | jq -e '.position_ms < 9000' >/dev/null 2>&1 && ok "…y la app lo confirma" || bad "posición en la app" "$OUT"

OUT=$(busctl --user set-property "$MP" "$MPP" "$MPI" Volume d 0.2 2>&1); [ $? -eq 0 ] && ok "escribir Volume (0.2)" || bad "set Volume" "$OUT"
sleep 0.5
OUT=$(app "$APORT" audio status --json); printf '%s' "$OUT" | jq -e '.volume >= 18 and .volume <= 22' >/dev/null 2>&1 && ok "…cambia el volumen de música de Android" || bad "volumen en la app" "$OUT"
waitfor "$DB/mon.txt" "'Volume': <" 3 && ok "…y se emite PropertiesChanged con Volume" || bad "PropertiesChanged de Volume"
OUT=$(busctl --user set-property "$MP" "$MPP" "$MPI" Volume d 7 2>&1)
OUT=$(app "$APORT" audio status --json); printf '%s' "$OUT" | jq -e '.volume == 100' >/dev/null 2>&1 && ok "Volume por encima de 1 se recorta a 100 %" || bad "recorte de Volume" "$OUT"

# cambios que NO pasan por D-Bus (alguien toca el móvil): llegan por los eventos de la app
M0=$(nmon "$DB/mon.txt" "PlaybackStatus")
app "$APORT" media pause >/dev/null 2>&1
poll '[ "$(pl PlaybackStatus)" = "\"Paused\"" ]' 4 && ok "una pausa hecha en el móvil se refleja sola" || bad "pausa externa" "$(pl PlaybackStatus)"
M1=$(nmon "$DB/mon.txt" "PlaybackStatus")
[ "$M1" -gt "$M0" ] && ok "…con su PropertiesChanged" || bad "señal de pausa externa"
app "$APORT" media play >/dev/null 2>&1
app "$APORT" audio volume 80 >/dev/null 2>&1
poll '[ "$(pl Volume)" = 0.8 ]' 4 && ok "un cambio de volumen en el móvil se refleja (Volume = 0.8)" || bad "volumen externo" "$(pl Volume)"
app "$APORT" audio volume mute >/dev/null 2>&1
poll '[ "$(pl Volume)" = 0 ]' 4 && ok "silenciar el móvil pone Volume = 0" || bad "silencio externo" "$(pl Volume)"
app "$APORT" audio volume unmute >/dev/null 2>&1
app "$APORT" media pause >/dev/null 2>&1
sleep 0.4
P1=$(pl Position); sleep 1; P2=$(pl Position)
[ "$P1" = "$P2" ] && ok "en pausa la posición no avanza" || bad "Position avanza en pausa" "$P1 → $P2"
app "$APORT" media play >/dev/null 2>&1

# errores bien formados
OUT=$(mcall Nada); case $OUT in *"no tiene el método"*) ok "un método que no existe da UnknownMethod" ;; *) bad "método inexistente" "$OUT" ;; esac
OUT=$(mcall Seek s hola); case $OUT in *"espera «x»"*) ok "una firma equivocada da InvalidArgs" ;; *) bad "firma equivocada" "$OUT" ;; esac
OUT=$(busctl --user call "$MP" /no/existe "$MPI" Play 2>&1); case $OUT in *"No hay ningún objeto"*) ok "un objeto que no existe da UnknownObject" ;; *) bad "objeto inexistente" "$OUT" ;; esac
OUT=$(busctl --user set-property "$MP" "$MPP" "$MPI" Rate d 2 2>&1); case $OUT in *"solo lectura"*) ok "escribir una propiedad de solo lectura da PropertyReadOnly" ;; *) bad "Rate de solo lectura" "$OUT" ;; esac
OUT=$(busctl --user set-property "$MP" "$MPP" "$MPI" Volume s hola 2>&1); case $OUT in *"tipo"*) ok "escribir con el tipo equivocado da InvalidArgs" ;; *) bad "tipo equivocado en Set" "$OUT" ;; esac
OUT=$(busctl --user get-property "$MP" "$MPP" "$MPI" Nada 2>&1); case $OUT in *"Propiedad desconocida"*) ok "una propiedad que no existe da UnknownProperty" ;; *) bad "propiedad inexistente" "$OUT" ;; esac
OUT=$(busctl --user get-property "$MP" "$MPP" org.cosas.Raras Nada 2>&1); case $OUT in *"Interfaz desconocida"*) ok "una interfaz que no existe da UnknownInterface" ;; *) bad "interfaz inexistente" "$OUT" ;; esac
OUT=$(mcall OpenUri s file:///x); case $OUT in *"no puede abrir"*) ok "OpenUri dice con claridad que no está soportado" ;; *) bad "OpenUri" "$OUT" ;; esac
OUT=$(busctl --user call "$MP" "$MPP" "$MPR" Raise 2>&1); [ $? -eq 0 ] && ok "Raise y Quit existen y no hacen nada" || bad "Raise" "$OUT"

# varios clientes a la vez
pids=()
for i in $(seq 30); do
    ( busctl --user get-property "$MP" "$MPP" "$MPI" Metadata >/dev/null 2>&1 && echo ok || echo no ) >>"$DB/par.out" &
    pids+=($!)
done
wait "${pids[@]}"
[ "$(grep -c '^ok$' "$DB/par.out")" -eq 30 ] && ok "30 clientes pidiendo Metadata a la vez: ninguno falla" || bad "concurrencia" "$(sort "$DB/par.out" | uniq -c)"
has_name "$MP" && ok "…y el reproductor sigue ahí" || bad "el reproductor desapareció"
kill "$MON_PID" 2>/dev/null; wait "$MON_PID" 2>/dev/null

# el nombre ya lo tiene otro programa (modo pasivo) / FORCE lo reclama
mkdir -p "$DB/run2" "$DB/run3"
dd_start A2 "$APORT" XDG_RUNTIME_DIR="$DB/run2"
sleep 2
grep -q "ya lo tiene otro programa" "$DB/A2.log" && ok "si otro ya tiene el nombre, nexo-dbus no lo pisa (modo pasivo)" || bad "modo pasivo" "$(cat "$DB/A2.log")"
kill -0 "$DD_PID" 2>/dev/null && ok "…y sigue vivo" || bad "murió en modo pasivo"
dd_stop
dd_start A3 "$APORT" XDG_RUNTIME_DIR="$DB/run3" NEXO_DBUS_FORCE=1
poll 'grep -q "cedo el nombre" "$DB/A.log"' 8 && ok "con NEXO_DBUS_FORCE=1 se queda el nombre y el dueño anterior lo cede" || bad "FORCE" "A=$(tail -3 "$DB/A.log") A3=$(tail -3 "$DB/A3.log")"
[ "$(pl PlaybackStatus)" = '"Playing"' ] || [ "$(pl PlaybackStatus)" = '"Paused"' ] && ok "…y el reproductor sigue respondiendo" || bad "tras FORCE"
dd_stop
kill "$A_PID" 2>/dev/null; wait "$A_PID" 2>/dev/null   # el primero cedió el nombre pero sigue vivo

# ------------------------------------------------------------------------------ escenarios de ciclo de vida
echo "== nexo-dbus: aparece y desaparece según lo que haya en Android"
wait_gone "$MP" 5
BPORT=$(start_app dbusB --no-session)
dd_start B "$BPORT"
sleep 3
has_name "$MP" && bad "sin música en Android no debe verse el reproductor" || ok "sin música en Android el reproductor no aparece"
grep -q "conectado con la app Nexo" "$DB/B.log" && ok "…aunque nexo-dbus sí está conectado a la app" || bad "conexión con la app" "$(cat "$DB/B.log")"
dd_stop
dd_start B2 "$BPORT" NEXO_DBUS_ALWAYS=1
wait_name "$MP" 6 && ok "con NEXO_DBUS_ALWAYS=1 aparece aunque no suene nada" || bad "ALWAYS" "$(cat "$DB/B2.log")"
[ "$(pl PlaybackStatus)" = '"Stopped"' ] && ok "…en estado Stopped" || bad "estado Stopped" "$(pl PlaybackStatus)"
md | jq -e '.data["mpris:trackid"].data == "/org/mpris/MediaPlayer2/TrackList/NoTrack" and (.data | length == 1)' >/dev/null 2>&1 && ok "…sin canción: solo mpris:trackid = NoTrack" || bad "metadatos vacíos" "$(md)"
[ "$(pl CanPlay)" = false ] && [ "$(pl CanControl)" = false ] && ok "…con CanPlay y CanControl en false (no hay nada que controlar)" || bad "Can* sin música" "$(pl CanPlay) $(pl CanControl)"
[ "$(pj "$MPR" Identity)" = '"Nexo"' ] && ok "…e Identity = Nexo" || bad "Identity sin música" "$(pj "$MPR" Identity)"
OUT=$(mcall Play); case $OUT in *"Call failed"*) ok "…y Play avisa de que no hay nada que reproducir" ;; *) ok "…Play sin sesión no rompe nada" ;; esac
dd_stop
wait_gone "$MP" 4 && ok "al parar nexo-dbus el nombre se libera" || bad "no liberó el nombre"

LPORT=$(start_app dbusL --no-listener)
dd_start L "$LPORT"
sleep 2.5
has_name "$MP" && bad "sin acceso a notificaciones no debe verse el reproductor" || ok "sin el acceso a notificaciones no aparece"
grep -q "acceso a notificaciones" "$DB/L.log" && grep -q "Permitir ajustes restringidos" "$DB/L.log" && ok "…y explica cómo arreglarlo (incluida la trampa de Android 13)" || bad "aviso del listener" "$(cat "$DB/L.log")"
dd_stop

OPORT=$(start_app dbusO --old)
dd_start O "$OPORT"
sleep 2.5
grep -q "no sabe de música" "$DB/O.log" && ok "con una app vieja avisa de que hay que actualizarla" || bad "aviso de app vieja" "$(cat "$DB/O.log")"
has_name "$MP" && bad "con una app vieja no debe verse el reproductor" || ok "…y no registra nada"
dd_stop

DD_TOKEN=00ff
dd_start W "$APORT"
sleep 2
grep -q "rechazó el enlace" "$DB/W.log" && ok "con un token equivocado lo dice y sugiere «nexo pair»" || bad "token equivocado" "$(cat "$DB/W.log")"
kill -0 "$DD_PID" 2>/dev/null && ok "…y no muere: sigue esperando" || bad "murió con el token malo"
has_name "$MP" && bad "token malo pero hay reproductor" || ok "…sin registrar nada"
dd_stop
DD_TOKEN=

# «nexo rekey»: cambia el token del archivo de enlace mientras nexo-dbus sigue en marcha
RKPORT=$(start_app dbusRK)
mkdir -p "$DB/runRK"
printf 'NEXO_PORT=%s\nNEXO_TOKEN=%s\n' "$RKPORT" "00ff" > "$DB/cfgRK"
env -i PATH="$PATH" HOME="$DB/home" XDG_RUNTIME_DIR="$DB/runRK" XDG_CACHE_HOME="$DB/cache" DBUS_SESSION_BUS_ADDRESS="unix:path=$BUS_SOCK" \
    NEXO_CONFIG="$DB/cfgRK" NEXO_DBUS_GRACE=1 python3 "$DD" run -v >"$DB/RK.log" 2>&1 &
DD_PID=$!
APP_PIDS+=("$DD_PID")
sleep 2
grep -q "rechazó el enlace" "$DB/RK.log" && ok "(rekey) con el token viejo la app lo rechaza y nexo-dbus lo dice" || bad "(rekey) no hubo rechazo" "$(cat "$DB/RK.log")"
has_name "$MP" && bad "(rekey) hay reproductor con un token malo" || ok "(rekey) …y no registra nada"
printf 'NEXO_PORT=%s\nNEXO_TOKEN=%s\n' "$RKPORT" "$TOKEN" > "$DB/cfgRK"
wait_name "$MP" 12 && ok "al cambiar el token en el archivo (como hace «nexo rekey»), nexo-dbus lo recoge solo y se conecta" || bad "no recogió el token nuevo" "$(tail -6 "$DB/RK.log")"
grep -q "el enlace con la app cambió" "$DB/RK.log" && ok "…y lo anota" || bad "no anotó el cambio de enlace"
dd_stop

# la app se apaga y vuelve
FPORT=$(start_app dbusF)
FPID=$(cat "$T/dbusF.pid")
dd_start F "$FPORT"
wait_name "$MP" 6 && ok "(app) el reproductor está" || bad "(app) no apareció" "$(cat "$DB/F.log")"
kill "$FPID" 2>/dev/null; wait "$FPID" 2>/dev/null
wait_gone "$MP" 10 && ok "si la app deja de responder, el reproductor se retira pasado el margen" || bad "no se retiró con la app caída" "$(tail -5 "$DB/F.log")"
grep -q "se perdió la conexión con la app" "$DB/F.log" && ok "…y lo anota" || bad "no anotó la pérdida"
OUT=$(mcall Play 2>&1); case $OUT in *"Call failed"*|*"not provided"*|*"ServiceUnknown"*|*"name"*) ok "…y Play ya no existe como servicio" ;; *) ok "(Play sin servicio)" ;; esac
start_app dbusF2 --port "$FPORT" >/dev/null
wait_name "$MP" 20 && ok "al volver la app, el reproductor vuelve solo" || bad "no volvió" "$(tail -5 "$DB/F.log")"
dd_stop

# el bus se reinicia
CPORT=$(start_app dbusC)
dd_start C "$CPORT"
wait_name "$MP" 6 && ok "(bus) el reproductor está" || bad "(bus) no apareció"
bus_stop
sleep 1
bus_start
wait_name "$MP" 15 && ok "si el bus se reinicia, nexo-dbus se reconecta y vuelve a registrarse" || bad "no se reconectó al bus" "$(tail -6 "$DB/C.log")"
grep -q "se perdió la conexión con el bus" "$DB/C.log" && ok "…y lo anota" || bad "no anotó la pérdida del bus"
dd_stop

# ------------------------------------------------------------------------------ start / stop / status / --own-bus
echo "== nexo-dbus: start, stop, status y bus propio"
SPORT=$(start_app dbusS)
sd() { env -i PATH="$PATH" HOME="$DB/home" XDG_RUNTIME_DIR="$DB/runS" XDG_CACHE_HOME="$DB/cacheS" NEXO_PORT="$SPORT" NEXO_TOKEN="$TOKEN" "$@"; }
mkdir -p "$DB/runS"
run sd python3 "$DD" status;                       rc_is "status con nexo-dbus parado → 1" 1
run sd DBUS_SESSION_BUS_ADDRESS="unix:path=$BUS_SOCK" python3 "$DD" start
rc_is "start" 0
has "…lo arranca en segundo plano" "en marcha"
wait_name "$MP" 6 && ok "…y el reproductor aparece" || bad "start no registró nada" "$(cat "$DB/cacheS/nexo/dbus.log" 2>/dev/null)"
run sd python3 "$DD" status;                       rc_is "status con nexo-dbus en marcha → 0" 0
run sd DBUS_SESSION_BUS_ADDRESS="unix:path=$BUS_SOCK" python3 "$DD" start
has "start otra vez no duplica nada" "ya está en marcha"
[ -s "$DB/cacheS/nexo/dbus.log" ] && ok "start anota en ~/.cache/nexo/dbus.log" || bad "registro de start"
run sd python3 "$DD" stop;                         rc_is "stop" 0
wait_gone "$MP" 4 && ok "…y el reproductor se va" || bad "stop no liberó el nombre"
run sd python3 "$DD" status;                       rc_is "status tras stop → 1" 1
if [ "$NOBUS" = 1 ]; then
run sd python3 "$DD" start;                        rc_is "start sin bus de sesión → 3" 3
has "…y dice qué hacer" "--own-bus"
fi

run sd python3 "$DD" start --own-bus
rc_is "start --own-bus arranca su propio bus" 0
OWN=unix:path=$DB/runS/nexo-bus
if poll "busctl --address=$OWN --no-legend list | awk '{print \$1}' | grep -qx $MP" 8; then
    ok "…y el reproductor aparece en ese bus"
else
    bad "bus propio" "$(cat "$DB/cacheS/nexo/dbus.log" 2>/dev/null)"
fi
run sd python3 "$DD" env
eq "env da la dirección del bus propio" "export DBUS_SESSION_BUS_ADDRESS='$OWN'"
run sd python3 "$DD" stop;                         rc_is "stop (con bus propio)" 0
for p in $(ps -eo pid,args | grep -F -- "--address=$OWN" | grep -v grep | awk '{print $1}'); do kill "$p" 2>/dev/null; done

# ------------------------------------------------------------------------------ nexo setup-dbus con el bus de pruebas
echo "== nexo setup-dbus de verdad (con el bus de pruebas)"
RPORT=$(start_app dbusR)
mkdir -p "$DB/runR" "$DB/homeR"
sdr() { env -i PATH="$SD/stubs:$SD/bin:$PATH" HOME="$DB/homeR" XDG_RUNTIME_DIR="$DB/runR" XDG_CACHE_HOME="$DB/cacheR" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$BUS_SOCK" NEXO_PORT="$RPORT" NEXO_TOKEN="$TOKEN" NEXO_DBUS_GRACE=1 SD_LOG="$DB/systemctlR.log" "$@"; }
run sdr "$SD/bin/nexo" setup-dbus
rc_is "setup-dbus deja nexo-dbus funcionando" 0
wait_name "$MP" 8 && ok "…y el reproductor aparece en el bus" || bad "setup-dbus no registró nada" "$(cat "$DB/cacheR/nexo/dbus.log" 2>/dev/null)"
[ -f "$DB/homeR/.config/autostart/nexo-dbus.desktop" ] && ok "…con su arranque automático" || bad "sin .desktop"
run sdr "$SD/bin/nexo" dbus status;               rc_is "«nexo dbus status» → en marcha (0)" 0
run sdr "$SD/bin/nexo" doctor
has "doctor lo ve en marcha" "nexo-dbus  $SD/bin/nexo-dbus $CLIENT_VERSION — en marcha"
PID1=$(cat "$DB/runR/nexo-dbus.pid" 2>/dev/null)
run sdr "$SD/bin/nexo" setup-dbus
rc_is "repetir setup-dbus no falla" 0
PID2=$(cat "$DB/runR/nexo-dbus.pid" 2>/dev/null)
[ -n "$PID1" ] && [ -n "$PID2" ] && [ "$PID1" != "$PID2" ] && ok "…y reinicia el servicio (así recoge una versión nueva)" || bad "no reinició" "antes $PID1, después $PID2"
wait_name "$MP" 8 && ok "…y el reproductor vuelve a verse" || bad "tras repetir setup-dbus no hay reproductor"
run sdr "$SD/bin/nexo" setup-dbus --uninstall
rc_is "--uninstall" 0
wait_gone "$MP" 6 && ok "…para el servicio y el reproductor se va" || bad "--uninstall no paró nexo-dbus"
[ ! -e "$DB/homeR/.config/autostart/nexo-dbus.desktop" ] && ok "…y quita el arranque automático" || bad "quedó el .desktop"
if [ "$NOBUS" = 1 ]; then
run env -i PATH="$SD/stubs:$SD/bin:$PATH" HOME="$DB/homeR" XDG_RUNTIME_DIR="$DB/runR2" XDG_CACHE_HOME="$DB/cacheR2" NEXO_PORT="$RPORT" NEXO_TOKEN="$TOKEN" "$SD/bin/nexo" setup-dbus
rc_is "sin bus de sesión, setup-dbus deja el arranque listo y no falla" 0
has "…y explica que se arrancará con el escritorio" "no hay bus de sesión"
run env -i PATH="$SD/stubs:$SD/bin:$PATH" HOME="$DB/homeR" XDG_RUNTIME_DIR="$DB/runR2" XDG_CACHE_HOME="$DB/cacheR2" NEXO_PORT="$RPORT" NEXO_TOKEN="$TOKEN" "$SD/bin/nexo" setup-dbus --uninstall
fi

fi   # hay dbus-daemon, busctl y gdbus
unset DBUS_SESSION_BUS_ADDRESS
