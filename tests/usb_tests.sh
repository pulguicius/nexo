# Pruebas de la parte SERIE de nexo-usb (la 0.4.1): monitor serie, puente con PTY / RFC 2217 / TCP crudo, permisos, desenchufar y volver a enchufar.
# (Los discos USB de la 0.4.2 están en tests/usb_storage_tests.sh.)
# No se ejecuta solo: lo carga tests/run_tests.sh (usa sus ok/bad/run/has/…). Necesita: bash, python3, jq.
#   NEXO_TESTS_ONLY=usb bash tests/run_tests.sh      ← solo estas (más rápido para trabajar en ellas)
#
# QUÉ SON ESTAS PRUEBAS Y QUÉ NO: hablan con la app FALSA (tests/fake_app.py), que imita a la app Android y a sus «chips» USB
# (CDC-ACM, CP210x, FTDI, CH340: un eco, un «Arduino» con su cargador STK500 y un chip mudo). Prueban el protocolo, la lógica
# de nexo-usb y los puertos que ofrece (PTY, RFC 2217, TCP). NO prueban un Arduino, un ESP32 ni un adaptador de verdad, ni el
# aviso de permiso de Android, ni avrdude/esptool/arduino-cli reales: eso solo se puede probar en el móvil (docs/USB.md).

echo "== nexo-usb: sintaxis, versión y ayuda"
UT=$T/usb
mkdir -p "$UT/home" "$UT/state" "$UT/tmp" "$UT/links"
NU=$T/bin/nexo-usb                       # (una copia ejecutable, como el cliente: ver el principio de run_tests.sh)
UCLIENT=$ROOT/tests/usb_client.py
USB_VERSION=$(sed -n 's/^NEXO_USB_VERSION = "\(.*\)"/\1/p' "$ROOT/termux/bin/nexo-usb")
: > "$UT/ctl"

if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)'; then
    if python3 -B - "$ROOT/termux/bin/nexo-usb" 2>"$T/err" <<'EOF'
import ast, sys
ast.parse(open(sys.argv[1], encoding="utf-8").read(), feature_version=(3, 7))
EOF
    then ok "nexo-usb usa solo sintaxis de Python 3.7 (el de las distros más viejas)"; else bad "sintaxis de Python 3.7 en nexo-usb" "$(cat "$T/err")"; fi
else
    echo "  (este Python es anterior al 3.8: no se comprueba la sintaxis de 3.7)"
fi
head -n 1 "$ROOT/termux/bin/nexo-usb" | grep -q '^#!/usr/bin/env python3$' && ok "nexo-usb empieza por #!/usr/bin/env python3" || bad "shebang de nexo-usb"
run python3 "$NU" version;                    has "version dice nexo-usb y su número" "nexo-usb $USB_VERSION"
[ "$USB_VERSION" = "$CLIENT_VERSION" ] && ok "nexo-usb y el cliente son de la misma versión ($USB_VERSION)" || bad "versiones distintas" "nexo-usb $USB_VERSION, cliente $CLIENT_VERSION"
run python3 "$NU" help;                       rc_is "help sale con 0" 0
has "la ayuda explica list y permit" "permit [DISPOSITIVO]"
has "…monitor y bridge" "bridge [DISPOSITIVO]"
has "…el servidor RFC2217 para esptool" "--rfc2217"
has "…y los códigos de salida" "5 se desenchufó"
run python3 "$NU";                            rc_is "sin argumentos muestra la ayuda y sale con 0" 0
run python3 "$NU" cosas;                      rc_is "comando desconocido → 2" 2
has "…y dice cuál" "cosas"

echo "== nexo-usb: lo que se ve sin móvil (sin app, sin token, token malo, app vieja)"
ue() { env -i PATH="$PATH" HOME="$UT/home" TMPDIR="$UT/tmp" NEXO_USB_DIR="$UT/state" "$@"; }   # sin enlace con la app
run ue NEXO_PORT=1 NEXO_TOKEN="$TOKEN" python3 "$NU" list;   rc_is "list con la app apagada → 10" 10
has "…y le dice que mire nexo doctor" "nexo doctor"
run ue python3 "$NU" list;                    rc_is "list sin token → 11" 11
has "…y le dice cómo enlazar" "nexo pair"
run ue python3 "$NU" bridge;                  rc_is "bridge sin token → 11" 11
UP=$(start_app usb --ctl "$UT/ctl")
UE() { env -i PATH="$PATH" HOME="$UT/home" TMPDIR="$UT/tmp" NEXO_USB_DIR="$UT/state" NEXO_PORT="$UP" NEXO_TOKEN="$TOKEN" "$@"; }
nu() { UE python3 "$NU" "$@"; }
uctl() { printf '%s\n' "$*" >> "$UT/ctl"; sleep 0.4; }                    # una orden para la app falsa (ella la lee cada 0,1 s)
uid() { nu list --json 2>/dev/null | jq -r --arg v "$1" '[.devices[] | select((.vid + ":" + .pid) == $v)][0].id // empty'; }
udump() {                                                                 # udump ID → lo que ve el chip, en JSON
    rm -f "$UT/dump.json"; printf 'usb dump %s %s\n' "$1" "$UT/dump.json" >> "$UT/ctl"
    local i; for i in $(seq 40); do [ -s "$UT/dump.json" ] && break; sleep 0.1; done
    cat "$UT/dump.json" 2>/dev/null
}
ubg() { local n=$1; shift; UE python3 "$NU" "$@" > "$UT/$n.out" 2> "$UT/$n.err" & echo $! > "$T/ub_$n.pid"; }   # ubg NOMBRE args… → en segundo plano
uwait() {                                                                 # uwait NOMBRE SEGUNDOS → espera a que acabe; deja OUT, ERR y RC (124 si no acabó)
    local p i; p=$(cat "$T/ub_$1.pid")
    for i in $(seq $(($2 * 10))); do kill -0 "$p" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$p" 2>/dev/null; then kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; RC=124; else wait "$p" 2>/dev/null; RC=$?; fi
    OUT=$(cat "$UT/$1.out" 2>/dev/null); ERR=$(cat "$UT/$1.err" 2>/dev/null)
}
ustop() { nu stop --all >/dev/null 2>&1; }

run env -i PATH="$PATH" HOME="$UT/home" TMPDIR="$UT/tmp" NEXO_USB_DIR="$UT/state" NEXO_PORT="$UP" NEXO_TOKEN="$(printf '0%.0s' $(seq 48))" python3 "$NU" list
rc_is "list con un token malo → 11" 11
has "…y habla del token" "token"
UOLD=$(start_app usbold --minor2)
run env -i PATH="$PATH" HOME="$UT/home" TMPDIR="$UT/tmp" NEXO_USB_DIR="$UT/state" NEXO_PORT="$UOLD" NEXO_TOKEN="$TOKEN" python3 "$NU" list
rc_is "con una app de la revisión 1.2 (sin USB) → 1" 1
has "…le dice que instale el APK nuevo" "no sabe de USB"

echo "== nexo usb list"
run nu list;                                  rc_is "list sin dispositivos sale con 0" 0
has "…y lo dice" "no ve ningún dispositivo USB"
has "…y menciona el OTG de Xiaomi" "OTG"
for k in arduino ch340 cp2102 ftdi esp32s3 pl2303 keyboard mouse disk hub; do uctl usb plug $k; done
run nu list;                                  rc_is "list con todos sale con 0" 0
has "Arduino por su nombre" "Arduino Uno"
has "…y el VID:PID" "2341:0043"
has "CH340 con su controlador" "ch34x"
has "CP210x" "cp210x"
has "FTDI" "ftdi"
has "ESP32-S3 (CDC-ACM)" "303a:1001"
has "…y el teclado, el disco y el hub salen aunque no sirvan" "USB Keyboard"
has "…el disco" "Ultra"
has "…y el hub" "USB2.0 Hub"
has "la nota del PL2303 se enseña" "PL2303"
has "sugiere el siguiente paso" "nexo usb permit"
run nu list --json;                           rc_is "list --json sale con 0" 0
jqok "…son 10 dispositivos" '.devices | length == 10'
jqok "…y los serie con controlador son 5" '[.devices[] | select(.serial_capable)] | length == 5'
jqok "…con host: true" '.host == true'
run nu list --lsusb;                          rc_is "list --lsusb sale con 0" 0
has "--lsusb imita a lsusb" "ID 2341:0043 Arduino (www.arduino.cc) Arduino Uno"
[ "$(printf '%s\n' "$OUT" | grep -c '^Bus ')" = 10 ] && ok "…una línea por dispositivo" || bad "--lsusb: una línea por dispositivo" "$OUT"
run nu list sobra;                            rc_is "list con un argumento de más → 2" 2
run nu list --cosa;                           rc_is "list con una opción desconocida → 2" 2

echo "== nexo usb list desde el cliente nexo (nexo usb …)"
cenv() { env -i PATH="$PATH" HOME="$UT/home" TMPDIR="$UT/tmp" NEXO_USB_DIR="$UT/state" NEXO_PORT="$UP" NEXO_TOKEN="$TOKEN" "$@"; }
run cenv "$NEXO" usb list;                    rc_is "nexo usb list sale con 0" 0
has "…y es la lista de nexo-usb" "Arduino Uno"
run cenv "$NEXO" usb version;                 has "nexo usb version es la de nexo-usb" "nexo-usb $USB_VERSION"
run cenv "$NEXO" usb list --json;             jqok "nexo usb list --json pasa la opción a nexo-usb" '.devices | length == 10'
run cenv "$NEXO" --json usb list;             jqok "nexo --json usb list también" '.devices | length == 10'
run cenv "$NEXO" usb cosas;                   rc_is "nexo usb cosas → 2 (el código de nexo-usb)" 2
run cenv "$NEXO" usb help;                    has "nexo usb help" "Códigos de salida"
run cenv NEXO_PORT=1 "$NEXO" usb list;        rc_is "nexo usb list con la app apagada → 10" 10
run env -i PATH="$PATH" HOME="$UT/home" "$NEXO" usb list;   rc_is "nexo usb list sin token → 11" 11
# el cliente le pasa a nexo-usb el archivo de enlace que usó él (aunque esté en un sitio que nexo-usb no mira por su cuenta)
printf 'NEXO_PORT=%s\nNEXO_TOKEN=%s\n' "$UP" "$TOKEN" > "$UT/enlace-raro"
run env -i PATH="$PATH" HOME="$UT/home" TMPDIR="$UT/tmp" NEXO_CONFIG="$UT/enlace-raro" "$NEXO" usb list --json
jqok "…con NEXO_CONFIG, el enlace que usa el cliente es el de nexo-usb" '.devices | length == 10'
run cenv "$NEXO" --port "$UP" usb list;       rc_is "nexo --port P usb list (la opción es del cliente) sale con 0" 0
# sin nexo-usb junto al cliente, avisa de cómo conseguirlo
mkdir -p "$UT/solo/bin"; cp "$ROOT/termux/bin/nexo" "$UT/solo/bin/nexo"; chmod +x "$UT/solo/bin/nexo"
run env -i PATH="/usr/bin:/bin" HOME="$UT/home" NEXO_PORT="$UP" NEXO_TOKEN="$TOKEN" bash "$UT/solo/bin/nexo" usb list
rc_is "nexo usb list sin nexo-usb instalado → 1" 1
has "…y dice qué hacer" "setup-guests --with-usb"
# sin python3: «nexo usb list» sigue funcionando (con bash y jq); lo demás pide python3
NOPY=$UT/nopy; mkdir -p "$NOPY"
for c in bash env jq sed tr cat head tail grep cut date sleep mktemp rm stat readlink dirname id timeout basename uname; do
    p=$(command -v "$c" 2>/dev/null) && ln -sf "$p" "$NOPY/$c"
done
run env -i PATH="$NOPY" HOME="$UT/home" TMPDIR="$UT/tmp" NEXO_PORT="$UP" NEXO_TOKEN="$TOKEN" "$NEXO" usb list
rc_is "nexo usb list sin python3 sale con 0" 0
has "…y muestra los dispositivos" "Arduino Uno"
has "…y avisa de lo que falta" "Sin python3"
run env -i PATH="$NOPY" HOME="$UT/home" TMPDIR="$UT/tmp" NEXO_PORT="$UP" NEXO_TOKEN="$TOKEN" "$NEXO" usb list --json
jqok "nexo usb list --json sin python3 también" '.devices | length == 10'
run env -i PATH="$NOPY" HOME="$UT/home" TMPDIR="$UT/tmp" NEXO_PORT="$UP" NEXO_TOKEN="$TOKEN" "$NEXO" usb monitor
rc_is "nexo usb monitor sin python3 → 1" 1
has "…y pide python3" "necesita python3"
uctl usb unplug all
run env -i PATH="$NOPY" HOME="$UT/home" TMPDIR="$UT/tmp" NEXO_PORT="$UP" NEXO_TOKEN="$TOKEN" "$NEXO" usb list
has "sin python3 y sin dispositivos, también lo dice" "no ve ningún dispositivo USB"

echo "== nexo usb permit (el aviso de permiso de Android, simulado: no se prueba el diálogo real)"
uctl usb auto grant
uctl usb plug arduino
ARD=$(uid 2341:0043)
[ -n "$ARD" ] && ok "la app falsa tiene un Arduino enchufado (id $ARD)" || bad "no veo el Arduino enchufado"
run nu permit;                                rc_is "permit sin dispositivo elegido usa el único adaptador y sale con 0" 0
has "…y dice que concedió el permiso" "Permiso concedido"
run nu list --json;                           jqok "…y la app lo da por concedido" '.devices[0].permission == true'
run nu permit;                                rc_is "permit otra vez → 0" 0
has "…y dice que ya lo tenía" "ya tiene permiso"
uctl usb plug cp2102
CP=$(uid 10c4:ea60)
uctl usb auto deny
run nu permit cp2102;                         rc_is "si el usuario rechaza el aviso → 3" 3
has "…y le dice qué hacer" "no te dio permiso"
uctl usb auto ignore
run nu permit "$CP" --timeout 1;              rc_is "si nadie contesta al aviso → 3" 3
has "…le avisa de que mire el móvil" "mira la pantalla del móvil"
has "…y al final dice que nadie contestó" "Nadie contestó"
uctl usb auto grant 800
run nu permit 10c4:ea60 --timeout 5;          rc_is "si el usuario acepta a los 0,8 s → 0" 0
has "…y lo dice" "Permiso concedido"
uctl usb plug ftdi
uctl usb plug esp32s3
run nu permit;                                rc_is "permit sin elegir con dos candidatos → 2" 2
has "…y los enseña para que elijas" "Hay 2 dispositivos posibles"
run nu permit nada;                           rc_is "permit con algo que no existe → 4" 4
has "…y lo dice" "Ningún dispositivo USB encaja"
run nu permit a b;                            rc_is "permit con dos dispositivos → 2" 2
uctl usb unplug all
run nu permit;                                rc_is "permit sin nada enchufado → 4" 4
has "…y habla del cable OTG" "OTG"
ubg pw permit --wait --timeout 5
sleep 0.8; uctl usb plug ftdi
uwait pw 8;                                   rc_is "permit --wait espera a que lo enchufes y lo concede" 0
has "…avisó de que esperaba" "Esperando a que enchufes"
has "…y concedió" "Permiso concedido"

echo "== nexo usb monitor"
uctl usb unplug all
uctl usb plug arduino; ARD=$(uid 2341:0043)
run nu monitor --baud 9600 --until 'Hola desde el Arduino' --seconds 6 --no-input
rc_is "monitor al Arduino a 9600 (con reinicio, como el IDE): ve el mensaje del sketch → 0" 0
has "…lo que escribe el sketch llega tal cual" "Hola desde el Arduino"
OUT=$(udump "$ARD")
jqok "…el monitor reinició la placa una vez (DTR, como el monitor del IDE de Arduino)" '.resets == 1'
jqok "…y la línea quedó a 9600 8N1" '.baud == 9600 and .bits == 8 and .parity == "none" and .stop == 1'
uctl usb unplug all; uctl usb plug arduino; ARD=$(uid 2341:0043)
run nu monitor --baud 9600 --no-reset --lines 2 --no-input
rc_is "monitor --no-reset --lines 2 → 0" 0
has "…ve el mensaje enseguida" "Hola desde el Arduino"
OUT=$(udump "$ARD"); jqok "…y NO reinició la placa" '.resets == 0 and .dtr == false'
run nu monitor --baud 115200 --no-reset --hex --seconds 1 --no-input
has "con la velocidad equivocada llega basura (el sketch habla a 9600): bytes 0xFE" "fe fe fe fe"
run nu monitor --baud 9600 --no-reset -T --lines 2 --no-input
printf '%s\n' "$OUT" | grep -Eq '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}\] Hola desde el Arduino' && ok "monitor -T pone la hora (HH:MM:SS.mmm) a cada línea" || bad "monitor -T" "$OUT"
run nu monitor --baud 9600 --no-reset --lines 2 --json --no-input
jqok "monitor --json resume lo recibido" '.lines >= 2 and .bytes >= 44 and (.text | contains("Hola desde el Arduino")) and (.hex | startswith("486f6c61"))'
run nu monitor --baud 9600 --no-reset --until 'NUNCA-SALDRA' --seconds 1 --no-input
rc_is "--until que no aparece → 12" 12
has "…y lo dice" "No apareció"
run nu monitor --baud 9600 --no-reset --until 'Hola.*Ardu' --seconds 4 --no-input
rc_is "--until es una expresión regular → 0" 0
run nu monitor --baud 9600 --no-reset --seconds 0.5 --no-input;  rc_is "--seconds termina solo → 0" 0

uctl usb plug cp2102; CP=$(uid 10c4:ea60)
run nu monitor cp2102 --send 'hola\n' --until 'hola' --seconds 4 --no-input
rc_is "--send manda el texto (con \\n) y el eco vuelve → 0" 0
eq "…y es exactamente lo enviado" "hola"
run nu monitor "$CP" --send '\x00\x01\xfe\xff' --hex --seconds 1 --no-input
has "bytes crudos con \\xNN: salen en hexadecimal" "00 01 fe ff"
OUT=$(printf 'abc\n' | nu monitor cp2102 --eol crlf --json --idle 1); RC=$?
jqok "una tubería entra por stdin; con --eol crlf el salto de línea sale como CR LF" '.text == "abc\r\n"'
OUT=$(printf 'abc\n' | nu monitor cp2102 --eol cr --json --idle 1)
jqok "--eol cr" '.text == "abc\r"'
OUT=$(printf 'abc\n' | nu monitor cp2102 --json --idle 1)
jqok "sin --eol se manda tal cual (LF)" '.text == "abc\n"'
run nu monitor cp2102 --baud 57600 --format 7E2 --seconds 0.5 --no-input
rc_is "monitor a 57600 7E2 → 0" 0
OUT=$(udump "$CP"); jqok "…y la línea que ve el chip es 57600 7E2" '.baud == 57600 and .bits == 7 and .parity == "even" and .stop == 2'
run nu monitor cp2102 --parity odd --stop 2 --bits 6 --seconds 0.3 --no-input
OUT=$(udump "$CP"); jqok "--bits/--parity/--stop sueltos también llegan al chip" '.bits == 6 and .parity == "odd" and .stop == 2'

echo "== nexo usb monitor: lo que no sirve, lo ambiguo y los errores de uso"
uctl usb plug pl2303; uctl usb plug keyboard; uctl usb plug disk
run nu monitor 067b:2303 --seconds 1 --no-input;      rc_is "un PL2303 no tiene controlador → 4" 4
has "…y dice por qué" "PL2303"
run nu monitor keyboard --seconds 1 --no-input;     rc_is "un teclado no es un puerto serie → 4" 4
has "…y explica lo del teclado y /dev/input" "/dev/input"
run nu monitor disk --seconds 1 --no-input;         rc_is "un disco no es un puerto serie → 4" 4
has "…y manda a nexo usb mounts (0.4.2)" "nexo usb mounts"
run nu monitor --seconds 1 --no-input;              rc_is "dos adaptadores serie y ninguno elegido → 2" 2
has "…y los enseña" "Hay 2 dispositivos posibles"
run nu monitor 0403 --seconds 1 --no-input;         rc_is "un VID suelto no es un dispositivo → 4" 4
run nu monitor 2341:0043 --baud 9600 --no-reset --lines 1 --no-input;   rc_is "se elige por VID:PID" 0
run nu monitor "$ARD" --baud 9600 --no-reset --lines 1 --no-input;      rc_is "…por id" 0
run nu monitor arduino --baud 9600 --no-reset --lines 1 --no-input;     rc_is "…por parte del nombre" 0
run nu monitor --baud abc --no-input;               rc_is "--baud abc → 2" 2
run nu monitor --format 9N1 --no-input;             rc_is "--format 9N1 → 2" 2
run nu monitor --baud 0 --no-input;                 rc_is "--baud 0 → 2" 2
run nu monitor --eol cosa --no-input;               rc_is "--eol cosa → 2" 2
run nu monitor --until '(' --no-input;              rc_is "--until con una expresión regular mala → 2" 2
run nu monitor a b --no-input;                      rc_is "dos dispositivos → 2" 2
run nu monitor --cosa;                              rc_is "opción desconocida → 2" 2
uctl usb unplug all
run nu monitor --seconds 1 --no-input;              rc_is "sin nada enchufado → 4" 4
has "…y habla del cable OTG" "OTG"

echo "== nexo usb monitor: lo que pasa a mitad (desenchufar, app caída, esperar)"
uctl usb plug cp2102; CP=$(uid 10c4:ea60)
ubg mon monitor --seconds 30 --no-input --baud 115200
sleep 1.2; uctl usb unplug "$CP"
uwait mon 8;                                  rc_is "si se desenchufa con el monitor abierto → 5" 5
has "…y lo dice" "desenchufó"
ubg monw monitor --wait --seconds 5 --no-input --send 'eco\n' --until eco --baud 115200
sleep 1.2; uctl usb plug ftdi
uwait monw 12;                                rc_is "monitor --wait espera al dispositivo y luego funciona → 0" 0
has "…lo esperó" "Esperando a que enchufes"
has "…y recibió el eco" "eco"
UK=$(start_app usbkill --ctl "$UT/ctl2"); : > "$UT/ctl2"
printf 'usb plug cp2102\n' >> "$UT/ctl2"; sleep 0.5
UE NEXO_PORT="$UK" python3 "$NU" monitor --seconds 30 --no-input > "$UT/mk.out" 2> "$UT/mk.err" & echo $! > "$T/ub_mk.pid"
sleep 1.2; kill "$(cat "$T/usbkill.pid")" 2>/dev/null
uwait mk 8;                                   rc_is "si la app se cae con el monitor abierto → 10" 10
has "…y dice que se perdió la conexión" "Se perdió la conexión con la app Nexo"

echo "== nexo usb bridge: el puerto serie falso (PTY) y el reinicio automático del Arduino"
uready() { local i; for i in $(seq $(($2 * 10))); do [ "$(jq -r .state "$UT/state/$1.json" 2>/dev/null)" = conectado ] && return 0; sleep 0.1; done; return 1; }
uptyc() { python3 "$UCLIENT" pty "$@"; }
uctl usb unplug all; uctl usb plug arduino; ARD=$(uid 2341:0043)
L1=$UT/links/ard.tty
ubg br1 bridge --link "$L1" --name t1
uready t1 10 && ok "el puente arranca y queda «conectado»" || bad "el puente no arrancó" "$(cat "$UT/br1.err")"
ERR=$(cat "$UT/br1.err"); OUT=""
has "el aviso enseña el puerto serie" "Puerto serie:  $L1"
has "…explica que el Arduino se reinicia al abrirlo (y cómo evitarlo)" "--no-auto-reset"
has "…y cómo cerrarlo" "nexo usb stop t1"
[ -L "$L1" ] && ok "el enlace al puerto serie existe" || bad "falta el enlace $L1"
case "$(readlink "$L1")" in /dev/pts/*|/dev/pty*) ok "…y apunta a un PTY de /dev/pts" ;; *) bad "el enlace no apunta a /dev/pts" "$(readlink "$L1")" ;; esac
OUT=$(cat "$UT/state/t1.json")
jqok "el archivo de estado dice nombre, línea y controlador" '.name == "t1" and .line.baud == 115200 and .driver == "cdc-acm" and .state == "conectado"'
jqok "…el dispositivo" '.device.vid == "2341" and .device.pid == "0043"'
jqok "…cómo se entera de que abren el puerto (inotify o /proc)" '.pty_watch == "inotify" or .pty_watch == "proc"'
jqok "…y que hará el reinicio automático" '.auto_reset == true'
[ "$(stat -c %a "$UT/state/t1.json")" = 600 ] && ok "…con modo 600" || bad "modo del archivo de estado" "$(stat -c %a "$UT/state/t1.json")"
OUT=$(uptyc "$L1" --baud 115200 --write 3020 --read 2)
jqok "un «avrdude»: abre el puerto, a 115200, manda GET_SYNC (30 20) y el cargador contesta 14 10" '.rx | test("^(..)*1410")'
OUT=$(udump "$ARD"); jqok "…porque al abrirse el puerto el puente reinició la placa (una vez)" '.resets == 1'
sleep 0.5; OUT=$(udump "$ARD"); jqok "…y al cerrarse soltó DTR y RTS" '.dtr == false and .rts == false'
OUT=$(uptyc "$L1" --baud 115200 --write 3020 --read 2)
jqok "abrirlo otra vez reinicia otra vez y vuelve a contestar" '.rx | test("^(..)*1410")'
OUT=$(udump "$ARD"); jqok "…(dos reinicios en total)" '.resets == 2'
OUT=$(uptyc "$L1" --baud 57600 --write 41 --read 0.3 --delay 0.3)
OUT=$(udump "$ARD"); jqok "la velocidad que fija el programa en el PTY (57600) llega al adaptador" '.baud == 57600'
OUT=$(uptyc "$L1" --baud 9600 --write 41 --read 0.3)
OUT=$(udump "$ARD"); jqok "…y 9600 también" '.baud == 9600'
before=$(jq .resets <<<"$OUT")
run nu reset t1;                              rc_is "nexo usb reset NOMBRE → 0" 0
has "…lo dice" "Reinicio enviado a «t1»"
sleep 0.6; OUT=$(udump "$ARD"); jqok "…y la placa se reinició (pulso en DTR)" ".resets == $((before + 1))"
run nu status;                                rc_is "status → 0" 0
has "status enseña el puente" "t1 · pid "
has "…con su puerto" "puerto serie   $L1"
run nu status --json;                         jqok "status --json es una lista con el puente" 'length == 1 and .[0].name == "t1" and .[0].state == "conectado"'
run nu stop t1;                               rc_is "stop NOMBRE → 0" 0
has "…lo dice" "Cerrado «t1»"
uwait br1 6;                                  rc_is "el puente en primer plano termina con 0 al recibir stop" 0
[ ! -e "$L1" ] && [ ! -L "$L1" ] && ok "al cerrarse quita el enlace" || bad "el enlace sigue ahí"
[ ! -e "$UT/state/t1.json" ] && ok "…y el archivo de estado" || bad "el estado sigue ahí"
has "…y deja el resumen en el registro" "puente cerrado"
run nu status;                                has "status sin puentes lo dice" "No hay ningún puente USB en marcha"
run nu stop;                                  rc_is "stop sin puentes → 0" 0
run nu stop t1;                               rc_is "stop de uno que no existe → 4" 4
run nu reset;                                 rc_is "reset sin puentes → 4" 4

echo "== nexo usb bridge: sin reinicio automático, y los otros modos de vigilar el puerto"
uctl usb unplug all; uctl usb plug arduino; ARD=$(uid 2341:0043)
ubg br2 bridge --link "$L1" --name t2 --no-auto-reset
uready t2 10 && ok "bridge --no-auto-reset arranca" || bad "bridge --no-auto-reset" "$(cat "$UT/br2.err")"
ERR=$(cat "$UT/br2.err"); OUT=""; hasnt "…y no habla del reinicio automático" "se reinicia"
OUT=$(uptyc "$L1" --baud 115200 --write 3020 --read 1.2)
jqok "abrir el puerto no reinicia la placa: el GET_SYNC no recibe respuesta" '(.rx | test("^(..)*1410")) == false'
OUT=$(udump "$ARD"); jqok "…(cero reinicios)" '.resets == 0'
OUT=$(cat "$UT/state/t2.json"); jqok "…y el estado lo dice" '.auto_reset == false'
nu stop t2 >/dev/null; uwait br2 6
uctl usb unplug all; uctl usb plug arduino; ARD=$(uid 2341:0043)
UE NEXO_USB_WATCH=proc python3 "$NU" bridge --link "$L1" --name t3 > "$UT/br3.out" 2> "$UT/br3.err" & echo $! > "$T/ub_br3.pid"
uready t3 10 && ok "con NEXO_USB_WATCH=proc el puente arranca" || bad "NEXO_USB_WATCH=proc" "$(cat "$UT/br3.err")"
OUT=$(cat "$UT/state/t3.json"); jqok "…vigilando con /proc/PID/fd (para sistemas donde inotify no deja)" '.pty_watch == "proc"'
OUT=$(uptyc "$L1" --baud 115200 --write 3020 --read 2 --hold 0.3)
jqok "…y el reinicio automático también funciona así" '.rx | test("^(..)*1410")'
OUT=$(udump "$ARD"); jqok "…con un solo reinicio" '.resets == 1'
nu stop t3 >/dev/null; uwait br3 6
uctl usb unplug all; uctl usb plug arduino; ARD=$(uid 2341:0043)
UE NEXO_USB_WATCH=none python3 "$NU" bridge --link "$L1" --name t4 > "$UT/br4.out" 2> "$UT/br4.err" & echo $! > "$T/ub_br4.pid"
uready t4 10 && ok "con NEXO_USB_WATCH=none el puente arranca" || bad "NEXO_USB_WATCH=none" "$(cat "$UT/br4.err")"
ERR=$(cat "$UT/br4.err"); OUT=""; has "…y avisa de que no puede saber cuándo abren el puerto" "sin reinicio automático del Arduino"
OUT=$(cat "$UT/state/t4.json"); jqok "…el estado dice «none»" '.pty_watch == "none"'
OUT=$(uptyc "$L1" --baud 115200 --write 3020 --read 1.2)
jqok "…y abrirlo no reinicia (el GET_SYNC se queda sin respuesta)" '(.rx | test("^(..)*1410")) == false'
run nu reset t4;                              rc_is "…pero «nexo usb reset» sí lo reinicia a mano" 0
sleep 0.5; OUT=$(udump "$ARD"); jqok "…(un reinicio)" '.resets == 1'
nu stop t4 >/dev/null; uwait br4 6

echo "== nexo usb bridge: los datos pasan enteros por el PTY (todos los valores de byte, en los dos sentidos)"
uctl usb unplug all; uctl usb plug cp2102; CP=$(uid 10c4:ea60)
L2=$UT/links/eco.tty
ubg br5 bridge --link "$L2" --name eco
uready eco 10 && ok "el puente al chip «eco» arranca" || bad "puente eco" "$(cat "$UT/br5.err")"
OUT=$(uptyc "$L2" --baud 115200 --write 00010203ff80fe7f0a0d1b03 --read 1)
jqok "los bytes de control y los altos vuelven tal cual (sin traducir LF/CR, sin eco del terminal, sin ^C)" '.rx == "00010203ff80fe7f0a0d1b03"'
OUT=$(python3 "$UCLIENT" echo "$L2" --via pty --bytes 204800 --baud 115200 --timeout 40)
jqok "200 KiB con los 256 valores de byte vuelven idénticos" '.equal == true and .got == 204800 and .sent == 204800'
OUT=$(python3 "$UCLIENT" echo "$L2" --via pty --bytes 65536 --baud 921600 --timeout 40)
jqok "…y a 921600 baudios también" '.equal == true'
OUT=$(udump "$CP"); jqok "…y el adaptador vio la velocidad que fijó el programa (921600)" '.baud == 921600'
echo "== nexo usb bridge: desenchufar y volver a enchufar (el puerto se queda donde está)"
uctl usb unplug "$CP"
waitfor "$UT/br5.err" "Esperando a que vuelva el dispositivo" 8 && ok "al desenchufar el puente lo dice y espera" || bad "no avisó de la espera" "$(tail -5 "$UT/br5.err")"
[ -L "$L2" ] && ok "…el enlace al puerto sigue donde estaba" || bad "el enlace desapareció al desenchufar"
OUT=$(cat "$UT/state/eco.json"); jqok "…y el estado dice «esperando»" '.state == "esperando"'
uctl usb plug cp2102
waitfor "$UT/br5.err" "Dispositivo de vuelta" 12 && ok "al volver a enchufarlo lo reconoce (mismo VID, PID y serie) y sigue" || bad "no volvió" "$(tail -6 "$UT/br5.err")"
uready eco 5 && ok "…el estado vuelve a «conectado»" || bad "estado tras volver"
OUT=$(uptyc "$L2" --baud 115200 --write 68656c6c6f --read 1)
jqok "…y por el mismo puerto vuelven a pasar datos" '.rx == "68656c6c6f"'
OUT=$(python3 "$UCLIENT" echo "$L2" --via pty --bytes 4096 --baud 115200 --timeout 20); jqok "…enteros" '.equal == true'
uctl usb unplug all; sleep 0.3; uctl usb plug ftdi
sleep 2.5; ERR=$(cat "$UT/br5.err"); OUT=""
hasnt "otro adaptador distinto (FTDI) no lo toma por el que se fue" "Dispositivo de vuelta: FT232R"
uctl usb unplug all; uctl usb plug cp2102
waitfor "$UT/br5.err" "Dispositivo de vuelta: CP2102" 12 && ok "…y el CP2102 de antes sí" || bad "el CP2102 no volvió" "$(tail -4 "$UT/br5.err")"
run nu stop eco; uwait br5 6;                 rc_is "stop cierra el puente (0)" 0
uctl usb unplug all; uctl usb plug cp2102
ubg br6 bridge --link "$L2" --name nore --no-reconnect
uready nore 10 || bad "puente --no-reconnect" "$(cat "$UT/br6.err")"
uctl usb unplug all
uwait br6 8;                                  rc_is "--no-reconnect: al desenchufar el puente termina con 5" 5
ERR=$(cat "$UT/br6.err"); OUT=""; has "…y dice por qué" "USB:"
[ ! -e "$UT/state/nore.json" ] && [ ! -L "$L2" ] && ok "…y limpia su estado y su enlace" || bad "no limpió"

echo "== nexo usb bridge: servidor RFC 2217 (esptool, pyserial con rfc2217://)"
uctl usb unplug all; uctl usb plug cp2102; CP=$(uid 10c4:ea60)
ubg br7 bridge --no-pty --rfc2217 0 --name rfc
uready rfc 10 && ok "bridge --no-pty --rfc2217 0 arranca (el 0 elige un puerto libre)" || bad "puente RFC2217" "$(cat "$UT/br7.err")"
RFC=$(jq -r .rfc2217 "$UT/state/rfc.json"); ERR=$(cat "$UT/br7.err"); OUT=""
has "el aviso da la dirección para esptool" "esptool --port rfc2217://$RFC"
hasnt "…y no hay PTY" "Puerto serie:"
OUT=$(cat "$UT/state/rfc.json"); jqok "…el estado no lleva PTY y sí RFC2217" '(.pty == null) and (.link == null) and (.rfc2217 | test("^127[.]0[.]0[.]1:[0-9]+$"))'
OUT=$(python3 "$UCLIENT" rfc "$RFC" --baud 57600 --size 7 --parity 3 --stop 2 --dtr 1 --rts 0 --write 68 --read 0.6)
jqok "el servidor negocia COM-PORT en las dos direcciones (WILL 44 y DO 44)" '.opts | (index("251,44") != null) and (index("253,44") != null)'
jqok "…SET-BAUDRATE, SET-DATASIZE, SET-PARITY y SET-STOPSIZE contestan con el valor pedido" '.baud == 57600 and .size == 7 and .parity == 3 and .stop == 2'
jqok "…SET-CONTROL DTR on (8) y RTS off (12) también" '.dtr == 8 and .rts == 12'
jqok "…y los datos llegan y vuelven" '.rx == "68"'
OUT=$(udump "$CP"); jqok "el chip vio 57600 7E2" '.baud == 57600 and .bits == 7 and .parity == "even" and .stop == 2'
sleep 0.5; OUT=$(udump "$CP"); jqok "…y al irse el cliente se soltaron DTR y RTS" '.dtr == false and .rts == false'
OUT=$(python3 "$UCLIENT" rfc "$RFC" --baud 115200 --size 8 --parity 1 --stop 1 --dtr 1 --rts 1 --write 00ff01ffff --read 0.6)
jqok "el byte 0xFF (IAC de telnet) va duplicado en los dos sentidos y llega entero" '.rx == "00ff01ffff"'
OUT=$(udump "$CP"); jqok "…el chip ve 115200 8N1" '.baud == 115200 and .bits == 8 and .parity == "none" and .stop == 1'
jqok "…recibió DTR y RTS activos mientras el cliente estaba (y los soltó al irse)" '([.ops[] | select(.[1] == "lines" and .[2] == true and .[3] == true)] | length) >= 1 and .dtr == false and .rts == false'
OUT=$(python3 "$UCLIENT" echo "$RFC" --via rfc --bytes 65536 --baud 115200 --timeout 40)
jqok "64 KiB con los 256 valores de byte por RFC2217 vuelven idénticos" '.equal == true and .got == 65536'
nu stop rfc >/dev/null; uwait br7 6

echo "== nexo usb bridge: TCP crudo (avrdude -c arduino -P net:…) y el reinicio al primer cliente"
uctl usb unplug all; uctl usb plug arduino; ARD=$(uid 2341:0043)
ubg br8 bridge --no-pty --tcp 0 --name raw
uready raw 10 && ok "bridge --no-pty --tcp 0 arranca" || bad "puente TCP" "$(cat "$UT/br8.err")"
TCPA=$(jq -r .tcp "$UT/state/raw.json")
OUT=$(python3 "$UCLIENT" tcp "$TCPA" --write 3020 --read 2 --delay 0.3)
jqok "el primer cliente TCP reinicia la placa y el GET_SYNC se contesta (14 10)" '.rx | test("^(..)*1410")'
OUT=$(udump "$ARD"); jqok "…con un solo reinicio" '.resets == 1'
python3 "$UCLIENT" tcp "$TCPA" --read 0.2 --hold 4 > "$UT/c1.out" 2>&1 & echo $! > "$T/ub_c1.pid"
sleep 1; OUT=$(udump "$ARD"); n1=$(jq .resets <<<"$OUT")
python3 "$UCLIENT" tcp "$TCPA" --read 0.3 > "$UT/c2.out" 2>&1
OUT=$(udump "$ARD"); jqok "un segundo cliente conectado a la vez no vuelve a reiniciar" ".resets == $n1"
nu stop raw >/dev/null; uwait br8 6
ubg br9 bridge --no-pty --rfc2217 0.0.0.0:0 --name ancho
waitfor "$UT/br9.err" "no solo en este móvil" 10 && ok "escuchar fuera de 127.0.0.1 avisa de que no hay contraseña" || bad "no avisó del riesgo" "$(cat "$UT/br9.err")"
nu stop ancho >/dev/null; uwait br9 6
python3 -c 'import socket,time; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(1); print(s.getsockname()[1], flush=True); time.sleep(60)' > "$UT/hold.port" & echo $! > "$T/ub_hold.pid"
sleep 0.6; HP=$(cat "$UT/hold.port")
run nu bridge --no-pty --rfc2217 "127.0.0.1:$HP" --name ocupado;   rc_is "un puerto ocupado → 1" 1
has "…lo explica" "No puedo escuchar en 127.0.0.1:$HP"
[ ! -e "$UT/state/ocupado.json" ] && ok "…y no deja estado a medias" || bad "estado a medias"
kill "$(cat "$T/ub_hold.pid")" 2>/dev/null

echo "== nexo usb bridge: en segundo plano (--detach), varios a la vez, status/stop/reset"
uctl usb unplug all; uctl usb plug cp2102; uctl usb plug ftdi
L3=$UT/links/det.tty
run nu bridge cp2102 --detach --name d1 --link "$L3" --rfc2217 0;   rc_is "bridge --detach vuelve en cuanto está listo → 0" 0
has "…enseña el puerto" "Puerto serie:  $L3"
has "…y cómo cerrarlo, sin hablar de Ctrl+C (ya no hay terminal)" "nexo usb stop d1"
hasnt "…" "Ctrl+C"
OUT=$(cat "$UT/state/d1.json"); DP=$(jq -r .pid <<<"$OUT")
kill -0 "$DP" 2>/dev/null && ok "el puente sigue vivo detrás (pid $DP)" || bad "el puente no está vivo"
[ -n "$(ps -o sid= -p "$DP" 2>/dev/null | tr -d ' ')" ] && [ "$(ps -o sid= -p "$DP" 2>/dev/null | tr -d ' ')" != "$(ps -o sid= -p $$ 2>/dev/null | tr -d ' ')" ] && ok "…en otra sesión que la de la terminal (no muere al cerrarla)" || bad "…en otra sesión" "sid=$(ps -o sid= -p "$DP" 2>/dev/null) la mía=$(ps -o sid= -p $$ 2>/dev/null)"
[ -s "$UT/state/d1.log" ] && grep -q 'listo:' "$UT/state/d1.log" && ok "…y escribe su registro ($UT/state/d1.log)" || bad "registro del puente" "$(cat "$UT/state/d1.log" 2>/dev/null)"
[ "$(stat -c %a "$UT/state/d1.log")" = 600 ] && ok "…con modo 600" || bad "modo del registro"
OUT=$(uptyc "$L3" --baud 115200 --write 68 --read 1);   jqok "…y el PTY funciona" '.rx == "68"'
run nu bridge cp2102 --name d1;               rc_is "otro puente con el mismo nombre → 2" 2
has "…lo dice" "Ya hay un puente llamado «d1»"
run nu bridge ftdi --name "a b";              rc_is "un nombre con espacio → 2" 2
run nu bridge ftdi --detach;                  rc_is "otro puente, sin nombre, al otro adaptador → 0" 0
has "…se llama usb0" "nexo usb stop usb0"
run nu status;                                has "status enseña los dos" "d1 · pid "
has "…y el segundo" "usb0 · pid "
has "…con su RFC2217" "RFC2217        rfc2217://127.0.0.1:"
run nu status --json;                         jqok "status --json: dos puentes" 'length == 2 and (map(.name) | sort) == ["d1","usb0"]'
run nu stop;                                  rc_is "stop sin nombre con dos puentes → 2" 2
has "…pide que digas cuál (o --all)" "--all"
run nu reset;                                 rc_is "reset sin nombre con dos puentes → 2" 2
run nu stop d1 usb0;                          rc_is "stop con los dos nombres → 0" 0
has "…cierra el primero" "Cerrado «d1»"
has "…y el segundo" "Cerrado «usb0»"
kill -0 "$DP" 2>/dev/null && bad "el puente d1 sigue vivo tras stop" || ok "…el proceso ya no existe"
[ ! -e "$L3" ] && [ ! -e "$UT/state/d1.json" ] && ok "…y no quedan enlace ni estado" || bad "quedan restos de d1"
grep -q 'puente cerrado' "$UT/state/d1.log" && ok "…y el registro dice cómo terminó" || bad "el registro no dice cómo terminó"
run nu bridge cp2102 --detach --name x1;      rc_is "un tercero para probar stop --all" 0
run nu bridge ftdi --detach --name x2;        rc_is "…y un cuarto" 0
run nu stop --all;                            rc_is "stop --all → 0" 0
run nu status --json;                         jqok "…no queda ninguno" 'length == 0'

echo "== nexo usb bridge: restos, procesos ajenos y errores de uso"
printf '{"name":"fantasma","pid":999999,"link":"%s","pty":"/dev/pts/999"}\n' "$UT/links/fantasma.tty" > "$UT/state/fantasma.json"
ln -sf /dev/pts/999 "$UT/links/fantasma.tty"
run nu status;                                has "un estado de un proceso que ya no existe no cuenta como puente" "No hay ningún puente USB en marcha"
[ ! -e "$UT/state/fantasma.json" ] && [ ! -L "$UT/links/fantasma.tty" ] && ok "…y se limpia (también su enlace)" || bad "no limpió el estado fantasma"
sleep 60 & SLP=$!; echo $SLP > "$T/ub_sleep.pid"
printf '{"name":"ajeno","pid":%s}\n' "$SLP" > "$UT/state/ajeno.json"
run nu status;                                has "un número de proceso que ahora es de otro programa tampoco cuenta" "No hay ningún puente USB en marcha"
kill -0 "$SLP" 2>/dev/null && ok "…y NUNCA se le manda una señal (stop no mata procesos ajenos)" || bad "se mató un proceso ajeno"
run nu stop ajeno;                            rc_is "stop de un estado que no es de nexo-usb → 4" 4
kill -0 "$SLP" 2>/dev/null && ok "…y el proceso ajeno sigue vivo" || bad "stop mató un proceso ajeno"
kill "$SLP" 2>/dev/null; rm -f "$UT/state/ajeno.json"
run nu bridge --no-pty;                       rc_is "--no-pty sin RFC2217 ni TCP → 2" 2
has "…lo explica" "--rfc2217 o --tcp"
run nu bridge --no-pty --link "$UT/links/x" --tcp 0;   rc_is "--no-pty con --link → 2" 2
run nu bridge --rfc2217 abc;                  rc_is "--rfc2217 abc → 2" 2
run nu bridge --cosa;                         rc_is "opción desconocida → 2" 2
run nu bridge a b;                            rc_is "dos dispositivos → 2" 2
uctl usb unplug all; uctl usb plug cp2102
run nu bridge cp2102 --link "$UT/links";      rc_is "--link que es una carpeta → 2" 2
has "…lo explica" "es una carpeta"
uctl usb unplug all
run nu bridge;                                rc_is "bridge sin nada enchufado → 4" 4
has "…y habla del cable OTG" "OTG"
uctl usb plug keyboard
run nu bridge keyboard;                       rc_is "bridge de un teclado → 4" 4
uctl usb unplug all; uctl usb plug cp2102; uctl usb plug ftdi
run nu bridge;                                rc_is "bridge con dos adaptadores y ninguno elegido → 2" 2
uctl usb unplug all
ubg bw bridge --wait --no-pty --tcp 0 --name espera
sleep 1.3; uctl usb plug cp2102
uready espera 12 && ok "bridge --wait espera al dispositivo y arranca cuando lo enchufas" || bad "bridge --wait" "$(cat "$UT/bw.err")"
ERR=$(cat "$UT/bw.err"); OUT=""; has "…avisó de que no había nada (y siguió esperando)" "No veo ningún dispositivo USB"
nu stop espera >/dev/null; uwait bw 6
uctl usb unplug all; uctl usb auto ignore; uctl usb plug cp2102
run nu bridge --perm-timeout 1 --no-pty --tcp 0;   rc_is "si nadie acepta el permiso de Android → 3" 3
has "…lo dice" "Nadie contestó"
uctl usb auto grant; uctl usb unplug all
echo "== tests/usb_hardware_check.sh (la prueba con hardware real; aquí, contra la app falsa para comprobar que el script funciona)"
HC=$ROOT/tests/usb_hardware_check.sh
hc() { UE env NEXO_CHECK_BIN="$T/bin/nexo" NEXO_CHECK_HOOK_UNPLUG="${HC_UNPLUG:-}" NEXO_CHECK_HOOK_PLUG="${HC_PLUG:-}" "$@"; }
head -n 1 "$HC" | grep -q '^#!/usr/bin/env bash$' && ok "empieza por #!/usr/bin/env bash" || bad "shebang de usb_hardware_check.sh"
run hc bash "$HC" --help;                     rc_is "--help sale con 0" 0
has "…y explica --loopback" "--loopback"
has "…y --esp32" "--esp32"
run hc bash "$HC" --baud abc;                 rc_is "--baud con algo que no es un número → 2" 2
run hc bash "$HC" --raro;                     rc_is "una opción desconocida → 2" 2
run hc bash "$HC" uno dos;                    rc_is "dos dispositivos → 2" 2
run env -i PATH="$PATH" NEXO_CHECK_BIN="$T/no-existe" bash "$HC" --yes;   rc_is "sin nexo instalado → 2" 2
run env -i PATH="$PATH" HOME="$UT/home" TMPDIR="$UT/tmp" NEXO_USB_DIR="$UT/state" NEXO_PORT=1 NEXO_TOKEN="$TOKEN" NEXO_CHECK_BIN="$T/bin/nexo" bash "$HC" --yes
rc_is "con la app apagada → 1" 1
has "…dice qué falló (código 10: la app no responde)" "falló (código 10)"
uctl usb unplug all
run hc bash "$HC" --yes;                      rc_is "sin nada enchufado → 1" 1
has "…lo dice" "no hay ningún adaptador serie conectado"
for k in arduino cp2102 esp32s3 ch340 keyboard; do uctl usb plug $k; done
run hc bash "$HC" --yes;                      rc_is "con varios adaptadores y ninguno elegido → 1" 1
has "…pide que indiques cuál" "hay varios dispositivos"
has "…y los enumera" "1a86:7523"
run hc bash "$HC" keyboard --yes;             rc_is "un teclado no es un puerto serie → 1" 1
has "…lo dice" "Nexo no tiene controlador para este dispositivo"
AID=$(uid 2341:0043)
HC_UNPLUG="printf 'usb unplug %s\n' $AID >> '$UT/ctl'; sleep 0.6"
HC_PLUG="printf 'usb plug arduino\n' >> '$UT/ctl'; sleep 0.6"
run hc bash "$HC" 2341:0043 --arduino --unplug --yes
rc_is "Arduino: --arduino --unplug → 0" 0
hasnt "…sin ninguna prueba fallida" "FALLA"
has "…Android ve el dispositivo" "Android ve el dispositivo"
has "…permiso" "permiso concedido"
has "…el puerto abre con la configuración pedida" "el puerto abre con esa configuración"
has "…el cargador contesta 14 10 tras el reinicio automático" "el cargador contestó 14 10"
has "…al desenchufar, el puente se queda esperando" "se queda «esperando»"
has "…el puerto serie falso sigue donde estaba" "el puerto serie sigue donde estaba"
has "…y al enchufar otra vez se recupera solo" "el puente lo recupera solo"
has "…el informe trae el dispositivo en JSON" '"vid": "2341"'
has "…y el registro del puente" "registro del puente chk-unp"
hasnt "…y no lleva el token" "$TOKEN"
HC_UNPLUG=""; HC_PLUG=""
run hc bash "$HC" cp2102 --loopback --yes;    rc_is "CP210x: --loopback → 0" 0
hasnt "…sin ninguna prueba fallida" "FALLA"
has "…el texto vuelve igual" "el texto vuelve igual"
has "…y los 256 valores de byte" "los 256 valores de byte vuelven iguales y en orden"
run hc bash "$HC" 1a86:7523 --arduino --yes;  rc_is "CH340 (una placa Arduino detrás): --arduino → 0" 0
has "…el cargador contesta" "el cargador contestó 14 10"
mkdir -p "$UT/stubs"
cat > "$UT/stubs/esptool" <<'EOF'
#!/usr/bin/env python3
# esptool DE MENTIRA: solo comprueba que la URL rfc2217://HOST:PUERTO que ofrece el puente acepta conexiones.
import re, socket, sys
a = sys.argv[1:]
m = re.match(r"rfc2217://([0-9.]+):([0-9]+)$", a[a.index("--port") + 1]) if "--port" in a else None
if not m or a[-1] not in ("chip_id", "chip-id"):
    print("uso raro: %r" % (a,))
    sys.exit(2)
socket.create_connection((m.group(1), int(m.group(2))), 3).close()
print("Chip is ESP32-S3 (esptool de mentira)")
EOF
chmod +x "$UT/stubs/esptool"
run hc PATH="$UT/stubs:$PATH" bash "$HC" 303a:1001 --esp32 --yes
rc_is "ESP32-S3: --esp32 con un esptool de mentira → 0" 0
has "…el puente ofrece la URL RFC 2217" "el puente ofrece rfc2217://127.0.0.1:"
has "…y esptool «lee» el chip a través de ella" "esptool leyó el chip: Chip is ESP32-S3"
if command -v esptool >/dev/null 2>&1 || command -v esptool.py >/dev/null 2>&1; then
    echo "  (hay un esptool de verdad en el PATH: no se prueba el aviso de que falta)"
else
    run hc bash "$HC" 303a:1001 --esp32 --yes; rc_is "sin esptool, --esp32 se omite sin fallar → 0" 0
    has "…y dice cómo instalarlo" "pip install esptool"
fi
run nu status --json;                         eq "el script no deja puentes abiertos" "[]"
[ "$(ls "$UT/tmp" | grep -c 'nexo-usb-check')" = 0 ] && ok "…ni archivos temporales" || bad "usb_hardware_check.sh dejó temporales" "$(ls "$UT/tmp")"
uctl usb unplug all
ustop
