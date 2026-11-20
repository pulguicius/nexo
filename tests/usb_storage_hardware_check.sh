#!/usr/bin/env bash
# Prueba REAL de los discos de «nexo usb» con un pendrive, un disco duro o un SSD enchufado al móvil.
#
# QUÉ ES: las pruebas automáticas (tests/usb_storage_tests.sh) hablan con una app FALSA cuyos «discos» son carpetas: prueban el cliente y el
# protocolo, no que Android monte TU disco, que el selector de carpetas te deje elegirlo, ni que se pueda leer y escribir de verdad.
# Esto es lo que solo se puede hacer con el móvil y el disco delante. Se ejecuta en Termux (o en una distro) con la app Nexo en marcha y
# nexo-usb instalado, y al final imprime un informe que puedes copiar y pegar: no lleva tu token ni los nombres de tus archivos (sí la
# etiqueta y el UUID del disco, y cuántas entradas tiene su raíz).
#
# SEGURIDAD: solo escribe dentro de UNA carpeta que crea ella misma en la raíz del disco («nexo-check-NNNNN»). Al terminar la borra y
# comprueba que la raíz quedó con los mismos nombres que tenía. No formatea, no toca nada más y no usa más permisos que «nexo usb».
# Si la interrumpes (Ctrl+C), intenta borrar su carpeta igualmente; si no pudo, el informe te lo dice.
#
# USO:   bash tests/usb_storage_hardware_check.sh [DISCO] [--speed MIB] [--big MIB] [--eject] [--unplug] [--keep] [--yes]
#   DISCO      lo mismo que en «nexo usb mounts» (UUID o parte de la etiqueta); sin él, el único disco montado
#   --speed N  además, mide la velocidad: escribe y lee un archivo de N MiB (N de 1 a 4096)
#   --big N    además, intenta guardar un archivo de N MiB (N de 1 a 65536): con 4200 se ve el límite de 4 GiB de FAT32 (tarda y necesita ese espacio libre)
#   --eject    además, prueba la expulsión (lo último que hace: el disco queda expulsado y hay que desenchufarlo y volver a enchufarlo)
#   --unplug   además, te pide desenchufar el disco en mitad de una copia y volver a enchufarlo (comprueba que nada se cuelga ni queda a medias
#              con su nombre, y que Android recuerda el permiso)
#   --keep     no borra su carpeta al terminar (para mirarla)
#   --yes      no espera a que pulses Enter (para automatizar)
# Siempre hace lo básico: ver el disco, pedir el acceso, leer la raíz, y —si el disco deja escribir— crear, copiar de ida y vuelta (SHA‑256),
# mover, renombrar, borrar y probar nombres difíciles, todo dentro de su carpeta.
# Códigos de salida: 0 todo bien · 1 alguna prueba falló · 2 uso incorrecto.

set -u
NX=${NEXO_CHECK_BIN:-nexo}                       # (las pruebas automáticas lo apuntan a su copia)
DISK=""; SPEED=0; BIG=0; DO_EJ=0; DO_UNP=0; KEEP=0; YES=0
while [ $# -gt 0 ]; do
    case $1 in
        --speed) SPEED=${2:-}; shift ;;
        --big) BIG=${2:-}; shift ;;
        --eject) DO_EJ=1 ;;
        --unplug) DO_UNP=1 ;;
        --keep) KEEP=1 ;;
        --yes|-y) YES=1 ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "Opción desconocida: $1 (mira --help)" >&2; exit 2 ;;
        *) if [ -z "$DISK" ]; then DISK=$1; else echo "Solo se puede probar un disco a la vez." >&2; exit 2; fi ;;
    esac
    shift
done
case $SPEED in ''|*[!0-9]*) echo "--speed pide un número de MiB (por ejemplo 64)." >&2; exit 2 ;; esac
case $BIG in ''|*[!0-9]*) echo "--big pide un número de MiB (por ejemplo 4200)." >&2; exit 2 ;; esac
[ "$SPEED" -le 4096 ] || { echo "--speed: como mucho 4096 MiB." >&2; exit 2; }
[ "$BIG" -le 65536 ] || { echo "--big: como mucho 65536 MiB." >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "Falta python3 (Termux: pkg install python)." >&2; exit 2; }
command -v "$NX" >/dev/null 2>&1 || { echo "No encuentro «$NX». Instala Nexo (el comando de instalación de la app) y vuelve a probar." >&2; exit 2; }

W=$(mktemp -d "${TMPDIR:-/tmp}/nexo-storage-check.XXXXXX") || exit 1
PASS=0; FAIL=0; SKIP=0; INFO=0
REPORT=$W/report; : > "$REPORT"
UUID=""            # el disco que se prueba
RDIR=""            # su carpeta de prueba en el disco (la que se borra al salir)
RDIR_GONE=0        # 1 cuando ya se borró y se comprobó
NOTE_LEFT=""       # si algo quedó sin borrar, lo que quedó
cleanup() {
    if [ -n "$RDIR" ] && [ "$RDIR_GONE" = 0 ] && [ "$KEEP" = 0 ] && [ -n "$UUID" ]; then
        "$NX" usb rm -rf "$RDIR" --vol "$UUID" --via app --no-ask >/dev/null 2>&1 \
            || echo "  (no pude borrar la carpeta de prueba $RDIR del disco: bórrala con «nexo usb rm -r $RDIR»)" >&2
    fi
    rm -rf "$W"
}
trap cleanup EXIT
trap 'trap "" INT TERM; echo; echo "  (interrumpido)"; exit 130' INT TERM       # (un segundo Ctrl+C no debe cortar la limpieza)

say()  { printf '%s\n' "$*"; }
note() { printf '           %s\n' "$*"; printf '           %s\n' "$*" >> "$REPORT"; }
ok()   { PASS=$((PASS + 1)); printf '  ok        %s\n' "$1"; printf 'ok        %s\n' "$1" >> "$REPORT"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FALLA     %s\n' "$1"; printf 'FALLA     %s\n' "$1" >> "$REPORT"; [ -n "${2:-}" ] && note "$2"; return 0; }
skip() { SKIP=$((SKIP + 1)); printf '  omitido   %s\n' "$1"; printf 'omitido   %s\n' "$1" >> "$REPORT"; [ -n "${2:-}" ] && note "$2"; return 0; }
info() { INFO=$((INFO + 1)); printf '  info      %s\n' "$1"; printf 'info      %s\n' "$1" >> "$REPORT"; [ -n "${2:-}" ] && note "$2"; return 0; }

# pause MENSAJE [ORDEN]: espera a que hagas algo en el móvil. Con ORDEN (solo para las pruebas automáticas) la ejecuta en vez de esperar.
pause() {
    say "  →  $1"
    if [ -n "${2:-}" ]; then eval "$2"
    elif [ "$YES" = 0 ]; then read -r -p "     (pulsa Enter cuando lo hayas hecho) " _ || true
    fi
}

short() { printf '%s' "$1" | head -c "${2:-200}" | tr '\n\r' '  '; }
# pj ARCHIVO EXPRESIÓN → evalúa una expresión de Python sobre el JSON del archivo (d). Las expresiones las escribe este script, no el usuario.
pj() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null; }
ms() { python3 -c 'import time; print(int(time.monotonic() * 1000))'; }

u()  { "$NX" usb "$@"; }                                          # órdenes sin disco (mounts, access)
fs() { "$NX" usb "$@" --vol "$UUID" --via app --no-ask; }         # órdenes del disco: siempre por la app (es lo que se quiere probar)
# cap ORDEN…: la ejecuta y deja RC, OUT y ERR
cap() { "$@" > "$W/o.out" 2> "$W/o.err"; RC=$?; OUT=$(cat "$W/o.out"); ERR=$(cat "$W/o.err"); return 0; }
rcis() { if [ "$RC" = "$2" ]; then ok "$1"; else bad "$1" "código $RC (se esperaba $2): $(short "$ERR$OUT" 300)"; fi; }
has()  { if printf '%s\n%s\n' "$OUT" "$ERR" | grep -qF -- "$2"; then ok "$1"; else bad "$1" "no aparece «$2» en: $(short "$ERR$OUT" 300)"; fi; }
# existe RUTA → 0 si existe en el disco
existe() { "$NX" usb stat "$1" --vol "$UUID" --via app --no-ask > /dev/null 2>&1; }

read -r -d '' PYSAME <<'PY'
import hashlib, os, sys
a, b, names = sys.argv[1], sys.argv[2], sys.argv[3:]
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()
bad = []
for n in names:
    pa, pb = os.path.join(a, n), os.path.join(b, n)
    if not os.path.isfile(pb): bad.append("falta " + n); continue
    if os.path.getsize(pa) != os.path.getsize(pb): bad.append("otro tamaño: " + n); continue
    if sha(pa) != sha(pb): bad.append("otro contenido: " + n)
print("OK" if not bad else "; ".join(bad))
PY
read -r -d '' PYTREE <<'PY'
import hashlib, os, sys
a, b = sys.argv[1], sys.argv[2]
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()
def walk(r):
    out = {}
    for d, ds, fs_ in os.walk(r):
        for n in ds: out[os.path.relpath(os.path.join(d, n), r) + "/"] = None
        for n in fs_:
            p = os.path.join(d, n)
            out[os.path.relpath(p, r)] = (os.path.getsize(p), sha(p))
    return out
x, y = walk(a), walk(b)
bad = ["falta " + k for k in sorted(x) if k not in y] + ["sobra " + k for k in sorted(y) if k not in x] + \
      ["distinto " + k for k in sorted(x) if k in y and x[k] != y[k]]
print("OK %d" % len(x) if not bad else "; ".join(bad[:8]))
PY
same()     { python3 -c "$PYSAME" "$@"; }
treesame() { python3 -c "$PYTREE" "$@"; }
sha() { python3 -c 'import hashlib,sys; h=hashlib.sha256(); f=open(sys.argv[1],"rb"); [h.update(c) for c in iter(lambda: f.read(1<<20), b"")]; print(h.hexdigest())' "$1"; }
# rootnames → "N HASH" de los nombres de la raíz del disco (con los ocultos): sirve para comprobar que queda igual
rootnames() {
    "$NX" usb ls -a --json / --vol "$UUID" --via app --no-ask 2>/dev/null | python3 -c '
import hashlib, json, sys
d = json.load(sys.stdin)
n = sorted(e["name"] for l in d["listings"] for e in l["entries"])
print(len(n), hashlib.sha256("\n".join(n).encode("utf-8")).hexdigest()[:16])' 2>/dev/null
}
# names RUTA → los nombres que hay en esa carpeta del disco, uno por línea
names() {
    "$NX" usb ls -a --json "$1" --vol "$UUID" --via app --no-ask 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
for l in d["listings"]:
    for e in l["entries"]:
        print(e["name"])' 2>/dev/null
}
fail_early_skip() { skip "$1" "(no se pudo con lo anterior)"; }

# ----------------------------------------------------------------------------------------------------------------- 1. Entorno
say "== 1. Entorno"
{
    echo "fecha        $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "sistema      $(uname -srm 2>/dev/null)"
    echo "python3      $(python3 --version 2>&1)"
    echo "nexo         $("$NX" version --check 2>&1 | head -n 3 | tr '\n' ' ')"
    echo "nexo-usb     $("$NX" usb version 2>&1 | head -n 1)"
} > "$W/env.txt"
sed 's/^/     /' "$W/env.txt"

# ------------------------------------------------------------------------------------------------------------------ 2. El disco
say "== 2. El disco"
FAIL_EARLY=0; RO=0; FREE=0; TOTAL=0
u mounts --json > "$W/mounts.json" 2> "$W/mounts.err"; rc=$?
if [ "$rc" -ne 0 ]; then
    bad "«nexo usb mounts» falló (código $rc)" "$(short "$(cat "$W/mounts.err")" 300)"
    note "10 = la app no responde (¿está encendido el puente?) · 11 = token · mira «nexo doctor»"
    FAIL_EARLY=1
elif [ "$(pj "$W/mounts.json" 'd.get("available")')" != True ]; then
    bad "la app no maneja discos (¿es anterior a la 0.4.2?) o el móvil no tiene servicio de almacenamiento"; FAIL_EARLY=1
else
    ok "la app maneja discos (protocolo con storage.*)"
    python3 - "$W/mounts.json" "$DISK" "$W/vol.json" > "$W/pick.txt" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
raw = sys.argv[2].strip()
sel = raw.lower()
vols = [v for v in d.get("volumes", []) if not v.get("primary")]
def label(v): return v.get("label") or "(sin nombre)"
if sel:
    c = [v for v in vols if sel == (v.get("uuid") or "").lower() or sel == (v.get("label") or "").lower()] or \
        [v for v in vols if (v.get("uuid") or "").lower().startswith(sel) or (v.get("label") or "").lower().startswith(sel)] or \
        [v for v in vols if sel in (v.get("uuid") or "").lower() or sel in (v.get("label") or "").lower()]
else:
    c = [v for v in vols if v.get("mounted")]
if len(c) == 1:
    v = c[0]
    out = dict(v)
    if out.get("scope"): out["scope"] = "(una carpeta)"
    json.dump(out, open(sys.argv[3], "w"), ensure_ascii=False)
    print("\t".join(["ok", v["uuid"], label(v), str(v.get("state")), str(bool(v.get("mounted"))), str(bool(v.get("readonly"))),
                     str(v.get("total") if v.get("total") is not None else -1), str(v.get("free") if v.get("free") is not None else -1)]))
elif not c:
    print("\t".join(["none", ("ningún disco coincide con «%s»" % raw) if sel else "no hay ningún disco USB montado"]))
else:
    print("\t".join(["many", "; ".join("%s «%s» (%s)" % (v["uuid"], label(v), v.get("state")) for v in c)]))
PY
    IFS=$'\t' read -r st f1 f2 f3 f4 f5 f6 f7 < "$W/pick.txt"
    case $st in
        ok)
            UUID=$f1; TOTAL=$f6; FREE=$f7
            if [ "$f4" = True ]; then
                ok "Android tiene montado el disco «$f2» ($f1)"
                note "estado: $f3 · solo lectura: $f5 · total: $f6 B · libre: $f7 B"
                [ "$f5" = True ] && RO=1
            else
                bad "el disco «$f2» ($f1) está en estado «$f3»: no está montado"
                note "Android no lo montó: sin sistema de archivos que entienda, dañado, o expulsado. Enchúfalo otra vez"
                FAIL_EARLY=1
            fi
            [ "$(pj "$W/mounts.json" 'd.get("mass_storage_devices", 0)')" != 0 ] && note "dispositivos de almacenamiento USB que ve Android: $(pj "$W/mounts.json" 'd.get("mass_storage_devices")')"
            ;;
        none) bad "no encuentro el disco: $f1"; note "enchúfalo (cable OTG, un hub con corriente si es un disco duro) y mira «nexo usb mounts»"; FAIL_EARLY=1 ;;
        many) bad "hay varios discos: indica cuál (UUID o parte de la etiqueta)"; note "$f1"; FAIL_EARLY=1 ;;
        *) bad "no pude elegir el disco"; FAIL_EARLY=1 ;;
    esac
fi
NOWRITE=""          # si no está vacío, por qué no se escribe en el disco
[ "$RO" = 1 ] && NOWRITE="el disco está montado en SOLO LECTURA"
if [ -z "$NOWRITE" ] && [ "$FREE" -ge 0 ] 2>/dev/null && [ "$FREE" -lt $((16 * 1048576)) ]; then
    NOWRITE="al disco le quedan menos de 16 MiB libres (la prueba necesita unos 16)"
fi
[ -n "$NOWRITE" ] && [ "$FAIL_EARLY" = 0 ] && info "$NOWRITE: se omiten las pruebas de escritura"

# ----------------------------------------------------------------------------------------------------------------- 3. El acceso
if [ "$FAIL_EARLY" = 0 ]; then
    say "== 3. El acceso de Nexo al disco"
    if [ "$(pj "$W/vol.json" 'd.get("granted")')" = True ]; then
        ok "Nexo ya tenía acceso (Android recordó el permiso de otra vez)"
    else
        pause "Va a abrirse el selector de carpetas de Android: busca tu disco (≡ arriba a la izquierda), entra en él y pulsa «Usar esta carpeta» → «Permitir»." ""
        cap u access "$UUID" --timeout 120
        if [ "$RC" = 0 ]; then ok "acceso concedido"; else bad "«nexo usb access» salió con $RC" "$(short "$ERR$OUT" 300)"; note "3 = no lo concediste a tiempo · mira «nexo logs 25»"; FAIL_EARLY=1; fi
    fi
    if [ "$FAIL_EARLY" = 0 ]; then
        cap u mounts --json
        printf '%s\n' "$OUT" > "$W/mounts2.json"
        SC=$(pj "$W/mounts2.json" 'next((v.get("scope") for v in d["volumes"] if v["uuid"] == "'"$UUID"'"), None)')
        if [ "$SC" = "" ] || [ "$SC" = "None" ]; then ok "el acceso es al disco entero"; else info "el acceso es a UNA CARPETA del disco (no a todo): esa carpeta es la raíz para Nexo"; fi
        cap u df --vol "$UUID" --json
        if [ "$RC" = 0 ] && python3 -c 'import json,sys; d=json.loads(sys.argv[1]); v=(d if isinstance(d, list) else d.get("volumes", []))[0]; sys.exit(0 if v["total"] and 0 <= v["free"] <= v["total"] else 1)' "$OUT" 2>/dev/null; then
            ok "df: el espacio libre cabe en el total"
        else bad "df no da un total y un libre coherentes" "$(short "$ERR$OUT" 300)"; fi
    fi
fi

# ----------------------------------------------------------------------------------------------------------- 4. Leer la raíz
if [ "$FAIL_EARLY" = 0 ]; then
    say "== 4. Leer"
    cap fs ls -a --json /
    if [ "$RC" = 0 ]; then
        ok "ls de la raíz → 0"
        ROOT0=$(rootnames)
        if [ -n "$ROOT0" ]; then ok "la raíz tiene ${ROOT0%% *} entradas (el informe no lleva sus nombres)"; else bad "no pude contar las entradas de la raíz"; FAIL_EARLY=1; fi
        cap fs stat /;                        rcis "stat de la raíz → 0" 0
        has "…y dice que es una carpeta" "carpeta"
    else
        bad "ls de la raíz falló (código $RC): sin poder leer el disco no sigo" "$(short "$ERR$OUT" 300)"
        FAIL_EARLY=1
    fi
fi

# ---------------------------------------------------------------------------------------------------------- 5. Escribir y copiar
WROTE=0
if [ "$FAIL_EARLY" = 0 ] && [ -z "$NOWRITE" ]; then
    say "== 5. Escribir, copiar de ida y vuelta, mover y borrar (todo dentro de una carpeta propia)"
    RDIR="/nexo-check-$(printf '%05d' $((RANDOM % 100000)))"
    if existe "$RDIR"; then bad "la carpeta de prueba $RDIR ya existe (muy raro): vuelve a ejecutar"; FAIL_EARLY=1; RDIR=""; fi
fi
if [ "$FAIL_EARLY" = 0 ] && [ -z "$NOWRITE" ]; then
    cap fs mkdir "$RDIR";                     rcis "mkdir $RDIR → 0" 0
    if [ "$RC" != 0 ]; then FAIL_EARLY=1; RDIR=""; fi
fi
if [ "$FAIL_EARLY" = 0 ] && [ -z "$NOWRITE" ]; then
    WROTE=1
    cap fs mkdir "$RDIR";                     rcis "mkdir de algo que ya existe → 1 (ya existe)" 1
    cap fs mkdir -p "$RDIR/a/b/c";            rcis "mkdir -p de tres niveles → 0" 0
    cap fs rm -r "$RDIR/a";                   rcis "rm -r de esas carpetas → 0" 0

    mkdir -p "$W/loc" "$W/back"
    python3 - "$W/loc" <<'PY'
import os, sys
d = sys.argv[1]
def w(name, data):
    with open(os.path.join(d, name), "wb") as f:
        f.write(data)
w("vacio.bin", b"")
w("uno.bin", b"\x00")
for n in (4095, 4096, 4097):
    w("%d.bin" % n, os.urandom(n))
w("medio mega.bin", os.urandom(1024 * 1024 + 13))
w("tres mega.bin", os.urandom(3 * 1024 * 1024 + 5))
w("Música ñandú.txt", "línea 1\nlínea 2 con acentos: áéíóú ñ ü\n".encode("utf-8"))
w("Cumpleaños 🎂 año.txt", "felicidades\n".encode("utf-8"))
w("a:b.txt", b"dos puntos\n")
w("Mayus.txt", b"M\n")
w("mayus.txt", b"m\n")
PY
    GOOD=("vacio.bin" "uno.bin" "4095.bin" "4096.bin" "4097.bin" "medio mega.bin" "tres mega.bin" "Música ñandú.txt")
    for f in "${GOOD[@]}"; do
        cap fs put "$W/loc/$f" "$RDIR/" --verify
        if [ "$RC" = 0 ]; then ok "put --verify de «$f» ($(wc -c < "$W/loc/$f" | tr -d ' ') bytes)"; else bad "put de «$f» falló" "código $RC: $(short "$ERR$OUT" 300)"; fi
    done

    # lo que dice el disco: nombres y tamaños
    fs ls -a --json "$RDIR" > "$W/list.json" 2> /dev/null
    python3 - "$W/list.json" "$W/loc" > "$W/sizes.txt" "${GOOD[@]}" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
got = {e["name"]: e["size"] for l in d["listings"] for e in l["entries"]}
bad = []
for n in sys.argv[3:]:
    if n not in got: bad.append("no sale " + n)
    elif got[n] != os.path.getsize(os.path.join(sys.argv[2], n)): bad.append("tamaño de %s: %s en vez de %s" % (n, got[n], os.path.getsize(os.path.join(sys.argv[2], n))))
print("OK" if not bad else "; ".join(bad))
PY
    [ "$(cat "$W/sizes.txt")" = OK ] && ok "ls enseña los ${#GOOD[@]} archivos con el tamaño exacto" || bad "ls no coincide con lo copiado" "$(cat "$W/sizes.txt")"
    names "$RDIR" | grep -qE '\.nexo-part-' && bad "quedó algún .nexo-part-… (archivo provisional) en el disco" || ok "no queda ningún archivo provisional (.nexo-part-…)"

    cap fs get -r "$RDIR" "$W/back/uno"
    if [ "$RC" = 0 ]; then
        R=$(same "$W/loc" "$W/back/uno" "${GOOD[@]}")
        [ "$R" = OK ] && ok "get -r: los ${#GOOD[@]} archivos vuelven idénticos (SHA‑256)" || bad "get -r: lo que vuelve no es lo que se mandó" "$R"
    else bad "get -r de la carpeta de prueba falló" "código $RC: $(short "$ERR$OUT" 300)"; fi
    cap fs cat "$RDIR/4097.bin"
    fs cat "$RDIR/4097.bin" > "$W/cat.out" 2> /dev/null
    cmp -s "$W/cat.out" "$W/loc/4097.bin" && ok "cat devuelve el archivo idéntico" || bad "cat devolvió otra cosa"
    cap fs cat "$RDIR/medio mega.bin" "$RDIR/uno.bin"
    fs cat "$RDIR/medio mega.bin" "$RDIR/uno.bin" > "$W/cat2.out" 2> /dev/null
    cat "$W/loc/medio mega.bin" "$W/loc/uno.bin" | cmp -s - "$W/cat2.out" && ok "cat de dos archivos los une en orden" || bad "cat de dos archivos devolvió otra cosa"

    # nombres con emoji (depende del disco: informativo si no se puede)
    cap fs put "$W/loc/Cumpleaños 🎂 año.txt" "$RDIR/"
    if [ "$RC" = 0 ]; then
        fs cat "$RDIR/Cumpleaños 🎂 año.txt" > "$W/emoji.out" 2> /dev/null
        cmp -s "$W/emoji.out" "$W/loc/Cumpleaños 🎂 año.txt" && ok "un nombre con emoji («Cumpleaños 🎂 año.txt») se guarda y se lee igual" || bad "el archivo con emoji volvió distinto"
    else
        info "este disco o este Android no admite emoji en los nombres (no es un fallo de Nexo)" "código $RC: $(short "$ERR$OUT" 200)"
    fi

    # un árbol de carpetas con una carpeta vacía
    mkdir -p "$W/tree/a/b/c" "$W/tree/vacia"
    printf 'profundo\n' > "$W/tree/a/b/c/hondo.txt"
    python3 -c 'import os,sys; open(sys.argv[1],"wb").write(os.urandom(100*1024))' "$W/tree/a/b/x.bin"
    printf 'y\n' > "$W/tree/a/y.txt"
    printf 'z\n' > "$W/tree/z.txt"
    cap fs put -r "$W/tree" "$RDIR/arbol";    rcis "put -r de un árbol de carpetas → 0" 0
    cap fs get -r "$RDIR/arbol" "$W/tree_back"
    if [ "$RC" = 0 ]; then
        R=$(treesame "$W/tree" "$W/tree_back")
        case $R in OK*) ok "el árbol vuelve idéntico (${R#OK } elementos, con su carpeta vacía)" ;; *) bad "el árbol que vuelve no es el que se mandó" "$R" ;; esac
    else bad "get -r del árbol falló" "código $RC: $(short "$ERR$OUT" 300)"; fi

    # lo que ya existe
    cap fs put "$W/loc/4095.bin" "$RDIR/4095.bin";            rcis "put sobre algo que ya existe → 1" 1
    has "…y dice cómo seguir (-f o -n)" "usa -f"
    cap fs put -n "$W/loc/4095.bin" "$RDIR/4095.bin";         rcis "put -n sobre algo que ya existe → 0 (lo salta)" 0
    cap fs put -f "$W/loc/4097.bin" "$RDIR/4095.bin";         rcis "put -f lo sustituye → 0" 0
    fs cat "$RDIR/4095.bin" > "$W/over.out" 2> /dev/null
    cmp -s "$W/over.out" "$W/loc/4097.bin" && ok "…y el contenido es el nuevo, entero (sin restos del anterior)" || bad "tras put -f el archivo no tiene el contenido nuevo"

    # mover y renombrar
    cap fs mv "$RDIR/uno.bin" "$RDIR/uno renombrado.bin";     rcis "mv (renombrar) → 0" 0
    existe "$RDIR/uno.bin" && bad "…el nombre viejo sigue existiendo" || ok "…el nombre viejo ya no existe"
    existe "$RDIR/uno renombrado.bin" && ok "…y el nuevo sí" || bad "…y el nombre nuevo no existe"
    cap fs mv "$RDIR/4096.bin" "$RDIR/4097.bin";             rcis "mv sobre algo que ya existe → 1" 1
    cap fs mv -f "$RDIR/4096.bin" "$RDIR/4097.bin";          rcis "mv -f lo sustituye → 0" 0
    fs cat "$RDIR/4097.bin" > "$W/mvf.out" 2> /dev/null
    cmp -s "$W/mvf.out" "$W/loc/4096.bin" && ok "…y queda el contenido del que se movió" || bad "tras mv -f el contenido no es el esperado"
    cap fs mkdir "$RDIR/carpeta";             cap fs mv "$RDIR/arbol" "$RDIR/carpeta/arbol2";   rcis "mv de una carpeta a otra carpeta → 0" 0
    cap fs get -r "$RDIR/carpeta/arbol2" "$W/tree_back2"
    R=$(treesame "$W/tree" "$W/tree_back2")
    case $R in OK*) ok "…y todo lo que tenía sigue ahí" ;; *) bad "tras mover la carpeta le falta algo" "$R" ;; esac

    # nombres difíciles
    cap fs put "$W/loc/a:b.txt" "$RDIR/";                    rcis "put de «a:b.txt» (los discos USB no admiten «:») → 1" 1
    has "…y lo dice" "carácter"
    existe "$RDIR/a:b.txt" && bad "…pero quedó un archivo con ese nombre" || ok "…y no queda nada con ese nombre ni parecido"
    cap fs put --fix-names "$W/loc/a:b.txt" "$RDIR/";        rcis "put --fix-names lo cambia por «_» → 0" 0
    existe "$RDIR/a_b.txt" && ok "…y existe «a_b.txt»" || bad "…pero no existe «a_b.txt»"
    cap fs put "$W/loc/Mayus.txt" "$RDIR/Mayus.txt";         rcis "put de «Mayus.txt» → 0" 0
    cap fs put "$W/loc/mayus.txt" "$RDIR/mayus.txt"
    if [ "$RC" = 0 ]; then
        info "el disco DISTINGUE mayúsculas de minúsculas (ext4, NTFS en Linux…): «Mayus.txt» y «mayus.txt» son dos archivos"
    else
        info "el disco NO distingue mayúsculas de minúsculas (FAT, exFAT…): el segundo put dijo «ya existe»" "código $RC: $(short "$ERR$OUT" 160)"
    fi
    if names "$RDIR" | grep -qE '\([0-9]+\)'; then bad "Android dejó un archivo renombrado con « (1)» al chocar los nombres" "$(names "$RDIR" | grep -E '\([0-9]+\)' | head -n 3 | tr '\n' ' ')"; else ok "…y no quedó ningún archivo « (1)» de los que Android inventa al chocar dos nombres"; fi
    # cambiar SOLO las mayúsculas: en un disco que no las distingue, depende de Android (puede negarse a «renombrar a lo mismo»)
    cap fs mv "$RDIR/Mayus.txt" "$RDIR/MAYUS.txt"
    if [ "$RC" = 0 ]; then
        ok "mv que solo cambia las mayúsculas («Mayus.txt» → «MAYUS.txt») → 0"
        if names "$RDIR" | grep -qxF "MAYUS.txt"; then ok "…y el nombre queda con las mayúsculas nuevas"
        elif names "$RDIR" | grep -qxF "Mayus.txt"; then info "…pero el disco conservó las mayúsculas de antes («Mayus.txt»): FAT hace eso a veces" "no es un fallo de Nexo"
        else bad "…pero ya no existe ni «MAYUS.txt» ni «Mayus.txt»"; fi
    else
        info "Android no dejó cambiar solo las mayúsculas de un nombre (código $RC)" "$(short "$ERR$OUT" 240) · si te hace falta, renómbralo en dos pasos (por otro nombre y luego el que quieres)"
        existe "$RDIR/Mayus.txt" && ok "…y el archivo sigue con su nombre de antes" || bad "…pero el archivo desapareció"
    fi

    # borrar
    cap fs rm "$RDIR/carpeta";                rcis "rm de una carpeta sin -r → 1" 1
    existe "$RDIR/carpeta" && ok "…y la carpeta sigue ahí, con todo" || bad "…pero la carpeta desapareció"
    cap fs rm "$RDIR/vacio.bin";              rcis "rm de un archivo → 0" 0
    existe "$RDIR/vacio.bin" && bad "…el archivo sigue existiendo" || ok "…y ya no existe"
    cap fs rm -r "$RDIR/carpeta";             rcis "rm -r de la carpeta con su árbol → 0" 0
    existe "$RDIR/carpeta" && bad "…la carpeta sigue existiendo" || ok "…y ya no existe"
    cap fs rm "$RDIR/no-existe.txt";          rcis "rm de algo que no existe → 1" 1
    cap fs rm -f "$RDIR/no-existe.txt";       rcis "rm -f de algo que no existe → 0" 0

    cap u mounts --json
    OF=$(printf '%s\n' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("open_files"))' 2>/dev/null)
    [ "$OF" = 0 ] && ok "no queda ningún archivo abierto en la app" || bad "la app dice que quedan archivos abiertos: $OF"
elif [ -n "$NOWRITE" ]; then
    skip "escribir, copiar, mover y borrar" "$NOWRITE"
else
    skip "escribir, copiar, mover y borrar" "(no se pudo con lo anterior)"
fi

# ------------------------------------------------------------------------------------------------------------------ 6. Velocidad
if [ "$SPEED" -gt 0 ]; then
    if [ "$WROTE" = 1 ]; then
        say "== 6. Velocidad ($SPEED MiB)"
        if [ "$FREE" -gt 0 ] 2>/dev/null && [ "$FREE" -lt $((SPEED * 1048576 + 8388608)) ]; then
            skip "velocidad" "al disco le quedan menos de $SPEED MiB libres"
        else
            python3 -c '
import os, sys
n = int(sys.argv[2]) * 1024 * 1024
with open(sys.argv[1], "wb") as f:
    left = n
    while left:
        c = min(left, 1 << 20)
        f.write(os.urandom(c))
        left -= c' "$W/speed.bin" "$SPEED"
            t0=$(ms); cap fs put -q "$W/speed.bin" "$RDIR/velocidad.bin"; t1=$(ms)
            if [ "$RC" = 0 ]; then
                ok "put de $SPEED MiB"
                note "escribir: $(python3 -c 'import sys; s=int(sys.argv[1]); t=max(int(sys.argv[2]), 1); print("%.1f MiB/s (%.1f s)" % (s * 1000.0 / t, t / 1000.0))' "$SPEED" $((t1 - t0)))"
                echo "escritura   $SPEED MiB en $(( (t1 - t0) )) ms" >> "$W/speed.txt"
                t2=$(ms); cap fs get -q "$RDIR/velocidad.bin" "$W/speed.back"; t3=$(ms)
                if [ "$RC" = 0 ]; then
                    note "leer: $(python3 -c 'import sys; s=int(sys.argv[1]); t=max(int(sys.argv[2]), 1); print("%.1f MiB/s (%.1f s)" % (s * 1000.0 / t, t / 1000.0))' "$SPEED" $((t3 - t2)))"
                    echo "lectura     $SPEED MiB en $(( (t3 - t2) )) ms" >> "$W/speed.txt"
                    [ "$(sha "$W/speed.bin")" = "$(sha "$W/speed.back")" ] && ok "los $SPEED MiB vuelven idénticos (SHA‑256)" || bad "los $SPEED MiB que vuelven no son los que se mandaron"
                else bad "get de $SPEED MiB falló" "código $RC: $(short "$ERR$OUT" 300)"; fi
            else bad "put de $SPEED MiB falló" "código $RC: $(short "$ERR$OUT" 300)"; fi
            cap fs rm -f "$RDIR/velocidad.bin"
            rm -f "$W/speed.bin" "$W/speed.back"
        fi
    else
        skip "velocidad" "(sin escritura no se puede medir)"
    fi
fi

# ----------------------------------------------------------------------------------------------------------- 7. Un archivo enorme
if [ "$BIG" -gt 0 ]; then
    if [ "$WROTE" = 1 ]; then
        say "== 7. Un archivo de $BIG MiB"
        if [ "$FREE" -gt 0 ] 2>/dev/null && [ "$FREE" -lt $((BIG * 1048576 + 8388608)) ]; then
            skip "archivo de $BIG MiB" "al disco le quedan menos de $BIG MiB libres"
        else
            python3 -c 'import sys; f=open(sys.argv[1],"wb"); f.truncate(int(sys.argv[2])*1024*1024)' "$W/big.bin" "$BIG"
            cap fs put -q "$W/big.bin" "$RDIR/grande.bin"
            if [ "$RC" = 0 ]; then
                SZ=$(fs stat --json "$RDIR/grande.bin" 2> /dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("size"))' 2>/dev/null)
                if [ "$SZ" = "$((BIG * 1048576))" ]; then ok "el disco aceptó un archivo de $BIG MiB y tiene el tamaño exacto (no es FAT32, o es menor de 4 GiB)"; else bad "el archivo de $BIG MiB quedó con otro tamaño: $SZ" "esperado $((BIG * 1048576))"; fi
            else
                if printf '%s\n%s\n' "$OUT" "$ERR" | grep -qF "no admite un archivo tan grande"; then
                    ok "el disco rechazó el archivo de $BIG MiB con un mensaje claro (es FAT32: máximo 4 GiB por archivo)"
                    existe "$RDIR/grande.bin" && bad "…pero quedó un grande.bin a medias con el nombre bueno" || ok "…y no quedó nada con el nombre bueno"
                else bad "put de $BIG MiB falló por otra causa" "código $RC: $(short "$ERR$OUT" 300)"; fi
            fi
            names "$RDIR" | grep -qE '\.nexo-part-' && bad "quedó un archivo provisional (.nexo-part-…) tras el archivo grande" || ok "no queda ningún archivo provisional"
            cap fs rm -f "$RDIR/grande.bin"
            rm -f "$W/big.bin"
        fi
    else
        skip "archivo de $BIG MiB" "(sin escritura no se puede probar)"
    fi
fi

# ----------------------------------------------------------------------------------------------------- 8. Desenchufar a media copia
if [ "$DO_UNP" = 1 ]; then
    if [ "$WROTE" = 1 ]; then
        say "== 8. Desenchufar a media copia"
        UN=1024
        if [ "$FREE" -gt 0 ] 2>/dev/null && [ "$FREE" -lt $((UN * 1048576 * 2)) ]; then UN=$(( FREE / 1048576 / 2 )); [ "$UN" -ge 64 ] || UN=64; fi
        python3 -c 'import sys; f=open(sys.argv[1],"wb"); f.truncate(int(sys.argv[2])*1024*1024)' "$W/unp.bin" "$UN"
        rm -f "$W/unp.rc"
        ( fs put -q "$W/unp.bin" "$RDIR/desenchufar.bin" > "$W/unp.out" 2>&1; echo $? > "$W/unp.rc" ) &
        UPID=$!
        for _ in $(seq 120); do
            names "$RDIR" | grep -qE '\.nexo-part-' && break
            [ -s "$W/unp.rc" ] && break
            sleep 0.5
        done
        if [ -s "$W/unp.rc" ]; then
            skip "desenchufar" "la copia de $UN MiB terminó antes de poder pedirte que desenchufes (el disco es muy rápido); prueba con más espacio libre"
        else
            pause "DESENCHUFA el cable del disco AHORA: la copia de $UN MiB está en marcha." "${NEXO_CHECK_HOOK_UNPLUG:-}"
            for _ in $(seq 180); do [ -s "$W/unp.rc" ] && break; sleep 0.5; done
            if [ -s "$W/unp.rc" ]; then
                URC=$(cat "$W/unp.rc")
                case $URC in
                    0) skip "desenchufar" "la copia terminó bien: lo desenchufaste demasiado tarde" ;;
                    5) ok "la copia se detuvo sola con el código 5 (el disco se desenchufó), sin colgarse" ;;
                    *) ok "la copia se detuvo sola (código $URC) en vez de colgarse"; note "$(short "$(cat "$W/unp.out")" 240)" ;;
                esac
            else
                kill "$UPID" 2>/dev/null; wait "$UPID" 2>/dev/null
                bad "la copia no se detuvo en 90 s tras desenchufar el disco (se colgó)"
            fi
            pause "Vuelve a ENCHUFAR el disco. Si Android pregunta algo, acepta." "${NEXO_CHECK_HOOK_PLUG:-}"
            cap u mounts --wait 90 --json
            printf '%s\n' "$OUT" > "$W/mounts3.json"
            M3=$(pj "$W/mounts3.json" 'next((v for v in d["volumes"] if v["uuid"] == "'"$UUID"'" and v.get("mounted")), None) is not None')
            if [ "$M3" = True ]; then
                ok "al volver a enchufarlo, Android lo monta otra vez y Nexo lo ve"
                G3=$(pj "$W/mounts3.json" 'next((v.get("granted") for v in d["volumes"] if v["uuid"] == "'"$UUID"'"), None)')
                [ "$G3" = True ] && ok "…y Nexo conserva el acceso (Android recordó el permiso)" || bad "…pero Nexo perdió el acceso: hay que volver a darlo con «nexo usb access»" "(esto es lo que la guía dice que NO pasa: cuéntalo en el informe)"
                cap fs ls -a --json "$RDIR";   rcis "ls de la carpeta de prueba tras volver a enchufar → 0" 0
                if existe "$RDIR/desenchufar.bin"; then
                    bad "tras desenchufar quedó un desenchufar.bin con su nombre de verdad (a medias)"
                else ok "…y no quedó ningún archivo a medias con su nombre de verdad"; fi
                LEFT=$(names "$RDIR" | grep -E '\.nexo-part-' | head -n 5)
                if [ -n "$LEFT" ]; then
                    info "quedó un archivo provisional del corte (se esperaba: la guía lo dice) y se borra ahora"
                    printf '%s\n' "$LEFT" | while IFS= read -r nm; do "$NX" usb rm -f "$RDIR/$nm" --vol "$UUID" --via app --no-ask > /dev/null 2>&1; done
                fi
            else
                bad "el disco no volvió a salir montado en 90 s"; note "estado: $(short "$(cat "$W/mounts3.json")" 300)"
                FAIL_EARLY=1
            fi
        fi
    else
        skip "desenchufar" "(sin escritura no se puede probar)"
    fi
fi

# ------------------------------------------------------------------------------------------------------------------- 9. Limpiar
if [ -n "$RDIR" ] && [ "$KEEP" = 1 ]; then
    say "== 9. Limpieza"
    info "--keep: la carpeta $RDIR se queda en el disco (bórrala con «nexo usb rm -r $RDIR»)"
elif [ -n "$RDIR" ]; then
    say "== 9. Limpiar y comprobar que el disco queda como estaba"
    if [ "$FAIL_EARLY" = 1 ] && ! u mounts --json 2>/dev/null | grep -q "$UUID"; then
        bad "no puedo limpiar: el disco ya no está"; note "cuando vuelva, borra $RDIR con «nexo usb rm -r $RDIR»"
    else
        cap fs rm -r "$RDIR";                 rcis "rm -r de la carpeta de prueba → 0" 0
        [ "$RC" = 0 ] && RDIR_GONE=1
        existe "$RDIR" && bad "la carpeta de prueba sigue en el disco" || ok "la carpeta de prueba ya no está"
        ROOT1=$(rootnames)
        if [ -n "${ROOT0:-}" ] && [ "$ROOT1" = "$ROOT0" ]; then ok "la raíz del disco queda con los mismos nombres que tenía (${ROOT1%% *} entradas)"; else bad "la raíz del disco NO quedó igual que al empezar" "antes: ${ROOT0:-?} · ahora: ${ROOT1:-?}  (entradas y huella de los nombres)"; fi
        cap u mounts --json
        OF=$(printf '%s\n' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("open_files"))' 2>/dev/null)
        [ "$OF" = 0 ] && ok "no queda ningún archivo abierto en la app" || bad "la app dice que quedan archivos abiertos: $OF"
    fi
fi

# ------------------------------------------------------------------------------------------------------------------ 10. Expulsar
if [ "$DO_EJ" = 1 ]; then
    if [ "$FAIL_EARLY" = 0 ] || [ -n "$UUID" ]; then
        say "== 10. Expulsar"
        cap u eject "$UUID" --json
        ERC=$RC
        printf '%s\n' "$OUT" > "$W/eject.json"
        sleep 1
        u mounts --json > "$W/mounts4.json" 2> /dev/null
        ST=$(pj "$W/mounts4.json" 'next((v.get("state") for v in d["volumes"] if v["uuid"] == "'"$UUID"'"), "ya no está")')
        MNT=$(pj "$W/mounts4.json" 'next((v.get("mounted") for v in d["volumes"] if v["uuid"] == "'"$UUID"'"), False)')
        if [ "$ERC" = 0 ]; then
            if [ "$MNT" = False ]; then ok "eject dijo que sí y Android confirma que ya no está montado (estado: $ST)"; else bad "eject dijo que expulsó, pero Android lo sigue teniendo montado ($ST)"; fi
            note "ya puedes desenchufarlo; para seguir probando, enchúfalo otra vez"
        else
            if [ "$MNT" = True ]; then info "Android no dejó expulsar desde Nexo (código $ERC) y el disco sigue montado: es lo esperado en un móvil sin permisos especiales" "$(short "$ERR$OUT" 300)"; else bad "eject dijo que no pudo, pero el disco ya no está montado ($ST)"; fi
            note "expúlsalo con el botón de Android antes de desenchufar"
        fi
    else
        skip "expulsar" "(no se pudo con lo anterior)"
    fi
fi

# ------------------------------------------------------------------------------------------------------------------------ Informe
say
say "== Resultado: $PASS bien · $FAIL con fallos · $SKIP omitidas · $INFO informativas"
say
say "== Informe (copia desde aquí si algo falla; no lleva tu token ni los nombres de tus archivos)"
{
    cat "$W/env.txt"
    echo "opciones     disco=${DISK:-auto} speed=$SPEED big=$BIG eject=$DO_EJ unplug=$DO_UNP keep=$KEEP"
    echo "--- disco (nexo usb mounts --json; la carpeta autorizada, si la hay, aparece como «(una carpeta)»)"
    [ -s "$W/vol.json" ] && cat "$W/vol.json" && echo
    echo "--- pruebas"
    cat "$REPORT"
    [ -s "$W/speed.txt" ] && { echo "--- velocidad"; cat "$W/speed.txt"; }
    [ -n "$RDIR" ] && [ "$RDIR_GONE" = 0 ] && echo "!!! la carpeta $RDIR sigue en el disco: bórrala con «nexo usb rm -r $RDIR»"
    echo "--- app (nexo logs 25)"
    "$NX" logs 25 2>&1 | head -n 40
} 2>&1 | sed 's/^/  /'
[ "$FAIL" -eq 0 ] || exit 1
exit 0
