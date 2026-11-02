#!/usr/bin/env bash
# Instalador del cliente «nexo». Sirve en Termux (F-Droid, GitHub, Monet, cualquier fork)
# y dentro de cualquier distro de proot-distro. No usa rutas fijas: todo sale de $PREFIX y $HOME.
#
# Lo normal es no ejecutarlo a mano: la app Nexo copia un comando de una línea que lo descarga
# de sí misma (sin internet) y lo lanza ya con el token. A mano, desde este repositorio:
#   bash termux/install.sh                                  # solo instala el cliente
#   NEXO_TOKEN=... NEXO_PORT=8765 bash termux/install.sh    # instala y enlaza
#   bash termux/install.sh --uninstall                      # quita cliente y enlace
#
# Variables opcionales: NEXO_BIN_DIR, NEXO_CONFIG_DIR, NEXO_NO_DEPS=1 (no instalar jq)

set -u
umask 022

say()  { printf '%s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

SRC_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)

IS_TERMUX=0
case ${PREFIX:-} in
    */files/usr) [ -d "$PREFIX/bin" ] && IS_TERMUX=1 ;;
esac
UID_NOW=$(id -u 2>/dev/null || echo 1)

# ---------------------------------------------------------------- dónde se instala
if [ -n "${NEXO_BIN_DIR:-}" ]; then
    BIN_DIR=$NEXO_BIN_DIR
elif [ "$IS_TERMUX" = 1 ]; then
    BIN_DIR=$PREFIX/bin
elif [ "$UID_NOW" = 0 ]; then
    BIN_DIR=/usr/local/bin
else
    BIN_DIR=${HOME:-/tmp}/.local/bin
fi

if [ -n "${NEXO_CONFIG_DIR:-}" ]; then
    CONF_DIR=$NEXO_CONFIG_DIR; CONF_MODE=600
elif [ "$IS_TERMUX" = 1 ] || [ "$UID_NOW" != 0 ]; then
    CONF_DIR=${XDG_CONFIG_HOME:-${HOME:-/tmp}/.config}/nexo; CONF_MODE=600
else
    # root dentro de una distro: /etc/nexo lo pueden leer todos los usuarios de esa distro
    CONF_DIR=/etc/nexo; CONF_MODE=644
fi

# ---------------------------------------------------------------- desinstalar
if [ "${1:-}" = "--uninstall" ]; then
    rm -f "$BIN_DIR/nexo" "$CONF_DIR/config"
    rmdir "$CONF_DIR" 2>/dev/null
    say "✔ Nexo (cliente) desinstalado de $BIN_DIR"
    exit 0
fi

# ---------------------------------------------------------------- dependencias
install_pkg() {
    local pkg=$1 sudo=""
    if [ "$IS_TERMUX" = 1 ]; then
        if have pkg; then pkg install -y "$pkg" >/dev/null 2>&1; return; fi
        have apt-get && apt-get install -y "$pkg" >/dev/null 2>&1
        return
    fi
    if [ "$UID_NOW" != 0 ]; then
        have sudo || return 1
        sudo=sudo
    fi
    if   have apt-get;      then $sudo apt-get update -qq >/dev/null 2>&1; $sudo apt-get install -y -qq "$pkg" >/dev/null 2>&1
    elif have pacman;       then $sudo pacman -S --needed --noconfirm "$pkg" >/dev/null 2>&1
    elif have apk;          then $sudo apk add --no-cache "$pkg" >/dev/null 2>&1
    elif have dnf;          then $sudo dnf install -y -q "$pkg" >/dev/null 2>&1
    elif have zypper;       then $sudo zypper --non-interactive install "$pkg" >/dev/null 2>&1
    elif have xbps-install; then $sudo xbps-install -y "$pkg" >/dev/null 2>&1
    else return 1; fi
}

if ! have jq && [ "${NEXO_NO_DEPS:-0}" != 1 ]; then
    say "• Instalando jq (opcional: da formato a la salida)…"
    install_pkg jq || warn "No pude instalar jq. Nexo funciona igual, pero muestra JSON sin formato."
fi

# ---------------------------------------------------------------- cliente
mkdir -p "$BIN_DIR" 2>/dev/null || { warn "No pude crear $BIN_DIR"; exit 1; }
TMP=$BIN_DIR/nexo.tmp.$$
if [ -n "${NEXO_CLIENT_B64:-}" ]; then
    printf '%s' "$NEXO_CLIENT_B64" | base64 -d > "$TMP" 2>/dev/null || { rm -f "$TMP"; warn "No pude decodificar el cliente (¿falta base64?)"; exit 1; }
elif [ -f "$SRC_DIR/bin/nexo" ]; then
    cp "$SRC_DIR/bin/nexo" "$TMP" || { warn "No pude copiar el cliente"; exit 1; }
else
    warn "No encuentro el cliente. Ejecuta este instalador desde el repositorio o usa el comando de la app."
    exit 1
fi
chmod 755 "$TMP" && mv -f "$TMP" "$BIN_DIR/nexo" || { warn "No pude instalar en $BIN_DIR"; exit 1; }
# Termux: que el shebang apunte al bash de Termux, sea cual sea su paquete
if [ "$IS_TERMUX" = 1 ] && have termux-fix-shebang; then termux-fix-shebang "$BIN_DIR/nexo" 2>/dev/null; fi
say "✔ Cliente instalado en $BIN_DIR/nexo"

case ":${PATH:-}:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR no está en tu PATH. Añade:  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

# ---------------------------------------------------------------- enlace con la app
PORT=${NEXO_PORT:-8765}
if [ -n "${NEXO_TOKEN:-}" ]; then
    case $NEXO_TOKEN in *[!0-9a-fA-F]*) warn "El token no es válido (solo 0-9 y a-f)"; exit 1 ;; esac
    case $PORT in ''|*[!0-9]*) warn "Puerto inválido: $PORT"; exit 1 ;; esac
    mkdir -p "$CONF_DIR" 2>/dev/null || { warn "No pude crear $CONF_DIR"; exit 1; }
    CT=$CONF_DIR/config.tmp.$$
    ( umask 077
      {
        printf '# Enlace con la app Nexo. No compartas este archivo: contiene el token.\n'
        printf 'NEXO_PORT=%s\n' "$PORT"
        printf 'NEXO_TOKEN=%s\n' "$NEXO_TOKEN"
      } > "$CT" ) || { warn "No pude escribir la configuración"; exit 1; }
    chmod "$CONF_MODE" "$CT" && mv -f "$CT" "$CONF_DIR/config"
    say "✔ Enlazado con la app (puerto $PORT)"
    if "$BIN_DIR/nexo" ping >/dev/null 2>&1; then
        say "✔ La app responde"
    else
        warn "Guardé el enlace, pero la app no respondió. ¿Está encendido el puente? Prueba:  nexo doctor"
    fi
else
    say "• Falta enlazar: copia el comando de instalación desde la app Nexo, o ejecuta  nexo pair TOKEN"
fi

say ""
say "Listo. Prueba:   nexo status"
if [ "$IS_TERMUX" = 1 ] && [ -d "$PREFIX/var/lib/proot-distro/installed-rootfs" ]; then
    say "¿Usas distros de proot-distro?   nexo setup-guests   (les copia el cliente y el enlace)"
fi
