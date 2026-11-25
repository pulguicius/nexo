# shellcheck shell=bash
# Pruebas de las notificaciones de Android en el escritorio: nexo-dbus como CLIENTE de org.freedesktop.Notifications.
# No se ejecuta solo: lo carga tests/dbus_tests.sh (usa sus ok/bad/poll/wait_name/dd_start/… y su dbus-daemon de pruebas).
# El «demonio de notificaciones» es tests/fake_notifd.py (apunta en un archivo cada llamada que recibe); el móvil es la app
# falsa de siempre, con --ctl (órdenes «notif post/remove…») y --reqlog (lo que le pide nexo-dbus). Además, busctl (sd-bus, otra
# implementación de D-Bus) mira el cable: lo que nexo-dbus manda lo entiende un cliente que no es el suyo.
# Lo que NO se prueba aquí: dunst, mako, swaync, GNOME o KDE de verdad (docs/LIMITACIONES.md).

echo "== nexo-dbus: las notificaciones de Android en el escritorio (con un demonio de avisos de pruebas)"
[ -S "$BUS_SOCK" ] || bus_start
NTF=org.freedesktop.Notifications
NTF_LOG=$DB/ntf.log
NTF_CTL=$DB/ntf.ctl
NTF_PID=""
NPH=$DB/nphone.ctl                       # órdenes para el «móvil» (la app falsa)
NREQ=$DB/nphone.req                      # lo que nexo-dbus le pide al «móvil»
: > "$NPH"
: > "$NREQ"
: > "$NTF_LOG"

phone() { printf '%s\n' "$*" >> "$NPH"; }
ntfctl() { printf '%s\n' "$*" >> "$NTF_CTL"; }
# ntf_start [opciones de fake_notifd.py…] → un demonio de notificaciones de pruebas (con el registro vacío)
ntf_start() {
    : > "$NTF_LOG"
    : > "$NTF_CTL"
    python3 "$ROOT/tests/fake_notifd.py" "$DD" "$DBUS_SESSION_BUS_ADDRESS" --log "$NTF_LOG" --ctl "$NTF_CTL" "$@" >"$DB/ntf.out" 2>&1 &
    NTF_PID=$!
    APP_PIDS+=("$NTF_PID")
    wait_name "$NTF" 6
}
ntf_stop() {
    [ -n "$NTF_PID" ] && { kill "$NTF_PID" 2>/dev/null; wait "$NTF_PID" 2>/dev/null; }
    NTF_PID=""
    wait_gone "$NTF" 4
}
ncount() { jq -s --arg op "$1" '[.[] | select(.op == $op)] | length' "$NTF_LOG" 2>/dev/null; }
nlast() { jq -c 'select(.op == "notify")' "$NTF_LOG" 2>/dev/null | tail -n 1; }
nid() { jq -rs --arg s "$1" '[.[] | select(.op == "notify" and .summary == $s)] | last | .id' "$NTF_LOG" 2>/dev/null; }
# nwait N [SEGUNDOS] → espera a que el demonio de pruebas haya recibido N avisos (Notify) en total
nwait() { poll "[ \"\$(ncount notify)\" -ge $1 ]" "${2:-6}"; }
# ntail N CAMPO → ese campo (filtro de jq) de los últimos N avisos, separados por «|»
ntail() { jq -rs --argjson n "$1" "[.[] | select(.op == \"notify\")] | .[-\$n:] | map($2) | join(\"|\")" "$NTF_LOG" 2>/dev/null; }
# nchk "descripción" 'filtro jq' → el último aviso que recibió el demonio de pruebas cumple el filtro
nchk() {
    local rec
    rec=$(nlast)
    if printf '%s' "$rec" | jq -e "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1" "último aviso: $rec"; fi
}
nreq_has() { jq -e --arg c "$1" 'select(.cmd == $c)' "$NREQ" >/dev/null 2>&1; }
ndis() { jq -r 'select(.cmd == "notif.dismiss") | .key' "$NREQ" 2>/dev/null | paste -sd, -; }
# lo que cuenta «nexo-dbus status» (lo lee del archivo de estado del demonio de $DB/run)
nstate() { env -i PATH="$PATH" HOME="$DB/home" XDG_RUNTIME_DIR="$DB/run" XDG_CACHE_HOME="$DB/cache" python3 "$DD" status 2>&1; }
nst_has() { nstate | grep -qF -- "$(printf '%-15s %s' Notificaciones "$1")"; }
# nsubscribed → nexo-dbus ya está apuntado a los avisos del móvil (la app contestó a su subscribe y le preguntó por el reenvío)
nsubscribed() { poll 'nreq_has notif.status' "${1:-8}"; }

NPORT=$(start_app dbusNt --ctl "$NPH" --reqlog "$NREQ")
run python3 "$DD" help
has "la ayuda explica las notificaciones y cómo apagarlas" "--no-notify"
has "…y las variables que las ajustan" "NEXO_DBUS_NOTIFY_ALL=1"

# ------------------------------------------------------------------------------ sin demonio de notificaciones
dd_start N1 "$NPORT" NEXO_DBUS_MPRIS=0
nsubscribed && ok "nexo-dbus se conecta a la app y pide el tema «notif»" || bad "no se suscribió" "$(cat "$DB/N1.log") $(cat "$NREQ")"
jq -e 'select(.cmd == "subscribe") | .topics | index("notif")' "$NREQ" >/dev/null 2>&1 && ok "…en su suscripción (los avisos no llegan sin pedirlos)" || bad "subscribe sin notif" "$(cat "$NREQ")"
poll 'grep -q "no hay un demonio de notificaciones" "$DB/N1.log"' 8 && ok "sin demonio de notificaciones en el bus, nexo-dbus lo dice en su registro…" || bad "no avisó de que falta el demonio" "$(cat "$DB/N1.log")"
grep -q "dunst, mako o swaync" "$DB/N1.log" && ok "…y explica qué instalar" || bad "sin explicación" "$(cat "$DB/N1.log")"
phone notif post k0 Calendario 'Reunión|a las 10'
phone notif post k0b Calendario 'Otra|cosa'
sleep 1
[ "$(grep -c "no hay un demonio de notificaciones" "$DB/N1.log")" = 1 ] && ok "…una sola vez, no una por cada aviso" || bad "repite el aviso en el registro" "$(cat "$DB/N1.log")"
poll 'nst_has "no hay un demonio de notificaciones en el bus de sesión"' 6 && ok "«nexo-dbus status» también lo cuenta" || bad "status sin demonio" "$(nstate)"

# ------------------------------------------------------------------------------ aparece un demonio
ntf_start && ok "arranca un demonio de notificaciones de pruebas (ocupa org.freedesktop.Notifications en el bus)" || bad "demonio de notificaciones de pruebas" "$(cat "$DB/ntf.out")"
busctl --user monitor --json=short "$NTF" >"$DB/ntfmon.json" 2>"$DB/ntfmon.err" &
NMON=$!
APP_PIDS+=("$NMON")
sleep 0.6
phone notif post k1 WhatsApp 'Ana|Hola, ¿vienes?'
nwait 1 && ok "al aparecer el demonio, el siguiente aviso del móvil sale en él (sin reiniciar nexo-dbus)" || bad "el aviso no llegó al demonio" "$(tail -5 "$DB/N1.log")"
nchk "el aviso lleva la app, el título y el texto de Android" '.app == "WhatsApp" and .summary == "Ana" and .body == "Hola, ¿vienes?"'
nchk "…con el icono «phone», sin botones, sin reemplazar nada y con la caducidad que decida el demonio (-1)" '.icon == "phone" and .actions == [] and .replaces == 0 and .expire == -1'
nchk "…urgencia normal (1) y categoría im.received (es un mensaje)" '.hints.urgency == ["y", 1] and .hints.category == ["s", "im.received"]'
grep -q "demonio de notificaciones: fakenotifd 1.0" "$DB/N1.log" && ok "nexo-dbus anota qué demonio hay" || bad "no anotó el demonio" "$(cat "$DB/N1.log")"
poll 'nst_has "reenviando a fakenotifd 1.0 (org.freedesktop.Notifications)"' 6 && ok "«nexo-dbus status» cuenta a qué demonio reenvía" || bad "status con demonio" "$(nstate)"

# lo que viaja por el bus lo entiende otro cliente D-Bus (busctl, sd-bus), no solo el código de nexo-dbus
ID1=$(nlast | jq .id)
phone notif remove k1
poll '[ "$(ncount close)" -ge 1 ]' 6
sleep 0.5
kill "$NMON" 2>/dev/null
wait "$NMON" 2>/dev/null
jq -e 'select(.type == "method_call" and .member == "Notify") | .payload | .type == "susssasa{sv}i" and .data == ["WhatsApp", 0, "phone", "Ana", "Hola, ¿vienes?", [], {"urgency": {"type": "y", "data": 1}, "category": {"type": "s", "data": "im.received"}}, -1]' "$DB/ntfmon.json" >/dev/null 2>&1 \
    && ok "en el cable (visto por busctl): Notify lleva exactamente (app, 0, \"phone\", título, texto, [], {urgency: byte, category: string}, -1)" || bad "Notify en el cable" "$(cat "$DB/ntfmon.json" "$DB/ntfmon.err")"
jq -e 'select(.type == "method_call" and .member == "CloseNotification") | .payload | .type == "u"' "$DB/ntfmon.json" >/dev/null 2>&1 \
    && ok "…y CloseNotification lleva un número (uint32)" || bad "CloseNotification en el cable" "$(cat "$DB/ntfmon.json")"
jq -e --argjson id "$ID1" 'select(.type == "method_call" and .member == "CloseNotification") | .payload.data == [$id]' "$DB/ntfmon.json" >/dev/null 2>&1 \
    && ok "…el del aviso que se quitó en el móvil" || bad "número de CloseNotification" "$(cat "$DB/ntfmon.json")"

# ------------------------------------------------------------------------------ reemplazo, marcado y categorías
phone notif post k1 WhatsApp 'Ana|primer texto'
nwait 2
ID1=$(nlast | jq .id)
phone notif post k1 WhatsApp 'Ana|texto cambiado'
nwait 3
nchk "si Android actualiza una notificación, se REEMPLAZA la de antes (replaces_id = su número): no salen dos" ".replaces == $ID1 and .id == $ID1 and .body == \"texto cambiado\""
phone notif post k2 Gmail 'Correo nuevo|a <b>negrita</b> & más <img src=x> @category=email'
nwait 4
nchk "un demonio que entiende marcado (body-markup) recibe el texto ESCAPADO: lo del móvil no puede meter etiquetas" '.body == "a &lt;b&gt;negrita&lt;/b&gt; &amp; más &lt;img src=x&gt;"'
nchk "…y la categoría email sale como email.arrived" '.hints.category == ["s", "email.arrived"]'
phone notif post k2t 'Gm<i>ail' '<u>Título</u>|texto'
nwait 5
nchk "…y en el título y la app las etiquetas se vuelven ‹…› (algunos demonios interpretan marcado también ahí)" '.summary == "‹u›Título‹/u›" and .app == "Gm‹i›ail"'
phone notif post k2p Descargas 'Archivo|bajando @category=progress'
nwait 6
nchk "…la categoría progress sale como transfer" '.hints.category == ["s", "transfer"]'
phone notif post k2o Otra 'Sin categoría conocida|texto @category=promo'
nwait 7
nchk "…y una categoría que Android tiene pero el escritorio no, sale sin categoría" '(.hints | has("category") | not) and .hints.urgency == ["y", 1]'

# ------------------------------------------------------------------------------ urgencia y lo que no se enseña
N=$(ncount notify)
phone notif post k3 Reloj 'Alarma|despierta @category=alarm'
phone notif post k4 Teléfono 'Llamada|mamá @category=call'
phone notif post k5 Tienda 'Oferta|barata @importance=2'
phone notif post k6 Sistema 'Silenciosa|no molesta @importance=1'
phone notif post k7 Música 'Sonando|algo @ongoing=1'
phone notif post k8 Final 'Centinela|fin'
nwait $((N + 4)) && ok "los avisos llegan en el orden en que los manda el móvil" || bad "faltan avisos" "$(cat "$NTF_LOG")"
sleep 0.5
[ "$(ncount notify)" = "$((N + 4))" ] && [ "$(ntail 4 .summary)" = "Alarma|Llamada|Oferta|Centinela" ] \
    && ok "las de importancia mínima y las fijas (reproductor, VPN, servicios en marcha) NO se enseñan" || bad "filtro de fijas y mínimas" "$(ntail 8 .summary)"
[ "$(ntail 4 '.hints.urgency[1]')" = "2|2|0|1" ] && ok "…alarmas y llamadas con urgencia alta (2), las poco importantes con baja (0) y el resto con normal (1)" || bad "urgencias" "$(ntail 4 '.hints.urgency[1]')"

# ------------------------------------------------------------------------------ el texto del móvil llega limpio
N=$(ncount notify)
printf 'notif post k9 App T\007ítulo|cue\007rpo\033[0m\n' >> "$NPH"
nwait $((N + 1))
nchk "los caracteres de control del móvil (pitidos, escapes) no llegan al escritorio" '.summary == "Título" and .body == "cuerpo[0m"'
LT=$(python3 -c 'print("t" * 500)')
LB=$(python3 -c 'print("x" * 3000)')
phone notif post kA App "$LT|$LB"
nwait $((N + 2))
nchk "…y los textos larguísimos se recortan (título a 200 letras, cuerpo a 1000, con «…»)" '(.summary | length) == 200 and (.summary | endswith("…")) and (.body | length) == 1000 and (.body | endswith("…"))'
phone notif post kB App2 '|solo cuerpo'
nwait $((N + 3))
nchk "…y sin título, el nombre de la app hace de título" '.summary == "App2" and .body == "solo cuerpo"'

# ------------------------------------------------------------------------------ cerrarla en un lado la quita en el otro
phone notif post kR Chat 'Se irá|pronto'
nwait $((N + 4))
RID=$(nid 'Se irá')
phone notif post k6 Sistema 'Silenciosa|sigue sin enseñarse @importance=1'
C0=$(ncount close)
phone notif remove kR
phone notif remove k6
poll "[ \"\$(ncount close)\" -ge $((C0 + 1)) ]" 6 && ok "si la quitas en el móvil, desaparece también del escritorio (CloseNotification)" || bad "no se cerró en el demonio" "$(cat "$NTF_LOG")"
sleep 0.5
[ "$(ncount close)" = "$((C0 + 1))" ] && jq -e --argjson id "$RID" 'select(.op == "close") | .id == $id' <(jq -c 'select(.op == "close")' "$NTF_LOG" | tail -n 1) >/dev/null 2>&1 \
    && ok "…solo la suya: quitar una que nunca se enseñó no cierra nada" || bad "CloseNotification de más o de menos" "$(cat "$NTF_LOG")"

: > "$NREQ"
N=$(ncount notify)
for k in D1 D2 D3 D4; do phone notif post "k$k" Chat "Aviso $k|texto"; done
nwait $((N + 4))
ntfctl closed "$(nid 'Aviso D1')" 1
ntfctl closed "$(nid 'Aviso D2')" 3
ntfctl closed "$(nid 'Aviso D3')" 4
sleep 1
[ -z "$(ndis)" ] && ok "si el demonio la cierra porque caducó (1), por una llamada (3) u otro motivo (4), el móvil no se entera" || bad "quitó del móvil por un motivo que no era del usuario" "$(ndis)"
C0=$(ncount close)
ntfctl closed "$(nid 'Aviso D4')" 2
poll '[ "$(ndis)" = kD4 ]' 6 && ok "si el usuario la cierra aquí (motivo 2), nexo-dbus se lo dice al móvil: notif.dismiss con su clave" || bad "no quitó la notificación del móvil" "$(ndis) | $(cat "$DB/N1.log" | tail -3)"
sleep 0.5
[ "$(ncount close)" = "$C0" ] && ok "…y no la vuelve a cerrar en el demonio (no hay bucle)" || bad "bucle de cierres" "$(cat "$NTF_LOG")"
ntfctl closed 4242 2
sleep 0.5
[ "$(ndis)" = kD4 ] && ok "una notificación que no es de Android (otro programa cerrada por el usuario) no toca el móvil" || bad "tocó el móvil por una que no era suya" "$(ndis)"

# ------------------------------------------------------------------------------ el demonio se reinicia o cambia
ntf_stop
poll 'nst_has "no hay un demonio de notificaciones en el bus de sesión"' 6 && ok "si el demonio se va, «nexo-dbus status» lo cuenta enseguida" || bad "no se enteró de que el demonio se fue" "$(nstate)"
ntf_start --caps body --name plainnotifd --version 2.0
sleep 0.5
phone notif post k1 WhatsApp 'Ana|1 < 2 & <b>tres</b>'
nwait 1 && ok "…y cuando vuelve (otro, sin marcado), los avisos siguen saliendo" || bad "no volvió a avisar" "$(tail -5 "$DB/N1.log")"
nchk "los números del demonio de antes ya no valen: no se «reemplaza» nada (replaces_id = 0)" '.replaces == 0'
nchk "un demonio SIN marcado en el cuerpo recibe el texto tal cual (no se escapa)" '.body == "1 < 2 & <b>tres</b>"'
grep -q "demonio de notificaciones: plainnotifd 2.0" "$DB/N1.log" && ok "…y se anota el demonio nuevo" || bad "no anotó el demonio nuevo" "$(cat "$DB/N1.log")"
poll 'nst_has "reenviando a plainnotifd 2.0"' 6 && ok "«nexo-dbus status» ya habla del nuevo" || bad "status con el demonio nuevo" "$(nstate)"

# ------------------------------------------------------------------------------ un demonio que rechaza los avisos
ntf_stop
ntf_start --fail-notify
sleep 0.5
phone notif post kF1 Chat 'Falla|el demonio'
poll 'grep -q "el demonio no aceptó una notificación" "$DB/N1.log"' 6 && ok "un demonio que rechaza un aviso no tumba a nexo-dbus: lo anota…" || bad "no anotó el rechazo" "$(cat "$DB/N1.log")"
kill -0 "$DD_PID" 2>/dev/null && ok "…y sigue vivo" || bad "nexo-dbus murió"
ntf_stop
ntf_start
sleep 0.5
phone notif post kF2 Chat 'Sigue|funcionando'
nwait 1 && ok "…y cuando el demonio vuelve a funcionar, los avisos vuelven a salir" || bad "no se recuperó" "$(tail -5 "$DB/N1.log")"
dd_stop

# ------------------------------------------------------------------------------ NEXO_DBUS_NOTIFY_ALL y NEXO_DBUS_NOTIFY_DISMISS
: > "$NREQ"
dd_start N2 "$NPORT" NEXO_DBUS_MPRIS=0 NEXO_DBUS_NOTIFY_ALL=1 NEXO_DBUS_NOTIFY_DISMISS=0
nsubscribed
N=$(ncount notify)
phone notif post kO1 Musica 'Fija|siempre ahí @ongoing=1'
phone notif post kO2 Sistema 'Muda|sin avisar @importance=1'
nwait $((N + 2))
[ "$(ntail 2 .summary)" = "Fija|Muda" ] && [ "$(ntail 2 .expire)" = "0|-1" ] && [ "$(ntail 2 '.hints.urgency[1]')" = "1|0" ] \
    && ok "NEXO_DBUS_NOTIFY_ALL=1 enseña también las fijas (sin caducidad: se quedan hasta que se quiten) y las de importancia mínima (urgencia baja)" || bad "NEXO_DBUS_NOTIFY_ALL" "$(ntail 2 .summary) $(ntail 2 .expire) $(ntail 2 '.hints.urgency[1]')"
ntfctl closed "$(nid 'Muda')" 2
sleep 1
[ -z "$(ndis)" ] && ok "NEXO_DBUS_NOTIFY_DISMISS=0: cerrar un aviso aquí ya no lo quita del móvil" || bad "NEXO_DBUS_NOTIFY_DISMISS=0 no se respetó" "$(ndis)"
dd_stop

# ------------------------------------------------------------------------------ con el reproductor MPRIS a la vez
: > "$NREQ"
dd_start N3 "$NPORT"
nsubscribed
wait_name "$MP" 8 && ok "con las notificaciones y el reproductor MPRIS en el mismo nexo-dbus, el reproductor sigue apareciendo" || bad "sin reproductor" "$(cat "$DB/N3.log")"
N=$(ncount notify)
phone notif post kM1 Chat 'Los dos|a la vez'
nwait $((N + 1)) && ok "…y las notificaciones también salen" || bad "sin notificaciones junto a MPRIS" "$(cat "$DB/N3.log")"
jq -e 'select(.cmd == "subscribe") | .topics | (index("notif") != null and index("media") != null)' "$NREQ" >/dev/null 2>&1 && ok "…y se piden los dos temas en la misma suscripción (media y notif)" || bad "suscripción conjunta" "$(cat "$NREQ")"
dd_stop

# ------------------------------------------------------------------------------ cómo se ve cuando algo falta o se apaga
printf 'notif forwarding off\n' > "$DB/nphone2.ctl"
N2PORT=$(start_app dbusNt2 --ctl "$DB/nphone2.ctl")
dd_start N4 "$N2PORT" NEXO_DBUS_MPRIS=0
poll 'nst_has "el reenvío está apagado: actívalo en la app Nexo («Reenviar notificaciones a Linux»)"' 8 && ok "con «Reenviar notificaciones a Linux» apagado en la app, «nexo-dbus status» dice cómo encenderlo" || bad "status con el reenvío apagado" "$(nstate)"
grep -q "no hay un demonio" "$DB/N4.log" && bad "con el reenvío apagado no tiene por qué quejarse de que falte el demonio" "$(cat "$DB/N4.log")" || ok "…sin llenar el registro de quejas (quien no usa el reenvío no necesita saber más)"
N=$(ncount notify)
printf 'notif forwarding on\nnotif post kS1 Chat Encendido|ya reenvía\n' >> "$DB/nphone2.ctl"
nwait $((N + 1)) && ok "en cuanto se enciende en la app, los avisos salen (no hace falta reiniciar nexo-dbus)" || bad "no salió el aviso tras encender el reenvío" "$(cat "$DB/N4.log")"
dd_stop

printf 'notif access off\n' > "$DB/nphone3.ctl"
N3PORT=$(start_app dbusNt3 --ctl "$DB/nphone3.ctl")
dd_start N5 "$N3PORT" NEXO_DBUS_MPRIS=0
poll 'nst_has "falta el acceso a notificaciones de Android (app Nexo → Permisos → Acceso a notificaciones)"' 8 && ok "sin el acceso a notificaciones de Android, «nexo-dbus status» dice dónde darlo" || bad "status sin acceso" "$(nstate)"
dd_stop

N4PORT=$(start_app dbusNt4 --minor4)
dd_start N6 "$N4PORT" NEXO_DBUS_MPRIS=0
poll 'nst_has "esta versión de la app Nexo no reenvía notificaciones"' 8 && ok "con una app anterior a la 0.4.3, «nexo-dbus status» lo dice…" || bad "status con app antigua" "$(nstate)"
poll 'grep -q "esta versión de la app Nexo no reenvía notificaciones" "$DB/N6.log"' 4 && ok "…y lo anota en el registro" || bad "registro con app antigua" "$(cat "$DB/N6.log")"
dd_stop

: > "$NREQ"
dd_start N7 "$NPORT" NEXO_DBUS_NOTIFY=0
poll 'nst_has apagado' 8 && ok "NEXO_DBUS_NOTIFY=0 apaga las notificaciones y «nexo-dbus status» lo dice" || bad "status con las notificaciones apagadas" "$(nstate)"
sleep 0.5
jq -e 'select(.cmd == "subscribe") | .topics | index("notif")' "$NREQ" >/dev/null 2>&1 && bad "apagadas, no debería pedir el tema notif" "$(cat "$NREQ")" || ok "…y no pide el tema «notif» a la app (nada sale del móvil)"
dd_stop
: > "$NREQ"
DD_OPTS=(-v --no-notify)
dd_start N8 "$NPORT"
poll 'nst_has apagado' 8 && ok "--no-notify hace lo mismo" || bad "--no-notify" "$(nstate)"
dd_stop
DD_OPTS=(-v)

ntf_stop
