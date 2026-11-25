# shellcheck shell=bash
# Pruebas de los DISCOS USB de nexo-usb 0.4.2: mounts, access, ls, stat, cat, get, put, mkdir, rm, mv, df y eject.
# No se ejecuta solo: lo carga tests/run_tests.sh (usa sus ok/bad/run/has/…). Necesita: bash, python3, jq.
#   NEXO_TESTS_ONLY=storage bash tests/run_tests.sh      ← solo estas (más rápido para trabajar en ellas)
#
# QUÉ SON ESTAS PRUEBAS Y QUÉ NO: hablan con la app FALSA (tests/fake_app.py), cuyos «discos» son carpetas reales y que aplica las
# mismas reglas, en el mismo orden y con los mismos errores que StorageOps (la lógica de la app real, que además tiene sus pruebas
# JVM en android/app/src/test/java/org/nexo/bridge/StorageLogicTest.kt). Aquí se prueba el cliente (nexo-usb) y el protocolo; tras
# cada operación se mira, SIN pasar por el protocolo, lo que quedó de verdad en la carpeta del «disco».
# NO prueban: el selector de carpetas de Android (Storage Access Framework), vold, un pendrive o un disco duro de verdad, sus
# sistemas de archivos (FAT32, exFAT, NTFS), la expulsión real ni la velocidad en un móvil. Eso solo se comprueba en el móvil
# (docs/USB-ALMACENAMIENTO.md, «Probarlo en tu móvil», y tests/usb_storage_hardware_check.sh).

echo "== nexo usb (discos): sintaxis, ayuda y errores de uso"
SD=$T/stor
mkdir -p "$SD/home" "$SD/state" "$SD/tmp" "$SD/discos" "$SD/loc" "$SD/work"
NU=$T/bin/nexo-usb
: > "$SD/ctl"
SP=$(start_app stor --ctl "$SD/ctl" --storage-dir "$SD/discos" --reqlog "$SD/req.log")
SE() { env -i PATH="$PATH" HOME="$SD/home" TMPDIR="$SD/tmp" NEXO_USB_DIR="$SD/state" NEXO_PORT="$SP" NEXO_TOKEN="$TOKEN" "$@"; }
sn() { SE python3 "$NU" "$@"; }
sctl() { printf '%s\n' "$*" >> "$SD/ctl"; sleep 0.4; }          # una orden para la app falsa (ella la lee cada 0,1 s)
V1=1111-2222; D1=$SD/discos/$V1                                  # «MI DISCO»
nreq() { grep -c "\"cmd\":\"$1\"" "$SD/req.log" 2>/dev/null || true; }
openfiles() { sn mounts --json 2>/dev/null | jq -r '.open_files'; }
parts() { find "$SD/discos" -name '.nexo-part-*' 2>/dev/null | wc -l | tr -d ' '; }      # restos de copias a medias (en todos los discos)
cmpf() { if cmp -s "$2" "$3"; then ok "$1"; else bad "$1" "no son iguales: $2 y $3"; fi; }
tree_sig() { (cd "$1" && { find . -mindepth 1 -type d | sort; find . -type f -exec sha1sum {} + | sort -k2; }); }
norm() { sed -E 's/ en [0-9]+\.[0-9] s( \([^)]*\))?//; s/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}/FECHA/g; s/"seconds": [0-9.e-]+/"seconds": N/'; }

printf 'hola mundo\n' > "$SD/loc/a.txt"
: > "$SD/loc/vacio.txt"
printf 'ñandú y canción\n' > "$SD/loc/Música ñ.txt"
head -c 5000000 /dev/urandom > "$SD/loc/grande.bin"
mkdir -p "$SD/loc/arbol/sub/hondo" "$SD/loc/arbol/vacia"
printf 'uno\n' > "$SD/loc/arbol/uno.txt"; printf 'dos\n' > "$SD/loc/arbol/sub/dos.txt"; printf 'tres\n' > "$SD/loc/arbol/sub/hondo/tres.txt"
ln -s uno.txt "$SD/loc/arbol/enlace"

if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)'; then
    if python3 -B - "$ROOT/termux/bin/nexo-usb" 2>"$T/err" <<'EOF'
import ast, sys
ast.parse(open(sys.argv[1], encoding="utf-8").read(), feature_version=(3, 7))
EOF
    then ok "nexo-usb (con los discos) sigue usando solo sintaxis de Python 3.7"; else bad "sintaxis de Python 3.7 en nexo-usb" "$(cat "$T/err")"; fi
fi
run sn help;                                  rc_is "help sale con 0" 0
has "la ayuda explica mounts" "mounts [--all] [--json] [--wait S]"
has "…get y put" "get [-rfn] ORIGEN… DESTINO"
has "…eject" "eject [DISCO]"
has "…los archivos a medias (.nexo-part-)" ".nexo-part-"
has "…y que una RUTA es de la raíz del disco" "una RUTA es de la raíz del disco"
run sn get;                                   rc_is "get sin nada → 2" 2
has "…y dice qué falta" "necesita ORIGEN"
run sn put a;                                 rc_is "put con un solo argumento → 2" 2
run sn cat;                                   rc_is "cat sin rutas → 2" 2
run sn stat;                                  rc_is "stat sin ruta → 2" 2
run sn mkdir;                                 rc_is "mkdir sin ruta → 2" 2
run sn rm;                                    rc_is "rm sin ruta → 2" 2
run sn mv a;                                  rc_is "mv con un solo argumento → 2" 2
run sn mounts sobra;                          rc_is "mounts con un argumento → 2" 2
run sn ls --via magia;                        rc_is "--via con un valor raro → 2" 2
has "…y dice cuál" "--via"
run sn ls --nada;                             rc_is "una opción que no existe → 2" 2
run sn ls -lz;                                rc_is "«-lz»: -l vale y -z no → 2" 2
has "…y señala la que falla" "-z"

echo "== nexo usb (discos): sin app, sin token, app más vieja"
run env -i PATH="$PATH" HOME="$SD/home" TMPDIR="$SD/tmp" NEXO_PORT=1 NEXO_TOKEN="$TOKEN" python3 "$NU" mounts
rc_is "mounts con la app apagada → 10" 10
has "…y le dice que mire nexo doctor" "nexo doctor"
run env -i PATH="$PATH" HOME="$SD/home" TMPDIR="$SD/tmp" python3 "$NU" ls
rc_is "ls sin token → 11" 11
has "…y le dice cómo enlazar" "nexo pair"
OLD3=$(start_app stor3 --minor3)
run env -i PATH="$PATH" HOME="$SD/home" TMPDIR="$SD/tmp" NEXO_PORT="$OLD3" NEXO_TOKEN="$TOKEN" python3 "$NU" mounts
rc_is "con la app 0.4.1 (sin discos), mounts → 1" 1
has "…dice que esa app no sabe de discos" "no sabe de discos USB"
has "…y que instales el APK de la 0.4.2" "0.4.2"
run env -i PATH="$PATH" HOME="$SD/home" TMPDIR="$SD/tmp" NEXO_PORT="$OLD3" NEXO_TOKEN="$TOKEN" python3 "$NU" ls
rc_is "…ls también → 1" 1
run env -i PATH="$PATH" HOME="$SD/home" TMPDIR="$SD/tmp" NEXO_PORT="$OLD3" NEXO_TOKEN="$TOKEN" python3 "$NU" list
rc_is "…y list (el USB serie de la 0.4.1) sigue funcionando con esa app → 0" 0
OLD2=$(start_app stor2 --minor2)
run env -i PATH="$PATH" HOME="$SD/home" TMPDIR="$SD/tmp" NEXO_PORT="$OLD2" NEXO_TOKEN="$TOKEN" python3 "$NU" mounts
rc_is "con la app 0.4.0 (sin USB), mounts → 1" 1
has "…lo mismo" "no sabe de discos USB"

echo "== nexo usb mounts / access: ver los discos y pedir entrar"
run sn mounts;                                rc_is "mounts sin ningún disco sale con 0" 0
has "…y explica cómo enchufar" "No hay ningún disco USB"
run sn mounts --wait 1;                       rc_is "mounts --wait 1 sin disco → 4 (no apareció)" 4
has "…y espera de verdad" "Esperando a que enchufes un disco"
run sn mounts --json;                         jqok "mounts --json: available y lista de volúmenes vacía" '.available == true and (.volumes | length) == 0'
sctl storage add "MI_DISCO" $V1 noaccess
run sn mounts;                                rc_is "con un disco montado, mounts sale con 0" 0
has "…lo enseña por su nombre (la «_» de la prueba es un espacio)" "MI DISCO"
has "…con su UUID" "$V1"
has "…montado" "montado"
has "…y la ruta que da Android" "/storage/$V1"
has "…dice que Nexo aún no puede entrar" "NEXO PUEDE ENTRAR"
has "…y cuál es el siguiente paso" "nexo usb access"
run sn mounts --json;                         jqok "mounts --json: el disco, sin acceso" '.volumes[0].uuid == "1111-2222" and .volumes[0].granted == false and .volumes[0].mounted == true'
jqok "…con su espacio" '.volumes[0].total == 8589934592 and .volumes[0].free == 8589934592'
sctl storage auto ignore
run sn access --timeout 2;                    rc_is "access sin que nadie toque el móvil → 3 (a los 2 s)" 3
has "…dice que nadie eligió el disco" "Nadie eligió el disco"
has "…avisó de lo que hay que hacer en el móvil" "mira la pantalla del móvil"
sctl storage auto deny
run sn access --timeout 5;                    rc_is "access y el usuario dice que no → 3" 3
has "…lo cuenta" "no le dio acceso"
sctl storage auto grant 700
run sn access --timeout 20;                   rc_is "access y el usuario acepta (tras 0,7 s) → 0" 0
has "…lo cuenta" "Nexo ya puede entrar en «MI DISCO»"
run sn access;                                rc_is "access cuando ya lo tiene → 0" 0
has "…lo dice" "ya tiene acceso a «MI DISCO» (el disco entero)"
run sn access --json;                         jqok "access --json cuando ya lo tiene" '.granted == true and .requested == false and .scope == ""'
run sn mounts;                                has "mounts ya dice que sí puede entrar" "Listo para: nexo usb ls"
run sn access --revoke;                       rc_is "access --revoke → 0" 0
has "…y lo cuenta" "ya no tiene acceso a «MI DISCO»"
run sn ls --no-ask;                           rc_is "ls --no-ask sin acceso → 3 (no abre el selector)" 3
has "…y dice cómo pedirlo" "nexo usb access"
sctl storage auto grant
run sn ls;                                    rc_is "ls sin acceso pide el acceso solo y entra → 0" 0
run sn mounts --json;                         jqok "…y quedó con acceso" '.volumes[0].granted == true'

echo "== nexo usb: elegir entre varios discos (nombre, UUID, principio, interno)"
V2=7777-8888
sctl storage add "OTRO_DISCO" $V2
sctl storage add "INTERNO" primary
run sn mounts;                                hasnt "mounts no enseña el almacenamiento interno" "INTERNO"
run sn mounts --all;                          has "mounts --all sí lo enseña (como interno)" "INTERNO (interno)"
run sn ls;                                    rc_is "con dos discos y sin decir cuál, ls → 2" 2
has "…lista cuáles hay" "«OTRO DISCO»"
run sn ls --vol "otro";                       rc_is "--vol con parte del nombre (sin mayúsculas) → 0" 0
run sn ls --vol 7777;                         rc_is "--vol con el principio del UUID → 0" 0
run sn ls "OTRO DISCO:/";                     rc_is "NOMBRE:/ruta → 0" 0
run sn ls 7777-8888:/;                        rc_is "UUID:/ruta → 0" 0
run sn ls --vol DISCO;                        rc_is "--vol con algo que encaja con dos discos → 2" 2
has "…lo dice" "Varios discos encajan con «DISCO»"
run sn ls --vol zzz;                          rc_is "--vol con algo que no existe → 4" 4
has "…lo dice" "No hay ningún disco llamado «zzz»"
run sn ls "MI DISCO:/" --vol "OTRO DISCO";    rc_is "dos discos distintos en una orden → 2" 2
has "…lo dice" "Mezclas discos distintos"
run sn ls --vol INTERNO --via app --no-ask;   rc_is "el interno se puede pedir por su nombre (aquí con acceso concedido) → 0" 0
sctl storage remove $V2
run sn df;                                    rc_is "df con un solo disco → 0" 0
has "…lo enseña" "MI DISCO"
has "…con sus columnas" "TOTAL"
has "…y el espacio" "8.0 GiB"
run sn df --json;                             jqok "df --json: la lista de discos" 'length == 1 and .[0].uuid == "1111-2222"'
run sn df INTERNO;                            rc_is "df de un disco concreto (el interno) → 0" 0
has "…lo enseña" "INTERNO"

echo "== nexo usb: crear carpetas y subir archivos (put) con --via app"
VIA="--via app --vol $V1"
run sn mkdir -p /Música/rock $VIA;            rc_is "mkdir -p crea la ruta entera → 0" 0
[ -d "$D1/Música/rock" ] && ok "…y en la carpeta del disco está" || bad "mkdir -p no creó la carpeta en el disco"
run sn mkdir /Música $VIA;                    rc_is "mkdir de una que ya existe → 1" 1
has "…dice que ya existe" "Ya existe"
run sn mkdir -p /Música $VIA;                 rc_is "mkdir -p de una que ya existe → 0" 0
run sn mkdir /nada/hondo $VIA;                rc_is "mkdir sin la de arriba → 1" 1
has "…dice que no existe" "No existe"
run sn mkdir '/a:b' $VIA;                     rc_is "mkdir con «:» → 1 (Android lo cambiaría por «_» sin avisar)" 1
has "…y lo explica" "no admiten el carácter «:»"
[ ! -e "$D1/a_b" ] && [ ! -e "$D1/a:b" ] && ok "…y no creó nada" || bad "mkdir con «:» creó algo"
run sn mkdir -p '/ok/x?y' $VIA;               rc_is "mkdir -p con una «?» en el último nivel → 1" 1
[ ! -e "$D1/ok" ] && ok "…y no dejó creada la carpeta de arriba" || bad "mkdir -p dejó /ok a medias"
run sn mkdir 'fin.' $VIA;                     rc_is "mkdir de un nombre que acaba en punto → 1" 1
run sn put "$SD/loc/a.txt" /Música/ $VIA;     rc_is "put de un archivo a una carpeta → 0" 0
has "…y lo cuenta" "→ MI DISCO:/Música/a.txt"
cmpf "…y en el disco está igual" "$SD/loc/a.txt" "$D1/Música/a.txt"
run sn put "$SD/loc/a.txt" /Música/a.txt $VIA;   rc_is "put encima de uno que ya existe → 1" 1
has "…dice que ya existe y cómo seguir" "usa -f para sustituirlo"
run sn put -n "$SD/loc/a.txt" /Música/a.txt $VIA;   rc_is "put -n lo salta → 0" 0
has "…y lo dice" "omitido (ya existe)"
printf 'distinto\n' > "$SD/loc/b.txt"
run sn put -f "$SD/loc/b.txt" /Música/a.txt $VIA;   rc_is "put -f lo sustituye → 0" 0
cmpf "…y el disco tiene lo nuevo" "$SD/loc/b.txt" "$D1/Música/a.txt"
[ "$(parts)" = 0 ] && ok "…sin dejar archivos .nexo-part" || bad "put dejó restos" "$(find "$SD/discos" -name '.nexo-part-*')"
run sn put "$SD/loc/vacio.txt" /vacio.txt $VIA;     rc_is "put de un archivo vacío → 0" 0
[ -f "$D1/vacio.txt" ] && [ ! -s "$D1/vacio.txt" ] && ok "…y queda vacío" || bad "el archivo vacío no quedó vacío"
run sn put "$SD/loc/Música ñ.txt" /Música/ $VIA;    rc_is "put de un nombre con acentos y espacios → 0" 0
cmpf "…y queda igual" "$SD/loc/Música ñ.txt" "$D1/Música/Música ñ.txt"
printf 'felicidades\n' > "$SD/loc/Cumpleaños 🎂 año.txt"
run sn mkdir /Emoji $VIA;                     rc_is "mkdir de una carpeta para probar nombres con emoji → 0" 0
run sn put "$SD/loc/Cumpleaños 🎂 año.txt" /Emoji/ $VIA;   rc_is "put de un nombre con emoji → 0" 0
cmpf "…y queda igual, con ese nombre" "$SD/loc/Cumpleaños 🎂 año.txt" "$D1/Emoji/Cumpleaños 🎂 año.txt"
run sn ls /Emoji $VIA;                        eq "…ls lo enseña con su nombre" "Cumpleaños 🎂 año.txt"
rm -rf "$SD/emoji_out"; mkdir -p "$SD/emoji_out"
run sn get "/Emoji/Cumpleaños 🎂 año.txt" "$SD/emoji_out" $VIA;   rc_is "get de un nombre con emoji → 0" 0
cmpf "…y baja igual" "$SD/loc/Cumpleaños 🎂 año.txt" "$SD/emoji_out/Cumpleaños 🎂 año.txt"
run sn rm -r /Emoji $VIA;                     rc_is "rm -r de la carpeta de los emoji → 0" 0
rm -rf "$SD/emoji_out" "$SD/loc/Cumpleaños 🎂 año.txt"
run sn put "$SD/loc/a.txt" "$SD/loc/vacio.txt" /nada/ $VIA;   rc_is "put de varios a una carpeta que no existe → 2" 2
has "…lo dice" "tiene que ser una carpeta que ya exista"
run sn put "$SD/loc/a.txt" "$SD/loc/vacio.txt" /Música/rock/ $VIA;   rc_is "put de varios a una carpeta → 0" 0
[ -f "$D1/Música/rock/a.txt" ] && [ -f "$D1/Música/rock/vacio.txt" ] && ok "…y están los dos" || bad "faltan archivos tras put de varios"
run sn put "$SD/loc/arbol" /X $VIA;           rc_is "put de una carpeta sin -r → 1" 1
has "…dice que hace falta -r" "usa -r"
run sn put -r "$SD/loc/arbol" /Copia $VIA;    rc_is "put -r de una carpeta que no existe en el disco → 0" 0
has "…se salta el enlace simbólico (un disco FAT no los tiene)" "omitido (enlace simbólico)"
has "…y resume" "put: 3 archivos"
[ "$(cat "$D1/Copia/sub/hondo/tres.txt")" = tres ] && [ -d "$D1/Copia/vacia" ] && [ ! -e "$D1/Copia/enlace" ] && ok "…y la carpeta quedó entera (con la vacía y sin el enlace)" || bad "put -r dejó mal la carpeta"
run sn put -r "$SD/loc/arbol" /Música $VIA;   rc_is "put -r a una carpeta que existe la mete dentro → 0" 0
[ -f "$D1/Música/arbol/uno.txt" ] && ok "…en /Música/arbol" || bad "put -r no metió la carpeta dentro"
run sn put -r "$SD/loc/arbol" /Copia $VIA;    rc_is "put -r a una carpeta que ya existe (y que ahora ya tiene «arbol» dentro) la mete otra vez dentro → 0" 0
run sn put -r "$SD/loc/arbol/" /Copia $VIA;   rc_is "put -r de «carpeta/» copia lo de dentro a /Copia (mezcla; los 3 archivos que ya están son fallos) → 1" 1
has "…dice cuántos" "3 con fallos"
run sn put -rn "$SD/loc/arbol/" /Copia $VIA;  rc_is "…con -n se salta lo que ya está → 0" 0
run sn put -r "$SD/loc/arbol/" /Nueva2 $VIA;  rc_is "put -r de «carpeta/» a una que no existe la crea con lo de dentro → 0" 0
[ -f "$D1/Nueva2/sub/hondo/tres.txt" ] && [ ! -e "$D1/Nueva2/arbol" ] && ok "…y no metió la carpeta «arbol» dentro" || bad "put -r carpeta/ metió la carpeta dentro"
rm -rf "$D1/Nueva2" "$D1/Copia/arbol"
printf 'a:b' > "$SD/loc/a:b.txt"
run sn put "$SD/loc/a:b.txt" / $VIA;          rc_is "put de un archivo cuyo nombre lleva «:» → 1" 1
has "…lo explica" "no admiten el carácter «:»"
run sn put --fix-names "$SD/loc/a:b.txt" / $VIA;    rc_is "put --fix-names lo cambia por «_» → 0" 0
[ -f "$D1/a_b.txt" ] && ok "…y el archivo se llama a_b.txt" || bad "--fix-names no dejó a_b.txt"
run sn put "$SD/loc/nada.txt" / $VIA;         rc_is "put de un archivo local que no existe → 1" 1
has "…lo dice" "No such file or directory"
run sn put "$SD/loc/a.txt" /Música/a.txt/x.txt $VIA;   rc_is "put debajo de un archivo → 1" 1
run sn put "$SD/loc/a.txt" /Música $VIA;      rc_is "put a una carpeta sin la barra final (la usa de carpeta) → 0 o ya existe" 1
has "…y como dentro ya está a.txt, lo dice" "Ya existe"
run sn put --verify "$SD/loc/grande.bin" /grande.bin $VIA;   rc_is "put --verify de 5 MB → 0" 0
cmpf "…y en el disco está igual" "$SD/loc/grande.bin" "$D1/grande.bin"
[ "$(openfiles)" = 0 ] && ok "…sin archivos abiertos en la app" || bad "quedaron archivos abiertos" "$(openfiles)"
run sn put -q "$SD/loc/a.txt" /callado.txt $VIA;     eq "put -q no dice nada" ""
run sn put --json "$SD/loc/a.txt" /json.txt $VIA;    jqok "put --json: resumen" '.ok == true and .files == 1 and .bytes == 11 and (.items[0].dst | endswith("/json.txt"))'
[ "$(nreq storage.write)" -gt 0 ] && ok "las escrituras fueron storage.write" || bad "no hubo storage.write"
python3 -B - "$SD/req.log" <<'EOF' && ok "ninguna escritura pasó de 32 KiB (lo que admite la app real)" || bad "alguna escritura pasó de 32 KiB"
import base64, json, sys
big = 0
for line in open(sys.argv[1], encoding="utf-8"):
    r = json.loads(line)
    if r.get("cmd") == "storage.write" and len(base64.b64decode(r["data"])) > 32768:
        big += 1
sys.exit(1 if big else 0)
EOF

echo "== nexo usb: ver (ls, stat, cat) con --via app"
run sn ls $VIA;                               rc_is "ls de la raíz → 0" 0
has "…con las carpetas con «/»" "Música/"
has "…y los archivos" "grande.bin"
run sn ls $VIA;                               eq "…primero las carpetas, luego los archivos, por nombre" "$(printf 'Copia/\nMúsica/\na_b.txt\ncallado.txt\ngrande.bin\njson.txt\nvacio.txt')"
printf 'x' > "$D1/.oculto"
run sn ls $VIA;                               hasnt "ls no enseña los archivos ocultos" ".oculto"
run sn ls -a $VIA;                            has "ls -a sí" ".oculto"
run sn ls -l /Música $VIA;                    has "ls -l enseña un detalle (carpeta, escribible)" "dw"
has "…con el tamaño en bytes" "11"
run sn ls -lh /Música/rock $VIA;              has "ls -lh con tamaños legibles" "B"
run sn ls -R /Copia $VIA;                     has "ls -R baja por las carpetas" "/Copia/sub/hondo:"
has "…y enseña lo de dentro" "tres.txt"
run sn ls /Música/a.txt $VIA;                 eq "ls de un archivo enseña el archivo" "/Música/a.txt"
run sn ls /nada $VIA;                         rc_is "ls de algo que no existe → 1" 1
has "…lo dice" "No existe: /nada"
run sn ls /Música /Copia $VIA;                has "ls de varias rutas pone el nombre de cada una" "/Copia:"
run sn ls --json /Música $VIA;                jqok "ls --json: volumen, ruta y entradas" '.volume == "1111-2222" and .listings[0].path == "/Música" and (.listings[0].entries | map(.name) | index("a.txt")) != null'
run sn stat /Música/a.txt $VIA;               rc_is "stat de un archivo → 0" 0
has "…el tipo" "archivo"
has "…el tamaño" "9 bytes"
has "…el tipo MIME" "text/plain"
run sn stat /Música --json $VIA;              jqok "stat --json de una carpeta" '.type == "dir" and .path == "/Música" and .volume == "1111-2222"'
run sn stat /nada $VIA;                       rc_is "stat de algo que no existe → 1" 1
run sn cat /Música/a.txt $VIA;                eq "cat enseña el contenido" "distinto"
run sn cat /Música/a.txt "/Música/Música ñ.txt" $VIA;  eq "cat de dos archivos los junta" "$(printf 'distinto\nñandú y canción')"
run sn cat /Música $VIA;                      rc_is "cat de una carpeta → 1" 1
has "…lo dice" "Es una carpeta"
SE python3 "$NU" cat /grande.bin $VIA > "$SD/cat.bin" 2>/dev/null
cmpf "cat de 5 MB sale byte a byte igual" "$SD/loc/grande.bin" "$SD/cat.bin"
SE python3 "$NU" cat /grande.bin $VIA 2>/dev/null | head -c 10 > /dev/null; rc=${PIPESTATUS[0]}
[ "$rc" = 141 ] && ok "cat | head se corta sin ruido y sale como cat (141)" || bad "cat | head sale con $rc (se esperaba 141)"
[ "$(openfiles)" = 0 ] && ok "…y no deja archivos abiertos" || bad "cat | head dejó archivos abiertos" "$(openfiles)"

# una carpeta con muchos archivos: el cliente pide las páginas de 2000 en 2000 y no pierde ni repite ninguno
mkdir -p "$D1/Muchos"; (cd "$D1/Muchos" && for i in $(seq 1 4500); do : > "f$i.txt"; done)
python3 -c "print('\n'.join(sorted(('f%d.txt' % i for i in range(1, 4501)), key=lambda n: (n.lower(), n))))" > "$SD/muchos.esperado"
N0=$(nreq storage.list)
run sn ls /Muchos $VIA;                       rc_is "ls de una carpeta con 4500 archivos → 0" 0
printf '%s\n' "$OUT" > "$SD/muchos.obtenido"
cmpf "…los enseña todos, sin repetir ninguno y en el orden de siempre" "$SD/muchos.esperado" "$SD/muchos.obtenido"
N1=$(nreq storage.list)
[ $((N1 - N0)) = 3 ] && ok "…en tres páginas (2000 + 2000 + 500)" || bad "ls de 4500 archivos pidió $((N1 - N0)) páginas (se esperaban 3)"
run sn ls --json /Muchos $VIA;                jqok "ls --json de 4500 archivos los trae todos" '(.listings[0].entries | length) == 4500'
run sn ls -l /Muchos $VIA;                    [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 4500 ] && ok "ls -l también: una línea por archivo" || bad "ls -l de 4500 archivos" "$(printf '%s\n' "$OUT" | wc -l) líneas"
rm -rf "$D1/Muchos" "$SD/muchos.esperado" "$SD/muchos.obtenido"

echo "== nexo usb: bajar archivos (get) con --via app"
rm -rf "$SD/work"; mkdir -p "$SD/work"
run sn get /Música/a.txt "$SD/work" $VIA;     rc_is "get de un archivo a una carpeta → 0" 0
cmpf "…y queda igual" "$D1/Música/a.txt" "$SD/work/a.txt"
[ "$(stat -c %Y "$SD/work/a.txt")" = "$(stat -c %Y "$D1/Música/a.txt")" ] && ok "…con la misma fecha que tenía en el disco" || bad "get no conservó la fecha"
run sn get /Música/a.txt "$SD/work/otro.txt" $VIA;   rc_is "get a un nombre nuevo → 0" 0
cmpf "…y queda igual" "$D1/Música/a.txt" "$SD/work/otro.txt"
run sn get /Música/a.txt "$SD/work" $VIA;     rc_is "get sobre uno que ya existe → 1" 1
has "…dice que ya existe y cómo seguir" "usa -f para sustituirlo"
printf 'mío\n' > "$SD/work/a.txt"
run sn get -n /Música/a.txt "$SD/work" $VIA;  rc_is "get -n lo salta → 0" 0
[ "$(cat "$SD/work/a.txt")" = "mío" ] && ok "…y no toca el tuyo" || bad "get -n tocó el archivo local"
run sn get -f /Música/a.txt "$SD/work" $VIA;  rc_is "get -f lo sustituye → 0" 0
cmpf "…y queda lo del disco" "$D1/Música/a.txt" "$SD/work/a.txt"
run sn get /Música/a.txt /Música/rock/vacio.txt "$SD/work/noexiste" $VIA;   rc_is "get de varios a una carpeta local que no existe → 2" 2
run sn get /Música/rock/a.txt /Música/rock/vacio.txt "$SD/work/dos" $VIA;   rc_is "get de varios → 2 si la carpeta de destino no existe" 2
mkdir -p "$SD/work/dos"
run sn get /Música/rock/a.txt /Música/rock/vacio.txt "$SD/work/dos" $VIA;   rc_is "get de varios a una carpeta que existe → 0" 0
[ -f "$SD/work/dos/a.txt" ] && [ -f "$SD/work/dos/vacio.txt" ] && ok "…y están los dos" || bad "faltan archivos tras get de varios"
run sn get /Copia "$SD/work/c" $VIA;          rc_is "get de una carpeta sin -r → 1" 1
has "…dice que hace falta -r" "usa -r"
run sn get -r /Copia "$SD/work/c" $VIA;       rc_is "get -r a un nombre que no existe → 0" 0
diff -r "$D1/Copia" "$SD/work/c" >/dev/null 2>&1 && ok "…la carpeta queda igual (con la vacía)" || bad "get -r no copió igual" "$(diff -r "$D1/Copia" "$SD/work/c" 2>&1 | head -3)"
run sn get -r /Copia "$SD/work/dos" $VIA;     rc_is "get -r a una carpeta que existe la mete dentro → 0" 0
[ -f "$SD/work/dos/Copia/sub/dos.txt" ] && ok "…en dos/Copia" || bad "get -r no la metió dentro"
run sn get -r /Copia/ "$SD/work/otra" $VIA;   rc_is "get -r de «/carpeta/» a una que no existe la crea con lo de dentro → 0" 0
[ -f "$SD/work/otra/sub/dos.txt" ] && [ ! -e "$SD/work/otra/Copia" ] && ok "…sin la carpeta «Copia» en medio" || bad "get -r carpeta/ la metió dentro"
run sn get -r /Copia/ "$SD/work/otra" $VIA;   rc_is "get -r de «/carpeta/» sobre lo que ya hay: los archivos que ya están son fallos → 1" 1
has "…dice cuántos" "con fallos"
run sn get -rf /Copia/ "$SD/work/otra" $VIA;  rc_is "…con -f los sustituye → 0" 0
run sn get /nada "$SD/work" $VIA;             rc_is "get de algo que no existe → 1" 1
has "…lo dice" "No existe"
run sn get --verify /grande.bin "$SD/work/g.bin" $VIA;    rc_is "get --verify de 5 MB → 0" 0
cmpf "…y queda igual que el original" "$SD/loc/grande.bin" "$SD/work/g.bin"
run sn get /Música/a.txt "$SD/nada/aqui.txt" $VIA;        rc_is "get a una carpeta local que no existe → 1" 1
has "…lo dice" "No existe la carpeta de destino"
run sn get --json /Música/a.txt "$SD/work/j.txt" $VIA;    jqok "get --json: resumen" '.ok == true and .files == 1 and .bytes == 9 and .items[0].src == "MI DISCO:/Música/a.txt"'
[ "$(find "$SD/work" -name '.nexo-part-*' | wc -l | tr -d ' ')" = 0 ] && ok "get no deja archivos .nexo-part en tu distro" || bad "get dejó restos locales"
[ "$(openfiles)" = 0 ] && ok "…ni archivos abiertos en la app" || bad "quedaron archivos abiertos" "$(openfiles)"
run sn get -r / "$SD/work/todo" $VIA;         rc_is "get -r de toda la raíz → 0" 0
[ -f "$SD/work/todo/Música/a.txt" ] && ok "…copia la raíz entera" || bad "get -r / no copió la raíz"

echo "== nexo usb: mover y borrar (mv, rm) con --via app"
run sn mv /Música/a.txt /Música/rock/b.txt $VIA;       rc_is "mv a un nombre nuevo en otra carpeta → 0" 0
[ ! -e "$D1/Música/a.txt" ] && [ "$(cat "$D1/Música/rock/b.txt")" = distinto ] && ok "…y se movió (el origen ya no está)" || bad "mv no movió bien"
run sn mv /Música/rock/b.txt /Música/rock/a.txt $VIA;  rc_is "mv a un nombre que ya existe → 1" 1
has "…dice que ya existe" "Ya existe"
run sn mv -f /Música/rock/b.txt /Música/rock/a.txt $VIA;   rc_is "mv -f lo sustituye → 0" 0
[ "$(cat "$D1/Música/rock/a.txt")" = distinto ] && [ ! -e "$D1/Música/rock/b.txt" ] && ok "…y quedó lo nuevo" || bad "mv -f no sustituyó"
run sn mv /Música/rock/a.txt /vacio.txt /Copia/vacia $VIA;   rc_is "mv de varios a una carpeta (aquí vacio.txt ya está en /Copia… no: va a /Copia/vacia) → 0" 0
[ -f "$D1/Copia/vacia/a.txt" ] && [ -f "$D1/Copia/vacia/vacio.txt" ] && ok "…y llegaron los dos" || bad "mv de varios falló"
run sn mv /Música /Música/rock/dentro $VIA;   rc_is "mv de una carpeta dentro de sí misma → 1" 1
has "…lo dice" "dentro de sí misma"
run sn mv /nada /x $VIA;                      rc_is "mv de algo que no existe → 1" 1
run sn mv / /x $VIA;                          rc_is "mv de la raíz → 1" 1
has "…lo dice" "raíz"
run sn mv /Copia/sub '/z:z' $VIA;             rc_is "mv a un nombre con «:» → 1" 1
has "…lo explica" "no admiten el carácter «:»"
run sn mv /Copia/sub /Copia/vacia $VIA;       rc_is "mv de una carpeta a otra carpeta (la mete dentro) → 0" 0
[ -f "$D1/Copia/vacia/sub/dos.txt" ] && ok "…y está dentro" || bad "mv de carpeta no la metió dentro"
run sn rm /Copia $VIA;                        rc_is "rm de una carpeta sin -r → 1" 1
has "…dice que hace falta -r" "usa -r"
[ -d "$D1/Copia" ] && ok "…y no la borró" || bad "rm sin -r borró la carpeta"
run sn rm /grande.bin /json.txt $VIA;         rc_is "rm de dos archivos → 0" 0
[ ! -e "$D1/grande.bin" ] && [ ! -e "$D1/json.txt" ] && ok "…y ya no están" || bad "rm no borró"
run sn rm -r /Copia $VIA;                     rc_is "rm -r borra una carpeta con todo → 0" 0
[ ! -e "$D1/Copia" ] && ok "…y ya no está" || bad "rm -r no borró"
run sn rm /nada $VIA;                         rc_is "rm de algo que no existe → 1" 1
run sn rm -f /nada $VIA;                      rc_is "rm -f de algo que no existe → 0" 0
run sn rm -r / $VIA;                          rc_is "rm -r / → 1 (la raíz no se borra)" 1
has "…lo dice" "La raíz del disco no se borra"
[ -d "$D1/Música" ] && ok "…y no tocó nada" || bad "rm -r / borró algo"
run sn rm -rv /Música $VIA;                   rc_is "rm -rv enseña lo que borra → 0" 0
has "…lo enseña" "borrado: MI DISCO:/Música/rock"
[ "$(openfiles)" = 0 ] && ok "mv y rm no dejan archivos abiertos" || bad "quedaron archivos abiertos" "$(openfiles)"

echo "== nexo usb: acceso directo (--via direct) y comparación con la app"
DV=5555-6666; DD=$SD/discos/$DV
sctl storage add "DIFERENCIAL" $DV direct
mkdir -p "$DD/Música/rock" "$DD/Música/vacia" "$DD/Fotos/2026" "$DD/.Trashes"
printf 'rock A\n' > "$DD/Música/rock/a.mp3"; printf 'rock B\n' > "$DD/Música/rock/b.txt"; head -c 100000 /dev/urandom > "$DD/Fotos/2026/f1.jpg"
printf 'léeme\n' > "$DD/leeme.txt"; printf 'o' > "$DD/.oculto"; printf 'x' > "$DD/.Trashes/x"
run sn ls --vol DIFERENCIAL --via direct;     rc_is "ls --via direct en un disco cuya ruta ve este proceso → 0" 0
has "…lista lo del disco" "Música/"
run sn ls --vol "MI DISCO" --via direct;      rc_is "--via direct en un disco cuya ruta NO se ve → 1" 1
has "…y dice por qué" "No puedo entrar directamente"
N0=$(nreq storage.list); run sn ls --vol DIFERENCIAL;      N1=$(nreq storage.list)
[ "$N1" = "$N0" ] && ok "--via auto en un disco que este proceso ve entra directo (la app no recibió storage.list)" || bad "auto usó la app" "$N0 → $N1"
N0=$(nreq storage.list); run sn ls --vol DIFERENCIAL --via app;      N1=$(nreq storage.list)
[ "$N1" -gt "$N0" ] && ok "…y --via app sí pasa por la app" || bad "--via app no usó la app" "$N0 → $N1"
N0=$(nreq storage.list); run sn ls --vol "MI DISCO";      N1=$(nreq storage.list)
[ "$N1" -gt "$N0" ] && ok "--via auto en un disco que no se ve entra por la app" || bad "auto no usó la app donde no había otra" "$N0 → $N1"

# El mismo comando, por la app y directo, desde el mismo punto de partida: tienen que dar lo mismo (código, texto y lo que queda en el disco y en tu distro)
snap_dd() { rm -rf "$SD/snap" "$SD/snapw"; cp -a "$DD" "$SD/snap"; rm -rf "$SD/work"; mkdir -p "$SD/work"; }
dcmp() {
    local what=$1 ra rd oa od sa sd wa wd
    shift
    snap_dd
    run sn "$@" --vol DIFERENCIAL --via app;    ra=$RC; oa=$(printf '%s\n%s' "$OUT" "$ERR" | norm); sa=$(tree_sig "$DD"); wa=$(tree_sig "$SD/work")
    rm -rf "$DD"; cp -a "$SD/snap" "$DD"; rm -rf "$SD/work"; mkdir -p "$SD/work"
    run sn "$@" --vol DIFERENCIAL --via direct; rd=$RC; od=$(printf '%s\n%s' "$OUT" "$ERR" | norm); sd=$(tree_sig "$DD"); wd=$(tree_sig "$SD/work")
    if [ "$ra" = "$rd" ] && [ "$oa" = "$od" ] && [ "$sa" = "$sd" ] && [ "$wa" = "$wd" ]; then ok "app = directo: $what (código $ra)"
    else bad "app ≠ directo: $what" "app: código $ra [$oa] · directo: código $rd [$od] · disco igual: $([ "$sa" = "$sd" ] && echo sí || echo no) · tu distro igual: $([ "$wa" = "$wd" ] && echo sí || echo no)"; fi
    rm -rf "$DD"; cp -a "$SD/snap" "$DD"
}
W=$SD/work
dcmp "ls /" ls /
dcmp "ls -la /" ls -la /
dcmp "ls -lhR /" ls -lhR /
dcmp "ls --json /Música" ls --json /Música
dcmp "ls de un archivo" ls /leeme.txt
dcmp "ls de algo que no existe" ls /nada
dcmp "ls de algo debajo de un archivo" ls /leeme.txt/x
dcmp "ls de dos rutas" ls /Música /Fotos
dcmp "stat de un archivo" stat /Música/rock/a.mp3
dcmp "stat de una carpeta" stat /Música
dcmp "stat de la raíz" stat /
dcmp "stat de algo que no existe" stat /nada
dcmp "stat --json" stat --json /leeme.txt
dcmp "cat" cat /leeme.txt /Música/rock/b.txt
dcmp "cat de una carpeta" cat /Música
dcmp "cat de algo que no existe" cat /nada
dcmp "mkdir" mkdir /Nueva
dcmp "mkdir de una que existe" mkdir /Música
dcmp "mkdir -p de una que existe" mkdir -p /Música
dcmp "mkdir -p de varios niveles" mkdir -p /A/B/C
dcmp "mkdir sin la de arriba" mkdir /A/B/C
dcmp "mkdir debajo de un archivo" mkdir /leeme.txt/x
dcmp "mkdir con «:»" mkdir '/x:y'
dcmp "mkdir -p con «?» en el último nivel (no debe dejar nada)" mkdir -p '/nuevo/hondo/x?y'
dcmp "mkdir que acaba en punto" mkdir 'fin.'
dcmp "mkdir de la raíz" mkdir /
dcmp "put de un archivo" put "$SD/loc/a.txt" /nuevo.txt
dcmp "put a una carpeta" put "$SD/loc/a.txt" /Música/
dcmp "put sobre uno que existe" put "$SD/loc/a.txt" /leeme.txt
dcmp "put -f" put -f "$SD/loc/a.txt" /leeme.txt
dcmp "put -n" put -n "$SD/loc/a.txt" /leeme.txt
dcmp "put sobre una carpeta (va dentro)" put "$SD/loc/a.txt" /Música
dcmp "put sobre una carpeta sin la barra y con un nombre que ya está dentro" put "$SD/loc/a.txt" /Música/rock/b.txt/
dcmp "put a una carpeta que no existe" put "$SD/loc/a.txt" /nada/x.txt
dcmp "put debajo de un archivo" put "$SD/loc/a.txt" /leeme.txt/x.txt
dcmp "put de varios" put "$SD/loc/a.txt" "$SD/loc/vacio.txt" /Música/
dcmp "put de varios a algo que no es carpeta" put "$SD/loc/a.txt" "$SD/loc/vacio.txt" /nada
dcmp "put de una carpeta sin -r" put "$SD/loc/arbol" /X
dcmp "put -r" put -r "$SD/loc/arbol" /Copia
dcmp "put -r dentro de una carpeta que existe" put -r "$SD/loc/arbol" /Música
dcmp "put -r sobre una carpeta que ya tiene lo mismo" put -r "$SD/loc/arbol" /Música/vacia
dcmp "put -r de «carpeta/» a una que existe (mezcla)" put -r "$SD/loc/arbol/" /Música/vacia
dcmp "put -r de «carpeta/» a la raíz" put -r "$SD/loc/arbol/" /
dcmp "put -r de «carpeta/» sin -r" put "$SD/loc/arbol/" /Copia
dcmp "put con «:» en el nombre" put "$SD/loc/a:b.txt" /
dcmp "put --fix-names" put --fix-names "$SD/loc/a:b.txt" /
dcmp "put con acentos y espacios" put "$SD/loc/Música ñ.txt" /
dcmp "put de un archivo vacío" put "$SD/loc/vacio.txt" /v.txt
dcmp "put de un archivo local que no existe" put "$SD/loc/nada.txt" /
dcmp "put --verify de 5 MB" put --verify "$SD/loc/grande.bin" /g.bin
dcmp "put -q --json" put -q --json "$SD/loc/a.txt" /q.txt
dcmp "get" get /leeme.txt "$W"
dcmp "get a un nombre nuevo" get /leeme.txt "$W/otro.txt"
dcmp "get de varios" get /leeme.txt /Música/rock/b.txt "$W"
dcmp "get de algo que no existe" get /nada "$W"
dcmp "get de una carpeta sin -r" get /Música "$W"
dcmp "get -r a un nombre nuevo" get -r /Música "$W/m"
dcmp "get -r a una carpeta que existe" get -r /Música "$W"
dcmp "get -r de toda la raíz (con ocultos)" get -r / "$W/todo"
dcmp "get -r de «/carpeta/»" get -r /Música/ "$W/m"
dcmp "get -r de «/carpeta/» a una carpeta que existe" get -r /Música/ "$W"
dcmp "get de «/carpeta/» sin -r" get /Música/ "$W"
dcmp "get --verify" get --verify /Fotos/2026/f1.jpg "$W"
dcmp "get --json" get --json /leeme.txt "$W"
dcmp "mv a un nombre nuevo" mv /leeme.txt /otro.txt
dcmp "mv a una carpeta" mv /leeme.txt /Música
dcmp "mv de varios a una carpeta" mv /leeme.txt /.oculto /Música/vacia
dcmp "mv sobre uno que existe" mv /leeme.txt /Música/rock/b.txt
dcmp "mv -f" mv -f /leeme.txt /Música/rock/b.txt
dcmp "mv de una carpeta a otra" mv /Música /Fotos
dcmp "mv de una carpeta dentro de sí misma" mv /Música /Música/rock/dentro
dcmp "mv de algo que no existe" mv /nada /x
dcmp "mv a un nombre con «:»" mv /leeme.txt '/a:b'
dcmp "mv de la raíz" mv / /x
dcmp "mv de uno a sí mismo" mv /leeme.txt /leeme.txt
dcmp "rm de un archivo" rm /leeme.txt
dcmp "rm de una carpeta sin -r" rm /Música
dcmp "rm -r" rm -r /Música
dcmp "rm -rv" rm -rv /Música
dcmp "rm de algo que no existe" rm /nada
dcmp "rm -f de algo que no existe" rm -f /nada
dcmp "rm -r de la raíz" rm -r /
dcmp "rm de una carpeta vacía con -r" rm -r /Música/vacia
dcmp "rm de varios con uno que no existe" rm /leeme.txt /nada /.oculto

echo "== nexo usb: acceso solo a una carpeta del disco (el selector de Android deja elegir una)"
sctl storage grant $DV off
sctl storage grant $DV on Música
run sn mounts;                                has "mounts dice que solo puede entrar en esa carpeta" "sí (solo /Música)"
run sn access --vol DIFERENCIAL;              has "access lo dice" "(solo /Música)"
run sn ls --vol DIFERENCIAL --via app;        has "ls (por la app) ve la carpeta autorizada como si fuera el disco" "rock/"
hasnt "…y no ve lo de fuera" "Fotos"
run sn ls --vol DIFERENCIAL --via direct;     has "ls (directo) ve lo mismo" "rock/"
hasnt "…y tampoco lo de fuera" "Fotos"
run sn cat /leeme.txt --vol DIFERENCIAL --via app;      rc_is "cat de algo fuera de la carpeta autorizada (por la app) → 1" 1
run sn cat /leeme.txt --vol DIFERENCIAL --via direct;   rc_is "…igual (directo) → 1" 1
run sn cat /rock/b.txt --vol DIFERENCIAL --via app;     eq "cat dentro de la carpeta autorizada (por la app)" "rock B"
run sn cat /rock/b.txt --vol DIFERENCIAL --via direct;  eq "…igual (directo)" "rock B"
run sn put "$SD/loc/a.txt" /rock/ --vol DIFERENCIAL --via app;   rc_is "put dentro de la carpeta autorizada → 0" 0
[ -f "$DD/Música/rock/a.txt" ] && ok "…y llegó a /Música/rock del disco real" || bad "el put con carpeta autorizada llegó a otro sitio"
run sn rm -r / --vol DIFERENCIAL --via app;   rc_is "rm -r / dentro de la carpeta autorizada → 1 (su «raíz» no se borra)" 1
sctl storage grant $DV on
run sn ls --vol DIFERENCIAL --via direct;     has "con el disco entero autorizado, directo ve todo" "Fotos/"

echo "== nexo usb: un disco de solo lectura"
mkdir -p "$D1/Música/rock"; printf 'x\n' > "$D1/Música/rock/x.txt"
sctl storage ro $V1 on
run sn mounts;                                has "mounts lo dice" "solo lectura"
run sn ls /Música $VIA;                       rc_is "ls en un disco de solo lectura → 0" 0
run sn put "$SD/loc/a.txt" /nuevo.txt $VIA;   rc_is "put → 1" 1
has "…dice que es de solo lectura" "solo lectura"
run sn mkdir /x $VIA;                         rc_is "mkdir → 1" 1
run sn rm -r /Música $VIA;                    rc_is "rm → 1" 1
run sn mv /Música /M2 $VIA;                   rc_is "mv → 1" 1
[ -d "$D1/Música" ] && [ ! -e "$D1/nuevo.txt" ] && [ ! -e "$D1/x" ] && ok "…y no cambió nada en el disco" || bad "un disco de solo lectura cambió"
run sn get -r /Música "$SD/work/ro" $VIA;     rc_is "get de un disco de solo lectura → 0" 0
sctl storage ro $V1 off
run sn put --vol DIFERENCIAL "$SD/loc/a.txt" /ro.txt --via direct;  rc_is "(un disco con acceso directo) put en uno normal → 0" 0
sctl storage ro $DV on
run sn put --vol DIFERENCIAL "$SD/loc/a.txt" /ro2.txt --via direct; rc_is "(directo) put en uno de solo lectura → 1" 1
has "…dice que es de solo lectura" "solo lectura"
run sn rm /ro.txt --vol DIFERENCIAL --via direct;                   rc_is "(directo) rm en uno de solo lectura → 1" 1
[ -f "$DD/ro.txt" ] && ok "…y no lo borró" || bad "rm directo borró en un disco de solo lectura"
sctl storage ro $DV off

echo "== nexo usb: disco lleno, archivo demasiado grande, disco con errores"
sctl storage size $V1 100000
run sn put "$SD/loc/grande.bin" /grande.bin $VIA;    rc_is "put de 5 MB en un disco de 100 KB → 1" 1
has "…dice que está lleno" "El disco está lleno"
[ ! -e "$D1/grande.bin" ] && [ "$(parts)" = 0 ] && ok "…y no queda ni el archivo ni restos .nexo-part" || bad "disco lleno: quedaron restos" "$(find "$SD/discos" -name '.nexo-part-*')"
[ "$(openfiles)" = 0 ] && ok "…ni archivos abiertos" || bad "quedaron archivos abiertos tras disco lleno" "$(openfiles)"
sctl storage size $V1 none
sctl storage maxfile $V1 100000
run sn put "$SD/loc/grande.bin" /grande.bin $VIA;    rc_is "put de 5 MB donde el sistema de archivos solo admite 100 KB → 1" 1
has "…dice que es FAT32" "FAT32"
has "…y qué hacer" "exFAT"
[ ! -e "$D1/grande.bin" ] && [ "$(parts)" = 0 ] && ok "…y tampoco deja restos" || bad "too_big: quedaron restos"
run sn put "$SD/loc/a.txt" /pequeno.txt $VIA;        rc_is "…uno pequeño sí cabe → 0" 0
sctl storage maxfile $V1 none
sctl storage fail $V1 on
run sn ls $VIA;                               rc_is "un disco que da errores: ls → 1" 1
has "…lo dice" "da errores"
run sn put "$SD/loc/a.txt" /fallo.txt $VIA;   rc_is "…put → 1" 1
[ "$(openfiles)" = 0 ] && ok "…sin archivos abiertos" || bad "quedaron archivos abiertos con errores de disco" "$(openfiles)"
sctl storage fail $V1 off
run sn ls $VIA;                               rc_is "…y al arreglarse, todo vuelve a funcionar → 0" 0
rm -f "$D1/pequeno.txt"

echo "== nexo usb: el disco no está montado, se quita o se expulsa"
sctl storage state $V1 unmountable
run sn ls $VIA;                               rc_is "disco que Android no pudo montar: ls → 4" 4
has "…dice que no está montado" "no está montado"
has "…y por qué puede ser" "no pudo montarlo"
run sn get /Música "$SD/work" $VIA;           rc_is "…get → 4" 4
run sn mounts;                                has "mounts lo enseña con su estado" "no se puede montar"
sctl storage state $V1 checking
run sn ls $VIA;                               has "disco que Android aún comprueba: dice que espere" "espera unos segundos"
sctl storage state $V1 mounted
run sn ls $VIA;                               rc_is "al montarse, vuelve a funcionar → 0" 0
sctl storage remove $V1
run sn ls --vol "MI DISCO";                   rc_is "disco desenchufado: ls → 4" 4
run sn mounts --json;                         jqok "…y mounts ya no lo lista (solo queda «DIFERENCIAL»)" '[.volumes[].uuid] | index("1111-2222") == null and index("5555-6666") != null'
sctl storage add "MI_DISCO" $V1
sctl storage eject $V1 ok
run sn eject "MI DISCO";                      rc_is "eject (Android lo expulsa) → 0" 0
has "…lo dice" "expulsado: ya puedes desenchufarlo"
run sn ls --vol "MI DISCO" $VIA;              rc_is "…y después ya no está montado → 4" 4
sctl storage add "MI_DISCO" $V1
sctl storage eject $V1 silent
run sn eject "MI DISCO";                      rc_is "eject cuando Android lo ignora (lo normal en muchos móviles) → 1" 1
has "…dice cómo hacerlo a mano" "Expulsar"
run sn eject "MI DISCO" --json;               jqok "eject --json: no expulsado" '.ejected == false and .attempted == true'
sctl storage eject $V1 throw
run sn eject "MI DISCO";                      rc_is "eject cuando Android lanza una excepción → 1" 1
has "…también dice cómo hacerlo a mano" "Expulsar"
run sn eject zzz;                             rc_is "eject de un disco que no existe → 4" 4
sctl storage eject $V1 ok

echo "== nexo usb: se desenchufa a mitad de una copia"
SD2=$T/stor2
mkdir -p "$SD2/discos"
: > "$SD2/ctl"
SP2=$(start_app storslow --slow-ms 6 --ctl "$SD2/ctl" --storage-dir "$SD2/discos")
SE2() { env -i PATH="$PATH" HOME="$SD/home" TMPDIR="$SD/tmp" NEXO_USB_DIR="$SD/state" NEXO_PORT="$SP2" NEXO_TOKEN="$TOKEN" "$@"; }
printf 'storage add DISCO_LENTO 9999-0000\n' >> "$SD2/ctl"; sleep 0.5
( SE2 python3 "$NU" put "$SD/loc/grande.bin" /grande.bin --via app > "$SD/u.out" 2> "$SD/u.err"; echo $? > "$SD/u.rc" ) &
for i in $(seq 100); do ls "$SD2/discos/9999-0000"/.nexo-part-* >/dev/null 2>&1 && break; sleep 0.1; done
printf 'storage remove 9999-0000\n' >> "$SD2/ctl"
for i in $(seq 150); do [ -s "$SD/u.rc" ] && break; sleep 0.1; done
OUT=$(cat "$SD/u.out"); ERR=$(cat "$SD/u.err"); RC=$(cat "$SD/u.rc" 2>/dev/null || echo 124)
rc_is "put de 5 MB y el disco desaparece a mitad → 5" 5
has "…dice que se perdió el disco" "Se perdió el disco"
has "…y cómo reconocer lo que pudo quedar" ".nexo-part-"
ls "$SD2/discos/9999-0000"/.nexo-part-* >/dev/null 2>&1 && ok "…y el resto a medias está donde dijo (en el disco, con el nombre de aviso)" || bad "no hay resto del archivo a medias"
[ ! -e "$SD2/discos/9999-0000/grande.bin" ] && ok "…y el archivo con el nombre bueno NO existe (nunca queda uno a medias con su nombre)" || bad "quedó un grande.bin a medias"
printf 'storage add DISCO_LENTO 9999-0000\n' >> "$SD2/ctl"; sleep 0.5
run env -i PATH="$PATH" HOME="$SD/home" TMPDIR="$SD/tmp" NEXO_USB_DIR="$SD/state" NEXO_PORT="$SP2" NEXO_TOKEN="$TOKEN" python3 "$NU" ls -a /
has "al volver a enchufarlo, ls -a enseña el resto" ".nexo-part-"
run env -i PATH="$PATH" HOME="$SD/home" TMPDIR="$SD/tmp" NEXO_USB_DIR="$SD/state" NEXO_PORT="$SP2" NEXO_TOKEN="$TOKEN" python3 "$NU" rm -f /.nexo-part-*
rm -f "$SD2/discos/9999-0000"/.nexo-part-* 2>/dev/null

echo "== nexo usb: la app se cae a mitad de una copia"
SD3=$T/stor3
mkdir -p "$SD3/discos"
: > "$SD3/ctl"
SP3=$(start_app storcrash --slow-ms 8 --ctl "$SD3/ctl" --storage-dir "$SD3/discos")
SE3() { env -i PATH="$PATH" HOME="$SD/home" TMPDIR="$SD/tmp" NEXO_USB_DIR="$SD/state" NEXO_PORT="$SP3" NEXO_TOKEN="$TOKEN" "$@"; }
printf 'storage add DISCO_CAE 7777-8888\n' >> "$SD3/ctl"; sleep 0.5
rm -f "$SD/c.rc"
( SE3 python3 "$NU" put "$SD/loc/grande.bin" /grande.bin --via app > "$SD/c.out" 2> "$SD/c.err"; echo $? > "$SD/c.rc" ) &
for i in $(seq 100); do ls "$SD3/discos/7777-8888"/.nexo-part-* >/dev/null 2>&1 && break; sleep 0.1; done
kill -9 "$(cat "$T/storcrash.pid")" 2>/dev/null
for i in $(seq 200); do [ -s "$SD/c.rc" ] && break; sleep 0.1; done
OUT=$(cat "$SD/c.out"); ERR=$(cat "$SD/c.err"); RC=$(cat "$SD/c.rc" 2>/dev/null || echo 124)
rc_is "put de 5 MB y la app se cae a mitad → 10" 10
has "…dice que se perdió la conexión con la app" "Se perdió la conexión con la app"
[ ! -e "$SD3/discos/7777-8888/grande.bin" ] && ok "…y el archivo con el nombre bueno NO existe (nunca queda uno a medias con su nombre)" || bad "quedó un grande.bin a medias"
rm -rf "$SD3"

echo "== nexo usb desde el cliente nexo (nexo usb …): discos"
cenv() { env -i PATH="$PATH" HOME="$SD/home" TMPDIR="$SD/tmp" NEXO_USB_DIR="$SD/state" NEXO_PORT="$SP" NEXO_TOKEN="$TOKEN" "$@"; }
run cenv "$NEXO" usb mounts;                  rc_is "nexo usb mounts → 0" 0
has "…es la lista de nexo-usb" "NEXO PUEDE ENTRAR"
run cenv "$NEXO" usb mounts --json;           jqok "nexo usb mounts --json pasa la opción" '.volumes | length >= 2'
run cenv "$NEXO" --json usb mounts;           jqok "nexo --json usb mounts también" '.volumes | length >= 2'
run cenv "$NEXO" usb ls --vol "MI DISCO" --via app;   rc_is "nexo usb ls → 0" 0
has "…lista de verdad (ahora ls es de archivos)" "a_b.txt"
run cenv "$NEXO" --json usb df;               jqok "nexo --json usb df pasa --json" 'type == "array" and length >= 2'
run cenv "$NEXO" usb cat /Música/rock/a.txt --vol "MI DISCO" --via app;   rc_is "nexo usb cat → 0 o 1 (según lo que quede)" 1
run cenv "$NEXO" usb help;                    has "nexo usb help enseña los discos" "mounts [--all] [--json] [--wait S]"
run cenv "$NEXO" help;                        has "nexo help enseña los comandos de discos" "usb get|put ORIGEN… DESTINO"
run cenv "$NEXO" version --check;             rc_is "nexo version --check con la app (protocolo $APP_MINOR) → 0" 0
OLD3=$(start_app stor3b --minor3)
run cenv NEXO_PORT="$OLD3" "$NEXO" version --check;    rc_is "nexo version --check con una app 0.4.1 → 1 (le faltan los discos)" 1
has "…dice que le falta storage" "storage"
# sin python3: «nexo usb mounts» sigue funcionando (con bash y jq); lo demás pide python3
NOPY=$SD/nopy; mkdir -p "$NOPY"
for c in bash env jq sed tr cat head tail grep cut date sleep mktemp rm stat readlink dirname id timeout basename uname; do
    p=$(command -v "$c" 2>/dev/null) && ln -sf "$p" "$NOPY/$c"
done
nopy() { env -i PATH="$NOPY" HOME="$SD/home" TMPDIR="$SD/tmp" NEXO_PORT="$SP" NEXO_TOKEN="$TOKEN" "$@"; }
run nopy "$NEXO" usb mounts;                  rc_is "nexo usb mounts sin python3 → 0" 0
has "…muestra el disco" "MI DISCO"
has "…y avisa de lo que falta" "Sin python3"
run nopy "$NEXO" usb mounts --json;           jqok "nexo usb mounts --json sin python3 también" '.volumes | length >= 2'
run nopy "$NEXO" usb mounts --all;            has "…y --all enseña también el interno" "INTERNO (interno)"
run nopy "$NEXO" usb ls;                      rc_is "nexo usb ls sin python3 → 1" 1
has "…pide python3" "necesita python3"
has "…y dice qué sí funciona" "nexo usb mounts"

echo "== nexo watch storage: enchufar, montar, expulsar y quitar un disco"
run cenv "$NEXO" watch cosas;                 rc_is "watch con un tema que no existe → 2" 2
has "…y lista los que sí (con usb y storage)" "usb, storage"
WS=$SD/watch; mkdir -p "$WS"
V3=3333-4444
( cenv NEXO_CACHE_TTL=0 timeout 40 "$NEXO" watch storage --event > "$WS/ev.json" 2> "$WS/ev.err" ) &
( cenv NEXO_CACHE_TTL=0 timeout 40 "$NEXO" watch storage --pretty > "$WS/pretty.txt" 2> "$WS/pretty.err" ) &
waitfor "$WS/ev.json" '"initial":true' 10 && ok "al empezar, cada disco que ya estaba sale como evento inicial" || bad "no hubo eventos iniciales" "$(cat "$WS/ev.json" "$WS/ev.err" 2>/dev/null | head -5)"
sctl storage add "NUEVO_DISCO" $V3 noaccess
sctl storage grant $V3 on
sctl storage state $V3 unmountable
sctl storage state $V3 mounted
sctl storage grant $V3 off
sctl storage remove $V3
waitfor "$WS/ev.json" '"event":"removed"' 15 && ok "…y al quitar un disco sale «removed»" || bad "no salió el evento removed" "$(cat "$WS/ev.json")"
SEQ=$(jq -c 'select(.volume == "3333-4444") | .event' "$WS/ev.json" 2>/dev/null | tr -d '"' | paste -sd,)
[ "$SEQ" = "mounted,access_granted,unmounted,mounted,access_revoked,removed" ] && ok "la secuencia de eventos del disco: mounted → access_granted → unmounted → mounted → access_revoked → removed" || bad "secuencia de eventos" "$SEQ"
jq -e 'select(.volume == "3333-4444" and .event == "unmounted") | .state == "unmountable" and .label == "NUEVO DISCO"' "$WS/ev.json" >/dev/null 2>&1 && ok "…cada evento lleva el estado y el nombre" || bad "los eventos no llevan estado y nombre"
waitfor "$WS/pretty.txt" "NUEVO DISCO (no se puede montar)" 5 && ok "watch storage --pretty lo cuenta en español" || bad "watch --pretty no tradujo el estado" "$(cat "$WS/pretty.txt")"
waitfor "$WS/pretty.txt" "NUEVO DISCO (montado)" 5 && ok "…y cuando está montado" || bad "watch --pretty: sin «montado»" "$(cat "$WS/pretty.txt")"
pkill -f "$NEXO watch storage" 2>/dev/null; sleep 0.3

echo "== tests/usb_storage_hardware_check.sh (la prueba con un disco de verdad; aquí, contra la app falsa para comprobar que el script funciona)"
HS=$ROOT/tests/usb_storage_hardware_check.sh
SH=$T/storhw
mkdir -p "$SH/home" "$SH/state" "$SH/tmp" "$SH/discos"
: > "$SH/ctl"
SPH=$(start_app storhw --ctl "$SH/ctl" --storage-dir "$SH/discos")
hctl() { printf '%s\n' "$*" >> "$SH/ctl"; sleep 0.4; }
hs() { env -i PATH="$PATH" HOME="$SH/home" TMPDIR="$SH/tmp" NEXO_USB_DIR="$SH/state" NEXO_PORT="$SPH" NEXO_TOKEN="$TOKEN" NEXO_CHECK_BIN="$T/bin/nexo" NEXO_CHECK_HOOK_UNPLUG="${HS_UNPLUG:-}" NEXO_CHECK_HOOK_PLUG="${HS_PLUG:-}" timeout 240 "$@"; }
HV=5A5A-0001; HD=$SH/discos/$HV
checks() { printf '%s\n%s\n' "$OUT" "$ERR" | grep -c '^  FALLA '; }        # cuántas comprobaciones falladas cuenta el script
mydirs() { find "$HD" -maxdepth 1 -name 'nexo-check-*' 2>/dev/null | wc -l | tr -d ' '; }

head -n 1 "$HS" | grep -q '^#!/usr/bin/env bash$' && ok "empieza por #!/usr/bin/env bash" || bad "shebang de usb_storage_hardware_check.sh"
run hs bash "$HS" --help;                     rc_is "--help sale con 0" 0
has "…y explica --speed" "--speed"
has "…--big" "--big"
has "…--eject" "--eject"
has "…--unplug" "--unplug"
has "…y que solo escribe en su propia carpeta" "nexo-check-"
run hs bash "$HS" --speed abc;                rc_is "--speed con algo que no es un número → 2" 2
run hs bash "$HS" --speed 5000;               rc_is "--speed por encima del máximo (4096) → 2" 2
run hs bash "$HS" --big;                      rc_is "--big sin valor → 2" 2
run hs bash "$HS" --big 70000;                rc_is "--big por encima del máximo (65536) → 2" 2
run hs bash "$HS" --raro;                     rc_is "una opción desconocida → 2" 2
run hs bash "$HS" uno dos;                    rc_is "dos discos → 2" 2
run env -i PATH="$PATH" NEXO_CHECK_BIN="$T/no-existe" bash "$HS" --yes;   rc_is "sin nexo instalado → 2" 2
run env -i PATH="$PATH" HOME="$SH/home" TMPDIR="$SH/tmp" NEXO_USB_DIR="$SH/state" NEXO_PORT=1 NEXO_TOKEN="$TOKEN" NEXO_CHECK_BIN="$T/bin/nexo" bash "$HS" --yes
rc_is "con la app apagada → 1" 1
has "…dice qué falló (código 10: la app no responde)" "falló (código 10)"
run hs bash "$HS" --yes;                      rc_is "sin ningún disco enchufado → 1" 1
has "…lo dice" "no hay ningún disco USB montado"
hctl storage add DISCO_UNO $HV
hctl storage add DISCO_DOS 5A5A-0002
run hs bash "$HS" --yes;                      rc_is "con dos discos y ninguno elegido → 1" 1
has "…pide que indiques cuál" "hay varios discos"
has "…y los enumera" "5A5A-0002"
run hs bash "$HS" ZZZ --yes;                  rc_is "un disco que no existe → 1" 1
has "…lo dice con las letras que escribiste" "ningún disco coincide con «ZZZ»"
hctl storage remove 5A5A-0002
hctl storage state $HV unmountable
run hs bash "$HS" $HV --yes;                  rc_is "un disco que Android no montó → 1" 1
has "…lo dice" "no está montado"
hctl storage state $HV mounted
hctl storage grant $HV off
hctl storage auto deny
run hs bash "$HS" --yes;                      rc_is "sin acceso, y en el selector dices que no → 1" 1
has "…dice que «nexo usb access» salió con 3" "«nexo usb access» salió con 3"
[ "$(mydirs)" = 0 ] && ok "…y no llegó a escribir nada en el disco" || bad "creó una carpeta en un disco sin acceso"

echo "== tests/usb_storage_hardware_check.sh: una pasada completa"
mkdir -p "$HD/Fotos" "$HD/Docs"
printf 'x\n' > "$HD/Fotos/a.jpg"; printf 'y\n' > "$HD/.oculto"; printf 'z\n' > "$HD/secreto-personal.txt"
SIG0=$(tree_sig "$HD")
N0=$(ls -A "$HD" | wc -l | tr -d ' ')
hctl storage auto grant 200
run hs bash "$HS" --yes;                      rc_is "pasada completa (dando el acceso en el selector) → 0" 0
hasnt "…sin ninguna prueba fallida" "FALLA"
has "…el acceso se concedió" "acceso concedido"
has "…el acceso es al disco entero" "el acceso es al disco entero"
has "…el espacio libre cabe en el total" "df: el espacio libre cabe en el total"
has "…put --verify de un archivo de 0 bytes" "put --verify de «vacio.bin» (0 bytes)"
has "…y de uno con el límite de un bloque más 1" "put --verify de «4097.bin» (4097 bytes)"
has "…de un nombre con acentos y eñes" "put --verify de «Música ñandú.txt»"
has "…ls enseña los archivos con el tamaño exacto" "ls enseña los 8 archivos con el tamaño exacto"
has "…get -r devuelve los archivos idénticos (SHA-256)" "get -r: los 8 archivos vuelven idénticos"
has "…cat los devuelve iguales" "cat devuelve el archivo idéntico"
has "…y cat de dos los une en orden" "cat de dos archivos los une en orden"
has "…un nombre con emoji ida y vuelta" "se guarda y se lee igual"
has "…un árbol con una carpeta vacía vuelve idéntico" "el árbol vuelve idéntico (8 elementos, con su carpeta vacía)"
has "…put sobre lo que existe → 1 y dice cómo seguir" "dice cómo seguir (-f o -n)"
has "…put -f sustituye sin restos" "el contenido es el nuevo, entero"
has "…mv sobre lo que existe → 1" "mv sobre algo que ya existe → 1"
has "…mv -f lo sustituye" "mv -f lo sustituye → 0"
has "…mover una carpeta con todo lo que tiene" "todo lo que tenía sigue ahí"
has "…«a:b.txt» se rechaza antes de tocar el disco" "put de «a:b.txt» (los discos USB no admiten «:») → 1"
has "…--fix-names lo cambia por «_»" "existe «a_b.txt»"
has "…ningún « (1)» inventado por Android" "ningún archivo « (1)»"
has "…rm de una carpeta sin -r → 1" "rm de una carpeta sin -r → 1"
has "…rm -r borra el árbol" "rm -r de la carpeta con su árbol → 0"
has "…la carpeta de prueba se borra" "la carpeta de prueba ya no está"
has "…la raíz queda con los mismos nombres" "la raíz del disco queda con los mismos nombres que tenía ($N0 entradas)"
has "…y no quedan archivos abiertos" "no queda ningún archivo abierto en la app"
has "…el resumen no cuenta fallos" " 0 con fallos"
has "…el informe trae el disco en JSON" '"uuid": "5A5A-0001"'
has "…y el registro de la app" "(nexo logs 25)"
hasnt "…el informe no lleva el token" "$TOKEN"
hasnt "…ni los nombres de los archivos del disco" "secreto-personal"
[ "$(tree_sig "$HD")" = "$SIG0" ] && ok "mirando la carpeta del disco SIN el protocolo, quedó exactamente como estaba (mismos archivos y contenido)" || bad "el disco no quedó como estaba" "$(diff <(echo "$SIG0") <(tree_sig "$HD") | head -5)"
[ "$(mydirs)" = 0 ] && ok "…y no queda ninguna carpeta nexo-check-*" || bad "quedó una carpeta nexo-check-* en el disco"
[ "$(parts)" = 0 ] && ok "…ni archivos .nexo-part-* provisionales" || bad "quedaron archivos provisionales"
[ "$(ls "$SH/tmp" | grep -c 'nexo-storage-check')" = 0 ] && ok "…ni archivos temporales del script" || bad "el script dejó temporales" "$(ls "$SH/tmp")"

echo "== tests/usb_storage_hardware_check.sh: velocidad, archivo enorme, FAT32"
run hs bash "$HS" --yes --speed 4;            rc_is "--speed 4 → 0" 0
has "…escribe 4 MiB" "put de 4 MiB"
has "…lee 4 MiB" "leer: "
has "…dice MiB/s" "MiB/s"
has "…los 4 MiB vuelven idénticos" "los 4 MiB vuelven idénticos"
has "…el informe trae la velocidad" "--- velocidad"
hasnt "…sin ninguna prueba fallida" "FALLA"
run hs bash "$HS" --yes --big 6;              rc_is "--big 6 en un disco sin límite → 0" 0
has "…el disco acepta el archivo con el tamaño exacto" "el disco aceptó un archivo de 6 MiB y tiene el tamaño exacto"
hctl storage maxfile $HV 4194304
run hs bash "$HS" --yes --big 6;              rc_is "--big 6 en un disco que no admite archivos de más de 4 MiB (como FAT32 con 4 GiB) → 0" 0
has "…lo rechaza con el mensaje claro" "el disco rechazó el archivo de 6 MiB con un mensaje claro (es FAT32: máximo 4 GiB por archivo)"
has "…y no queda nada con el nombre bueno" "no quedó nada con el nombre bueno"
hasnt "…sin ninguna prueba fallida" "FALLA"
[ "$(parts)" = 0 ] && ok "…ni provisionales en el disco" || bad "quedaron provisionales tras el archivo grande"
hctl storage maxfile $HV none
hctl storage size $HV 3000000
run hs bash "$HS" --yes --speed 4;            rc_is "con el disco casi lleno (3 MB) → 0 (no se escribe, se omite)" 0
has "…lo dice" "al disco le quedan menos de 16 MiB libres"
has "…y marca omitido lo de escribir" "omitido   escribir, copiar, mover y borrar"
hasnt "…sin ninguna prueba fallida" "FALLA"
[ "$(mydirs)" = 0 ] && ok "…y no creó ninguna carpeta" || bad "creó una carpeta en un disco casi lleno"
hctl storage size $HV 8589934592

echo "== tests/usb_storage_hardware_check.sh: solo lectura y disco con errores"
hctl storage ro $HV on
SIGR=$(tree_sig "$HD")
run hs bash "$HS" --yes;                      rc_is "disco de solo lectura → 0" 0
has "…lo anota" "SOLO LECTURA"
has "…y omite escribir" "omitido   escribir, copiar, mover y borrar"
hasnt "…sin ninguna prueba fallida" "FALLA"
[ "$(tree_sig "$HD")" = "$SIGR" ] && ok "…y el disco no cambió" || bad "el disco de solo lectura cambió"
hctl storage ro $HV off
hctl storage fail $HV on
run hs bash "$HS" --yes;                      rc_is "disco que da errores → 1" 1
has "…lo cuenta" "FALLA     ls de la raíz falló"
has "…y no sigue" "sin poder leer el disco no sigo"
[ "$(mydirs)" = 0 ] && ok "…y no escribió nada" || bad "escribió en un disco con errores"
hctl storage fail $HV off

echo "== tests/usb_storage_hardware_check.sh: --keep, --unplug, --eject y Ctrl+C"
run hs bash "$HS" --yes --keep;               rc_is "--keep → 0" 0
has "…avisa de que se queda" "--keep: la carpeta"
[ "$(mydirs)" = 1 ] && ok "…y la carpeta nexo-check-* sigue en el disco" || bad "--keep no dejó su carpeta"
has "…con cómo borrarla" "nexo usb rm -r"
rm -rf "$HD"/nexo-check-*
HS_UNPLUG="printf 'storage remove $HV\n' >> '$SH/ctl'; sleep 0.6"
HS_PLUG="printf 'storage add DISCO_UNO $HV\n' >> '$SH/ctl'; sleep 0.6"
run hs bash "$HS" --yes --unplug;             rc_is "--unplug → 0" 0
hasnt "…sin ninguna prueba fallida" "FALLA"
has "…la copia se detiene sola (código 5: se fue el disco)" "la copia se detuvo sola con el código 5"
has "…el disco vuelve a montarse" "Android lo monta otra vez y Nexo lo ve"
has "…y Nexo conserva el acceso" "Nexo conserva el acceso"
has "…nada a medias con su nombre de verdad" "no quedó ningún archivo a medias con su nombre de verdad"
HS_UNPLUG=""; HS_PLUG=""
[ "$(mydirs)" = 0 ] && ok "…y al terminar no queda su carpeta" || bad "--unplug dejó su carpeta"
[ "$(parts)" = 0 ] && ok "…ni el .nexo-part-* del corte" || bad "--unplug dejó un .nexo-part-*"
run hs bash "$HS" --yes --eject;              rc_is "--eject → 0" 0
has "…Android confirma que ya no está montado" "Android confirma que ya no está montado"
run hs env -i PATH="$PATH" HOME="$SH/home" TMPDIR="$SH/tmp" NEXO_USB_DIR="$SH/state" NEXO_PORT="$SPH" NEXO_TOKEN="$TOKEN" python3 "$NU" mounts --json
jqok "…de verdad (el estado del disco es «unmounted»)" '.volumes[] | select(.uuid == "5A5A-0001") | .state == "unmounted"'
hctl storage state $HV mounted
hctl storage eject $HV silent
run hs bash "$HS" --yes --eject;              rc_is "--eject con Android que no obedece (ejectRoot no hace nada) → 0, lo cuenta como información" 0
has "…lo dice" "Android no dejó expulsar desde Nexo"
hasnt "…y no es un fallo" "FALLA"
hctl storage eject $HV ok
( hs bash "$HS" --yes --speed 64 > "$SH/term.out" 2> "$SH/term.err"; echo $? > "$SH/term.rc" ) &
for i in $(seq 200); do [ "$(mydirs)" -ge 1 ] && break; sleep 0.05; done
pkill -TERM -f '^bash [^ ]*usb_storage_hardware_check.sh --yes --speed 64' 2>/dev/null      # (solo al script, no a timeout)
for i in $(seq 300); do [ -s "$SH/term.rc" ] && break; sleep 0.1; done
[ "$(cat "$SH/term.rc" 2>/dev/null)" = 130 ] && ok "al recibir una señal de parada, el script sale con 130" || bad "salida al pararlo" "$(cat "$SH/term.rc" 2>/dev/null) $(tail -n 3 "$SH/term.out")"
[ "$(mydirs)" = 0 ] && ok "…y antes de irse borró su carpeta del disco" || bad "al pararlo quedó su carpeta en el disco"
[ "$(ls "$SH/tmp" | grep -c 'nexo-storage-check')" = 0 ] && ok "…y sus temporales" || bad "al pararlo quedaron temporales"
run hs env -i PATH="$PATH" HOME="$SH/home" TMPDIR="$SH/tmp" NEXO_USB_DIR="$SH/state" NEXO_PORT="$SPH" NEXO_TOKEN="$TOKEN" python3 "$NU" mounts --json
jqok "…y la app no tiene archivos abiertos" '.open_files == 0'

echo "== nexo usb: nada se queda abierto"
[ "$(openfiles)" = 0 ] && ok "al final no hay archivos abiertos en la app" || bad "quedaron archivos abiertos al final" "$(openfiles)"
[ "$(parts)" = 0 ] && ok "…ni restos .nexo-part en ningún disco" || bad "quedaron restos al final" "$(find "$SD/discos" -name '.nexo-part-*')"
run sn status --json;                         eq "…ni puentes serie" "[]"
