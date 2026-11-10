# Pruebas de los servicios de nexo-dbus que viven en el bus del SISTEMA (BlueZ; después NetworkManager). No se ejecuta
# solo: lo carga tests/dbus_tests.sh dentro del bloque que ya comprobó que hay dbus-daemon, busctl y gdbus, así que
# hereda DB, DD, ok/bad/…, poll, start_app, dd_start… Como en MPRIS, los clientes son independientes de nexo-dbus:
# busctl (sd-bus, el de systemd) y gdbus (GLib, el de GNOME). Si ellos entienden lo que dice nexo-dbus, lo entenderán
# bluetoothctl, blueman, nmcli, nm-applet, GNOME y KDE. (Estos dos últimos grupos no están instalados aquí: ver docs.)
# El «bus del sistema» de las pruebas es otro dbus-daemon con la configuración de sesión (deja ocupar cualquier nombre).

echo "== nexo-dbus: BlueZ (org.bluez en un bus del sistema de pruebas)"
SYS_SOCK=$DB/sysbus
SYS_ADDR=unix:path=$SYS_SOCK
SYS_PID=""
BZ=org.bluez
BZA=/org/bluez/hci0
BZ1=$BZA/dev_AA_BB_CC_DD_EE_01
BZ2=$BZA/dev_AA_BB_CC_DD_EE_02
BZ3=$BZA/dev_AA_BB_CC_DD_EE_03
BZ7=$BZA/dev_AA_BB_CC_DD_EE_77
BZIA=org.bluez.Adapter1
BZID=org.bluez.Device1
BZIB=org.bluez.Battery1
UUID_A2DP=0000110b-0000-1000-8000-00805f9b34fb
NOSD=$DB/no-hay-systemd       # no existe: en un PC con systemd, la pista «bluetooth.service lo arranca systemd» no cuenta aquí
mkdir -p "$DB/sysservices" "$DB/ownsys"
# org.bluez «activable» (como cuando bluez está instalado): solo la ve nexo-dbus si NEXO_DBUS_SYSTEMD_DIR existe
printf '[D-BUS Service]\nName=org.bluez\nExec=/bin/false\n' > "$DB/sysservices/org.bluez.service"
printf '[D-BUS Service]\nName=org.freedesktop.NetworkManager\nExec=/bin/false\n' > "$DB/sysservices/org.freedesktop.NetworkManager.service"

# sbus_conf [REGLAS DE POLÍTICA] → escribe la configuración del bus del sistema de pruebas
mkdir -p "$DB/policy.d"
sbus_conf() {
    cat > "$DB/sys.conf" <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>$SYS_ADDR</listen>
  <auth>EXTERNAL</auth>
  <servicedir>$DB/sysservices</servicedir>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
    ${1:-}
  </policy>
  <includedir>$DB/policy.d</includedir>
</busconfig>
EOF
}
sbus_start() {
    local i
    rm -f "$SYS_SOCK"
    dbus-daemon --config-file="$DB/sys.conf" --nofork --nopidfile >"$DB/sysbus.log" 2>&1 &
    SYS_PID=$!
    APP_PIDS+=("$SYS_PID")
    for i in $(seq 50); do [ -S "$SYS_SOCK" ] && return 0; sleep 0.1; done
    return 1
}
sbus_stop() { [ -n "$SYS_PID" ] && { kill "$SYS_PID" 2>/dev/null; wait "$SYS_PID" 2>/dev/null; }; SYS_PID=""; rm -f "$SYS_SOCK"; }

sb()  { busctl --address="$SYS_ADDR" "$@"; }
sbj() { busctl --address="$SYS_ADDR" --json=short "$@"; }
# ¿tiene dueño el nombre? (busctl list también enseña los nombres «activables» sin dueño: por eso se pregunta al bus)
shas() { [ "$(sbj call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus NameHasOwner s "$1" 2>/dev/null | jq -c '.data[0]')" = true ]; }
swait() { poll "shas $1" "${2:-8}"; }
sgone() { poll "! shas $1" "${2:-8}"; }
sowner() { sbj call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetNameOwner s "$1" 2>/dev/null | jq -r '.data[0]'; }
# bp RUTA INTERFAZ PROPIEDAD → el valor de la propiedad en JSON (vacío si no existe)
bp() { sbj get-property "$BZ" "$1" "$2" "$3" 2>/dev/null | jq -c '.data'; }
mo() { sbj call "$BZ" / org.freedesktop.DBus.ObjectManager GetManagedObjects 2>&1; }
# gc RUTA INTERFAZ.MÉTODO [ARGS…] → llamada con gdbus (enseña el NOMBRE del error, que busctl no enseña)
gc() { gdbus call --address "$SYS_ADDR" --dest "$BZ" --object-path "$1" --method "$2" "${@:3}" 2>&1; }
# gset RUTA INTERFAZ PROPIEDAD VALOR(texto GVariant) → escribe una propiedad con gdbus
gset() { gdbus call --address "$SYS_ADDR" --dest "$BZ" --object-path "$1" --method org.freedesktop.DBus.Properties.Set "$2" "$3" "$4" 2>&1; }
eqv() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1" "se esperaba $2 y salió [$3]"; fi; }
# bzdd NOMBRE PUERTO [VAR=VAL…] → nexo-dbus solo con BlueZ (sin MPRIS) en el bus del sistema de pruebas
bzdd() {
    local n=$1 p=$2
    shift 2
    dd_start "$n" "$p" NEXO_DBUS_SYSTEM_BUS="$SYS_ADDR" NEXO_DBUS_MPRIS=0 NEXO_DBUS_NM=0 NEXO_DBUS_SYSTEMD_DIR="$NOSD" NEXO_DBUS_REFRESH=3 "$@"
}
ZMON=""
zmon_start() {
    zmon_stop
    : > "$DB/zmon.txt"
    gdbus monitor --address "$SYS_ADDR" --dest "${1:-$BZ}" >"$DB/zmon.txt" 2>&1 &
    ZMON=$!
    APP_PIDS+=("$ZMON")
    sleep 0.5
}
zmon_stop() { [ -n "$ZMON" ] && { kill "$ZMON" 2>/dev/null; wait "$ZMON" 2>/dev/null; }; ZMON=""; }
# zsig SEÑAL RUTA TEXTO → ¿hubo una señal con ese nombre, sobre ese objeto y con ese texto?
zsig() { grep -F -- "$1" "$DB/zmon.txt" | grep -F -- "$2" | grep -qF -- "$3"; }
ctl() { echo "$1" >> "$DB/ctlZ"; }
# dstate → lo que cuenta «nexo-dbus status» (lo lee del archivo de estado que escribe el demonio de $DB/run)
dstate() { env -i PATH="$PATH" HOME="$DB/home" XDG_RUNTIME_DIR="$DB/run" XDG_CACHE_HOME="$DB/cache" python3 "$DD" status 2>&1; }
dst_has() { dstate | grep -qF -- "$1"; }
[ -S "$BUS_SOCK" ] || bus_start

sbus_conf ""
sbus_start && ok "arranca un bus «del sistema» de pruebas (otro dbus-daemon, aparte del de sesión)" || bad "bus del sistema de pruebas" "$(cat "$DB/sysbus.log")"
HOLD_OUT=$DB/hold.out

# NEXO_TESTS_SYSTEM_ONLY=bluez|nm → solo una de las dos partes (para repetir una sola con rapidez); sin ello, las dos.
if [ "${NEXO_TESTS_SYSTEM_ONLY:-all}" != nm ]; then   # parte BlueZ

# ------------------------------------------------------------------------------ los objetos y sus propiedades
: > "$DB/ctlZ"
ZPORT=$(start_app dbusZ --ctl "$DB/ctlZ")
ZPID=$(cat "$T/dbusZ.pid")
bzdd Z "$ZPORT"
swait "$BZ" 8 && ok "con Bluetooth en el móvil, org.bluez aparece en el bus del sistema" || bad "org.bluez no apareció" "$(cat "$DB/Z.log")"
grep -q "BlueZ: conectado al bus del sistema" "$DB/Z.log" && grep -q "BlueZ: org.bluez disponible" "$DB/Z.log" && ok "…y lo anota" || bad "registro de BlueZ" "$(cat "$DB/Z.log")"
poll '[ -n "$(bp "$BZ2" $BZID Address)" ] && [ -n "$(bp "$BZ1" $BZIB Percentage)" ]' 8 && ok "…con los dispositivos emparejados y la batería (sin esperar al refresco de un minuto)" || bad "los dispositivos no aparecen" "$(mo)"
poll 'dst_has "$(printf "%-15s %s" BlueZ "org.bluez activo")"' 4 && ok "nexo-dbus status cuenta que BlueZ está activo" || bad "status de BlueZ activo" "$(dstate)"
dst_has "$(printf "%-15s %s" NetworkManager apagado)" && dst_has "$(printf "%-15s %s" MPRIS apagado)" && ok "…y que NetworkManager y MPRIS están apagados (esta prueba los apaga)" || bad "status de los apagados" "$(dstate)"
dst_has "nexo-dbus en marcha (PID $DD_PID)" && ok "…con el PID del demonio" || bad "PID en status" "$(dstate)"

OUT=$(mo)
printf '%s' "$OUT" | jq -e --arg a "$BZA" --arg d1 "$BZ1" --arg d2 "$BZ2" '.data[0] | keys == ["/org/bluez", $a, $d1, $d2]' >/dev/null 2>&1 \
    && ok "GetManagedObjects (ObjectManager en «/») lista /org/bluez, el adaptador y los dos dispositivos" || bad "objetos" "$OUT"
printf '%s' "$OUT" | jq -e --arg a "$BZA" --arg d1 "$BZ1" --arg d2 "$BZ2" '.data[0] | (.["/org/bluez"] | keys) == ["org.bluez.AgentManager1"] and (.[$a] | keys) == ["org.bluez.Adapter1"] and (.[$d1] | keys) == ["org.bluez.Battery1", "org.bluez.Device1"] and (.[$d2] | keys) == ["org.bluez.Device1"]' >/dev/null 2>&1 \
    && ok "…cada uno con sus interfaces (Battery1 solo en el que da batería)" || bad "interfaces de los objetos" "$OUT"
OUT=$(gc / org.freedesktop.DBus.ObjectManager.GetManagedObjects)
case $OUT in *"'org.bluez.Adapter1'"*) ok "gdbus (GLib) también lee GetManagedObjects…" ;; *) bad "gdbus GetManagedObjects" "$OUT" ;; esac
# (el texto con ñ y tildes se comprueba con busctl más abajo: gdbus lo imprime como «?» si el idioma del sistema no es UTF-8)
case $OUT in *"'Name': <'Auriculares "*"'Class': <uint32 1024>"*"'Connected': <true>"*) ok "…y los tipos (a{oa{sa{sv}}}, uint32, objectpath…) le llegan bien" ;; *) bad "tipos para gdbus" "$OUT" ;; esac

eqv "Adapter1.Powered = true (el Bluetooth del móvil está encendido)" true "$(bp "$BZA" $BZIA Powered)"
eqv "…Name = el nombre Bluetooth del móvil" '"Redmi 15C"' "$(bp "$BZA" $BZIA Name)"
eqv "…Alias" '"Redmi 15C"' "$(bp "$BZA" $BZIA Alias)"
eqv "…PowerState = on" '"on"' "$(bp "$BZA" $BZIA PowerState)"
eqv "…Discovering = false" false "$(bp "$BZA" $BZIA Discovering)"
eqv "…Pairable = true, Discoverable = false" "true false" "$(bp "$BZA" $BZIA Pairable) $(bp "$BZA" $BZIA Discoverable)"
eqv "…Class = 0x5a020c (teléfono inteligente)" 5898764 "$(bp "$BZA" $BZIA Class)"
ADDR1=$(bp "$BZA" $BZIA Address)
[[ $ADDR1 =~ ^\"02(:[0-9A-F]{2}){5}\"$ ]] && ok "…Address = una dirección inventada y «administrada localmente» (02:…): Android no da la real" || bad "Address del adaptador" "$ADDR1"

eqv "Device1.Name" '"Auriculares ñandú"' "$(bp "$BZ1" $BZID Name)"
eqv "…Alias (sin apodo, es el nombre)" '"Auriculares ñandú"' "$(bp "$BZ1" $BZID Alias)"
eqv "…Address" '"AA:BB:CC:DD:EE:01"' "$(bp "$BZ1" $BZID Address)"
eqv "…Paired, Bonded, Connected, Trusted" "true true true true" "$(bp "$BZ1" $BZID Paired) $(bp "$BZ1" $BZID Bonded) $(bp "$BZ1" $BZID Connected) $(bp "$BZ1" $BZID Trusted)"
eqv "…Blocked = false" false "$(bp "$BZ1" $BZID Blocked)"
eqv "…Class = 0x0400 (audio/vídeo)" 1024 "$(bp "$BZ1" $BZID Class)"
eqv "…Icon = audio-headset (tiene perfil de manos libres)" '"audio-headset"' "$(bp "$BZ1" $BZID Icon)"
eqv "…Adapter = el hci0" "\"$BZA\"" "$(bp "$BZ1" $BZID Adapter)"
eqv "…UUIDs (los que da bt info)" "[\"$UUID_A2DP\"]" "$(bp "$BZ1" $BZID UUIDs)"
eqv "…ServicesResolved = true mientras está conectado" true "$(bp "$BZ1" $BZID ServicesResolved)"
eqv "Battery1.Percentage = 80" 80 "$(bp "$BZ1" $BZIB Percentage)"

OUT=$(sb get-property "$BZ" "$BZ2" $BZID Name 2>&1); [ $? -ne 0 ] && ok "un dispositivo sin nombre no tiene la propiedad Name (como en BlueZ)" || bad "Name sin nombre" "$OUT"
eqv "…y su Alias es la dirección con guiones" '"AA-BB-CC-DD-EE-02"' "$(bp "$BZ2" $BZID Alias)"
eqv "…no está conectado ni tiene los servicios resueltos" "false false" "$(bp "$BZ2" $BZID Connected) $(bp "$BZ2" $BZID ServicesResolved)"
[ -z "$(bp "$BZ2" $BZID Class)" ] && [ -z "$(bp "$BZ2" $BZID Icon)" ] && ok "…y sin Class ni Icon cuando no se sabe de qué tipo es" || bad "Class/Icon de un dispositivo desconocido"
[ -z "$(bp "$BZ2" $BZIB Percentage)" ] && ok "…ni Battery1 si no hay batería" || bad "Battery1 de un dispositivo sin batería"

OUT=$(gdbus introspect --address "$SYS_ADDR" --dest "$BZ" --object-path "$BZA" 2>&1)
case $OUT in *"interface org.bluez.Adapter1"*"StartDiscovery"*"readwrite b Powered"*) ok "gdbus introspect enseña Adapter1 con StartDiscovery y Powered de lectura y escritura" ;; *) bad "introspección del adaptador" "$OUT" ;; esac
OUT=$(gdbus introspect --address "$SYS_ADDR" --dest "$BZ" --object-path "$BZ1" 2>&1)
case $OUT in *"interface org.bluez.Device1"*"Connect()"*"ConnectProfile"*"readonly b Connected"*"readwrite b Trusted"*"interface org.bluez.Battery1"*"readonly y Percentage"*) ok "…y Device1 con Connect, Connected de solo lectura, Trusted de escritura y Battery1" ;; *) bad "introspección del dispositivo" "$OUT" ;; esac
OUT=$(sb --no-legend tree "$BZ" 2>&1)
case $OUT in *"$BZ1"*"$BZ2"*) ok "busctl tree dibuja el árbol de objetos" ;; *) bad "busctl tree" "$OUT" ;; esac
OUT=$(sb call "$BZ" /org/bluez org.bluez.AgentManager1 RegisterAgent os /nexo/prueba KeyboardDisplay 2>&1) && sb call "$BZ" /org/bluez org.bluez.AgentManager1 RequestDefaultAgent o /nexo/prueba >/dev/null 2>&1 \
    && ok "AgentManager1 acepta que los applets registren su agente (aunque aquí no se empareja)" || bad "AgentManager1" "$OUT"
OUT=$(gc "$BZA" $BZIA.SetDiscoveryFilter "{}"); [ "$OUT" = "()" ] && ok "SetDiscoveryFilter y GetDiscoveryFilters responden" || bad "SetDiscoveryFilter" "$OUT"

# ------------------------------------------------------------------------------ escrituras
echo "== nexo-dbus: BlueZ, propiedades que se escriben"
OUT=$(sb set-property "$BZ" "$BZ1" $BZID Alias s "Mis cascos" 2>&1); [ $? -eq 0 ] && ok "escribir Alias de un dispositivo funciona" || bad "set Alias" "$OUT"
poll '[ "$(bp "$BZ1" $BZID Alias)" = "\"Mis cascos\"" ]' 3 && ok "…y la propiedad cambia" || bad "Alias no cambió" "$(bp "$BZ1" $BZID Alias)"
OUT=$(app "$ZPORT" bt info AA:BB:CC:DD:EE:01 --json); printf '%s' "$OUT" | jq -e '.alias == "Mis cascos"' >/dev/null 2>&1 && ok "…de verdad en Android (bt.rename)" || bad "el alias no llegó a la app" "$OUT"
sb set-property "$BZ" "$BZ1" $BZID Alias s "" >/dev/null 2>&1
poll '[ "$(bp "$BZ1" $BZID Alias)" = "\"Auriculares ñandú\"" ]' 3 && ok "…y un Alias vacío vuelve al nombre de siempre" || bad "Alias vacío" "$(bp "$BZ1" $BZID Alias)"
sb set-property "$BZ" "$BZ1" $BZID Trusted b false >/dev/null 2>&1
eqv "Trusted se puede cambiar (Android no lo tiene: se recuerda en el demonio)" false "$(bp "$BZ1" $BZID Trusted)"
OUT=$(gset "$BZ1" $BZID Blocked "<true>"); case $OUT in *org.bluez.Error.NotSupported*) ok "bloquear un dispositivo → org.bluez.Error.NotSupported (Android no deja)" ;; *) bad "Blocked" "$OUT" ;; esac
OUT=$(gset "$BZ1" $BZID Blocked "<false>"); [ "$OUT" = "()" ] && ok "…y desbloquear no es un error" || bad "Blocked false" "$OUT"
OUT=$(gset "$BZA" $BZIA Alias "<'otro'>"); case $OUT in *org.bluez.Error.NotSupported*) ok "cambiar el Alias del adaptador → NotSupported (se hace en los ajustes de Android)" ;; *) bad "Alias del adaptador" "$OUT" ;; esac
OUT=$(gset "$BZA" $BZIA Discoverable "<true>"); case $OUT in *org.bluez.Error.NotSupported*) ok "Discoverable = true → NotSupported" ;; *) bad "Discoverable" "$OUT" ;; esac
OUT=$(gset "$BZA" $BZIA Pairable "<false>"); case $OUT in *org.bluez.Error.NotSupported*) ok "Pairable = false → NotSupported" ;; *) bad "Pairable" "$OUT" ;; esac
OUT=$(gset "$BZ1" $BZID Connected "<false>"); case $OUT in *PropertyReadOnly*|*"not writable"*|*"read-only"*) ok "una propiedad de solo lectura (Connected) no se deja escribir" ;; *) bad "Connected de solo lectura" "$OUT" ;; esac

# ------------------------------------------------------------------------------ métodos y errores
echo "== nexo-dbus: BlueZ, métodos y errores"
OUT=$(gc "$BZ1" $BZID.Connect)
case $OUT in *org.nexo.Error.NeedsUserAction*"Android no permite"*) ok "Device1.Connect → org.nexo.Error.NeedsUserAction con el aviso de la app (sin root, Android no deja conectar)" ;; *) bad "Connect" "$OUT" ;; esac
OUT=$(gc "$BZ1" $BZID.Disconnect);                          case $OUT in *org.nexo.Error.NeedsUserAction*) ok "Device1.Disconnect → lo mismo" ;; *) bad "Disconnect" "$OUT" ;; esac
OUT=$(gc "$BZ1" $BZID.ConnectProfile "$UUID_A2DP");         case $OUT in *org.nexo.Error.NeedsUserAction*) ok "ConnectProfile → lo mismo" ;; *) bad "ConnectProfile" "$OUT" ;; esac
OUT=$(gc "$BZ1" $BZID.DisconnectProfile "$UUID_A2DP");      case $OUT in *org.nexo.Error.NeedsUserAction*) ok "DisconnectProfile → lo mismo" ;; *) bad "DisconnectProfile" "$OUT" ;; esac
OUT=$(gc "$BZ1" $BZID.Pair);                                case $OUT in *org.bluez.Error.AlreadyExists*) ok "Pair → org.bluez.Error.AlreadyExists (se empareja en Android; aquí todo está ya emparejado)" ;; *) bad "Pair" "$OUT" ;; esac
OUT=$(gc "$BZ1" $BZID.CancelPairing);                       case $OUT in *org.bluez.Error.DoesNotExist*) ok "CancelPairing → org.bluez.Error.DoesNotExist" ;; *) bad "CancelPairing" "$OUT" ;; esac
OUT=$(gc "$BZ1" $BZID.NoExiste);                            case $OUT in *UnknownMethod*|*"no such method"*|*"No such method"*) ok "un método que no existe → UnknownMethod" ;; *) bad "método desconocido" "$OUT" ;; esac
OUT=$(gc "$BZ7" $BZID.Connect);                             case $OUT in *UnknownObject*|*"No such"*|*"no such"*|*UnknownMethod*) ok "un dispositivo que no existe → UnknownObject" ;; *) bad "objeto desconocido" "$OUT" ;; esac

# ------------------------------------------------------------------------------ cambios en Android → señales
echo "== nexo-dbus: BlueZ, lo que pasa en Android llega como señales"
zmon_start
ctl "bt connect AA:BB:CC:DD:EE:02"
waitfor "$DB/zmon.txt" "'Connected': <true>" 5 && ok "al conectar Android un dispositivo sale PropertiesChanged con Connected = true" || bad "señal de Connected" "$(cat "$DB/zmon.txt")"
zsig PropertiesChanged "$BZ2" "'ServicesResolved': <true>" && ok "…junto con ServicesResolved" || bad "ServicesResolved"
eqv "…y la propiedad lo dice" true "$(bp "$BZ2" $BZID Connected)"
poll '[ "$(bp "$BZ2" $BZIB Percentage)" = 80 ]' 6 && ok "…y como ahora hay batería, aparece Battery1" || bad "Battery1 de $BZ2" "$(mo)"
zsig InterfacesAdded "$BZ2" "org.bluez.Battery1" && ok "…anunciada con InterfacesAdded" || bad "InterfacesAdded de la batería" "$(cat "$DB/zmon.txt")"
ctl "bt battery AA:BB:CC:DD:EE:02 55"
poll '[ "$(bp "$BZ2" $BZIB Percentage)" = 55 ]' 10 && ok "si la batería cambia, Percentage se actualiza (cada NEXO_DBUS_REFRESH segundos, aquí 3)" || bad "batería 55" "$(bp "$BZ2" $BZIB Percentage)"
zsig PropertiesChanged "$BZ2" "'Percentage': <byte 0x37>" && ok "…con PropertiesChanged" || bad "PropertiesChanged de la batería" "$(grep Percentage "$DB/zmon.txt" | tail -3)"
ctl "bt battery AA:BB:CC:DD:EE:02 none"
poll '[ -z "$(bp "$BZ2" $BZIB Percentage)" ]' 10 && ok "si el dispositivo deja de dar batería, Battery1 desaparece" || bad "Battery1 no se quitó"
zsig InterfacesRemoved "$BZ2" "org.bluez.Battery1" && ok "…con InterfacesRemoved" || bad "InterfacesRemoved de la batería" "$(cat "$DB/zmon.txt")"
ctl "bt disconnect AA:BB:CC:DD:EE:01"
waitfor "$DB/zmon.txt" "'Connected': <false>" 5 && ok "al desconectarse otro, Connected = false" || bad "señal de desconexión"
poll '[ "$(bp "$BZ1" $BZID Connected)" = false ] && [ "$(bp "$BZ1" $BZID ServicesResolved)" = false ]' 3 && ok "…y ServicesResolved también" || bad "ServicesResolved tras desconectar"
ctl "bt add Teclado AA:BB:CC:DD:EE:03 peripheral le"
poll '[ "$(bp "$BZ3" $BZID Name)" = "\"Teclado\"" ]' 6 && ok "un dispositivo recién emparejado en Android aparece solo" || bad "dispositivo nuevo" "$(mo)"
zsig InterfacesAdded "$BZ3" "org.bluez.Device1" && ok "…con InterfacesAdded" || bad "InterfacesAdded del dispositivo" "$(cat "$DB/zmon.txt")"
eqv "…con Class de periférico (0x0500) y sin Icon (no hay un icono estándar)" "1280 " "$(bp "$BZ3" $BZID Class) $(bp "$BZ3" $BZID Icon)"
ctl "bt remove AA:BB:CC:DD:EE:03"
poll '[ -z "$(bp "$BZ3" $BZID Address)" ]' 6 && ok "y uno que se desempareja en Android desaparece" || bad "dispositivo quitado" "$(mo)"
zsig InterfacesRemoved "$BZ3" "org.bluez.Device1" && ok "…con InterfacesRemoved" || bad "InterfacesRemoved del dispositivo" "$(cat "$DB/zmon.txt")"

# ------------------------------------------------------------------------------ encender y apagar
echo "== nexo-dbus: BlueZ, encendido y apagado"
app "$ZPORT" bt off >/dev/null 2>&1
poll '[ "$(bp "$BZA" $BZIA Powered)" = false ]' 4 && ok "«nexo bt off» → Powered = false" || bad "Powered tras apagar" "$(bp "$BZA" $BZIA Powered)"
eqv "…PowerState = off" '"off"' "$(bp "$BZA" $BZIA PowerState)"
poll '[ "$(bp "$BZ2" $BZID Connected)" = false ]' 4 && ok "…y los dispositivos dejan de estar conectados (siguen emparejados)" || bad "Connected con el Bluetooth apagado"
waitfor "$DB/zmon.txt" "'Powered': <false>" 3 && ok "…con PropertiesChanged" || bad "señal de Powered"
app "$ZPORT" bt on >/dev/null 2>&1
poll '[ "$(bp "$BZA" $BZIA Powered)" = true ]' 4 && ok "«nexo bt on» → Powered = true" || bad "Powered tras encender"
sb set-property "$BZ" "$BZA" $BZIA Powered b false >/dev/null 2>&1
eqv "escribir Powered = false apaga el Bluetooth de Android" false "$(app "$ZPORT" bt status --json | jq -c '.enabled')"
eqv "…y la propiedad ya lo dice" false "$(bp "$BZA" $BZIA Powered)"
sb set-property "$BZ" "$BZA" $BZIA Powered b true >/dev/null 2>&1
eqv "Powered = true lo enciende" true "$(app "$ZPORT" bt status --json | jq -c '.enabled')"

# ------------------------------------------------------------------------------ descubrimiento
echo "== nexo-dbus: BlueZ, StartDiscovery y StopDiscovery"
OUT=$(gc "$BZA" $BZIA.StartDiscovery); [ "$OUT" = "()" ] && ok "StartDiscovery responde" || bad "StartDiscovery" "$OUT"
eqv "…Discovering = true" true "$(bp "$BZA" $BZIA Discovering)"
grep -q "StartDiscovery solo enciende el Bluetooth" "$DB/Z.log" && ok "…y el registro avisa (una vez) de que Nexo no busca dispositivos nuevos" || bad "aviso de StartDiscovery"
OUT=$(gc "$BZA" $BZIA.StopDiscovery); [ "$OUT" = "()" ] && ok "StopDiscovery responde" || bad "StopDiscovery" "$OUT"
eqv "…Discovering = false" false "$(bp "$BZA" $BZIA Discovering)"
OUT=$(gc "$BZA" $BZIA.StopDiscovery); case $OUT in *org.bluez.Error.Failed*) ok "un segundo StopDiscovery → org.bluez.Error.Failed (como BlueZ)" ;; *) bad "StopDiscovery sin Start" "$OUT" ;; esac
app "$ZPORT" bt off >/dev/null 2>&1
poll '[ "$(bp "$BZA" $BZIA Powered)" = false ]' 4
OUT=$(gc "$BZA" $BZIA.StartDiscovery); [ "$OUT" = "()" ] && ok "con el Bluetooth apagado, StartDiscovery funciona…" || bad "StartDiscovery con el Bluetooth apagado" "$OUT"
eqv "…lo ENCIENDE en Android" true "$(app "$ZPORT" bt status --json | jq -c '.enabled')"
eqv "…y Discovering = true" true "$(bp "$BZA" $BZIA Discovering)"
gc "$BZA" $BZIA.StopDiscovery >/dev/null
eqv "StopDiscovery NO lo vuelve a apagar (por omisión)" true "$(app "$ZPORT" bt status --json | jq -c '.enabled')"
dd_stop
sgone "$BZ" 6 && ok "al parar nexo-dbus, org.bluez se va" || bad "org.bluez no se fue"
grep -q "BlueZ: retiro org.bluez" "$DB/Z.log" && ok "…y lo anota" || bad "retirada sin anotar" "$(tail -4 "$DB/Z.log")"

bzdd Z2 "$ZPORT" NEXO_DBUS_DISCOVERY_RESTORE=1 NEXO_DBUS_DISCOVERY_SECS=2
swait "$BZ" 8 || bad "(restore) org.bluez no apareció" "$(cat "$DB/Z2.log")"
eqv "con la misma app y el mismo nombre, el adaptador tiene la misma dirección inventada tras reiniciar" "$ADDR1" "$(bp "$BZA" $BZIA Address)"
app "$ZPORT" bt off >/dev/null 2>&1
poll '[ "$(bp "$BZA" $BZIA Powered)" = false ]' 4
gc "$BZA" $BZIA.StartDiscovery >/dev/null
eqv "(NEXO_DBUS_DISCOVERY_RESTORE=1) StartDiscovery enciende el Bluetooth…" true "$(app "$ZPORT" bt status --json | jq -c '.enabled')"
gc "$BZA" $BZIA.StopDiscovery >/dev/null
poll '[ "$(app "$ZPORT" bt status --json | jq -c ".enabled")" = false ]' 4 && ok "…y StopDiscovery lo vuelve a apagar, porque lo encendió él" || bad "no se restauró el apagado"
app "$ZPORT" bt on >/dev/null 2>&1
poll '[ "$(bp "$BZA" $BZIA Powered)" = true ]' 4
gc "$BZA" $BZIA.StartDiscovery >/dev/null; gc "$BZA" $BZIA.StopDiscovery >/dev/null
eqv "…pero si ya estaba encendido (lo hizo el usuario), no lo toca" true "$(app "$ZPORT" bt status --json | jq -c '.enabled')"
gc "$BZA" $BZIA.StartDiscovery >/dev/null
eqv "Discovering = true tras StartDiscovery" true "$(bp "$BZA" $BZIA Discovering)"
poll '[ "$(bp "$BZA" $BZIA Discovering)" = false ]' 6 && ok "…y a los NEXO_DBUS_DISCOVERY_SECS segundos (aquí 2) vuelve solo a false" || bad "Discovering no caducó"

# ------------------------------------------------------------------------------ desemparejar
echo "== nexo-dbus: BlueZ, RemoveDevice"
zmon_start
OUT=$(gc "$BZA" $BZIA.RemoveDevice "$BZ2")
case $OUT in *org.nexo.Error.NeedsUserAction*) ok "RemoveDevice cuando Android no deja desemparejar → NeedsUserAction (con el aviso de la app)" ;; *) bad "RemoveDevice bloqueado" "$OUT" ;; esac
[ -n "$(bp "$BZ2" $BZID Address)" ] && ok "…y el dispositivo sigue ahí" || bad "el dispositivo desapareció"
OUT=$(gc "$BZA" $BZIA.RemoveDevice "$BZ7"); case $OUT in *org.bluez.Error.DoesNotExist*) ok "RemoveDevice de uno que no existe → DoesNotExist" ;; *) bad "RemoveDevice inexistente" "$OUT" ;; esac
app "$ZPORT" bt off >/dev/null 2>&1
poll '[ "$(bp "$BZA" $BZIA Powered)" = false ]' 4
OUT=$(gc "$BZA" $BZIA.RemoveDevice "$BZ1"); case $OUT in *org.bluez.Error.NotReady*) ok "con el Bluetooth apagado, Android no deja desemparejar → org.bluez.Error.NotReady" ;; *) bad "RemoveDevice con el Bluetooth apagado" "$OUT" ;; esac
app "$ZPORT" bt on >/dev/null 2>&1
poll '[ "$(bp "$BZA" $BZIA Powered)" = true ]' 4
OUT=$(gc "$BZA" $BZIA.RemoveDevice "$BZ1"); [ "$OUT" = "()" ] && ok "RemoveDevice del dispositivo 01 funciona" || bad "RemoveDevice" "$OUT"
poll '[ -z "$(bp "$BZ1" $BZID Address)" ]' 4 && ok "…el objeto desaparece" || bad "el objeto no desapareció"
zsig InterfacesRemoved "$BZ1" "org.bluez.Device1" && ok "…con InterfacesRemoved (y la batería con él)" || bad "InterfacesRemoved" "$(cat "$DB/zmon.txt")"
OUT=$(app "$ZPORT" bt paired --json); printf '%s' "$OUT" | jq -e '[.devices[].address] == ["AA:BB:CC:DD:EE:02"]' >/dev/null 2>&1 && ok "…y de verdad en Android (bt.forget)" || bad "Android sigue con el dispositivo" "$OUT"
zmon_stop

# ------------------------------------------------------------------------------ ciclo de vida
echo "== nexo-dbus: BlueZ aparece y desaparece según Android y el bus"
dd_stop
kill "$ZPID" 2>/dev/null; wait "$ZPID" 2>/dev/null
: > "$DB/ctlZ"
ZPORT=$(start_app dbusZ2 --ctl "$DB/ctlZ")
ZPID=$(cat "$T/dbusZ2.pid")
bzdd Z3 "$ZPORT"
swait "$BZ" 8 && ok "(app nueva) org.bluez está" || bad "(app nueva) no apareció" "$(cat "$DB/Z3.log")"
poll '[ -n "$(bp "$BZ2" $BZID Address)" ]' 6
kill "$ZPID" 2>/dev/null; wait "$ZPID" 2>/dev/null
sgone "$BZ" 10 && ok "si la app deja de responder, org.bluez se retira pasado el margen" || bad "no se retiró" "$(tail -5 "$DB/Z3.log")"
grep -q "retiro org.bluez (la app Nexo no responde)" "$DB/Z3.log" && ok "…y dice por qué" || bad "motivo de la retirada" "$(tail -5 "$DB/Z3.log")"
poll 'dst_has "esperando a la app Nexo"' 4 && ok "…y nexo-dbus status también (esperando a la app Nexo)" || bad "status con la app caída" "$(dstate)"
: > "$DB/ctlZ"
start_app dbusZ3 --port "$ZPORT" --ctl "$DB/ctlZ" >/dev/null
ZPID=$(cat "$T/dbusZ3.pid")
swait "$BZ" 20 && ok "al volver la app, org.bluez vuelve solo" || bad "no volvió" "$(tail -5 "$DB/Z3.log")"
poll '[ -n "$(bp "$BZ1" $BZID Address)" ]' 8 && ok "…con sus dispositivos" || bad "sin dispositivos tras volver"

sbus_stop
sleep 1
kill -0 "$DD_PID" 2>/dev/null && ok "si el bus del sistema se cae, nexo-dbus sigue vivo" || bad "murió con el bus"
sbus_start
swait "$BZ" 15 && ok "…y cuando el bus vuelve, org.bluez también" || bad "no volvió tras reiniciar el bus" "$(tail -6 "$DB/Z3.log")"
grep -q "BlueZ: se perdió la conexión con el bus; reconecto" "$DB/Z3.log" && ok "…y lo anota" || bad "no anotó la pérdida del bus"
poll '[ -n "$(bp "$BZ1" $BZID Address)" ]' 8 && ok "…con los dispositivos otra vez" || bad "sin dispositivos tras el reinicio del bus"
dd_stop

# el bus del sistema todavía no existe cuando arranca nexo-dbus; mientras, MPRIS (bus de sesión) funciona
sbus_stop
YPORT=$(start_app dbusY)
bzdd Y "$YPORT" NEXO_DBUS_MPRIS=1
wait_name "$MP" 8 && ok "sin bus del sistema, el reproductor MPRIS (bus de sesión) funciona igual: cada servicio falla por separado" || bad "MPRIS sin bus del sistema" "$(cat "$DB/Y.log")"
poll 'grep -q "BlueZ: esperando un bus del sistema de D-Bus" "$DB/Y.log"' 6 && ok "…y BlueZ avisa de que espera un bus del sistema" || bad "aviso de espera" "$(cat "$DB/Y.log")"
poll 'dst_has "No pude conectar con el bus del sistema"' 4 && ok "…y nexo-dbus status lo cuenta, con el motivo" || bad "status sin bus del sistema" "$(dstate)"
dst_has "$(printf "%-15s %s" MPRIS "org.mpris.MediaPlayer2.nexo activo")" && ok "…mientras MPRIS figura como activo" || bad "status de MPRIS" "$(dstate)"
sbus_start
swait "$BZ" 10 && ok "cuando aparece el bus del sistema, org.bluez aparece" || bad "no apareció al llegar el bus" "$(tail -5 "$DB/Y.log")"
has_name "$MP" && ok "…y MPRIS sigue donde estaba" || bad "MPRIS desapareció"
sbus_stop
sleep 1
has_name "$MP" && ok "si luego se cae el bus del sistema, MPRIS no se entera" || bad "MPRIS cayó con el bus del sistema"
sbus_start
swait "$BZ" 15 || bad "(Y) no volvió org.bluez" "$(tail -5 "$DB/Y.log")"
dd_stop

bzdd N "$YPORT" NEXO_DBUS_BLUEZ=0 NEXO_DBUS_MPRIS=1
wait_name "$MP" 8 || bad "(N) MPRIS no apareció: el demonio no está en marcha" "$(cat "$DB/N.log")"
sleep 2.5
! shas "$BZ" && ok "NEXO_DBUS_BLUEZ=0 → no ocupa org.bluez" || bad "BLUEZ=0 ocupó el nombre"
dst_has "$(printf "%-15s %s" BlueZ apagado)" && ok "…y status dice que BlueZ está apagado" || bad "status con BLUEZ=0" "$(dstate)"
dd_stop
[ ! -e "$DB/run/nexo-dbus.state" ] && ok "al parar, el demonio borra su archivo de estado" || bad "quedó el archivo de estado"
dstate | grep -qF "nexo-dbus parado" && ok "…y status dice «parado»" || bad "status parado" "$(dstate)"
DD_OPTS=(-v --no-bluez)
bzdd N2 "$YPORT" NEXO_DBUS_MPRIS=1
wait_name "$MP" 8 || bad "(N2) MPRIS no apareció: el demonio no está en marcha" "$(cat "$DB/N2.log")"
sleep 2.5
! shas "$BZ" && ok "--no-bluez → tampoco" || bad "--no-bluez ocupó el nombre"
dd_stop
DD_OPTS=(-v)
# sin ningún servicio que ofrecer, no tiene sentido quedarse: sale diciendo por qué (y no «no hay bus»)
DD_OPTS=(-v --no-mpris --no-bluez --no-nm)
bzdd N3 "$YPORT"
poll '! kill -0 "$DD_PID" 2>/dev/null' 5 && ok "con todos los servicios apagados, nexo-dbus sale en vez de quedarse sin hacer nada…" || bad "siguió en marcha sin servicios"
grep -q "todos los servicios están apagados" "$DB/N3.log" && ok "…y dice que es porque están apagados" || bad "mensaje sin servicios" "$(cat "$DB/N3.log")"
dd_stop
DD_OPTS=(-v)

# ------------------------------------------------------------------------------ otro programa tiene el nombre
echo "== nexo-dbus: BlueZ y el BlueZ de verdad (modo pasivo, NEXO_DBUS_FORCE, política, systemd)"
: > "$HOLD_OUT"
python3 "$ROOT/tests/dbus_hold.py" "$ROOT/termux/bin/nexo-dbus" "$SYS_ADDR" "$BZ" >"$HOLD_OUT" 2>&1 &
HOLD_PID=$!
APP_PIDS+=("$HOLD_PID")
waitfor "$HOLD_OUT" "OWNER" 4 && ok "(un «BlueZ de verdad» ocupa org.bluez)" || bad "el dueño de prueba no arrancó" "$(cat "$HOLD_OUT")"
HOLD_NAME=$(awk '/^OWNER/ {print $2}' "$HOLD_OUT")
bzdd P "$YPORT"
poll 'grep -q "ya hay un BlueZ de verdad en este bus" "$DB/P.log"' 6 && ok "con un BlueZ de verdad en el bus, nexo-dbus no lo pisa (modo pasivo)" || bad "modo pasivo" "$(cat "$DB/P.log")"
poll 'dst_has "pasivo: ya hay un BlueZ de verdad en este bus"' 4 && ok "…y nexo-dbus status lo cuenta (pasivo, y cómo forzarlo)" || bad "status en modo pasivo" "$(dstate)"
eqv "…y el dueño del nombre sigue siendo el de verdad" "$HOLD_NAME" "$(sowner "$BZ")"
kill -0 "$DD_PID" 2>/dev/null && ok "…y nexo-dbus sigue vivo" || bad "murió en modo pasivo"
dd_stop
bzdd P2 "$YPORT" NEXO_DBUS_FORCE=1
poll '[ "$(sowner "$BZ")" != "$HOLD_NAME" ] && [ -n "$(sowner "$BZ")" ]' 8 && ok "con NEXO_DBUS_FORCE=1 se queda el nombre…" || bad "FORCE" "$(tail -4 "$DB/P2.log")"
waitfor "$HOLD_OUT" "LOST $BZ" 3 && ok "…y el dueño anterior lo cede" || bad "el dueño anterior no recibió NameLost" "$(cat "$HOLD_OUT")"
poll '[ -n "$(bp "$BZA" $BZIA Address)" ]' 6 && ok "…y el adaptador responde" || bad "tras FORCE"
dd_stop
kill "$HOLD_PID" 2>/dev/null; wait "$HOLD_PID" 2>/dev/null

# alguien le reclama el nombre a nexo-dbus
bzdd R "$YPORT"
swait "$BZ" 8 || bad "(R) org.bluez no apareció" "$(cat "$DB/R.log")"
: > "$HOLD_OUT"
python3 "$ROOT/tests/dbus_hold.py" "$ROOT/termux/bin/nexo-dbus" "$SYS_ADDR" "$BZ" --replace >"$HOLD_OUT" 2>&1 &
HOLD_PID=$!
APP_PIDS+=("$HOLD_PID")
poll 'grep -q "otro programa reclamó org.bluez: cedo el nombre" "$DB/R.log"' 8 && ok "si luego un BlueZ de verdad reclama el nombre, nexo-dbus lo cede y lo anota" || bad "no cedió" "$(tail -4 "$DB/R.log")"
sleep 1.5
HOLD_NAME=$(awk '/^OWNER/ {print $2}' "$HOLD_OUT")
eqv "…y no se lo vuelve a quitar" "$HOLD_NAME" "$(sowner "$BZ")"
dd_stop
kill "$HOLD_PID" 2>/dev/null; wait "$HOLD_PID" 2>/dev/null

# systemd gestiona bluetooth.service
bzdd S "$YPORT" NEXO_DBUS_SYSTEMD_DIR="$DB"
poll 'grep -q "systemd gestiona bluetooth.service" "$DB/S.log"' 6 && ok "con systemd y bluez instalado (org.bluez «activable»), no ocupa org.bluez: lo arrancaría systemd" || bad "pista de systemd" "$(cat "$DB/S.log")"
! shas "$BZ" && ok "…y el nombre queda libre" || bad "ocupó el nombre con systemd"
poll 'dst_has "pasivo: systemd gestiona bluetooth.service en este equipo"' 4 && ok "…y status lo cuenta" || bad "status con systemd" "$(dstate)"
dd_stop
bzdd S2 "$YPORT" NEXO_DBUS_SYSTEMD_DIR="$DB" NEXO_DBUS_BLUEZ=1
swait "$BZ" 8 && ok "…salvo que se pida con NEXO_DBUS_BLUEZ=1" || bad "BLUEZ=1" "$(cat "$DB/S2.log")"
dd_stop

# el bus no deja a este usuario ocupar org.bluez (en un bus del sistema de verdad hace falta una política)
sbus_stop
sbus_conf '<deny own="org.bluez"/>'
sbus_start
bzdd D "$YPORT" NEXO_DBUS_MPRIS=1
wait_name "$MP" 8 && ok "si la política del bus no deja ocupar org.bluez, MPRIS sigue funcionando" || bad "MPRIS con BlueZ denegado" "$(cat "$DB/D.log")"
poll 'grep -q "no deja a este usuario ocupar org.bluez" "$DB/D.log"' 6 && ok "…y BlueZ lo cuenta" || bad "aviso de política" "$(cat "$DB/D.log")"
grep -q -- "--system-policy" "$DB/D.log" && ok "…diciendo cómo arreglarlo (nexo setup-dbus --system-policy)" || bad "pista de --system-policy"
! shas "$BZ" && ok "…sin ocupar el nombre" || bad "ocupó el nombre a pesar de la política"
poll 'dst_has "nexo setup-dbus --system-policy"' 4 && ok "…y nexo-dbus status también lo cuenta, con el remedio" || bad "status sin permiso" "$(dstate)"
dd_stop

# La política de verdad: el bus lo niega todo por omisión (como un Linux normal) y «nexo setup-dbus --system-policy» lo permite.
echo "== nexo setup-dbus --system-policy (política del bus del sistema) con un bus que lo niega todo"
sbus_stop
sbus_conf '<deny own="org.bluez"/><deny own="org.freedesktop.NetworkManager"/><deny send_destination="org.bluez"/><deny send_destination="org.freedesktop.NetworkManager"/>'
sbus_start
NMN=org.freedesktop.NetworkManager
PF=$DB/policy.d/nexo.conf
rm -f "$PF"
dd_start Q "$YPORT" NEXO_DBUS_SYSTEM_BUS="$SYS_ADDR" NEXO_DBUS_MPRIS=0 NEXO_DBUS_SYSTEMD_DIR="$NOSD" NEXO_DBUS_DENIED_RETRY=2
poll 'grep -q "BlueZ: el bus no deja a este usuario ocupar org.bluez" "$DB/Q.log" && grep -q "NetworkManager: el bus no deja a este usuario ocupar org.freedesktop.NetworkManager" "$DB/Q.log"' 8 && ok "sin política, el bus no deja ocupar ni org.bluez ni NetworkManager, y los dos lo cuentan" || bad "sin política" "$(cat "$DB/Q.log")"
! shas "$BZ" && ! shas "$NMN" && ok "…y no ocupan ningún nombre" || bad "ocuparon nombres sin permiso"
sdp() { sdn env DBUS_SYSTEM_BUS_ADDRESS="$SYS_ADDR" NEXO_DBUS_POLICY_DIR="$DB/policy.d" NEXO_TOKEN="$TOKEN" NEXO_PORT="$YPORT" "$SD/bin/nexo" "$@"; }
run sdp setup-dbus --system-policy --no-start
rc_is "nexo setup-dbus --system-policy → 0 (aquí somos root)" 0
has "…cuenta dónde dejó la política y para quién" "$PF (usuarios: $(id -un))"
has "…y que el bus ya la leyó" "el bus del sistema ya la leyó"
[ -f "$PF" ] && python3 -c 'import sys, xml.dom.minidom; xml.dom.minidom.parse(sys.argv[1])' "$PF" 2>"$T/err" && ok "…el archivo es XML bien formado" || bad "nexo.conf mal formado" "$(cat "$T/err")"
grep -q "<policy user=\"$(id -un)\">" "$PF" && grep -q 'allow own="org.bluez"' "$PF" && grep -q 'allow own="org.freedesktop.NetworkManager"' "$PF" && ok "…con el usuario y los dos nombres" || bad "contenido de nexo.conf" "$(cat "$PF")"
swait "$BZ" 12 && swait "$NMN" 12 && ok "con la política, nexo-dbus ocupa org.bluez y NetworkManager sin reiniciarse (reintenta cada pocos segundos)" || bad "no ocupó tras la política" "$(tail -8 "$DB/Q.log")"
OUT=$(gc / org.freedesktop.DBus.ObjectManager.GetManagedObjects)
case $OUT in *"'org.bluez.Adapter1'"*) ok "…y hablarle también está permitido (send_destination)" ;; *) bad "llamada a org.bluez con la política" "$OUT" ;; esac
poll 'dst_has "$(printf "%-15s %s" BlueZ "org.bluez activo")" && dst_has "org.freedesktop.NetworkManager activo"' 4 && ok "…y nexo-dbus status los da por activos" || bad "status tras la política" "$(dstate)"
run sdp setup-dbus --system-policy --policy-user nobody --policy-user "$(id -un)" --no-start
rc_is "con --policy-user se pueden dar varios usuarios (repetir la orden lo reescribe)" 0
grep -q '<policy user="nobody">' "$PF" && [ "$(grep -c '<policy user=' "$PF")" = 2 ] && ok "…y el archivo los lleva a los dos, una sola vez cada uno" || bad "varios usuarios" "$(cat "$PF")"
run sdp setup-dbus --system-policy --policy-user 'a b' --no-start
rc_is "--policy-user con un nombre raro se rechaza (va dentro de un XML): 2" 2
run sdp setup-dbus --policy-user -x --no-start
rc_is "…y uno que empieza por guion también" 2
run sdn env NEXO_DBUS_POLICY_DIR=/proc/no-se-puede NEXO_TOKEN="$TOKEN" NEXO_PORT="$YPORT" "$SD/bin/nexo" setup-dbus --system-policy --no-start
rc_is "si no puede escribir la política, avisa pero sigue con el resto (0)" 0
has "…y dice qué hacer a mano" "sudo cp"
run sdp setup-dbus --uninstall
has "setup-dbus --uninstall quita la política…" "política del bus del sistema quitada"
[ ! -e "$PF" ] && ok "…y el archivo ya no está" || bad "sigue nexo.conf"
echo '<busconfig><!-- de otro programa --></busconfig>' > "$PF"
run sdp setup-dbus --uninstall
[ -f "$PF" ] && ok "…pero no toca un nexo.conf que no es suyo" || bad "borró un nexo.conf ajeno"
rm -f "$PF"
dd_stop
sbus_stop
sbus_conf ""
sbus_start

# ------------------------------------------------------------------------------ bus del sistema propio
echo "== nexo-dbus: --own-bus también crea el bus «del sistema» que falte (proot)"
OWN_SOCK=$DB/ownsys/system_bus_socket
mkdir -p "$DB/runO" "$DB/cacheO"
OPORT=$(start_app dbusO)
DD_OPTS=(-v --own-bus)
dd_start O "$OPORT" NEXO_DBUS_SYSTEM_BUS= NEXO_DBUS_SYSTEM_SOCKET="$OWN_SOCK" NEXO_DBUS_MPRIS=0 NEXO_DBUS_SYSTEMD_DIR="$NOSD" XDG_RUNTIME_DIR="$DB/runO" XDG_CACHE_HOME="$DB/cacheO"
DD_OPTS=(-v)
if [ "$(id -u)" = 0 ]; then OWN_ADDR=unix:path=$OWN_SOCK; else OWN_ADDR=unix:path=$DB/runO/nexo-system-bus; fi
poll "busctl --address=$OWN_ADDR --no-legend list --acquired | awk '{print \$1}' | grep -qx $BZ" 10 && ok "sin bus del sistema y con --own-bus, nexo-dbus arranca uno y registra org.bluez" || bad "bus del sistema propio" "$(cat "$DB/O.log")"
grep -q "bus del sistema propio en $OWN_ADDR" "$DB/O.log" && ok "…y lo anota" || bad "no anotó el bus propio" "$(cat "$DB/O.log")"
[ "$(cat "$DB/cacheO/nexo/system-bus" 2>/dev/null)" = "$OWN_ADDR" ] && ok "…guardando su dirección para el resto de terminales" || bad "dirección sin guardar" "$(ls -R "$DB/cacheO" 2>&1 | head)"
run env -i PATH="$PATH" HOME="$DB/home" XDG_RUNTIME_DIR="$DB/runO" XDG_CACHE_HOME="$DB/cacheO" NEXO_DBUS_SYSTEM_SOCKET="$OWN_SOCK" DBUS_SESSION_BUS_ADDRESS="unix:path=$BUS_SOCK" python3 "$DD" env
if [ "$(id -u)" = 0 ]; then
    hasnt "como root está en el socket de siempre: «nexo-dbus env» no pide exportar nada del sistema (bluetoothctl lo encuentra solo)" "DBUS_SYSTEM_BUS_ADDRESS"
else
    has "sin ser root va en tu carpeta de ejecución: «nexo-dbus env» da el export para tus terminales" "export DBUS_SYSTEM_BUS_ADDRESS='$OWN_ADDR'"
fi
dd_stop
for p in $(ps -eo pid,args | grep -F -- "--address=$OWN_ADDR" | grep -v grep | awk '{print $1}'); do kill "$p" 2>/dev/null; done

fi   # parte BlueZ

if [ "${NEXO_TESTS_SYSTEM_ONLY:-all}" != bluez ]; then   # parte NetworkManager

# ================================================================================ NetworkManager
echo "== nexo-dbus: NetworkManager (org.freedesktop.NetworkManager en el bus del sistema de pruebas)"
NM=org.freedesktop.NetworkManager
NMR=/org/freedesktop/NetworkManager
NMD=$NMR/Devices/1
NMS=$NMR/Settings
NMA=$NMR/AccessPoint
NMC=$NMR/ActiveConnection
NMIF=org.freedesktop.NetworkManager
# np RUTA INTERFAZ PROPIEDAD → el valor en JSON; nc RUTA INTERFAZ.MÉTODO [ARGS…] → llamada con gdbus; ntext TEXTO → sus bytes (para Ssid)
np() { sbj get-property "$NM" "$1" "$2" "$3" 2>/dev/null | jq -c '.data'; }
nc() { gdbus call --address "$SYS_ADDR" --dest "$NM" --object-path "$1" --method "$2" "${@:3}" 2>&1; }
ntext() { python3 -c 'import json,sys; print(json.dumps(list(sys.argv[1].encode()), separators=(",", ":")))' "$1"; }
nctl() { echo "$1" >> "$DB/ctlN"; }
nmdd() {
    local n=$1 p=$2
    shift 2
    dd_start "$n" "$p" NEXO_DBUS_SYSTEM_BUS="$SYS_ADDR" NEXO_DBUS_MPRIS=0 NEXO_DBUS_BLUEZ=0 NEXO_DBUS_SYSTEMD_DIR="$NOSD" NEXO_DBUS_NM_REFRESH=2 "$@"
}
npoll() { poll "$1" "${2:-6}"; }
# nap NOMBRE → la ruta del punto de acceso de esa red (vacío si no se ve): los números los reparte nexo-dbus por orden de aparición,
# y una red a la que se conecta una app sin salir en el escaneo también gasta uno, así que no se pueden dar por fijos.
nap() {
    local want p
    want=$(ntext "$1")
    for p in $(np "$NMD" $NMIF.Device.Wireless AccessPoints | jq -r '.[]'); do
        if [ "$(np "$p" $NMIF.AccessPoint Ssid)" = "$want" ]; then echo "$p"; return 0; fi
    done
    return 1
}
# lastrec → la última petición que recibió la app, normalizada (el JSON de la app falsa lleva espacios)
lastrec() { tail -1 "$DB/recN" | jq -c .; }

[ -S "$SYS_SOCK" ] || sbus_start
: > "$DB/ctlN"; : > "$DB/recN"
NPORT=$(start_app dbusN --ctl "$DB/ctlN" --record "$DB/recN" --minor3)
NPID=$(cat "$T/dbusN.pid")
nmdd N "$NPORT"
swait "$NM" 8 && ok "con WiFi en el móvil, org.freedesktop.NetworkManager aparece en el bus del sistema" || bad "NetworkManager no apareció" "$(cat "$DB/N.log")"
poll 'dst_has "$(printf "%-15s %s" NetworkManager "org.freedesktop.NetworkManager activo")"' 4 && ok "nexo-dbus status cuenta que NetworkManager está activo" || bad "status de NetworkManager activo" "$(dstate)"
grep -q "NetworkManager: org.freedesktop.NetworkManager disponible" "$DB/N.log" && ok "…y lo anota" || bad "registro de NetworkManager" "$(cat "$DB/N.log")"
npoll '[ "$(np "$NMD" $NMIF.Device State)" = 100 ] && [ -n "$(np "$NMA/3" $NMIF.AccessPoint Strength)" ]' 8 && ok "…con su dispositivo, las redes visibles y la conexión activa" || bad "faltan los objetos" "$(sbj call "$NM" /org/freedesktop org.freedesktop.DBus.ObjectManager GetManagedObjects | jq -c '.data[0] | keys')"

OUT=$(sbj call "$NM" /org/freedesktop org.freedesktop.DBus.ObjectManager GetManagedObjects 2>&1)
printf '%s' "$OUT" | jq -e --arg r "$NMR" '.data[0] | (.[$r] | keys) == ["org.freedesktop.NetworkManager"] and (.[$r + "/Devices/1"] | keys) == ["org.freedesktop.NetworkManager.Device", "org.freedesktop.NetworkManager.Device.Wireless"] and (.[$r + "/AccessPoint/1"] | keys) == ["org.freedesktop.NetworkManager.AccessPoint"] and (.[$r + "/Settings"] | keys) == ["org.freedesktop.NetworkManager.Settings"] and (.[$r + "/Settings/1"] | keys) == ["org.freedesktop.NetworkManager.Settings.Connection"] and (.[$r + "/ActiveConnection/1"] | keys) == ["org.freedesktop.NetworkManager.Connection.Active"] and (.[$r + "/IP4Config/1"] | keys) == ["org.freedesktop.NetworkManager.IP4Config"] and (.[$r + "/AgentManager"] | keys) == ["org.freedesktop.NetworkManager.AgentManager"]' >/dev/null 2>&1 \
    && ok "el ObjectManager de /org/freedesktop (el que usa libnm) lista cada objeto con sus interfaces" || bad "objetos de NetworkManager" "$(printf '%s' "$OUT" | jq -c '.data[0] | map_values(keys)')"
OUT=$(nc /org/freedesktop org.freedesktop.DBus.ObjectManager.GetManagedObjects)
case $OUT in *"'org.freedesktop.NetworkManager.Device.Wireless'"*"'org.freedesktop.NetworkManager.AccessPoint'"*"'Ssid': <[byte 0x4d, 0x69, 0x43, 0x61, 0x73, 0x61]>"*) ok "gdbus (GLib) también lo lee, con el nombre de red como arreglo de bytes (ay)" ;; *) bad "gdbus GetManagedObjects" "$OUT" ;; esac

eqv "NetworkManager.State = 70 (conectado)" 70 "$(np "$NMR" $NMIF State)"
eqv "…Connectivity = 4 (completa)" 4 "$(np "$NMR" $NMIF Connectivity)"
eqv "…WirelessEnabled, NetworkingEnabled" "true true" "$(np "$NMR" $NMIF WirelessEnabled) $(np "$NMR" $NMIF NetworkingEnabled)"
eqv "…PrimaryConnection y su tipo" "\"$NMC/1\" \"802-11-wireless\"" "$(np "$NMR" $NMIF PrimaryConnection) $(np "$NMR" $NMIF PrimaryConnectionType)"
eqv "…ActiveConnections" "[\"$NMC/1\"]" "$(np "$NMR" $NMIF ActiveConnections)"
eqv "…Devices y AllDevices" "[\"$NMD\"] [\"$NMD\"]" "$(np "$NMR" $NMIF Devices) $(np "$NMR" $NMIF AllDevices)"
eqv "…Metered = 2 (no es de pago por uso: lo dice la app con net.status)" 2 "$(np "$NMR" $NMIF Metered)"
[[ $(np "$NMR" $NMIF Version) =~ ^\"1\.[0-9]+\.[0-9]+\"$ ]] && ok "…Version con forma de versión de NetworkManager" || bad "Version" "$(np "$NMR" $NMIF Version)"
eqv "GetDevices → wlan0" "$NMD" "$(sbj call "$NM" "$NMR" $NMIF GetDevices | jq -r '.data[0][0]')"
eqv "GetDeviceByIpIface wlan0 → el mismo" "$NMD" "$(sbj call "$NM" "$NMR" $NMIF GetDeviceByIpIface s wlan0 | jq -r '.data[0]')"
OUT=$(nc "$NMR" $NMIF.GetDeviceByIpIface eth0); case $OUT in *"$NMIF.Error.UnknownDevice"*) ok "…y eth0 no existe → Error.UnknownDevice" ;; *) bad "GetDeviceByIpIface eth0" "$OUT" ;; esac
eqv "CheckConnectivity y state()" "4 70" "$(sbj call "$NM" "$NMR" $NMIF CheckConnectivity | jq -r '.data[0]') $(sbj call "$NM" "$NMR" $NMIF state | jq -r '.data[0]')"
OUT=$(sbj call "$NM" "$NMR" $NMIF GetPermissions | jq -c '.data[0]["org.freedesktop.NetworkManager.enable-disable-wifi"]'); eqv "GetPermissions dice que se puede encender y apagar el WiFi" '"yes"' "$OUT"

eqv "Device.Interface, DeviceType (2 = WiFi), State (100 = activado)" '"wlan0" 2 100' "$(np "$NMD" $NMIF.Device Interface) $(np "$NMD" $NMIF.Device DeviceType) $(np "$NMD" $NMIF.Device State)"
eqv "…ActiveConnection e Ip4Config" "\"$NMC/1\" \"$NMR/IP4Config/1\"" "$(np "$NMD" $NMIF.Device ActiveConnection) $(np "$NMD" $NMIF.Device Ip4Config)"
eqv "…Managed, Autoconnect, Driver" 'true true "nexo"' "$(np "$NMD" $NMIF.Device Managed) $(np "$NMD" $NMIF.Device Autoconnect) $(np "$NMD" $NMIF.Device Driver)"
[[ $(np "$NMD" $NMIF.Device HwAddress) =~ ^\"02(:[0-9A-F]{2}){5}\"$ ]] && ok "…HwAddress inventada y «administrada localmente» (Android no da la MAC real)" || bad "HwAddress" "$(np "$NMD" $NMIF.Device HwAddress)"
eqv "…Ip4Address = 192.168.1.23 como entero de red (0x1701A8C0)" 385984704 "$(np "$NMD" $NMIF.Device Ip4Address)"
eqv "…AvailableConnections = las 4 redes guardadas" 4 "$(np "$NMD" $NMIF.Device AvailableConnections | jq 'length')"
eqv "Device.Wireless: Mode (2 = infraestructura), Bitrate (kbit/s de wifi.status)" "2 433000" "$(np "$NMD" $NMIF.Device.Wireless Mode) $(np "$NMD" $NMIF.Device.Wireless Bitrate)"
eqv "…ActiveAccessPoint = el de MiCasa" "\"$NMA/1\"" "$(np "$NMD" $NMIF.Device.Wireless ActiveAccessPoint)"
eqv "…AccessPoints y GetAccessPoints" "[\"$NMA/1\",\"$NMA/2\",\"$NMA/3\"] [\"$NMA/1\",\"$NMA/2\",\"$NMA/3\"]" "$(np "$NMD" $NMIF.Device.Wireless AccessPoints) $(sbj call "$NM" "$NMD" $NMIF.Device.Wireless GetAccessPoints | jq -c '.data[0]')"
eqv "…GetAllAccessPoints igual" "[\"$NMA/1\",\"$NMA/2\",\"$NMA/3\"]" "$(sbj call "$NM" "$NMD" $NMIF.Device.Wireless GetAllAccessPoints | jq -c '.data[0]')"

APIF=$NMIF.AccessPoint
eqv "AccessPoint: Ssid de MiCasa (bytes)" "$(ntext MiCasa)" "$(np "$NMA/1" $APIF Ssid)"
eqv "…HwAddress (BSSID de la conexión, en mayúsculas) y Frecuencia" '"AA:BB:CC:00:00:01" 5180' "$(np "$NMA/1" $APIF HwAddress) $(np "$NMA/1" $APIF Frequency)"
eqv "…Strength = 90: de los -55 dBm de wifi.status (la red conectada usa la señal de ahora, no la del escaneo)" 90 "$(np "$NMA/1" $APIF Strength)"
eqv "…WPA2: Flags 1 (privada), WpaFlags 0, RsnFlags 0x188 (CCMP + PSK)" "1 0 392" "$(np "$NMA/1" $APIF Flags) $(np "$NMA/1" $APIF WpaFlags) $(np "$NMA/1" $APIF RsnFlags)"
eqv "…MaxBitrate = 433000 (la velocidad de enlace de ahora)" 433000 "$(np "$NMA/1" $APIF MaxBitrate)"
eqv "Ssid con tilde y comillas (UTF-8 en bytes)" "$(ntext 'Café "Luz"')" "$(np "$NMA/2" $APIF Ssid)"
eqv "…Strength = 60 (de -70 dBm) y 2437 MHz" "60 2437" "$(np "$NMA/2" $APIF Strength) $(np "$NMA/2" $APIF Frequency)"
eqv "Red abierta: Flags, WpaFlags y RsnFlags a 0, Strength = 38 (de -81 dBm)" "0 0 0 38" "$(np "$NMA/3" $APIF Flags) $(np "$NMA/3" $APIF WpaFlags) $(np "$NMA/3" $APIF RsnFlags) $(np "$NMA/3" $APIF Strength)"
eqv "…con una barra en el nombre (Wi-Fi/Invitados)" "$(ntext 'Wi-Fi/Invitados')" "$(np "$NMA/3" $APIF Ssid)"

ACIF=$NMIF.Connection.Active
eqv "ActiveConnection: Id, Type, State (2 = activada)" '"MiCasa" "802-11-wireless" 2' "$(np "$NMC/1" $ACIF Id) $(np "$NMC/1" $ACIF Type) $(np "$NMC/1" $ACIF State)"
eqv "…Connection (la conexión guardada), SpecificObject (el punto de acceso), Devices" "\"$NMS/1\" \"$NMA/1\" [\"$NMD\"]" "$(np "$NMC/1" $ACIF Connection) $(np "$NMC/1" $ACIF SpecificObject) $(np "$NMC/1" $ACIF Devices)"
eqv "…Default, Vpn, Ip4Config" "true false \"$NMR/IP4Config/1\"" "$(np "$NMC/1" $ACIF Default) $(np "$NMC/1" $ACIF Vpn) $(np "$NMC/1" $ACIF Ip4Config)"
eqv "…Uuid = el de su conexión guardada" "$(np "$NMS/1" $NMIF.Settings.Connection Filename >/dev/null; sbj call "$NM" "$NMS/1" $NMIF.Settings.Connection GetSettings | jq -c '.data[0].connection.uuid.data')" "$(np "$NMC/1" $ACIF Uuid)"
IPIF=$NMIF.IP4Config
eqv "IP4Config: Gateway" '"192.168.1.1"' "$(np "$NMR/IP4Config/1" $IPIF Gateway)"
eqv "…AddressData = 192.168.1.23/24" '[{"address":{"type":"s","data":"192.168.1.23"},"prefix":{"type":"u","data":24}}]' "$(sbj get-property "$NM" "$NMR/IP4Config/1" $IPIF AddressData | jq -c '.data')"
eqv "…NameserverData y Nameservers (192.168.1.1 y 8.8.8.8)" '["192.168.1.1","8.8.8.8"] [16885952,134744072]' "$(sbj get-property "$NM" "$NMR/IP4Config/1" $IPIF NameserverData | jq -c '[.data[][].data]') $(np "$NMR/IP4Config/1" $IPIF Nameservers)"
eqv "…Addresses (formato antiguo: dirección, prefijo, puerta de enlace)" '[[385984704,24,16885952]]' "$(np "$NMR/IP4Config/1" $IPIF Addresses)"

SIF=$NMIF.Settings
CIF=$NMIF.Settings.Connection
eqv "Settings.ListConnections: las 4 guardadas en Android" "4" "$(sbj call "$NM" "$NMS" $SIF ListConnections | jq '.data[0] | length')"
eqv "…Connections, Hostname y CanModify" "4 true" "$(np "$NMS" $SIF Connections | jq length) $(np "$NMS" $SIF CanModify)"
MIUUID=$(sbj call "$NM" "$NMS/1" $CIF GetSettings | jq -r '.data[0].connection.uuid.data')
[[ $MIUUID =~ ^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$ ]] && ok "cada conexión tiene un UUID con forma de UUID (sale del nombre, siempre el mismo)" || bad "uuid" "$MIUUID"
eqv "Settings.GetConnectionByUuid → la conexión" "$NMS/1" "$(sbj call "$NM" "$NMS" $SIF GetConnectionByUuid s "$MIUUID" | jq -r '.data[0]')"
OUT=$(nc "$NMS" $SIF.GetConnectionByUuid 00000000-0000-0000-0000-000000000000); case $OUT in *"$NMIF.Settings.Error.InvalidConnection"*) ok "…y un UUID desconocido → Settings.Error.InvalidConnection" ;; *) bad "UUID desconocido" "$OUT" ;; esac
OUT=$(sbj call "$NM" "$NMS/1" $CIF GetSettings | jq -c '.data[0] | {id: .connection.id.data, type: .connection.type.data, ssid: ."802-11-wireless".ssid.data, km: ."802-11-wireless-security"."key-mgmt".data, m4: .ipv4.method.data}')
eqv "Connection.GetSettings de MiCasa: id, tipo, ssid (ay), key-mgmt y IPv4 automático" "{\"id\":\"MiCasa\",\"type\":\"802-11-wireless\",\"ssid\":$(ntext MiCasa),\"km\":\"wpa-psk\",\"m4\":\"auto\"}" "$OUT"
eqv "…la red oculta lo dice (802-11-wireless.hidden)" true "$(sbj call "$NM" "$NMS/4" $CIF GetSettings | jq -c '.data[0]."802-11-wireless".hidden.data')"
eqv "…GetSecrets no entrega claves (Android no las da): vacío" '[{}]' "$(sbj call "$NM" "$NMS/1" $CIF GetSecrets s 802-11-wireless-security | jq -c '.data')"
OUT=$(gdbus introspect --address "$SYS_ADDR" --dest "$NM" --object-path "$NMR" 2>&1)
case $OUT in *"ActivateConnection"*"AddAndActivateConnection"*"DeactivateConnection"*"readwrite b WirelessEnabled"*"readonly u State"*) ok "gdbus introspect enseña ActivateConnection, AddAndActivateConnection, WirelessEnabled de escritura y State" ;; *) bad "introspección de NetworkManager" "$OUT" ;; esac
OUT=$(gdbus introspect --address "$SYS_ADDR" --dest "$NM" --object-path "$NMD" 2>&1)
case $OUT in *"interface org.freedesktop.NetworkManager.Device.Wireless"*"RequestScan"*"readonly ao AccessPoints"*) ok "…y el dispositivo con RequestScan y AccessPoints" ;; *) bad "introspección del dispositivo" "$OUT" ;; esac
OUT=$(sb call "$NM" "$NMR/AgentManager" $NMIF.AgentManager Register s nexo-prueba 2>&1) && ok "AgentManager.Register (nm-applet registra su agente de claves) responde" || bad "AgentManager" "$OUT"

# ------------------------------------------------------------------------------ conectar, desconectar, escanear
echo "== nexo-dbus: NetworkManager, conectar y desconectar"
zmon_start "$NM"
OUT=$(nc "$NMR" $NMIF.ActivateConnection "$NMS/2" "$NMD" "/")
case $OUT in "(objectpath '$NMC/2',)") ok "ActivateConnection de una red guardada (Oficina) devuelve la conexión activa" ;; *) bad "ActivateConnection" "$OUT" ;; esac
eqv "…Android recibió «conecta a Oficina» sin clave (usa la guardada)" '{"ssid":"Oficina","password":null}' "$(lastrec)"
npoll '[ "$(np "$NMD" $NMIF.Device ActiveConnection)" = "\"$NMC/2\"" ] && [ "$(np "$NMC/2" $ACIF State)" = 2 ]' 6 && ok "…y el dispositivo ya tiene esa conexión, activada" || bad "estado tras activar" "$(np "$NMD" $NMIF.Device ActiveConnection) $(np "$NMC/2" $ACIF State)"
eqv "…con el nombre de la red" '"Oficina"' "$(np "$NMC/2" $ACIF Id)"
zsig StateChanged "$NMC/1" "uint32 4" && ok "…la conexión anterior se desactiva (StateChanged a 4)" || bad "señal de la conexión anterior" "$(grep StateChanged "$DB/zmon.txt" | tail -3)"
LINES=$(wc -l < "$DB/recN")
OUT=$(nc "$NMR" $NMIF.ActivateConnection "$NMS/2" "$NMD" "/")
case $OUT in "(objectpath '$NMC/2',)") ok "activar la que ya está activa devuelve la misma sin molestar a Android" ;; *) bad "ActivateConnection repetida" "$OUT" ;; esac
eqv "…(Android no recibió otro wifi.connect)" "$LINES" "$(wc -l < "$DB/recN")"
OUT=$(nc "$NMR" $NMIF.AddAndActivateConnection "{'connection': {'uuid': <'11111111-2222-3333-4444-555555555555'>}, '802-11-wireless': {'ssid': <b'NuevaRed'>}, '802-11-wireless-security': {'psk': <'clave12345'>, 'key-mgmt': <'wpa-psk'>}}" "$NMD" "/")
case $OUT in "(objectpath '$NMS/5', objectpath '$NMC/3')") ok "AddAndActivateConnection (nmcli device wifi connect) con clave → la conexión nueva y la activa" ;; *) bad "AddAndActivateConnection" "$OUT" ;; esac
eqv "…Android recibió el nombre y la clave" '{"ssid":"NuevaRed","password":"clave12345"}' "$(lastrec)"
eqv "…y la conexión nueva se llama como la red y conserva el UUID que pidió el cliente" "$NMS/5" "$(sbj call "$NM" "$NMS" $SIF GetConnectionByUuid s 11111111-2222-3333-4444-555555555555 | jq -r '.data[0]')"
npoll '[ "$(np "$NMS" $SIF Connections | jq length)" = 5 ]' 6 && ok "…que aparece entre las guardadas" || bad "conexión nueva sin listar"
OUT=$(nc "$NMR" $NMIF.AddAndActivateConnection "{'802-11-wireless': {'ssid': <b'Mala'>}, '802-11-wireless-security': {'psk': <'x'>}}" "$NMD" "/")
case $OUT in *"$NMIF.Error.Failed"*"Android no confirm"*) ok "una red que no conecta (clave mala…) → Error.Failed con el motivo de la app" ;; *) bad "red que no conecta" "$OUT" ;; esac
npoll '[ "$(np "$NMD" $NMIF.Device State)" = 100 ] && [ "$(np "$NMR" $NMIF State)" = 70 ]' 6 && ok "…y el dispositivo vuelve a su estado de antes (no se queda «configurándose»)" || bad "estado tras fallar" "$(np "$NMD" $NMIF.Device State) $(np "$NMR" $NMIF State)"
OUT=$(nc "$NMR" $NMIF.AddAndActivateConnection "{'802-11-wireless': {'ssid': <b'SoloWpa3'>}, '802-11-wireless-security': {'psk': <'x'>, 'key-mgmt': <'sae'>}}" "$NMD" "/")
case $OUT in *"org.nexo.Error.NeedsUserAction"*"WPA3"*) ok "una red que Android no deja crear a una app → org.nexo.Error.NeedsUserAction con el aviso de la app" ;; *) bad "red solo WPA3" "$OUT" ;; esac
OUT=$(nc "$NMR" $NMIF.ActivateConnection "$NMS/99" "$NMD" "/"); case $OUT in *"$NMIF.Error.UnknownConnection"*) ok "activar una conexión que no existe → Error.UnknownConnection" ;; *) bad "conexión inexistente" "$OUT" ;; esac
OUT=$(nc "$NMR" $NMIF.ActivateConnection "$NMS/2" "$NMR/Devices/9" "/"); case $OUT in *"$NMIF.Error.UnknownDevice"*) ok "…y en un dispositivo que no existe → Error.UnknownDevice" ;; *) bad "dispositivo inexistente" "$OUT" ;; esac

nctl "wifi disconnect"
npoll '[ "$(np "$NMD" $NMIF.Device State)" = 30 ]' 6 && ok "cuando Android se desconecta, el dispositivo pasa a 30 (desconectado)…" || bad "estado tras desconectar" "$(np "$NMD" $NMIF.Device State)"
eqv "…State = 20, Connectivity = 1, sin conexión principal" '20 1 "/" "/"' "$(np "$NMR" $NMIF State) $(np "$NMR" $NMIF Connectivity) $(np "$NMR" $NMIF PrimaryConnection) $(np "$NMD" $NMIF.Device ActiveConnection)"
eqv "…ActiveAccessPoint = «/» y sin IP" '"/" "/" 0' "$(np "$NMD" $NMIF.Device.Wireless ActiveAccessPoint) $(np "$NMD" $NMIF.Device Ip4Config) $(np "$NMD" $NMIF.Device Ip4Address)"
waitfor "$DB/zmon.txt" "StateChanged (uint32 30, uint32 100" 3 && ok "…con la señal Device.StateChanged (30, antes 100)" || bad "señal del dispositivo" "$(grep StateChanged "$DB/zmon.txt" | tail -3)"
zsig StateChanged "$NMR:" "(uint32 20,)" || grep -q "NetworkManager.StateChanged (uint32 20,)" "$DB/zmon.txt" && ok "…y NetworkManager.StateChanged (20)" || bad "señal global" "$(grep StateChanged "$DB/zmon.txt" | tail -4)"
npoll '[ "$(np "$NMS" $SIF Connections | jq length)" = 5 ]' 3 && ok "…las redes guardadas siguen (cinco: las cuatro de antes y NuevaRed, que Android guardó al conectar)" || bad "Connections tras desconectar" "salen $(np "$NMS" $SIF Connections | jq length); $(grep -n "wifi.saved\|NetworkManager" "$DB/N.log" | tail -12)"
OUT=$(nc "$NMD" $NMIF.Device.Disconnect); case $OUT in *"$NMIF.Device.NotActive"*) ok "Device.Disconnect sin conexión → Device.NotActive" ;; *) bad "Disconnect sin conexión" "$OUT" ;; esac
OUT=$(nc "$NMR" $NMIF.DeactivateConnection "$NMC/1"); case $OUT in *"$NMIF.Error.ConnectionNotActive"*) ok "DeactivateConnection de una que no está activa → Error.ConnectionNotActive" ;; *) bad "DeactivateConnection" "$OUT" ;; esac
nc "$NMR" $NMIF.ActivateConnection "$NMS/1" "$NMD" "/" >/dev/null
npoll '[ "$(np "$NMD" $NMIF.Device State)" = 100 ] && [ "$(np "$NMR" $NMIF State)" = 70 ]' 6 && ok "volver a conectar (MiCasa) → 100 y State 70 otra vez" || bad "reconexión" "$(np "$NMD" $NMIF.Device State)"
ACT=$(np "$NMD" $NMIF.Device ActiveConnection | tr -d '"')
OUT=$(nc "$NMR" $NMIF.DeactivateConnection "$ACT"); [ "$OUT" = "()" ] && ok "DeactivateConnection de la activa responde" || bad "DeactivateConnection de la activa" "$OUT"
npoll '[ "$(np "$NMD" $NMIF.Device State)" = 30 ]' 6 && ok "…y Android se desconecta de verdad" || bad "no se desconectó"
nc "$NMR" $NMIF.ActivateConnection "$NMS/1" "$NMD" "/" >/dev/null
npoll '[ "$(np "$NMD" $NMIF.Device State)" = 100 ]' 6
OUT=$(nc "$NMD" $NMIF.Device.Disconnect); [ "$OUT" = "()" ] && ok "Device.Disconnect (nmcli device disconnect wlan0) responde" || bad "Device.Disconnect" "$OUT"
npoll '[ "$(np "$NMD" $NMIF.Device State)" = 30 ]' 6 && ok "…y desconecta" || bad "Device.Disconnect no desconectó"
nc "$NMR" $NMIF.ActivateConnection "$NMS/1" "$NMD" "/" >/dev/null
npoll '[ "$(np "$NMD" $NMIF.Device State)" = 100 ]' 6

# ------------------------------------------------------------------------------ escaneo
echo "== nexo-dbus: NetworkManager, escaneo de redes"
nctl "wifi add Fuerte aa:bb:cc:00:00:09 -40 WPA2 5180"
nctl "wifi add Lejana aa:bb:cc:00:00:0a -105 WEP 2412"
nctl "wifi add Nueva aa:bb:cc:00:00:0b -60 WPA3 5500"
nctl "wifi add Antigua aa:bb:cc:00:00:0c -60 WPA 2412"
nctl "wifi add Segura aa:bb:cc:00:00:0d -60 OWE 2412"
sleep 0.5
LS=$(np "$NMD" $NMIF.Device.Wireless LastScan)
OUT=$(sb call "$NM" "$NMD" $NMIF.Device.Wireless RequestScan a{sv} 0 2>&1) && ok "RequestScan responde (nmcli device wifi rescan)" || bad "RequestScan" "$OUT"
npoll '[ "$(np "$NMD" $NMIF.Device.Wireless AccessPoints | jq length)" = 8 ]' 6 && ok "…y las redes nuevas aparecen (de 3 a 8)" || bad "AccessPoints tras escanear" "$(np "$NMD" $NMIF.Device.Wireless AccessPoints)"
zsig AccessPointAdded "$NMD" "objectpath '$(nap Fuerte)'" && ok "…con la señal AccessPointAdded" || bad "AccessPointAdded" "$(grep AccessPoint "$DB/zmon.txt" | tail -3)"
eqv "…y LastScan avanza" "true" "$([ "$(np "$NMD" $NMIF.Device.Wireless LastScan)" -gt "$LS" ] && echo true || echo false)"
eqv "los puntos de acceso que ya estaban conservan su ruta (MiCasa sigue siendo el 1)" "$(ntext MiCasa)" "$(np "$NMA/1" $APIF Ssid)"
eqv "Strength se queda entre 0 y 100: -40 dBm → 100 y -105 dBm → 0" "100 0" "$(np "$(nap Fuerte)" $APIF Strength) $(np "$(nap Lejana)" $APIF Strength)"
eqv "WEP: Flags 1 sin WpaFlags ni RsnFlags" "1 0 0" "$(np "$(nap Lejana)" $APIF Flags) $(np "$(nap Lejana)" $APIF WpaFlags) $(np "$(nap Lejana)" $APIF RsnFlags)"
eqv "WPA3: RsnFlags 0x488 (SAE + CCMP)" "1160" "$(np "$(nap Nueva)" $APIF RsnFlags)"
eqv "WPA (el antiguo): WpaFlags 0x1cc" "460" "$(np "$(nap Antigua)" $APIF WpaFlags)"
eqv "OWE: RsnFlags 0x888" "2184" "$(np "$(nap Segura)" $APIF RsnFlags)"
eqv "5500 MHz sale tal cual" "5500" "$(np "$(nap Nueva)" $APIF Frequency)"
FUERTE=$(nap Fuerte)
nctl "wifi remove Fuerte"
nctl "wifi remove Lejana"
sleep 0.5
sb call "$NM" "$NMD" $NMIF.Device.Wireless RequestScan a{sv} 0 >/dev/null 2>&1
npoll '[ "$(np "$NMD" $NMIF.Device.Wireless AccessPoints | jq length)" = 6 ]' 6 && ok "las que desaparecen del escaneo se retiran" || bad "AccessPoints tras quitar"
zsig AccessPointRemoved "$NMD" "objectpath '$FUERTE'" && ok "…con la señal AccessPointRemoved" || bad "AccessPointRemoved" "$(grep AccessPoint "$DB/zmon.txt" | tail -3)"
[ -z "$(np "$FUERTE" $APIF Ssid)" ] && ok "…y su objeto deja de existir" || bad "el objeto sigue"

# ------------------------------------------------------------------------------ encender y apagar el WiFi, borrar redes
echo "== nexo-dbus: NetworkManager, WiFi apagado y redes guardadas"
sb set-property "$NM" "$NMR" $NMIF WirelessEnabled b false >/dev/null 2>&1
eqv "escribir WirelessEnabled = false apaga el WiFi de Android (nmcli radio wifi off)" false "$(app "$NPORT" wifi status --json | jq -c '.enabled')"
npoll '[ "$(np "$NMD" $NMIF.Device State)" = 20 ] && [ "$(np "$NMR" $NMIF WirelessEnabled)" = false ]' 6 && ok "…y el dispositivo queda «no disponible» (20)" || bad "estado con el WiFi apagado" "$(np "$NMD" $NMIF.Device State)"
npoll '[ "$(np "$NMD" $NMIF.Device.Wireless AccessPoints)" = "[]" ]' 4 && ok "…sin puntos de acceso" || bad "AccessPoints con el WiFi apagado"
eqv "…y sin conexión activa ni primaria" '[] "/"' "$(np "$NMR" $NMIF ActiveConnections) $(np "$NMR" $NMIF PrimaryConnection)"
OUT=$(nc "$NMR" $NMIF.ActivateConnection "$NMS/1" "$NMD" "/"); case $OUT in *"$NMIF.Error.Failed"*"apagado"*) ok "activar una conexión con el WiFi apagado → Error.Failed «apagado»" ;; *) bad "conectar sin WiFi" "$OUT" ;; esac
OUT=$(nc "$NMD" $NMIF.Device.Wireless.RequestScan "{}"); case $OUT in *"$NMIF.Error.Failed"*"apagado"*) ok "…y escanear también" ;; *) bad "escanear sin WiFi" "$OUT" ;; esac
sb set-property "$NM" "$NMR" $NMIF WirelessEnabled b true >/dev/null 2>&1
npoll '[ "$(np "$NMD" $NMIF.Device State)" -ge 30 ] && [ "$(np "$NMD" $NMIF.Device.Wireless AccessPoints | jq length)" -ge 3 ]' 8 && ok "WirelessEnabled = true lo enciende y vuelven las redes" || bad "reencendido" "$(np "$NMD" $NMIF.Device State)"
nctl "wifi off"
npoll '[ "$(np "$NMR" $NMIF WirelessEnabled)" = false ]' 4 && ok "si el WiFi se apaga en Android, WirelessEnabled lo dice (sin que nadie pregunte)" || bad "evento de WiFi apagado"
waitfor "$DB/zmon.txt" "'WirelessEnabled': <false>" 3 && ok "…con PropertiesChanged" || bad "señal de WirelessEnabled"
nctl "wifi on"
npoll '[ "$(np "$NMR" $NMIF WirelessEnabled)" = true ]' 4

nctl "wifi connect MiCasa"
npoll '[ "$(np "$NMD" $NMIF.Device State)" = 100 ]' 6
OUT=$(nc "$NMS/3" $CIF.Delete); [ "$OUT" = "()" ] && ok "Connection.Delete (nmcli connection delete) responde" || bad "Delete" "$OUT"
eqv "…y Android se olvida de la red (Café «Luz»)" "false" "$(app "$NPORT" wifi saved --json | jq -c '[.networks[].ssid] | index("Café \"Luz\"") != null')"
npoll '[ "$(np "$NMS" $SIF Connections | jq length)" = 4 ]' 6 && ok "…y desaparece de las conexiones" || bad "Connections tras Delete" "$(np "$NMS" $SIF Connections | jq length)"
zsig ConnectionRemoved "$NMS" "objectpath '$NMS/3'" && ok "…con ConnectionRemoved" || bad "ConnectionRemoved" "$(grep Connection "$DB/zmon.txt" | tail -3)"
OUT=$(nc "$NMS/1" $CIF.Update "{}"); case $OUT in *"$NMIF.Settings.Error.ReadOnlyConnection"*) ok "editar una conexión → Settings.Error.ReadOnlyConnection (las guarda Android)" ;; *) bad "Update" "$OUT" ;; esac
OUT=$(nc "$NMS" $SIF.AddConnection "{}"); case $OUT in *"$NMIF.Settings.Error.NotSupported"*) ok "AddConnection sin conectar → Settings.Error.NotSupported" ;; *) bad "AddConnection" "$OUT" ;; esac
OUT=$(gdbus call --address "$SYS_ADDR" --dest "$NM" --object-path "$NMR" --method org.freedesktop.DBus.Properties.Set $NMIF WwanEnabled "<true>" 2>&1); case $OUT in *NotSupported*) ok "WwanEnabled = true → NotSupported (Nexo no maneja datos móviles)" ;; *) bad "WwanEnabled" "$OUT" ;; esac

# ------------------------------------------------------------------------------ el estado de la red del móvil (net.status)
echo "== nexo-dbus: NetworkManager y la red del móvil (net.status)"
nctl "net cellular"
npoll '[ "$(np "$NMR" $NMIF Metered)" = 1 ]' 4 && ok "si Android sale por datos móviles, Metered = 1 (de pago por uso) para que las apps no bajen cosas grandes" || bad "Metered con datos móviles" "$(np "$NMR" $NMIF Metered)"
nctl "net none"
npoll '[ "$(np "$NMR" $NMIF State)" = 20 ] && [ "$(np "$NMR" $NMIF Connectivity)" = 1 ]' 4 && ok "sin ninguna red (modo avión…) State = 20 y Connectivity = 1, aunque el WiFi siga «conectado» en la lista" || bad "State sin red" "$(np "$NMR" $NMIF State) $(np "$NMR" $NMIF Connectivity)"
nctl "net auto"
npoll '[ "$(np "$NMR" $NMIF State)" = 70 ]' 4 && ok "…y vuelve a 70 cuando vuelve la red" || bad "State tras volver la red"
nctl "wifi disconnect"
npoll '[ "$(np "$NMR" $NMIF State)" = 20 ]' 4
nctl "net cellular"
npoll '[ "$(np "$NMR" $NMIF State)" = 70 ]' 4 && ok "con datos móviles y sin WiFi conectado, State = 70: las apps (Firefox…) no creen que no hay internet" || bad "State con datos móviles sin WiFi" "$(np "$NMR" $NMIF State)"
eqv "…y no hay conexión principal que enseñar (el WiFi no es la salida)" '"/" ""' "$(np "$NMR" $NMIF PrimaryConnection) $(np "$NMR" $NMIF PrimaryConnectionType)"
nctl "net auto"
nctl "wifi connect MiCasa"
npoll '[ "$(np "$NMD" $NMIF.Device State)" = 100 ]' 6
zmon_stop
dd_stop
sgone "$NM" 6 && ok "al parar nexo-dbus, NetworkManager se va" || bad "NetworkManager no se fue"

# una app anterior (0.2/0.3) no sabe de net.status: el estado sale solo del WiFi
kill "$NPID" 2>/dev/null; wait "$NPID" 2>/dev/null
: > "$DB/ctlN"
NPORT=$(start_app dbusN2 --ctl "$DB/ctlN")
NPID=$(cat "$T/dbusN2.pid")
nmdd N2 "$NPORT"
npoll '[ "$(np "$NMR" $NMIF State)" = 70 ]' 8 && ok "con una app 0.2/0.3 (sin net.status) conectada al WiFi, State = 70" || bad "app antigua" "$(cat "$DB/N2.log")"
eqv "…y Metered = 0 (no lo sabe)" 0 "$(np "$NMR" $NMIF Metered)"
nctl "wifi disconnect"
npoll '[ "$(np "$NMR" $NMIF State)" = 20 ]' 4 && ok "…y sin WiFi conectado, 20" || bad "app antigua sin WiFi"
dd_stop
# …salvo que se pida dar el internet por bueno (salir por datos móviles con una app que aún no cuenta la red del móvil)
nmdd N3 "$NPORT" NEXO_DBUS_NM_ASSUME_ONLINE=1
npoll '[ "$(np "$NMR" $NMIF State)" = 70 ]' 8 && ok "con NEXO_DBUS_NM_ASSUME_ONLINE=1, State = 70 aunque el WiFi del móvil no esté conectado" || bad "ASSUME_ONLINE" "$(cat "$DB/N3.log")"
eqv "…y Connectivity = 4 (completa)" 4 "$(np "$NMR" $NMIF Connectivity)"
eqv "…sin inventar una conexión: el dispositivo sigue desconectado y sin conexión principal" '30 "/"' "$(np "$NMD" $NMIF.Device State) $(np "$NMR" $NMIF PrimaryConnection)"
dd_stop
kill "$NPID" 2>/dev/null; wait "$NPID" 2>/dev/null
# con una app que sí cuenta la red (protocolo 1.3), manda lo que ella diga
: > "$DB/ctlN"
NPORT=$(start_app dbusN4 --ctl "$DB/ctlN" --minor3)
NPID=$(cat "$T/dbusN4.pid")
nctl "net none"
sleep 0.4
nmdd N4 "$NPORT" NEXO_DBUS_NM_ASSUME_ONLINE=1
npoll '[ "$(np "$NMR" $NMIF State)" = 20 ]' 8 && ok "…pero si la app dice que no hay red (modo avión), State = 20: esa opción solo vale cuando la app no informa" || bad "ASSUME_ONLINE con net.status" "$(cat "$DB/N4.log")"
dd_stop
kill "$NPID" 2>/dev/null; wait "$NPID" 2>/dev/null

# ------------------------------------------------------------------------------ NetworkManager y el NetworkManager de verdad
echo "== nexo-dbus: NetworkManager de verdad, systemd, política"
: > "$HOLD_OUT"
python3 "$ROOT/tests/dbus_hold.py" "$ROOT/termux/bin/nexo-dbus" "$SYS_ADDR" "$NM" >"$HOLD_OUT" 2>&1 &
HOLD_PID=$!
APP_PIDS+=("$HOLD_PID")
waitfor "$HOLD_OUT" "OWNER" 4 || bad "el dueño de prueba no arrancó" "$(cat "$HOLD_OUT")"
NPORT=$(start_app dbusN3)
nmdd NP "$NPORT"
poll 'grep -q "ya hay un NetworkManager de verdad en este bus" "$DB/NP.log"' 6 && ok "con un NetworkManager de verdad en el bus, nexo-dbus no lo pisa (modo pasivo)" || bad "modo pasivo de NetworkManager" "$(cat "$DB/NP.log")"
poll 'dst_has "pasivo: ya hay un NetworkManager de verdad en este bus"' 4 && ok "…y nexo-dbus status lo cuenta" || bad "status pasivo de NetworkManager" "$(dstate)"
dd_stop
kill "$HOLD_PID" 2>/dev/null; wait "$HOLD_PID" 2>/dev/null
nmdd NS "$NPORT" NEXO_DBUS_SYSTEMD_DIR="$DB"
poll 'grep -q "systemd gestiona NetworkManager.service" "$DB/NS.log"' 6 && ok "con systemd y NetworkManager instalado (activable), no ocupa el nombre: lo arrancaría systemd" || bad "pista de systemd de NetworkManager" "$(cat "$DB/NS.log")"
! shas "$NM" && ok "…y el nombre queda libre" || bad "ocupó el nombre con systemd"
poll 'dst_has "pasivo: systemd gestiona NetworkManager.service en este equipo"' 4 && ok "…y nexo-dbus status lo cuenta" || bad "status con systemd (NetworkManager)" "$(dstate)"
dd_stop
nmdd NF "$NPORT" NEXO_DBUS_SYSTEMD_DIR="$DB" NEXO_DBUS_NM=1
swait "$NM" 8 && ok "…salvo que se pida con NEXO_DBUS_NM=1" || bad "NM=1" "$(cat "$DB/NF.log")"
dd_stop
nmdd NO "$NPORT" NEXO_DBUS_NM=0 NEXO_DBUS_MPRIS=1
wait_name "$MP" 8 || bad "(NO) MPRIS no apareció: el demonio no está en marcha" "$(cat "$DB/NO.log")"
sleep 2.5
! shas "$NM" && ok "NEXO_DBUS_NM=0 → no ocupa el nombre" || bad "NM=0 ocupó el nombre"
dst_has "$(printf "%-15s %s" NetworkManager apagado)" && ok "…y status dice que NetworkManager está apagado" || bad "status con NM=0" "$(dstate)"
dd_stop
DD_OPTS=(-v --no-nm)
nmdd NO2 "$NPORT" NEXO_DBUS_MPRIS=1
wait_name "$MP" 8 || bad "(NO2) MPRIS no apareció: el demonio no está en marcha" "$(cat "$DB/NO2.log")"
sleep 2.5
! shas "$NM" && ok "--no-nm → tampoco" || bad "--no-nm ocupó el nombre"
dd_stop
DD_OPTS=(-v)

# BlueZ y NetworkManager a la vez, cada uno con su conexión al bus
dd_start NB "$NPORT" NEXO_DBUS_SYSTEM_BUS="$SYS_ADDR" NEXO_DBUS_MPRIS=0 NEXO_DBUS_SYSTEMD_DIR="$NOSD"
swait "$NM" 8 && swait "$BZ" 8 && ok "con las dos funciones, org.bluez y NetworkManager conviven en el mismo demonio" || bad "las dos a la vez" "$(cat "$DB/NB.log")"
eqv "…cada servicio con su propia conexión al bus (nombres únicos distintos)" "2" "$(printf '%s\n%s\n' "$(sowner "$NM")" "$(sowner "$BZ")" | sort -u | wc -l)"
dd_stop
sgone "$NM" 6 && sgone "$BZ" 6 && ok "…y al pararlo se van los dos" || bad "no se fueron los dos"

fi   # parte NetworkManager

zmon_stop
sbus_stop
