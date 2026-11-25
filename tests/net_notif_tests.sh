# shellcheck shell=bash
# Pruebas de «nexo net» y «nexo notif» (protocolo 1.5, versión 0.4.3): la red del móvil y sus notificaciones, vistas desde el cliente.
# No se ejecuta solo: lo carga tests/run_tests.sh (usa sus ok/bad/run/eq/has/… y el cliente $NEXO). Necesita: bash, python3, jq.
#   NEXO_TESTS_ONLY=net bash tests/run_tests.sh      ← solo estas (más rápido para trabajar en ellas)
#
# QUÉ SON ESTAS PRUEBAS Y QUÉ NO: hablan con la app FALSA (tests/fake_app.py), que imita a la app Android y recibe órdenes por --ctl
# (cambiar de WiFi a datos móviles, poner o quitar la VPN, un portal cautivo, publicar o retirar una notificación…). Prueban el
# cliente: los textos, los formatos (--json, --csv, --waybar…), los códigos de salida y los eventos en vivo. NO prueban lo que
# hace Android de verdad (ConnectivityManager, NotificationListenerService): eso solo se ve en el móvil (docs/LIMITACIONES.md).
# La parte de escritorio (nexo-dbus mostrando estas notificaciones con dunst, mako, GNOME…) está en tests/dbus_notif_tests.sh.

echo "== nexo net: por dónde sale el móvil a internet (la app falsa del WiFi de siempre)"
run "$NEXO" net;                         eq "net: por dónde sale el móvil" "Red: WiFi · con internet"
run "$NEXO" net status;                  eq "net status" "Red: WiFi · con internet"
run "$NEXO" network st --short;          eq "network st --short (alias)" "WiFi"
run "$NEXO" net --json;                  jqok "net --json" '.available == true and .type == "wifi" and .internet == true and .validated == true and .metered == false and .vpn == false and .captive == false'
run "$NEXO" net --env;                   has "net --env" "NEXO_NET_TYPE='wifi'"
has "…y los booleanos van como 1 y 0" "NEXO_NET_VALIDATED=1"
has "…también el de pago" "NEXO_NET_METERED=0"
run "$NEXO" net --csv
eq "net --csv" $'type,internet,validated,metered,vpn,captive\n"wifi",true,true,false,false,false'
run "$NEXO" net --waybar;                jqok "net --waybar" '.text == "WiFi" and .alt == "connected" and .class == "connected" and .percentage == 100 and .tooltip == "Red: WiFi"'
run "$NEXO" net --qml;                   jqok "net --qml" '.topic == "net" and .state == "connected" and .icon == "network-wireless-symbolic" and .active == true and .percentage == 100'
run "$NEXO" net --i3status;              jqok "net --i3status" '.name == "net" and (.full_text | endswith("WiFi")) and .color == "#7BD88F"'
run "$NEXO" net --polybar;               has "net --polybar" "WiFi"
run "$NEXO" net --dunst;                 has "net --dunst" "Red: WiFi · con internet"
NEXO_ICONS=none run "$NEXO" net --starship; eq "net --starship (sin iconos)" "WiFi"
NEXO_ICONS=none run "$NEXO" net --tmux;  eq "net --tmux (sin iconos)" "WiFi"
run "$NEXO" net --starship
case $OUT in *$'\357\202\254'*) ok "con iconos: el glifo de red (Nerd Font) va en UTF-8" ;; *) bad "falta el glifo de la red" "$OUT" ;; esac
run "$NEXO" net cosa;                    rc_is "net: subcomando desconocido → uso (2)" 2

echo "== nexo net: datos móviles, VPN, portal cautivo, sin internet y sin red"
NCTL=$T/net_notif.ctl; : > "$NCTL"
NA=$(start_app netnotif --ctl "$NCTL" --reqlog "$T/netnotif.req")
[ -n "$NA" ] || { bad "arrancó la app falsa de net y notif"; NA=1; }
nfctl() { printf '%s\n' "$@" >> "$NCTL"; sleep 0.4; }                    # órdenes para la app falsa (ella las lee cada 0,1 s)
nrun() { NEXO_PORT=$NA run "$NEXO" "$@"; }                               # el cliente contra ESA app
nrun net;                                eq "(app con órdenes) sin tocar nada, la red sale del WiFi" "Red: WiFi · con internet"
nfctl "net cellular"
nrun net;                                eq "datos móviles: de pago" "Red: datos móviles · con internet · de pago (datos limitados)"
nrun net --short;                        eq "…--short" "datos móviles"
nrun net --csv;                          has "…--csv: metered=true" '"cellular",true,true,true,false,false'
nrun net --qml;                          jqok "…con el icono de datos" '.icon == "network-cellular-symbolic" and .active == true'
nfctl "net vpn on"
nrun net;                                eq "con VPN" "Red: datos móviles + VPN · con internet · de pago (datos limitados)"
nrun net --short;                        eq "…--short" "datos móviles + VPN"
nrun net --qml;                          jqok "…con el icono de VPN" '.icon == "network-vpn-symbolic"'
nrun net --json;                         jqok "…--json: vpn y tipo" '.vpn == true and .type == "cellular"'
nfctl "net vpn off" "net captive on"
nrun net;                                eq "portal cautivo" "Red: datos móviles · portal cautivo: hay que iniciar sesión en la red · de pago (datos limitados)"
nrun net --short;                        eq "…--short" "datos móviles: iniciar sesión"
nrun net --waybar;                       jqok "…waybar: clase captive y 0 %" '.class == "captive" and .percentage == 0 and .text == "datos móviles: iniciar sesión"'
nrun net --qml;                          jqok "…qml: icono de error y no activa" '.icon == "network-error-symbolic" and .active == false and .state == "captive"'
nrun net --csv;                          has "…csv: validated=false y captive=true" '"cellular",true,false,true,false,true'
NEXO_ICONS=none nrun net --starship;     eq "…starship sí lo muestra (hay algo que hacer)" "datos móviles: iniciar sesión"
nfctl "net captive off" "net wifi" "net validated off"
nrun net;                                eq "WiFi sin internet de verdad (Android no logra comprobarlo)" "Red: WiFi · sin internet de verdad (Android no logra comprobarlo)"
nrun net --short;                        eq "…--short" "WiFi sin internet"
nrun net --waybar;                       jqok "…waybar: clase limited" '.class == "limited" and .percentage == 0'
NEXO_ICONS=none nrun net --starship;     eq "…starship lo muestra" "WiFi sin internet"
nfctl "net internet off"
nrun net;                                eq "red que ni declara salida a internet" "Red: WiFi · sin salida a internet"
nfctl "net internet on" "net validated on" "net ethernet"
nrun net;                                eq "cable" "Red: cable · con internet"
nrun net --qml;                          jqok "…con el icono de cable" '.icon == "network-wired-symbolic"'
nfctl "net bluetooth"
nrun net --short;                        eq "anclaje por Bluetooth" "Bluetooth"
nfctl "net other"
nrun net --short;                        eq "otro tipo de red" "otra red"
nfctl "net none"
nrun net;                                eq "sin red" "Red: el móvil no tiene conexión"
nrun net --short;                        eq "…--short" "sin red"
nrun net --waybar;                       jqok "…waybar: clase none" '.class == "none" and .text == "sin red" and .percentage == 0'
nrun net --csv;                          has "…csv" '"none",false,false,false,false,false'
NEXO_ICONS=none nrun net --starship;     eq "…starship no muestra nada" ""
nrun net --json;                         jqok "…--json" '.type == "none" and .validated == false'
nfctl "net auto"
nrun net --short;                        eq "net auto: vuelve a salir del WiFi" "WiFi"

echo "== nexo net: barras que nunca fallan, caché, app antigua"
rm -rf "$HOME/.cache"
NEXO_PORT=1 run "$NEXO" net --waybar;    rc_is "net --waybar con la app apagada: código 0" 0
jqok "…y muestra «offline»" '.class == "offline" and .text == "offline"'
rm -rf "$HOME/.cache"
nrun net --waybar >/dev/null;            rc_is "net --waybar buena rellena la caché" 0
NEXO_PORT=1 run "$NEXO" net --waybar
jqok "app apagada: la barra de red enseña el último dato conocido" '.class == "connected" and (.tooltip | contains("último dato"))'
rm -rf "$HOME/.cache"
NEXO_PORT=1 run "$NEXO" net;             rc_is "net sin barra y sin app → 10" 10
M4=$(start_app minor4 --minor4)
NEXO_PORT=$M4 run "$NEXO" net;           rc_is "net con una app 1.4 (sin net.status) → error (1)" 1
has "…y explica que la app es antigua" "más antigua"
NEXO_PORT=$M4 run "$NEXO" net --waybar;  rc_is "…pero una barra no falla (0)" 0
jqok "…y dice que no está disponible" '.class == "unavailable"'
NEXO_NO_JQ=1 nrun net;                   has "sin jq: net da el JSON crudo" '"type":"wifi"'
has "…y avisa" "instala jq"
NEXO_TRANSPORT=python nrun net --short;  eq "net con el transporte python3" "WiFi"

echo "== nexo notif: estado, lista y quitar"
nrun notif;                              eq "notif (sin subcomando) = notif status" "Notificaciones: se reenvían a Linux · 0 en el móvil ahora"
nrun notif status;                       eq "notif status" "Notificaciones: se reenvían a Linux · 0 en el móvil ahora"
nrun notif st --json;                    jqok "notif status --json" '.access == true and .forwarding == true and .active == 0'
nrun notif status --short;               eq "notif status --short" "0"
nrun notif status --csv;                 eq "notif status --csv" $'access,forwarding,active\ntrue,true,0'
nrun notif status --env;                 has "notif status --env" "NEXO_NOTIF_FORWARDING=1"
has "…y cuántas hay" "NEXO_NOTIF_ACTIVE=0"
nrun notif list;                         eq "notif list sin notificaciones" "No hay notificaciones."
nrun notif ls --short;                   eq "notif list --short" "0"
nrun notif list --json;                  jqok "notif list --json" '.notifications == []'
nrun notif list --csv;                   eq "notif list --csv (solo la cabecera)" "app,title,text,time,category,importance,ongoing,clearable,key"
nfctl 'notif post k1 Mensajes Ana|Hola ñandú' \
      'notif post k2 Correo Factura|Tu factura de octubre @category=email @importance=2' \
      'notif post k3 Spotify Reproduciendo|Canción ñandú @ongoing=1 @clearable=0' \
      'notif post k4 Sistema Aviso|No se puede quitar @clearable=0' \
      'notif post k0 Nada |' \
      'notif post kn Chat Ana|primera línea\nsegunda línea'
nrun notif status;                       eq "notif status cuenta las que hay" "Notificaciones: se reenvían a Linux · 6 en el móvil ahora"
nrun notif list;                         rc_is "notif list" 0
has "…cuenta cuántas hay" "6 notificaciones"
has "…enseña app · título: texto y desde cuándo" "• Mensajes · Ana: Hola ñandú   (ahora)"
has "…con la clave de cada una" "    clave: k1"
has "…las de servicios en marcha se marcan «fija»" "• Spotify · Reproduciendo: Canción ñandú   (ahora, fija)"
has "…y las que Android no deja quitar" "• Sistema · Aviso: No se puede quitar   (ahora, no se puede quitar)"
has "…una sin título ni texto sale solo con la app" "• Nada   (ahora)"
has "…y el texto de varias líneas se junta en una" "• Chat · Ana: primera línea segunda línea   (ahora)"
[ "$(printf '%s\n' "$OUT" | wc -l)" -eq 13 ] && ok "…y ocupa 13 líneas (una de cuenta y dos por notificación)" || bad "líneas de notif list" "$OUT"
[ "$(printf '%s\n' "$OUT" | sed -n 2p)" = "• Chat · Ana: primera línea segunda línea   (ahora)" ] && ok "…y salen las más nuevas primero (como en el móvil)" || bad "orden de notif list" "$OUT"
nrun notif list --json
jqok "notif list --json: las más nuevas primero" '[.notifications[].key] == ["kn","k0","k4","k3","k2","k1"]'
jqok "…todos los campos de cada una" '(.notifications | length) == 6 and (.notifications[] | select(.key == "k1") | .package == "org.fake.mensajes" and .app == "Mensajes" and .title == "Ana" and .text == "Hola ñandú" and .category == "msg" and .importance == 3 and .ongoing == false and .clearable == true and (.time | type == "number"))'
jqok "…la de categoría e importancia propias" '.notifications[] | select(.key == "k2") | .category == "email" and .importance == 2'
jqok "…y la fija: en marcha y no quitable" '.notifications[] | select(.key == "k3") | .ongoing == true and .clearable == false'
nrun notif list --csv;                   has "notif list --csv: cabecera" "app,title,text,time,category,importance,ongoing,clearable,key"
has "…una fila" '"Mensajes","Ana","Hola ñandú",'
has "…con el final de la fila" ',"msg",3,false,true,"k1"'
has "…y la fija" ',"msg",3,true,false,"k3"'
nrun notif list --short;                 eq "notif list --short (cuántas hay)" "6"
# privacidad: lo de las notificaciones no se guarda en la caché de las barras (lo de la red sí)
rm -rf "$HOME/.cache"
nrun net >/dev/null 2>&1; nrun notif list >/dev/null 2>&1; nrun notif status >/dev/null 2>&1
NCACHE=$HOME/.cache/nexo/last.json
if [ -s "$NCACHE" ] && jq -e '.net.data.type == "wifi"' "$NCACHE" >/dev/null 2>&1; then ok "net guarda su estado en la caché de las barras"; else bad "net no guardó su estado en la caché" "$(cat "$NCACHE" 2>/dev/null)"; fi
if jq -e 'has("notif") | not' "$NCACHE" >/dev/null 2>&1; then ok "…pero las notificaciones no tienen sitio en la caché"; else bad "la caché tiene un tema notif" "$(cat "$NCACHE" 2>/dev/null)"; fi
if grep -qE 'Hola|Factura|Reproduciendo|Ana' "$NCACHE" 2>/dev/null; then bad "algún texto de una notificación acabó en la caché" "$(cat "$NCACHE")"; else ok "…y ningún texto suyo acaba en el disco"; fi
rm -rf "$HOME/.cache"

nrun notif dismiss k1;                   eq "notif dismiss CLAVE" "Notificación quitada."
nrun notif list --short;                 eq "…y ya no está en el móvil" "5"
nrun notif dismiss k1;                   rc_is "quitar una que ya no está → error (1)" 1
has "…y lo explica" "No hay ninguna notificación con esa clave"
nrun notif dismiss k3;                   rc_is "quitar una fija → error (1)" 1
has "…dice que Android no deja" "Android no deja quitar esa notificación"
nrun notif dismiss k4;                   rc_is "quitar una que no se puede quitar → error (1)" 1
nrun notif dismiss;                      rc_is "notif dismiss sin clave → uso (2)" 2
has "…y dice de dónde sale la clave" "nexo notif list"
nrun notif dismiss a b;                  rc_is "notif dismiss con dos claves → uso (2)" 2
nrun notif dismiss --all k2;             rc_is "notif dismiss --all con una clave → uso (2)" 2
nrun notif dismiss --cosa;               rc_is "notif dismiss con una opción rara → uso (2)" 2
nrun notif dismiss k2 --json;            jqok "notif dismiss --json" '.dismissed == true'
nrun notif cosa;                         rc_is "notif: subcomando desconocido → uso (2)" 2
# quedan k3 y k4 (no se pueden quitar), k0 y kn
nrun notif dismiss --all;                rc_is "notif dismiss --all" 0
has "…cuenta las que quitó" "Quitadas: 2"
has "…y las que Android no deja quitar" "Sin quitar: 2 (Android no deja quitar las fijas ni las de servicios en marcha)"
nrun notif list --short;                 eq "…en el móvil solo quedan las fijas" "2"
nfctl 'notif post k5 Chat Uno|a' 'notif post k6 Chat Dos|b' 'notif post k7 Chat Tres|c @stubborn=1' 'notif post k8 Chat Fantasma|d @ghost=1'
nrun notif dismiss --all;                rc_is "dismiss --all: si Android no quita una → código 1" 1
has "…cuenta las quitadas (la que ya no estaba cuenta como quitada)" "Quitadas: 3"
has "…y avisa de la que no pudo" "No pude quitar 1: Android no quitó la notificación"
nrun notif dismiss --all --json;         eq "dismiss --all --json: quitadas, falladas y fijas" '{"dismissed":1,"failed":1,"skipped":2}'
rc_is "…y también sale con 1" 1
nfctl 'notif remove k7' 'notif remove k8' 'notif post k9 Chat Nueve|x' 'notif post k10 Chat Diez|y'
nrun notif dismiss --all --json;         eq "dismiss --all --json cuando todo sale bien" '{"dismissed":2,"failed":0,"skipped":2}'
rc_is "…y sale con 0" 0
nrun notif dismiss --all;                eq "dismiss --all con solo fijas" "Ninguna se puede quitar (2 son fijas o de servicios en marcha)."
rc_is "…y sale con 0" 0
nrun notif dismiss --all --json;         eq "…--json" '{"dismissed":0,"failed":0,"skipped":2}'
nfctl 'notif remove k3' 'notif remove k4'
nrun notif dismiss --all;                eq "dismiss --all sin notificaciones" "No hay notificaciones que quitar."
nrun notif dismiss --all --json;         eq "…--json" '{"dismissed":0,"failed":0,"skipped":0}'

echo "== nexo watch net notif: eventos en vivo"
NEXO_PORT=$NA "$NEXO" watch net notif --pretty >"$T/nw1.out" 2>&1 &
waitfor "$T/nw1.out" "red   → WiFi (con internet)" 5 && ok "watch net notif: llega el estado inicial de la red" || bad "watch net: estado inicial" "$(cat "$T/nw1.out")"
nfctl 'notif post kw Chat Luis|¿Qué tal?'
waitfor "$T/nw1.out" "notif → Chat: Luis — ¿Qué tal?" 5 && ok "watch --pretty: llega la notificación nueva" || bad "watch notif: publicada" "$(cat "$T/nw1.out")"
nfctl 'notif remove kw'
waitfor "$T/nw1.out" "notif → se quitó kw (la app la retiró)" 5 && ok "…y que la app la retiró" || bad "watch notif: retirada" "$(cat "$T/nw1.out")"
nfctl 'notif post kc Chat Dos|x' 'notif remove kc clicked'
waitfor "$T/nw1.out" "notif → se quitó kc (la tocaste)" 5 && ok "…y que la tocaste" || bad "watch notif: clicked" "$(cat "$T/nw1.out")"
nfctl 'notif post kt Chat Tres|x' 'notif remove kt timeout'
waitfor "$T/nw1.out" "notif → se quitó kt (caducó)" 5 && ok "…y que caducó" || bad "watch notif: timeout" "$(cat "$T/nw1.out")"
nfctl 'notif post ko Chat Cuatro|x' 'notif remove ko other'
waitfor "$T/nw1.out" "notif → se quitó ko (otro motivo)" 5 && ok "…y otro motivo" || bad "watch notif: other" "$(cat "$T/nw1.out")"
nfctl 'notif post kx Chat Cinco|x' 'notif remove kx motivo-raro'
waitfor "$T/nw1.out" "notif → se quitó kx (otro motivo)" 5 && ok "…un motivo que el cliente no conoce también es «otro motivo»" || bad "watch notif: motivo desconocido" "$(cat "$T/nw1.out")"
nfctl 'notif post kd Chat Seis|y'
nrun notif dismiss kd >/dev/null 2>&1
waitfor "$T/nw1.out" "notif → se quitó kd (descartada)" 5 && ok "…y que la descartaste con nexo notif dismiss" || bad "watch notif: dismissed" "$(cat "$T/nw1.out")"
nfctl 'notif post ks Chat Sola|' 'notif post kz Chat |solo texto'
waitfor "$T/nw1.out" "notif → Chat: Sola" 5 && ok "…una sin texto" || bad "watch notif: sin texto" "$(cat "$T/nw1.out")"
waitfor "$T/nw1.out" "notif → Chat: (sin título) — solo texto" 5 && ok "…y una sin título" || bad "watch notif: sin título" "$(cat "$T/nw1.out")"
nfctl 'net cellular'
waitfor "$T/nw1.out" "red   → datos móviles (con internet) · de pago" 5 && ok "watch net: cambia a datos móviles" || bad "watch net: datos" "$(cat "$T/nw1.out")"
nfctl 'net vpn on'
waitfor "$T/nw1.out" "red   → datos móviles + VPN (con internet) · de pago" 5 && ok "…y con VPN" || bad "watch net: vpn" "$(cat "$T/nw1.out")"
nfctl 'net captive on'
waitfor "$T/nw1.out" "red   → datos móviles + VPN (portal cautivo: falta iniciar sesión) · de pago" 5 && ok "…y con portal cautivo" || bad "watch net: portal" "$(cat "$T/nw1.out")"
nfctl 'net none'
waitfor "$T/nw1.out" "red   → sin conexión" 5 && ok "…y sin conexión" || bad "watch net: none" "$(cat "$T/nw1.out")"
pkill -f "$T/bin/nexo watch" 2>/dev/null
nfctl 'net captive off' 'net vpn off' 'net auto' 'notif remove ks' 'notif remove kz'

NEXO_PORT=$NA "$NEXO" watch net notif --event >"$T/nw2.out" 2>&1 &
waitfor "$T/nw2.out" '"type":"net","event":"online"' 5 && ok "watch --event: la red llega como eventos sueltos" || bad "watch --event: red inicial" "$(cat "$T/nw2.out")"
jq -e -s 'any(.[]; .type == "net" and .event == "connected" and .initial == true and .network == "wifi" and .internet == true and .metered == false and .vpn == false)' "$T/nw2.out" >/dev/null 2>&1 \
    && ok "watch --event: red conectada (inicial)" || bad "evento net connected inicial" "$(cat "$T/nw2.out")"
jq -e -s 'any(.[]; .type == "net" and .event == "online" and .initial == true)' "$T/nw2.out" >/dev/null 2>&1 && ok "…y con internet" || bad "evento net online inicial"
nfctl 'net cellular'
waitfor "$T/nw2.out" '"event":"changed","network":"cellular","previous":"wifi"' 5 && ok "watch --event: de WiFi a datos móviles es «changed»" || bad "evento net changed" "$(cat "$T/nw2.out")"
jq -e -s 'any(.[]; .event == "changed" and .metered == true and .vpn == false and .internet == true and (has("initial") | not))' "$T/nw2.out" >/dev/null 2>&1 && ok "…de pago y sin «initial»" || bad "campos del evento changed"
nfctl 'net vpn on'
waitfor "$T/nw2.out" '"type":"net","event":"vpn_on"' 5 && ok "watch --event: vpn_on" || bad "evento vpn_on" "$(cat "$T/nw2.out")"
nfctl 'net vpn off'
waitfor "$T/nw2.out" '"type":"net","event":"vpn_off"' 5 && ok "watch --event: vpn_off" || bad "evento vpn_off" "$(cat "$T/nw2.out")"
nfctl 'net validated off'
waitfor "$T/nw2.out" '"type":"net","event":"offline"' 5 && ok "watch --event: se pierde internet (offline)" || bad "evento offline" "$(cat "$T/nw2.out")"
nfctl 'net validated on'
sleep 0.3
[ "$(count "$T/nw2.out" '"event":"online"')" -ge 2 ] && ok "…y vuelve (online)" || bad "evento online al volver" "$(cat "$T/nw2.out")"
nfctl 'net none'
waitfor "$T/nw2.out" '"type":"net","event":"disconnected","previous":"cellular"' 5 && ok "watch --event: sin red (disconnected, y de cuál venía)" || bad "evento disconnected" "$(cat "$T/nw2.out")"
nfctl 'net wifi'
waitfor "$T/nw2.out" '"type":"net","event":"connected","network":"wifi"' 5 && ok "watch --event: vuelve la red (connected)" || bad "evento connected al volver" "$(cat "$T/nw2.out")"
nfctl 'notif post ke Chat Eva|nos vemos @category=msg @importance=4'
waitfor "$T/nw2.out" '"type":"notif","event":"posted","key":"ke"' 5 && ok "watch --event: notificación nueva (posted)" || bad "evento notif posted" "$(cat "$T/nw2.out")"
jq -e -s 'any(.[]; .type == "notif" and .event == "posted" and .key == "ke" and .package == "org.fake.chat" and .app == "Chat" and .title == "Eva" and .text == "nos vemos" and .category == "msg" and .importance == 4 and .ongoing == false and .clearable == true and (has("op") | not))' "$T/nw2.out" >/dev/null 2>&1 \
    && ok "…con todos sus campos (y sin el «op» interno)" || bad "campos del evento posted" "$(cat "$T/nw2.out")"
nfctl 'notif remove ke clicked'
waitfor "$T/nw2.out" '"type":"notif","event":"removed","key":"ke","reason":"clicked"' 5 && ok "watch --event: notificación quitada (removed) y por qué" || bad "evento notif removed" "$(cat "$T/nw2.out")"
pkill -f "$T/bin/nexo watch" 2>/dev/null

# net y notif no van en el «watch» por omisión (notif es privado: hay que pedirlo a propósito)
: > "$T/netnotif.req"
NEXO_PORT=$NA "$NEXO" watch >"$T/nw3.out" 2>&1 &
waitfor "$T/netnotif.req" '"subscribe"' 5 && sleep 0.2
grep -qF '"topics":["wifi","bt","audio","media"]' "$T/netnotif.req" && ok "watch sin temas pide wifi, bt, audio y media (net y notif hay que pedirlos)" || bad "temas de watch por omisión" "$(cat "$T/netnotif.req")"
pkill -f "$T/bin/nexo watch" 2>/dev/null
: > "$T/netnotif.req"
NEXO_PORT=$NA "$NEXO" notif watch >"$T/nw4.out" 2>&1 &
waitfor "$T/netnotif.req" '"subscribe"' 5 && sleep 0.2
grep -qF '"topics":["notif"]' "$T/netnotif.req" && ok "notif watch pide solo el tema notif" || bad "temas de notif watch" "$(cat "$T/netnotif.req")"
pkill -f "$T/bin/nexo notif watch" 2>/dev/null
NEXO_PORT=$M4 "$NEXO" watch net notif >"$T/nw5.out" 2>&1 &
waitfor "$T/nw5.out" "no ofrece eventos de «notif»" 5 && ok "watch net notif con una app 1.4 avisa de lo que no ofrece" || bad "watch en app 1.4" "$(cat "$T/nw5.out")"
grep -q "no ofrece eventos de «net»" "$T/nw5.out" && ok "…de los dos temas" || bad "aviso de net en app 1.4" "$(cat "$T/nw5.out")"
pkill -f "$T/bin/nexo watch" 2>/dev/null
nfctl 'notif forwarding off'
NEXO_PORT=$NA "$NEXO" notif watch --pretty >"$T/nw6.out" 2>&1 &
waitfor "$T/nw6.out" "el reenvío está apagado" 5 && ok "notif watch con el reenvío apagado: avisa (y dónde activarlo)" || bad "notif watch sin reenvío" "$(cat "$T/nw6.out")"
pkill -f "$T/bin/nexo notif watch" 2>/dev/null
nfctl 'notif forwarding on' 'notif access off'
NEXO_PORT=$NA "$NEXO" notif watch --pretty >"$T/nw7.out" 2>&1 &
waitfor "$T/nw7.out" "no llegará ninguna" 5 && ok "notif watch sin el acceso de Android: avisa de que no llegará ninguna" || bad "notif watch sin acceso" "$(cat "$T/nw7.out")"
pkill -f "$T/bin/nexo notif watch" 2>/dev/null
NEXO_TRANSPORT=python nrun notif watch;  rc_is "notif watch con el transporte python3 → uso (2)" 2
nrun watch cosas;                        rc_is "watch con un tema raro → uso (2)" 2

echo "== nexo notif: sin el acceso de Android o con el reenvío apagado"
nrun notif status;                       has "sin acceso: notif status lo explica" "Nexo no tiene el acceso a notificaciones de Android"
nrun notif status --short;               eq "…--short: off" "off"
nrun notif status --json;                jqok "…--json: access=false" '.access == false'
nrun notif list;                         rc_is "sin acceso: notif list pide un toque (3)" 3
has "…y dice dónde darlo" "Da a Nexo el acceso a las notificaciones en los ajustes de Android"
nrun notif dismiss k1;                   rc_is "sin acceso: notif dismiss (3)" 3
nrun notif dismiss --all;                rc_is "sin acceso: notif dismiss --all (3)" 3
nrun doctor;                             rc_is "doctor sin el acceso" 0
has "…lo cuenta" "falta el acceso a notificaciones de Android"
nfctl 'notif access on' 'notif forwarding off'
nrun notif status;                       has "reenvío apagado: notif status lo explica" "el reenvío está apagado"
nrun notif status --short;               eq "…--short: off" "off"
nrun notif list;                         rc_is "reenvío apagado: notif list pide activarlo en la app (3)" 3
has "…y dice dónde" "Reenviar notificaciones a Linux"
nrun notif dismiss k1;                   rc_is "reenvío apagado: notif dismiss (3)" 3
nrun notif dismiss --all --json;         rc_is "reenvío apagado: notif dismiss --all --json (3)" 3
nrun doctor;                             has "doctor: reenvío apagado y opcional" "notific.   reenvío a Linux: no (opcional"
hasnt "…y sin quejarse del acceso" "falta el acceso"
nfctl 'notif forwarding on'
nrun doctor;                             has "doctor: reenvío encendido" "notific.   reenvío a Linux: sí ("
has "…con la red del móvil" "red        WiFi, con internet"
nfctl 'net cellular' 'net vpn on' 'net captive on'
nrun doctor;                             has "doctor: portal cautivo" "red        datos móviles + VPN, con portal cautivo (falta iniciar sesión en la red) · de pago"
nfctl 'net captive off' 'net validated off' 'net vpn off'
nrun doctor;                             has "doctor: sin internet" "red        datos móviles, SIN internet · de pago"
nfctl 'net none'
nrun doctor;                             has "doctor: sin red" "red        el móvil no tiene conexión"
nfctl 'net validated on' 'net auto'
NEXO_PORT=$M4 run "$NEXO" doctor;        rc_is "doctor con una app 1.4 (sin net ni notif) → 0" 0
hasnt "…no inventa líneas de red ni de notificaciones" "notific."
NEXO_PORT=$M4 run "$NEXO" notif status;  rc_is "notif status con una app 1.4 → error (1)" 1
has "…y explica que la app es antigua" "más antigua"
NEXO_PORT=$M4 run "$NEXO" notif list;    rc_is "notif list con una app 1.4 → error (1)" 1
NEXO_PORT=$M4 run "$NEXO" notif dismiss k1; rc_is "notif dismiss con una app 1.4 → error (1)" 1
NEXO_PORT=$M4 run "$NEXO" notif dismiss --all; rc_is "notif dismiss --all con una app 1.4 → error (1)" 1
NEXO_PORT=$M4 run "$NEXO" version --check; rc_is "version --check con una app 1.4 → 1" 1
has "…dice que faltan net y notif" "faltan net notif"
run "$NEXO" version --check;             rc_is "version --check con la app nueva → 0" 0

echo "== nexo notif: sin jq, otro transporte, app apagada, ayuda"
NEXO_NO_JQ=1 nrun notif list;            has "sin jq: notif list da el JSON crudo" '"notifications"'
has "…y avisa" "instala jq"
NEXO_NO_JQ=1 nrun notif status;          has "sin jq: notif status también" '"forwarding":true'
NEXO_NO_JQ=1 nrun notif dismiss --all;   rc_is "sin jq: dismiss --all se niega (1)" 1
has "…y dice por qué" "necesita jq"
NEXO_TRANSPORT=python nrun notif list --short; eq "notif list con el transporte python3" "0"
NEXO_TRANSPORT=python nrun notif status --short; eq "notif status con el transporte python3" "0"
NEXO_PORT=1 run "$NEXO" notif status;    rc_is "notif status sin nadie escuchando → 10" 10
NEXO_PORT=1 run "$NEXO" notif list;      rc_is "notif list sin nadie escuchando → 10" 10
NEXO_PORT=1 run "$NEXO" notif dismiss --all; rc_is "notif dismiss --all sin nadie escuchando → 10" 10
NEXO_PORT=1 run "$NEXO" notif dismiss k1; rc_is "notif dismiss sin nadie escuchando → 10" 10
NEXO_TOKEN=00ff nrun notif list;         rc_is "notif list con un token malo → 11" 11
run "$NEXO" help;                        has "help describe nexo net" "net [status]"
has "…y nexo notif" "notif dismiss CLAVE | --all"
has "…y que con nexo-dbus salen en el escritorio" "salen en tu escritorio"
