# Pruebas de nexo-tools 2.4 (servidor HTTPS, emparejamiento, descubrimiento, explorador, escritura, envío con código).
# No se ejecuta solo: lo carga tests/run_tests.sh (usa sus ok/bad/run/has/…). Necesita: bash, python3, openssl.
# Simula DOS dispositivos en esta máquina: A (servidor, con su HOME) y B (cliente, con el suyo), hablando por 127.0.0.1.
# Nada de esto se ha probado entre dos móviles reales: aquí se prueba el protocolo, la seguridad y los comandos.

echo "== nexo-tools: sintaxis, versión y ayuda"
TT=$T/tools
mkdir -p "$TT"
cp "$ROOT/termux/bin/nexo-tools" "$TT/nexo-tools"
chmod +x "$TT/nexo-tools"
NT=$TT/nexo-tools
TOOLS_VERSION=$(sed -n 's/^NEXO_TOOLS_VERSION="\(.*\)"/\1/p' "$ROOT/termux/bin/nexo-tools")
extract_block() { sed -n "/<<'$1'\$/,/^$1\$/p" "$NT" | sed '1d;$d'; }   # extract_block NOMBRE → el Python embebido en esa ayuda «<<'NOMBRE'»
for blk in PY PYPEER PYCLIENT; do extract_block "$blk" > "$TT/$blk.py"; done
for blk in PY PYPEER PYCLIENT; do
    if [ -s "$TT/$blk.py" ] && python3 -B - "$TT/$blk.py" 2>"$T/err" <<'EOF'
import ast, sys
ast.parse(open(sys.argv[1], encoding="utf-8").read(), feature_version=(3, 8))
EOF
    then ok "el Python embebido «$blk» usa solo sintaxis de Python 3.8 (el de las distros más viejas)"; else bad "sintaxis de Python 3.8 en $blk" "$(cat "$T/err")"; fi
done
run bash "$NT" version;                   has "version dice la 2.4" "$TOOLS_VERSION"
case $TOOLS_VERSION in 2.4.*) ok "nexo-tools es la 2.4.x" ;; *) bad "versión de nexo-tools" "$TOOLS_VERSION" ;; esac
run bash "$NT" help;                      has "la ayuda explica send/fetch" "nexo-tools fetch"
has "…y discover, pair y connect" "nexo-tools pair"
has "…y el modo escritura" "--rw"
run bash "$NT" cosas;                     rc_is "comando desconocido → error" 2

TA=$TT/a; TB=$TT/b
mkdir -p "$TA/share/docs" "$TA/share/sub/deep" "$TA/share/big" "$TA/.ssh" "$TA/.config/nexo" "$TB"
DISC=$((20000 + $$ % 20000)); PORT_T=$((DISC + 1))
dev_a() { env -i PATH="$PATH" HOME="$TA" NEXO_TOOLS_IP=127.0.0.1 NEXO_TOOLS_DISCOVER_PORT=$DISC NEXO_TOOLS_BEACON_TO=127.0.0.1 NEXO_TOOLS_DEVICE=Telefono-A bash "$NT" "$@"; }
dev_b() { env -i PATH="$PATH" HOME="$TB" NEXO_TOOLS_DISCOVER_PORT=$DISC NEXO_TOOLS_DEVICE=Telefono-B bash "$NT" "$@"; }
P() { python3 -I "$ROOT/tests/tools_probe.py" --port "$PORT_T" "$@"; }
http_is() { local want=$2 got; got=$(P "${@:3}" 2>&1 | head -1); if [ "$got" = "$want" ]; then ok "$1"; else bad "$1" "HTTP $got (se esperaba $want) con: ${*:3}"; fi; }
http_in() { local want=" $2 " got; got=$(P "${@:3}" 2>&1 | head -1); case $want in *" $got "*) ok "$1" ;; *) bad "$1" "HTTP [$got] (se esperaba uno de: $2) con: ${*:3}" ;; esac; }
http_not() { local not=$2 got; got=$(P "${@:3}" 2>&1 | head -1); if [ "$got" != "$not" ] && [ -n "$got" ]; then ok "$1"; else bad "$1" "HTTP [$got] y no debería ser $not con: ${*:3}"; fi; }
# datos de prueba: de todo un poco (extensiones raras, sin extensión, ocultos, unicode, espacios, enlaces)
(
    cd "$TA/share/docs" || exit 1
    echo hello > a.txt; printf 'x' > B.JPG; printf 'x' > c.png; printf 'x' > pic.png; echo '<b>x</b>' > page.html; printf 'z' > data.xyz123
    printf 'n' > noext; printf 'g' > archive.tar.gz; printf 'h' > .hidden; echo u > 'ünicode-ñ.txt'; echo s > 'sp ace.txt'; : > empty.bin
    printf '\211PNG\r\n\032\n' > real.png
    ln -s /etc/passwd evil 2>/dev/null; ln -s a.txt ok-link 2>/dev/null
)
head -c 3000000 /dev/urandom > "$TA/share/sub/deep/file.bin"
for i in $(seq 1 500); do echo "$i" > "$TA/share/big/f$i.dat"; done
echo SECRETA > "$TA/.ssh/id_rsa"; echo tok > "$TA/.config/nexo/config"

echo "== nexo-tools: servidor (solo lectura por defecto), nombre y modo"
run dev_a server "$TA" "$PORT_T";           rc_is "server arranca" 0
has "…dice el nombre con el que se anuncia" "Telefono-A"
has "…y que está en solo lectura" "solo lectura"
run dev_a status;                           has "status muestra el modo" "Modo:"
TOKEN_A=$(cat "$TA/.local/state/nexo-tools/token")
case $(stat -c %a "$TA/.local/state/nexo-tools/token" 2>/dev/null || stat -f %Lp "$TA/.local/state/nexo-tools/token") in 600) ok "el token del servidor es 0600" ;; *) bad "permisos del token" ;; esac
http_is "sin token → 401" 401 GET /api/ping
http_is "token malo → 401" 401 --token nope GET /api/ping
run P --token "$TOKEN_A" GET /api/ping;     has "con el token: ping" '"name":"NEXO-TOOLS"'
has "…que es de solo lectura" '"role":"ro"'
has "…y dice que no admite escritura" '"rw":false'

echo "== nexo-tools: lo que NUNCA se sirve, aunque se comparta la carpeta que lo contiene"
run P --token "$TOKEN_A" GET "/api/list?path="
has "la raíz compartida (HOME) se lista" '"share"'
hasnt "…pero no sale .ssh (claves)" '".ssh"'
http_is "bajar .ssh/id_rsa directo → 404" 404 --token "$TOKEN_A" GET "/api/download?path=.ssh/id_rsa"
http_is "bajar el token del servidor → 404" 404 --token "$TOKEN_A" GET "/api/download?path=.local/state/nexo-tools/token"
http_is "bajar la clave TLS del servidor → 404" 404 --token "$TOKEN_A" GET "/api/download?path=.local/state/nexo-tools/server.key"
http_is "bajar la config de Nexo (token de la app) → 404" 404 --token "$TOKEN_A" GET "/api/download?path=.config/nexo/config"
run P --token "$TOKEN_A" GET "/api/list?path=.local/state"
hasnt "listar el estado de nexo-tools no muestra claves" "server.key"
http_not "../ no sale de la carpeta compartida" 200 --token "$TOKEN_A" GET "/api/download?path=../../etc/passwd"
http_not "%2e%2e tampoco" 200 --token "$TOKEN_A" GET "/api/download?path=%2e%2e/%2e%2e/etc/passwd"
http_not "una ruta absoluta tampoco" 200 --token "$TOKEN_A" GET "/api/download?path=/etc/passwd"
http_not "ni con un byte nulo" 200 --token "$TOKEN_A" GET "/api/download?path=share/docs/a.txt%00.png"
http_in "un enlace simbólico que escapa (→ /etc/passwd) no se sirve" "403 404" --token "$TOKEN_A" GET "/api/download?path=share/docs/evil"
http_in "los enlaces simbólicos no se sirven por defecto (ni los de dentro)" "403 404" --token "$TOKEN_A" GET "/api/download?path=share/docs/ok-link"

echo "== nexo-tools: descargas HTTP (rangos, cabeceras, listado sin tope)"
run P --token "$TOKEN_A" --header "Range: bytes=1-3" --show-headers GET "/api/download?path=share/docs/a.txt"
rc_is "Range: responde" 0
case $OUT in "206"*) ok "…con 206 (descarga parcial)" ;; *) bad "Range → 206" "$OUT" ;; esac
has "…y Content-Range" "H Content-Range: bytes 1-3/6"
run P --token "$TOKEN_A" --show-headers GET "/api/download?path=share/docs/a.txt"
has "una descarga lleva su SHA-256" "H X-Nexo-SHA256:"
has "…y se marca como adjunto (el navegador no la ejecuta)" "attachment"
run P --token "$TOKEN_A" GET "/api/list?path=share/big&limit=100&offset=450"
jqok_body() { printf '%s' "$OUT" | sed 1d | jq -e "$2" >/dev/null 2>&1 && ok "$1" || bad "$1" "jq «$2» falló sobre [$OUT]"; }
jqok_body "paginar 500 archivos: la última página trae 50 y no hay más" '(.entries|length)==50 and .total==500 and .has_more==false'
run P --token "$TOKEN_A" GET "/api/list?path=share/docs"
jqok_body "el listado incluye TODAS las extensiones (también sin extensión y ocultos)" '[.entries[].name]|(index("data.xyz123")!=null and index("noext")!=null and index(".hidden")!=null and index("ünicode-ñ.txt")!=null)'
jqok_body "…y resume cuántos archivos hay de cada extensión" '.ext_counts[".png"]==3 and .ext_counts[".xyz123"]==1'
run P --token "$TOKEN_A" GET "/api/list?path=share/docs&glob=*.JPG%7C*.PNG"
jqok_body "varios patrones separados por | sin distinguir mayúsculas (*.JPG|*.PNG)" '[.entries[]|select(.kind=="file")|.name]|sort==["B.JPG","c.png","pic.png","real.png"]'
run P --token "$TOKEN_A" GET "/api/list?path=share/docs&ext=.xyz123,(none)"
jqok_body "filtrar por extensión rara y por «sin extensión»" '[.entries[]|select(.kind=="file")|.name]|sort==[".hidden","data.xyz123","noext"]'

echo "== nexo-tools: interfaz web (gestor de archivos en el navegador)"
run P --show-headers GET /ui;               has "la interfaz web responde sin token (el token se pide dentro)" "H Content-Type: text/html"
has "…con una política de seguridad que no permite scripts ajenos" "script-src 'self'"
hasnt "…y sin scripts incrustados" "<script>"
run P --show-headers GET /ui.js;            has "el script de la interfaz se sirve aparte" "javascript"
run P --token "$TOKEN_A" POST /api/ticket --json '{"path":"share/docs/a.txt"}'
TK=$(printf '%s' "$OUT" | sed 1d | jq -r .url 2>/dev/null)
case $TK in /api/dl/*) ok "un ticket da un enlace de descarga que no lleva el token" ;; *) bad "ticket" "$OUT" ;; esac
run P --show-headers GET "$TK";             has "…y baja el archivo sin Authorization" "hello"
run P --token "$TOKEN_A" POST /api/ticket --json '{"path":"share/docs/real.png","inline":true}'
TK=$(printf '%s' "$OUT" | sed 1d | jq -r .url 2>/dev/null)
run P --show-headers --out /dev/null GET "$TK"; has "una imagen se puede ver en línea" "H Content-Disposition: inline"
run P --token "$TOKEN_A" POST /api/ticket --json '{"path":"share/docs/page.html","inline":true}'
TK=$(printf '%s' "$OUT" | sed 1d | jq -r .url 2>/dev/null)
run P --show-headers GET "$TK";             has "un HTML se muestra como TEXTO (nunca se ejecuta)" "text/plain"
http_is "un ticket inventado → 404" 404 GET /api/dl/00000000000000000000000000000000
http_is "un ticket de una ruta prohibida → 404" 404 --token "$TOKEN_A" POST /api/ticket --json '{"path":".ssh/id_rsa"}'

echo "== nexo-tools: en solo lectura nada se escribe"
http_is "mkdir → 403" 403 --token "$TOKEN_A" POST /api/mkdir --json '{"path":"share/nuevo"}'
echo up > "$TT/up.txt"
http_is "subir → 403" 403 --token "$TOKEN_A" PUT "/api/upload?path=share/up.txt" --file "$TT/up.txt"
http_is "borrar → 403" 403 --token "$TOKEN_A" POST /api/delete --json '{"path":"share/docs/a.txt"}'
[ -e "$TA/share/docs/a.txt" ] && [ ! -e "$TA/share/nuevo" ] && [ ! -e "$TA/share/up.txt" ] && ok "…y el disco quedó intacto" || bad "el disco cambió en solo lectura"

echo "== nexo-tools: un cliente lento no bloquea a los demás"
python3 -I - "$PORT_T" <<'EOF' &
import socket, sys, time
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
time.sleep(6)
EOF
SLOWPID=$!
sleep 0.3
START=$(date +%s)
run P --token "$TOKEN_A" GET /api/ping
ELAPSED=$(( $(date +%s) - START ))
{ [ "$ELAPSED" -le 3 ] && has "con un cliente que no habla, otro sigue atendido" '"name":"NEXO-TOOLS"'; } || bad "un cliente lento bloqueó el servidor" "tardó ${ELAPSED}s"
kill "$SLOWPID" 2>/dev/null; wait "$SLOWPID" 2>/dev/null

echo "== nexo-tools: emparejar con un código (y que el código no se pueda adivinar)"
run dev_b devices;                          has "B empieza sin dispositivos" "Todavía no hay dispositivos"
run dev_b discover -t 3;                    has "discover ve el anuncio de A" "Telefono-A"
has "…como dispositivo nuevo" "nuevo"
run dev_a pair;                             rc_is "pair da un código" 0
CODE=$(printf '%s' "$OUT" | sed 's/\x1b\[[0-9;]*m//g' | grep -o '[A-Z2-9]\{4\}-[A-Z2-9]\{4\}-[A-Z2-9]\{4\}' | head -1)
[ -n "$CODE" ] && ok "…con formato XXXX-XXXX-XXXX" || bad "formato del código" "$OUT"
case $(stat -c %a "$TA/.local/state/nexo-tools/pair.json" 2>/dev/null || stat -f %Lp "$TA/.local/state/nexo-tools/pair.json") in 600) ok "…guardado con permisos 0600" ;; *) bad "permisos de pair.json" ;; esac
run dev_b connect "127.0.0.1:$PORT_T" --code AAAA-BBBB-CCCC;  rc_is "un código equivocado → falla" 1
has "…y lo dice claro" "Código incorrecto"
run dev_b connect "127.0.0.1:$PORT_T" --code "$CODE";         rc_is "el código bueno empareja" 0
has "…y dice el permiso (solo lectura)" "solo lectura"
run dev_b connect "127.0.0.1:$PORT_T" --code "$CODE";         rc_is "el código se gasta: no sirve dos veces" 1
has "…y explica por qué" "código de emparejamiento activo"
case $(stat -c %a "$TB/.local/state/nexo-tools/known.json" 2>/dev/null || stat -f %Lp "$TB/.local/state/nexo-tools/known.json") in 600) ok "B guarda el token y la huella en un archivo 0600" ;; *) bad "permisos de known.json" ;; esac
run dev_b devices;                          has "devices lista a A" "telefono-a"
run dev_b discover -t 3;                    has "ahora discover lo marca como emparejado" "emparejado (telefono-a)"
run dev_b info telefono-a;                  has "info dice el permiso" "Mi permiso: solo lectura"
run dev_a authorized;                       has "A ve que B está autorizado" "Telefono-B"
# fuerza bruta: 5 fallos invalidan el código aunque el siguiente intento sea el bueno
run dev_a pair;                             CODE2=$(printf '%s' "$OUT" | sed 's/\x1b\[[0-9;]*m//g' | grep -o '[A-Z2-9]\{4\}-[A-Z2-9]\{4\}-[A-Z2-9]\{4\}' | head -1)
for i in 1 2 3 4 5; do dev_b connect "127.0.0.1:$PORT_T" --code "ZZZZ-ZZZZ-ZZZ$i" --name malo >/dev/null 2>&1; done
run dev_b connect "127.0.0.1:$PORT_T" --code "$CODE2" --name malo;  rc_is "tras 5 intentos fallidos el código ya no vale" 1
[ ! -e "$TB/.local/state/nexo-tools/known.json" ] || ! grep -q '"malo"' "$TB/.local/state/nexo-tools/known.json" && ok "…y no se guardó ningún emparejamiento falso" || bad "se emparejó pese a la fuerza bruta"

echo "== nexo-tools: listar y bajar desde otro dispositivo (todas las carpetas, todas las extensiones)"
run dev_b ls telefono-a;                    has "ls de la raíz" "share/"
run dev_b ls telefono-a share/docs --types; has "ls --types muestra las extensiones" "Extensiones en esta carpeta"
has "…incluso las raras" ".xyz123"
has "…y los archivos sin extensión" "(sin extensión)"
has "…y los nombres con ñ" "ünicode-ñ.txt"
run dev_b ls telefono-a share/docs --ext .jpg,.png;  has "ls --ext filtra (mayúsculas incluidas)" "B.JPG"
hasnt "…sin cuelar otras" "a.txt"
run dev_b ls telefono-a share/docs --find 'sp*|*.JPG'; has "ls --find con varios patrones" "sp ace.txt"
run dev_b ls telefono-a share/big;          has "una carpeta de 500 se lista entera" "500 elementos"
run dev_b ls telefono-a .ssh;               rc_is "las carpetas de claves no existen para el otro" 1
D=$TT/dl; mkdir -p "$D"
run dev_b get telefono-a share/docs/a.txt -o "$D";          rc_is "get de un archivo" 0
[ "$(cat "$D/a.txt" 2>/dev/null)" = hello ] && ok "…con su contenido" || bad "contenido de a.txt"
run dev_b get telefono-a share/docs/a.txt -o "$D";          has "repetirlo no lo baja otra vez" "ya estaba"
run dev_b get telefono-a share/docs -o "$D/f" --ext .jpg,.png;  has "get de una carpeta solo con ciertas extensiones" "4 archivo(s)"
[ -f "$D/f/docs/B.JPG" ] && [ ! -e "$D/f/docs/a.txt" ] && ok "…y deja el resto" || bad "filtro de extensiones en get"
run dev_b get telefono-a share/docs -o "$D/all";            has "get de una carpeta completa" "archivo(s)"
miss=""; for f in .hidden a.txt archive.tar.gz data.xyz123 empty.bin noext page.html 'sp ace.txt' 'ünicode-ñ.txt' real.png B.JPG; do [ -e "$D/all/docs/$f" ] || miss="$miss [$f]"; done
[ -z "$miss" ] && ok "…con TODO: ocultos, sin extensión, extensiones raras, ñ y espacios, vacíos" || bad "faltan archivos" "$miss"
[ ! -e "$D/all/docs/evil" ] && ok "…y sin el enlace que escapa de la carpeta" || bad "se bajó el enlace que escapa"
run dev_b get telefono-a share/sub -o "$D/s";               rc_is "get de un archivo de 3 MB" 0
cmp -s "$D/s/sub/deep/file.bin" "$TA/share/sub/deep/file.bin" && ok "…idéntico byte a byte" || bad "el archivo grande no coincide"
mkdir -p "$D/r/sub/deep"; head -c 1000000 "$TA/share/sub/deep/file.bin" > "$D/r/sub/deep/file.bin.nexo-part"
run dev_b get telefono-a share/sub -o "$D/r";               rc_is "reanuda una descarga cortada" 0
cmp -s "$D/r/sub/deep/file.bin" "$TA/share/sub/deep/file.bin" && [ ! -e "$D/r/sub/deep/file.bin.nexo-part" ] && ok "…y el resultado es idéntico" || bad "la reanudación dejó un archivo distinto"
mkdir -p "$D/c/sub/deep"; head -c 1000000 /dev/urandom > "$D/c/sub/deep/file.bin.nexo-part"
run dev_b get telefono-a share/sub -o "$D/c";               rc_is "un parcial dañado se detecta (SHA-256)" 1
[ ! -e "$D/c/sub/deep/file.bin" ] && ok "…y no queda un archivo corrupto con el nombre final" || bad "quedó un archivo corrupto"
echo cambiado > "$D/a.txt"
run dev_b get telefono-a share/docs/a.txt -o "$D";          [ -e "$D/a (1).txt" ] && ok "si ya existe distinto, se guarda como copia «a (1).txt»" || bad "conflicto de nombres"
run dev_b get telefono-a share/docs/a.txt -o "$D" --skip;   has "--skip lo omite" "omitido"
run dev_b get telefono-a share/docs/a.txt -o "$D" --overwrite; [ "$(cat "$D/a.txt")" = hello ] && ok "--overwrite lo reemplaza" || bad "--overwrite"
run dev_b get telefono-a nada/no.txt -o "$D";               rc_is "una ruta que no existe → error" 1
run dev_b get telefono-a ../x -o "$D";                      rc_is "una ruta con .. se rechaza" 2
run dev_b get telefono-a --all -o "$D/everything";          has "get --all baja todo lo compartido" "archivo(s)"
[ -e "$D/everything/share/sub/deep/file.bin" ] && [ ! -e "$D/everything/.ssh" ] && ok "…sin claves" || bad "get --all"
run dev_b put telefono-a "$TT/up.txt" --to share;           rc_is "put sin permiso de escritura falla" 1
has "…y explica cómo pedirlo" "pair --rw"
run dev_b mkdir telefono-a share/nuevo;                     rc_is "mkdir sin permiso falla" 1

echo "== nexo-tools: explorador de terminal (browse)"
run bash -c "printf 'types\n\nq\n' | env -i PATH=\"$PATH\" HOME=\"$TB\" NEXO_TOOLS_DISCOVER_PORT=$DISC bash \"$NT\" browse telefono-a --dest \"$D/br\""
has "browse conecta y dice el permiso" "permiso: solo lectura"
has "…lista la carpeta compartida" "share"

echo "== nexo-tools: huella cambiada = otro dispositivo (certificado nuevo)"
run dev_a rotate-cert;                      rc_is "rotate-cert renueva el certificado" 0
has "…y avisa de que hay que emparejar de nuevo" "emparejarse de nuevo"
run dev_b ls telefono-a;                    rc_is "B rechaza la huella nueva (podría ser un impostor)" 4
has "…y lo explica" "NO coincide"
run dev_b info telefono-a;                  rc_is "tampoco manda su token a quien no reconoce" 4

echo "== nexo-tools: escritura (server --rw) con papelera, y revocar el acceso"
run dev_a stop;                             rc_is "stop" 0
run dev_a server "$TA" "$PORT_T" --rw;      rc_is "server --rw arranca" 0
has "…avisa de que escribe" "lectura y escritura"
TOKEN_A=$(cat "$TA/.local/state/nexo-tools/token")
http_is "el token que se ve en pantalla NO escribe ni en modo --rw" 403 --token "$TOKEN_A" POST /api/mkdir --json '{"path":"share/nuevo"}'
run dev_a pair --rw;                        CODE=$(printf '%s' "$OUT" | sed 's/\x1b\[[0-9;]*m//g' | grep -o '[A-Z2-9]\{4\}-[A-Z2-9]\{4\}-[A-Z2-9]\{4\}' | head -1)
run dev_b connect "127.0.0.1:$PORT_T" --code "$CODE" --name telefono-a;  has "B se empareja con permiso de escritura" "lectura y escritura"
TOKEN_B=$(python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))['telefono-a']['token'])" "$TB/.local/state/nexo-tools/known.json")
run dev_b put telefono-a "$TT/up.txt" --to share/docs;      rc_is "put sube un archivo" 0
[ "$(cat "$TA/share/docs/up.txt" 2>/dev/null)" = up ] && ok "…y llegó íntegro" || bad "el archivo subido no llegó"
run dev_b put telefono-a "$TT/up.txt" --to share/docs;      has "subir lo mismo otra vez no lo pisa" "ya existe"
echo cambio > "$TT/up.txt"
run dev_b put telefono-a "$TT/up.txt" --to share/docs --overwrite;  [ "$(cat "$TA/share/docs/up.txt")" = cambio ] && ok "--overwrite sí lo reemplaza" || bad "--overwrite en put"
mkdir -p "$TT/updir/sub"; echo 1 > "$TT/updir/uno.txt"; echo 2 > "$TT/updir/sub/dos.bin"
run dev_b put telefono-a "$TT/updir" --to share;            rc_is "put sube una carpeta entera" 0
[ "$(cat "$TA/share/updir/sub/dos.bin" 2>/dev/null)" = 2 ] && ok "…con su estructura" || bad "estructura de la carpeta subida"
run dev_b mkdir telefono-a share/nuevo/dentro;              rc_is "mkdir sin padre → falla (no crea cadenas raras)" 1
run dev_b mkdir telefono-a share/nuevo;                     rc_is "mkdir crea una carpeta" 0
run dev_b mv telefono-a share/nuevo share/renombrada;       rc_is "mv renombra" 0
[ -d "$TA/share/renombrada" ] && [ ! -e "$TA/share/nuevo" ] && ok "…de verdad" || bad "mv no movió"
run dev_b mv telefono-a share/renombrada share/docs;        rc_is "mv no pisa algo que ya existe" 1
run dev_b rm telefono-a share/docs/a.txt --yes;             rc_is "rm" 0
[ ! -e "$TA/share/docs/a.txt" ] && [ -n "$(find "$TA/.nexo-trash" -name a.txt 2>/dev/null)" ] && ok "…no borra: lo manda a .nexo-trash dentro de la carpeta compartida" || bad "rm no usó la papelera"
run dev_b ls telefono-a;                    has "…y la papelera se ve en el listado (se puede recuperar bajando el archivo)" ".nexo-trash/"
http_is "…pero la papelera solo se vacía desde el propio dispositivo" 400 --token "$TOKEN_B" POST /api/delete --json '{"path":".nexo-trash"}'
http_is "subir con «..» → rechazado" 400 --token "$TOKEN_B" PUT "/api/upload?path=../evil.txt" --file "$TT/up.txt"
http_in "subir a la carpeta de claves → rechazado (no existe para el otro)" "400 404" --token "$TOKEN_B" PUT "/api/upload?path=.ssh/x" --file "$TT/up.txt"
http_in "pisar el estado de nexo-tools → rechazado" "400 404" --token "$TOKEN_B" PUT "/api/upload?path=.local/state/nexo-tools/peers.json&overwrite=1" --file "$TT/up.txt"
http_not "subir a través de un enlace simbólico → rechazado" 200 --token "$TOKEN_B" PUT "/api/upload?path=share/docs/evil/x.txt" --file "$TT/up.txt"
http_is "una suma SHA-256 que no cuadra → rechazado" 422 --token "$TOKEN_B" PUT "/api/upload?path=share/docs/mal.txt" --file "$TT/up.txt" --header "X-Nexo-SHA256: $(printf '0%.0s' $(seq 64))"
[ ! -e "$TA/share/docs/mal.txt" ] && ok "…y no deja el archivo a medias" || bad "quedó un archivo con SHA incorrecto"
http_not "borrar la raíz compartida → rechazado" 200 --token "$TOKEN_B" POST /api/delete --json '{"path":""}'
run dev_a authorized;                       has "authorized lista a B con escritura" "lectura/escr."
run dev_a revoke telefono-b;                rc_is "revoke quita el acceso" 0
run dev_b ls telefono-a;                    rc_is "…y B queda fuera al instante" 1
has "…con un mensaje que dice qué hacer" "401"
run dev_a web;                              rc_is "web da una dirección para el navegador" 0
URLW=$(printf '%s' "$OUT" | sed 's/\x1b\[[0-9;]*m//g' | grep -o 'https://[^ ]*/ui#t=[0-9a-f]*' | head -1)
case $URLW in https://127.0.0.1:*/ui#t=*) ok "…con el acceso en el fragmento (#t=…, que no viaja por la red)" ;; *) bad "dirección web" "$OUT" ;; esac
TOKEN_W=${URLW##*#t=}
http_is "el token del navegador (solo lectura) entra" 200 --token "$TOKEN_W" GET /api/ping
http_is "…pero no escribe" 403 --token "$TOKEN_W" POST /api/mkdir --json '{"path":"share/web-no"}'
run dev_a web --rw;                         TOKEN_W=$(printf '%s' "$OUT" | sed 's/\x1b\[[0-9;]*m//g' | grep -o '#t=[0-9a-f]*' | head -1); TOKEN_W=${TOKEN_W#\#t=}
http_is "web --rw da un token que sí escribe" 200 --token "$TOKEN_W" POST /api/mkdir --json '{"path":"share/web-si"}'
[ -d "$TA/share/web-si" ] && ok "…y la carpeta existe" || bad "la carpeta del navegador no se creó"
run dev_a stop;                             rc_is "stop cierra el servidor" 0
[ ! -e "$TA/.local/state/nexo-tools/pair.json" ] && ok "…y borra el código de emparejamiento pendiente" || bad "pair.json sigue ahí"

echo "== nexo-tools: send / fetch (enviar solo lo elegido, con un código)"
rm -rf "$TT/recv"
( cd "$TA/share" && exec env -i PATH="$PATH" HOME="$TA" NEXO_TOOLS_IP=127.0.0.1 NEXO_TOOLS_DISCOVER_PORT=$DISC NEXO_TOOLS_BEACON_TO=127.0.0.1 NEXO_TOOLS_DEVICE=Telefono-A bash "$NT" send docs/noext sub --port "$PORT_T" > "$TT/send.out" 2>&1 ) &
SEND_PID=$!
echo "$SEND_PID" > "$TT/send.pid"
waitfor "$TT/send.out" "fetch" 25 && ok "send arranca, da un código y la orden para el otro" || bad "send no llegó a mostrar la orden" "$(cat "$TT/send.out")"
FETCH=$(sed 's/\x1b\[[0-9;]*m//g' "$TT/send.out" | grep -o 'nexo-tools fetch [0-9.]*:[0-9]* [A-Z2-9-]*' | head -1)
[ -n "$FETCH" ] && ok "…con IP, puerto y código" || bad "orden fetch" "$(cat "$TT/send.out")"
set -- $FETCH
run dev_b fetch "$3" "$4" -o "$TT/recv";    rc_is "fetch en el otro dispositivo baja lo enviado" 0
[ -e "$TT/recv/sub/deep/file.bin" ] && [ -e "$TT/recv/docs/noext" ] && ok "…la carpeta y el archivo elegidos" || bad "fetch no bajó lo elegido"
[ ! -e "$TT/recv/docs/pic.png" ] && [ ! -e "$TT/recv/docs/B.JPG" ] && ok "…y NADA más (modo selección)" || bad "fetch bajó archivos no elegidos"
run dev_b devices;                          has "fetch no deja emparejado al receptor (se olvida solo)" "Todavía no hay dispositivos"
TOKEN_A=$(cat "$TA/.local/state/nexo-tools/token")
http_is "fuera de la selección, ni con el token del servidor (404)" 404 --token "$TOKEN_A" GET "/api/download?path=docs/pic.png"
http_is "dentro de la selección sí" 200 --token "$TOKEN_A" GET "/api/download?path=sub/deep/file.bin"
waitfor "$TA/.local/state/nexo-tools/server.log" "descarga" 5 && ok "el servidor registra las descargas (send las muestra en vivo)" || bad "no se registró la descarga"
kill -TERM "$SEND_PID" 2>/dev/null
for i in $(seq 40); do kill -0 "$SEND_PID" 2>/dev/null || break; sleep 0.1; done
kill -0 "$SEND_PID" 2>/dev/null && { bad "send no terminó con SIGTERM"; kill -KILL "$SEND_PID" 2>/dev/null; } || ok "SIGTERM termina send"
sleep 0.5
run dev_a status;                           has "…y cierra el servidor" "No hay"
[ ! -e "$TA/.local/state/nexo-tools/send.list" ] && [ ! -e "$TA/.local/state/nexo-tools/pair.json" ] && ok "…y limpia la selección y el código" || bad "send dejó restos"
run dev_a send "$TA/nada-de-esto";          rc_is "send de algo que no existe → error" 1
run dev_a send;                             rc_is "send sin nada → uso" 2

echo "== nexo-tools: lo de siempre sigue igual, y adivinar tokens se frena"
run dev_a server "$TA/share/docs" "$PORT_T"; rc_is "server con la sintaxis de siempre (CARPETA PUERTO)" 0
TOKEN_A=$(cat "$TA/.local/state/nexo-tools/token")
http_is "el token de siempre sigue sirviendo (solo lectura)" 200 --token "$TOKEN_A" GET "/api/list?path="
for i in $(seq 14); do P --token "mal$i" GET /api/ping >/dev/null 2>&1; done
http_is "demasiados tokens malos seguidos → 429" 429 --token malx GET /api/ping
http_is "…pero quien trae el token bueno sigue entrando" 200 --token "$TOKEN_A" GET /api/ping
run dev_a stop;                             rc_is "stop" 0
