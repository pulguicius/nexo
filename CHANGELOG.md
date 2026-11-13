# Cambios

Solo lo que cambia para quien usa Nexo. Qué está probado y qué no, en el [README](README.md#estado-y-lo-que-falta).

## 0.4.0‑beta2

- **Nuevo: `nexo tools`** — enviar y explorar archivos entre móviles (y PC con Linux) por la red local: `send`/`fetch` con un código de un solo uso, `server`, `discover` (detecta móviles con Nexo en la red), `pair`/`connect` (emparejamiento por código con certificado fijado por huella),
  `browse` (terminal), `ls`/`get`/`put`/`mkdir`/`mv`/`rm`, `web` (gestor en el navegador), `authorized`/`revoke`. Ve todas las carpetas y todas las extensiones (filtros `--ext`, `--find`, `--types`); solo lectura por omisión, escritura opcional y borrar va a una papelera.
  Parte de tu `nexo-tools.sh` 2.3.0 (ahora 2.4.0). Guía: [`docs/NEXO-TOOLS.md`](docs/NEXO-TOOLS.md). Probado entre dos «dispositivos» simulados en una máquina, no entre dos móviles reales.
- **Nuevo: `nexo update [RUTA|ARCHIVO.zip]`** — pone al día `nexo`, `nexo-dbus` y `nexo-tools` desde la carpeta del repositorio (o un `.zip`) y luego tus distros; `--check` solo mira. No descarga ni ejecuta nada de la red.
- **Corregido: `setup-guests`** — reconoce `…/proot-distro/containers/NOMBRE/rootfs` (proot-distro 5) además de `installed-rootfs/NOMBRE`; si una distro tiene varias copias de `nexo` (p. ej. `/usr/local/bin` y `/usr/bin`) las actualiza **todas**
  y comprueba ejecutando la distro cuál se usa de verdad (`--no-verify` lo omite); actualiza el `~/.config/nexo/config` propio de la distro si tenía el token viejo; un nombre que no existe da error en vez de crear una carpeta suelta.
  Nuevo `--with-tools` (copia `nexo-tools`); `--list` enseña la versión de cada copia; `--uninstall` quita todas las copias.
- **Instalador:** el comando de la app instala también `nexo-tools`; `install.sh --uninstall` lo quita y, con `--purge`, borra lo que guarda (certificado y dispositivos emparejados).
- **`nexo doctor`** muestra `nexo-tools`. **`nexo dbus restart`** (ya existía en `nexo-dbus`) aparece en la ayuda.
- Pruebas y CI: pruebas de `nexo tools`, `setup-guests` (con un `proot-distro` simulado) y `nexo update`; `tests/ui_tests.py` maneja el gestor web en un Chromium sin pantalla; trabajo `tools` en GitHub Actions (no bloquea).
- Protocolo: sin cambios (1.2). El estado de la red móvil y las notificaciones (protocolo 1.3) pasan a la 0.4.3.

## 0.4.0‑beta1

- `nexo-dbus` emula **BlueZ** (`org.bluez`: adaptador, dispositivos emparejados, batería, encender/apagar) y **NetworkManager** (`org.freedesktop.NetworkManager`: `wlan0`, redes a la vista y guardadas, conectar/desconectar) en el bus del sistema, para `bluetoothctl`, `nmcli` y los applets.
- `nexo setup-dbus --system-policy`, `--own-bus`, modo pasivo ante un BlueZ/NetworkManager de verdad, `nexo dbus status` por servicio.

## 0.3.0

- `nexo-dbus`: la música del móvil como reproductor **MPRIS** (`playerctl`, Waybar, Quickshell, GNOME, KDE); `nexo setup-dbus`; `setup-guests --with-dbus`.

## 0.2

- Audio (`nexo audio`), música (`nexo media`), redes guardadas, olvidar/renombrar Bluetooth, formatos para barras (`--polybar --i3status --qml --dunst --tmux --starship --csv`), `doctor --fix`, auto-recuperación.

## 0.1

- WiFi y Bluetooth por línea de comandos desde Termux y proot-distro; instalador de una línea que viaja dentro de la app.
