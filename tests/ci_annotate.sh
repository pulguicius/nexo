#!/usr/bin/env bash
# Ayuda para GitHub Actions: ejecuta una orden y, si falla, deja la CAUSA en una anotación visible en la página del trabajo
# (y en el resumen de la ejecución), para no tener que abrir el registro entero. La salida de la orden se ve igual que siempre y
# este programa sale con su mismo código (salvo el 77, ver abajo).
#
#   bash tests/ci_annotate.sh [--77-falla] "Título de la anotación" -- orden [argumentos…]
#
# Las pruebas de Nexo escriben «  FALLA nombre» y, debajo, el detalle: esas líneas son las que se anotan. Si no hay ninguna
# (la orden murió por otra cosa) se anotan las últimas líneas de su salida.
#   --77-falla   el código 77 («no se pudo correr»: tests/ui_tests.py lo usa cuando falta Playwright o Chromium) cuenta como fallo.
#                En un portátil sin navegador no es un error; en CI sí: allí el entorno debería poder correr las pruebas.
set -u

strict77=0
if [ "${1:-}" = "--77-falla" ]; then
    strict77=1
    shift
fi
if [ $# -lt 3 ] || [ "$2" != "--" ]; then
    echo 'uso: bash tests/ci_annotate.sh [--77-falla] "Título" -- orden [argumentos…]' >&2
    exit 2
fi
title=$1
shift 2

# Las anotaciones de GitHub llevan %, \r y \n codificados; en el título (una «propiedad») también : y ,
enc() {
    local s=$1
    s=${s//'%'/'%25'}
    s=${s//$'\r'/'%0D'}
    s=${s//$'\n'/'%0A'}
    printf '%s' "$s"
}
encp() {
    local s
    s=$(enc "$1")
    s=${s//':'/'%3A'}
    s=${s//','/'%2C'}
    printf '%s' "$s"
}

log=$(mktemp)
trap 'rm -f "$log"' EXIT
"$@" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
[ "$rc" -eq 0 ] && exit 0

if [ "$rc" -eq 77 ]; then
    # (el mensaje de ui_tests.py dice qué falta: va en la anotación)
    why=$(tail -n 3 "$log")
    if [ "$strict77" -eq 0 ]; then
        echo "::warning title=$(encp "$title")::$(enc "No se pudo correr (código 77). $why")"
        exit 0
    fi
    echo "::error title=$(encp "$title")::$(enc "No se pudo correr (código 77), y en CI debería poder. $why")"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        { echo "### ✗ $title: no se pudo correr (código 77)"; echo; echo '```'; printf '%s\n' "$why"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 1
fi

# Los «FALLA» (hasta 12) con su línea de detalle (la primera, recortada)
msg=""
n=0
extra=0
want=0
while IFS= read -r line; do
    case $line in
        "  FALLA "*)
            if [ "$n" -lt 12 ]; then
                msg+="• ${line#  FALLA }"$'\n'
                n=$((n + 1))
                want=1
            else
                extra=$((extra + 1))
                want=0
            fi
            ;;
        "        "*)
            if [ "$want" -eq 1 ]; then
                d=${line#"${line%%[![:space:]]*}"}
                [ "${#d}" -gt 300 ] && d="${d:0:300}…"
                msg+="    $d"$'\n'
                want=0
            fi
            ;;
        *) want=0 ;;
    esac
done < "$log"
[ "$extra" -gt 0 ] && msg+="(y $extra fallos más: mira el registro)"$'\n'
[ "$n" -eq 0 ] && msg=$(tail -n 8 "$log")
[ "${#msg}" -gt 3500 ] && msg="${msg:0:3500}…"

echo "::error title=$(encp "$title")::$(enc "Terminó con código $rc. $msg")"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    { echo "### ✗ $title (código $rc)"; echo; echo '```'; printf '%s\n' "$msg"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
fi
exit "$rc"
