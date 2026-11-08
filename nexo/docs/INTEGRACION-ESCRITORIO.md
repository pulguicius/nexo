# Integración con el escritorio: `nexo-dbus`

Los programas de Linux (barras, escritorios, `playerctl`…) no hablan con Nexo: hablan con **D‑Bus**. `nexo-dbus` es el traductor:
se queda conectado a la app Nexo y publica en D‑Bus lo que Android sabe, con los nombres que esos programas ya conocen.

| Versión | Qué publica | Quién lo usa |
|---|---|---|
| **0.3** (esta) | `org.mpris.MediaPlayer2.nexo`: la música del móvil como un reproductor más | `playerctl`, el módulo `mpris` de Waybar, Quickshell, GNOME, KDE, Plasma, los atajos multimedia… |
| 0.4 | `org.bluez` (solo estado: adaptador y dispositivos) | `bluetoothctl`, Blueman, applets |
| 0.5 | `org.freedesktop.NetworkManager` (solo estado: WiFi y redes a la vista) | `nmcli`, `nm-applet`, applets de red |
| 0.6 | `org.freedesktop.Notifications` (las notificaciones del móvil en tu escritorio) | dunst, mako, swaync, GNOME, KDE |

Esta guía describe la 0.3. Qué se ha probado y qué no, al final.

```
 App Nexo (Android) ──TCP 127.0.0.1:8765──▶ nexo-dbus ──D‑Bus (bus de sesión)──▶ playerctl · Waybar · Quickshell · GNOME · KDE
   sesión de medios activa                  (un proceso por distro)               «Nexo» aparece como un reproductor más
```

- **Un solo archivo de Python 3**, sin librerías (ni `pydbus` ni GObject): lleva su propia implementación del protocolo de D‑Bus.
  Está escrito para Python 3.7 o más nuevo (solo se ha ejecutado con 3.13; ver «Qué está probado»). Es un proceso por distro y por bus de sesión.
- El reproductor **solo aparece mientras haya música en Android** (una sesión de medios activa). Si no hay nada que controlar, no hay reproductor:
  así `playerctl` y los widgets no se llenan de un «Nexo» muerto. (`NEXO_DBUS_ALWAYS=1` lo deja siempre.)
- Todo es local: `nexo-dbus` solo habla con `127.0.0.1` y con el socket de tu bus de sesión.

## Activarlo

Necesitas tener ya Nexo funcionando (`nexo status` bien) y dar a la app el **acceso a notificaciones** (sin él Android no deja ver la música; `nexo doctor` te lo dice).

**En Termux** (el comando de instalación de la app ya trae `nexo-dbus`):

```bash
nexo setup-dbus            # instala python3 si falta, deja el arranque automático y lo arranca ahora
```

**En una distro de proot-distro** (Arch, Debian…): desde Termux las copias, y dentro de la distro lo activas.

```bash
# en Termux
nexo setup-guests --with-dbus          # copia nexo, el enlace y nexo-dbus a tus distros (o: setup-guests arch --with-dbus)

# dentro de la distro
nexo setup-dbus
```

Si ya habías copiado `nexo-dbus` a una distro, `nexo setup-guests` (y `nexo rekey`) lo mantienen al día sin que repitas `--with-dbus`.

Prueba: pon música en el móvil y, en la distro,

```bash
playerctl -l                      # → nexo
playerctl -p nexo metadata        # título, artista, álbum, carátula…
playerctl -p nexo play-pause
nexo dbus status                  # está en marcha o no
```

`playerctl` no viene en todas partes: `pacman -S playerctl` · `apt install playerctl` · `apk add playerctl`. Sin él puedes comprobar con
`busctl --user introspect org.mpris.MediaPlayer2.nexo /org/mpris/MediaPlayer2` o con `gdbus introspect --session --dest org.mpris.MediaPlayer2.nexo --object-path /org/mpris/MediaPlayer2`.

## El bus de sesión (lo único que puede fallar)

`nexo-dbus` tiene que conectarse al **mismo bus de sesión** que tu barra o tu escritorio; si no, ellos no ven el reproductor. Lo busca, en este orden, en
`--bus DIRECCIÓN` / `NEXO_DBUS_BUS`, `DBUS_SESSION_BUS_ADDRESS`, `$XDG_RUNTIME_DIR/bus`, `/run/user/UID/bus`, y el bus propio que él mismo creó (ver abajo).

| Tu caso | Qué hacer |
|---|---|
| Escritorio con sesión normal (GNOME, KDE, XFCE, Hyprland con `dbus-run-session`/`uwsm`…) | Nada: `nexo setup-dbus` lo arranca dentro de esa sesión y hereda el bus. |
| Escritorio en proot (VNC, Termux:X11) que arranca su bus con `dbus-launch` o `dbus-run-session` | Arranca `nexo-dbus` **desde esa sesión**: con `--launcher` (más abajo) o a mano en una terminal del escritorio: `nexo dbus start`. |
| Sin escritorio, solo terminal | `nexo setup-dbus --own-bus` crea un bus de sesión propio (hace falta el paquete `dbus`). En cada terminal donde quieras usarlo: `eval "$(nexo-dbus env)"`. |
| Un solo comando, sin instalar nada | `dbus-run-session -- bash` y, dentro, `nexo dbus start`. |

Ojo: con `--own-bus`, solo ven el reproductor los programas que usen **ese** bus (los que arrancaste con `eval "$(nexo-dbus env)"`). Una barra de un escritorio que ya
tiene su propio bus no lo verá: en ese caso usa su bus (primera fila de la tabla).

## Arranque automático

`nexo setup-dbus` deja **un** arranque automático, el primero de esta lista que sirva (volver a ejecutarlo sustituye al anterior, y `--uninstall` los quita todos):

1. **`--launcher ARCHIVO`**: añade a un script tuyo un bloque marcado con la orden `nexo-dbus start`. Se coloca **antes de la última línea `exec …`**
   del script (lo que va detrás de un `exec` nunca se ejecuta) o al final si no hay ninguna. Sirve para `xstartup` de VNC, `.xinitrc`, `.xprofile`, scripts de Quantum OS, etc.
   Repetirlo no duplica el bloque. Si el bus lo crea el propio script (`dbus-launch`…), el bloque tiene que quedar **después** de esa línea: revisa dónde lo puso.
2. **Servicio de systemd de usuario** (`~/.config/systemd/user/nexo-dbus.service`), si hay un gestor de usuario funcionando. En proot casi nunca lo hay.
3. **Arranque automático del escritorio** (`~/.config/autostart/nexo-dbus.desktop`): lo respetan GNOME, KDE, XFCE, LXQt, MATE, Cinnamon…

**Hyprland, Sway, i3, river y similares no leen `autostart`.** Ahí añade tú la orden a su configuración:

```ini
# Hyprland (~/.config/hypr/hyprland.conf)
exec-once = nexo-dbus start

# Sway / i3 (~/.config/sway/config · ~/.config/i3/config)
exec nexo-dbus start
```

`nexo-dbus start` arranca en segundo plano y vuelve enseguida; si ya hay uno en marcha, no hace nada. Su registro está en `~/.cache/nexo/dbus.log`.

Opciones de `setup-dbus`: `--no-start` (solo el arranque automático), `--own-bus`, `--always` (el reproductor siempre visible), `--launcher ARCHIVO`, `--uninstall`.

## Recetas

Todas son la sintaxis normal de cada programa; **no están probadas aquí con el programa real** (ver «Qué está probado»). En el bus el reproductor se llama `org.mpris.MediaPlayer2.nexo` (para `playerctl`: `nexo`);
su `Identity` es el nombre de la app que suena en el móvil (Spotify, YouTube Music…), o «Nexo» si no hay ninguna.

**Waybar**: el módulo `mpris` (Waybar debe estar compilado con `playerctl`):

```jsonc
"modules-right": ["mpris"],
"mpris": {
    "player": "nexo",
    "format": "{player_icon} {dynamic}",
    "format-paused": "{status_icon} {dynamic}",
    "player-icons": { "default": "▶", "nexo": "📱" },
    "status-icons": { "paused": "⏸" }
}
```

**Polybar** no tiene módulo MPRIS; se usa `playerctl` desde un script (o `nexo media status --polybar`, que ya trae el cliente):

```ini
[module/musica]
type = custom/script
exec = playerctl -p nexo metadata --format '{{ artist }} - {{ title }}' 2>/dev/null
interval = 2
click-left = playerctl -p nexo play-pause
click-right = playerctl -p nexo next
```

**Quickshell** (y Quantum OS): el servicio `Mpris` ya viene con Quickshell:

```qml
import QtQuick
import Quickshell.Services.Mpris

Text {
    // el reproductor del móvil, si suena algo (se reconoce por su nombre en el bus)
    property var movil: Mpris.players.values.find(p => p.dbusName === "org.mpris.MediaPlayer2.nexo")
    text: movil ? movil.trackArtist + " — " + movil.trackTitle : "Nada suena en el móvil"
    // movil.togglePlaying() · movil.next() · movil.previous()
}
```

**GNOME, KDE Plasma, XFCE (con su plugin)…**: sus controles multimedia leen MPRIS por su cuenta, así que «Nexo» sale en el applet o en el centro de control como cualquier reproductor.

**Atajos de teclado** (Hyprland / Sway / i3): `playerctl -p nexo play-pause`, `next`, `previous`:

```ini
bind = , XF86AudioPlay, exec, playerctl -p nexo play-pause     # Hyprland
bindsym XF86AudioNext exec playerctl -p nexo next               # Sway / i3
```

## Qué implementa de MPRIS

| Parte | Estado |
|---|---|
| `Identity` | ✅ el nombre de la app que suena en el móvil («Spotify»…), o «Nexo» si no hay ninguna |
| `CanQuit`, `CanRaise`, `HasTrackList` | ✅ siempre `false` (`Raise` y `Quit` no hacen nada) |
| `Play`, `Pause`, `PlayPause`, `Stop`, `Next`, `Previous` | ✅ van a la sesión de medios de Android |
| `Seek`, `SetPosition` | ✅ (la señal `Seeked` sale una vez por salto) |
| `PlaybackStatus`, `Metadata` (título, artista, álbum, artista del álbum, duración, carátula, `trackid`) | ✅ y se actualizan con `PropertiesChanged` |
| `Position` | ✅ se calcula en local y se corrige con la app cada 10 s mientras suena |
| `Volume` (lectura y escritura) | ✅ es el volumen de música de Android (que va por pasos, normalmente 15: pedir `0.3` deja el volumen en ≈ 0.33) |
| `CanPlay`, `CanPause`, `CanSeek`, `CanGoNext`, `CanGoPrevious`, `CanControl` | ✅ según lo que permita la app que suena |
| `Rate`, `MinimumRate`, `MaximumRate` | Solo lectura (1.0 normalmente) |
| `LoopStatus`, `Shuffle`, `Fullscreen`, `DesktopEntry`, `TrackList`, `Playlists` | ➖ No se publican (son opcionales en la especificación) |
| `OpenUri` | ➖ Responde «no soportado» (no se pueden abrir direcciones en el móvil desde aquí) |

La carátula se guarda en `~/.cache/nexo/art/` (se conservan las 30 últimas; la carpeta es solo tuya) y se publica como `mpris:artUrl` con una ruta `file://`.
Si ya hay otro programa con el nombre `org.mpris.MediaPlayer2.nexo` en tu bus, `nexo-dbus` **no se lo quita**: se queda pasivo (`NEXO_DBUS_FORCE=1` lo obliga).

## Variables de entorno

| Variable | Para qué |
|---|---|
| `NEXO_DBUS_BUS` | Dirección del bus (si no es la normal): `unix:path=/ruta/bus` (también `--bus`) |
| `NEXO_DBUS_ALWAYS=1` | El reproductor se ve aunque no haya música (`Stopped`, sin controles) |
| `NEXO_DBUS_GRACE` | Segundos que espera antes de retirar el reproductor cuando para la música (3) |
| `NEXO_DBUS_GRACE_DOWN` | Ídem si la app Nexo deja de responder (30): da tiempo a que Android la descongele |
| `NEXO_DBUS_FORCE=1` | Reclama el nombre aunque ya lo tenga otro |
| `NEXO_PORT`, `NEXO_TOKEN`, `NEXO_CONFIG` | Los mismos que el cliente `nexo`: el enlace se lee igual (y se vuelve a leer solo si cambia, p. ej. tras `nexo rekey`) |

## Si no funciona

| Síntoma | Causa probable | Solución |
|---|---|---|
| `playerctl -l` no dice nada | No hay música en Android, o el acceso a notificaciones no está dado | Pon música; `nexo doctor` y `nexo media status` (`listener: true`). En Android 13+: «Permitir ajustes restringidos» |
| `nexo dbus status` dice que no está en marcha | No arrancó (sin bus, sin token…) | `nexo dbus run -v` lo muestra en la terminal; el motivo sale con una explicación |
| «No encuentro un bus de sesión de D‑Bus» | Estás fuera de la sesión del escritorio | Mira «El bus de sesión» arriba |
| Se ve en `busctl` pero no en tu barra | La barra usa **otro** bus | Arranca `nexo-dbus` desde la sesión de la barra (`--launcher`, `exec-once`) |
| «la app Nexo rechazó el enlace» | Cambiaste el token | `nexo rekey` (o `nexo pair`): `nexo-dbus` recoge el nuevo en unos segundos |
| «esta versión de la app Nexo no sabe de música» | APK anterior a la 0.2 | Instala el APK nuevo |
| El reproductor tarda en irse al parar | Es a propósito (margen de 3 s: evita parpadeos entre canciones) | `NEXO_DBUS_GRACE=0` |
| Android congela la app y el reproductor desaparece | HyperOS y otras capas | Ver «Que Android no cierre la app» en el README |

## Qué está probado y qué no

**Probado aquí** (la suite de pruebas del repositorio, con un `dbus-daemon` real y una app Nexo simulada):

- el empaquetado de mensajes de D‑Bus (30 tipos, incluidos los que usarán BlueZ y NetworkManager), comprobado contra dos clientes independientes: `busctl` (systemd) y `gdbus` (GLib);
- el reproductor MPRIS completo visto con esos dos clientes: propiedades, metadatos, carátula, controles, `Seek`, `Volume`, cambios hechos desde Android, 30 clientes a la vez;
- aparecer y desaparecer según haya música, app caída y vuelta, bus reiniciado, token cambiado, modo pasivo cuando otro ya tiene el nombre;
- `nexo setup-dbus` (systemd simulado, autostart, script propio, desinstalar, sin python3), `setup-guests --with-dbus` y el instalador.

**No probado:** `playerctl`, Waybar, Polybar, Quickshell, GNOME, KDE (ningún programa real de escritorio; `busctl` y `gdbus` son los clientes que sí se han usado, y en GitHub Actions hay un trabajo
que prueba `playerctl` de verdad, sin bloquear nada si falla); el comportamiento dentro de proot en un móvil real (permisos del socket del bus, identidad de usuario dentro de proot);
Python anteriores a 3.13 en ejecución (solo se comprueba que el código usa sintaxis de 3.7); y todo lo que depende del código de Android (que tampoco se ha ejecutado en un móvil desde la 0.2).
Si algo de esto falla en tu equipo, `~/.cache/nexo/dbus.log` y `nexo dbus run -v` dicen qué pasó.

## Idea sin probar: el móvil por USB

La app solo escucha en `127.0.0.1` del móvil. Con `adb forward tcp:8765 tcp:8765` ese puerto aparece también en tu PC; con `nexo pair TOKEN` y `nexo setup-dbus` en el PC,
la música del móvil debería verse como reproductor en tu escritorio de Linux de verdad. No se ha probado y no forma parte de lo que Nexo promete.
