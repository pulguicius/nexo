# Nexo

**El WiFi, el Bluetooth, el audio y la música reales de tu móvil, dentro de Termux y de tus distros de proot.**

Nexo tiene dos piezas:

- una **app de Android** (Kotlin, sin librerías de terceros, sin anuncios ni telemetría) que habla con el WiFi, el Bluetooth, el audio y la música del móvil;
- un **cliente de línea de comandos, `nexo`** (un solo script de bash), que la propia app instala en Termux con un comando que ella misma copia.

Funciona con **Termux de F‑Droid, de GitHub, Termux Monet y cualquier otro fork**: no depende del nombre del paquete de Termux,
de rutas fijas, de Termux:API ni de root. Dentro de una distro de `proot-distro` (Arch, Debian, Ubuntu, Alpine…) funciona igual.

```
┌─ tu móvil (Android) ────────────────────────────────────────────────────┐
│                                                                         │
│  App Nexo  ── WiFi, Bluetooth, audio y música reales de Android         │
│     ▲        escucha solo en 127.0.0.1:8765 (servicio en primer plano)  │
│     │                                                                   │
│     │  TCP local · un JSON por línea · con token                        │
│     │                                                                   │
│     ├── Termux (F-Droid, GitHub, Monet, fork…)   →  nexo status         │
│     └── distro de proot-distro (Arch, Debian…)   →  nexo status         │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

`proot` comparte la red del móvil, así que el `127.0.0.1` de una distro es el mismo que el de Termux y el de la app.
Por eso no hacen falta sockets Unix ni `socat`.

```console
$ nexo status
WiFi: conectado a MiCasa · -55 dBm · 5GHz · 192.168.1.23
Bluetooth: encendido · con dispositivos conectados · 2 emparejados
Volumen: 60% (9/15) · Auriculares ñandú
Reproduciendo: Canción ñandú — Artista (Álbum) · Reproductor falso

$ nexo wifi scan
RED                                    SEÑAL  SEGUR. BANDA
MiCasa                               -52 dBm  WPA2   5GHz
CafeLuz                              -70 dBm  WPA2   2.4GHz
Invitados                            -81 dBm  OPEN   2.4GHz

$ nexo audio outputs
ID   TIPO             NOMBRE                       ACTIVA
2    speaker          Altavoz del teléfono
7    bluetooth_a2dp   Auriculares ñandú            ◀ suena aquí
9    usb_headset      USB-C

$ nexo media next          # y también: play, pause, playpause, stop, prev, seek +10s
```

> **Estado: versión 0.4.3** (la última versión cerrada es la 0.3.0). De la 0.1 (WiFi y Bluetooth) hay un APK compilado, firmado y probado en un móvil real
> (Xiaomi 25078RA3EL, Android 16 / SDK 36, con Termux Monet y Arch Linux en proot-distro).
> La 0.2 añadió audio, música, redes guardadas, olvidar/renombrar Bluetooth, formatos para barras de estado y auto-recuperación;
> la 0.3 añadió `nexo-dbus` con la música del móvil como reproductor MPRIS (`playerctl`, Waybar, Quickshell, GNOME, KDE);
> la 0.4.0‑beta1 añadió a `nexo-dbus` el Bluetooth (`org.bluez`) y el WiFi (`org.freedesktop.NetworkManager`) del móvil para `bluetoothctl`, `nmcli` y los applets;
> la **0.4.0‑beta2 añade `nexo tools`** (enviar y explorar archivos entre móviles: detección en la red, emparejamiento por código, explorador de terminal y gestor en el navegador, escritura opcional),
> **`nexo update`** (lo que antes era copiar a mano) y un **`setup-guests` corregido** (distros en `containers/NOMBRE/rootfs`, todas las copias de `nexo`, comprobación de cuál ejecuta cada distro);
> la **0.4.1 añade `nexo usb`**: un Arduino, un ESP32 o un adaptador USB↔serie conectado al móvil con un cable OTG (o un hub) sale en la distro como un puerto serie para `avrdude`, `arduino-cli`, `esptool`, PlatformIO, `screen`…;
> la **0.4.2 añade los discos USB** a `nexo usb`: un pendrive, un disco duro o un SSD conectado al móvil se explora y se copia desde la distro (`nexo usb mounts`, `ls`, `get`, `put`, `eject`…), sin root y sin «acceso a todos los archivos»: lo monta Android y tú le das acceso a Nexo en el selector de carpetas del sistema;
> la **0.4.3 añade `nexo net` y `nexo notif`**: por dónde sale el móvil a internet (WiFi, datos móviles, cable, VPN; si hay internet de verdad y si es de pago), que además hace que `nmcli` y los applets de red de la distro vean **la red real del móvil** (no solo el WiFi), y, **solo si tú lo activas en la app**, las notificaciones del móvil en tu escritorio (`dunst`, `mako`, GNOME, KDE…) y en la terminal (`nexo notif list`, `dismiss`, `watch`).
> El cliente, `nexo-dbus`, `nexo-tools` y `nexo-usb` pasan **2555 pruebas** (`nexo-dbus` contra un bus D‑Bus real, visto con `busctl` y `gdbus`; `nexo-tools` entre dos «dispositivos» simulados y en un Chromium sin pantalla) y el código de Android compila y coincide con la app simulada y con el protocolo,
> pero **el código nuevo de la app (0.2 y siguientes) todavía no se ha ejecutado en un móvil**, `nexo-dbus` **no se ha probado con `bluetoothctl`, `nmcli`, `playerctl`, Waybar, `dunst`, `mako`, GNOME ni KDE**, `nexo tools` **no se ha probado entre dos móviles reales** y `nexo usb` **no se ha probado con una placa, un disco ni un móvil reales** (hay un script para cada cosa: [placas](docs/USB.md#probarlo-en-tu-móvil) y [discos](docs/USB-ALMACENAMIENTO.md#probarlo-en-tu-móvil)). Lee [Estado y lo que falta](#estado-y-lo-que-falta).

---

## Empezar

### 1. Conseguir el APK

Descarga el APK ya compilado y firmado desde la pestaña **Releases** de este repositorio.

Al instalarlo, si Android pide permiso para «instalar apps desconocidas», concédelo a la app desde la que lo abres; si Play Protect avisa,
elige «Instalar de todos modos». Al estar firmado con clave propia, podrás actualizar la app en el futuro sin necesidad de desinstalarla.

### 2. Encender el puente

1. Abre **Nexo** y pulsa **Conceder permisos** (ubicación, avisos y Bluetooth).
   Nexo **no lee tu ubicación**: Android solo entrega el nombre del WiFi y las redes cercanas a apps que tienen ese permiso.
2. Pulsa **Iniciar puente**. Queda una notificación fija «Nexo activo»: es lo que mantiene la app viva.
3. **Muy importante en Xiaomi/HyperOS** y otras capas: mira [Que Android no cierre la app](#que-android-no-cierre-la-app).
   Si no se configura bien, el socket se abre pero la app no responde (código de error 12).
4. **Para la música** (título, pausa, siguiente, carátula): pulsa **Dar acceso a notificaciones** y activa Nexo. Para la música Nexo solo usa las sesiones de medios:
   **no lee tus notificaciones** salvo que además actives tú el interruptor **Reenviar notificaciones a Linux** (viene apagado; ver [Red y notificaciones del móvil](#red-y-notificaciones-del-móvil-nexo-net-y-nexo-notif)),
   y aun así no las guarda. En Android 13 o más, si el interruptor sale en gris, ve a
   Ajustes › Aplicaciones › Nexo › ⋮ (arriba a la derecha) › **Permitir ajustes restringidos** (Android lo exige a las apps instaladas desde un APK).

### 3. Enlazar Termux

1. En Nexo, pulsa **Copiar comando de instalación**.
2. Pégalo en Termux y pulsa Enter. Instala `nexo` (y `jq`, opcional, que da formato a la salida), guarda el enlace y comprueba que la app responde.
3. Prueba: `nexo status`.

El comando es el mismo para cualquier Termux: descarga el instalador **de la propia app** (sin internet) y comprueba su huella SHA‑256 antes de ejecutarlo.

### 4. Tus distros de proot-distro

En Termux, `nexo setup-guests` copia el cliente y el enlace a todas tus distros
(o a la que indiques: `nexo setup-guests ubuntu`, o la ruta de su carpeta). Reconoce las dos disposiciones de proot-distro:
`…/proot-distro/containers/NOMBRE/rootfs` (proot-distro 5) e `…/proot-distro/installed-rootfs/NOMBRE` (la antigua). `nexo setup-guests --list` te dice qué versión de `nexo` lleva cada una.
Dentro de la distro, el comando es el mismo: `nexo status`.

Si una distro ya tenía copias de `nexo` (por ejemplo una vieja en `/usr/local/bin` y otra a mano en `/usr/bin`), **las actualiza todas**: la que ejecuta la distro depende de su `PATH`, y si solo se tocara una, la otra podía seguir ganando con la versión vieja.
Después ejecuta `nexo version` **dentro de cada distro** (con `proot-distro login`) y te dice qué copia se ejecuta de verdad (`--no-verify` se lo salta). También pone el token nuevo en el `~/.config/nexo/config` propio de la distro si lo hay (ese gana al de `/etc/nexo`).

**Para actualizar todo a la vez** (Termux y distros) con la carpeta del repositorio o el `.zip` nuevo: `nexo update` (busca la carpeta donde estás o donde sueles dejarla; o `nexo update RUTA`, o `nexo update nexo-v0.4.1.zip`; `--check` solo mira). Si `nexo-dbus` estaba en marcha en una distro, reinícialo allí: `nexo dbus restart`.

**¿Quieres la música, el Bluetooth y el WiFi del móvil para tus programas de escritorio** (`playerctl`, `bluetoothctl`, `nmcli`, Waybar, Quickshell, GNOME, KDE…)? Copia también `nexo-dbus` con `nexo setup-guests --with-dbus` y,
dentro de la distro, `nexo setup-dbus --own-bus`. Guía completa: [`docs/INTEGRACION-ESCRITORIO.md`](docs/INTEGRACION-ESCRITORIO.md).
**¿Quieres pasar archivos entre móviles desde la distro?** `nexo setup-guests --with-tools` (necesita `python3` y `openssl` en la distro). Guía: [`docs/NEXO-TOOLS.md`](docs/NEXO-TOOLS.md).
**¿Quieres un Arduino, un ESP32 o un adaptador USB↔serie dentro de la distro?** Conéctalo al móvil con un cable OTG, copia `nexo-usb` con `nexo setup-guests --with-usb` (necesita `python3` en la distro) y, dentro de ella, `nexo usb list`. Guía: [`docs/USB.md`](docs/USB.md).
**¿Quieres explorar un pendrive o un disco duro desde la distro?** Conéctalo al móvil con un cable OTG (o un hub), copia `nexo-usb` como arriba y, dentro de la distro, `nexo usb mounts` y `nexo usb access` (eliges el disco una vez en el selector de carpetas de Android); después `nexo usb ls`, `get`, `put`… Guía: [`docs/USB-ALMACENAMIENTO.md`](docs/USB-ALMACENAMIENTO.md).

Dependiendo de la distro, necesitarás instalar `bash` y `jq`:

- Arch Linux: `pacman -S bash jq`
- Alpine: `apk add bash jq`
- Debian/Ubuntu: `apt install bash jq`

(`setup-guests` te avisa si detecta que le falta algo a la distro).

---

## Comandos

| Comando | Qué hace |
|---|---|
| `nexo status` | Resumen de WiFi, Bluetooth, audio y música |
| `nexo wifi\|bt\|audio\|media status` | Estado de cada parte |
| `nexo wifi on` · `off` · `toggle` | Enciende, apaga o alterna el WiFi |
| `nexo wifi scan [--rescan\|--cached]` | Redes cercanas: nombre, señal, seguridad y banda (`--cached`: sin pedir un escaneo nuevo) |
| `nexo wifi connect NOMBRE [CLAVE]` | Se conecta a una red abierta o WPA/WPA2 personal (`--hidden` si está oculta) |
| `nexo wifi disconnect` · `nexo wifi reconnect` | Se desconecta de la red actual, o se vuelve a conectar |
| `nexo wifi saved` · `nexo wifi forget NOMBRE` | Redes guardadas en el móvil, y olvidar una (`--id N`) |
| `nexo bt on` · `off` · `toggle` | Enciende, apaga o alterna el Bluetooth |
| `nexo bt paired` | Dispositivos emparejados y cuáles están conectados ahora |
| `nexo bt connect\|disconnect DIRECCIÓN` | Android lo reserva al sistema: Nexo deja una notificación que abre los ajustes de Bluetooth |
| `nexo bt forget DIRECCIÓN` · `bt rename DIRECCIÓN NOMBRE` · `bt info DIRECCIÓN` | Desemparejar, ponerle alias (Android 12+) y ver detalles: perfiles, tipo, batería si el dispositivo la da |
| `nexo audio volume [30\|+5\|-5\|mute\|unmute\|toggle]` | Volumen de música (sin argumento, lo muestra) |
| `nexo audio outputs` · `nexo audio switch SALIDA` | Salidas de audio y cuál suena. Cambiarla pide un toque (Android no deja a una app normal) |
| `nexo media play\|pause\|playpause\|stop\|next\|prev` | Controla la música que suena en el móvil (Spotify, YouTube Music, VLC…) |
| `nexo media seek +10s\|-10s\|90s\|1:30` · `nexo media art [ARCHIVO]` | Adelantar o ir a un punto; guardar la carátula (JPEG) |
| `nexo net [status]` | Por dónde sale el móvil a internet (WiFi, datos móviles, cable, VPN), si hay internet de verdad y si es de pago. Necesita la app 0.4.3 o más nueva |
| `nexo notif status\|list\|dismiss CLAVE\|--all\|watch` | Las notificaciones del móvil: ver cuáles hay, quitarlas y recibirlas en vivo. **Opcional: viene apagado** y se activa en la app («Reenviar notificaciones a Linux»); [detalles](#red-y-notificaciones-del-móvil-nexo-net-y-nexo-notif) |
| `nexo watch [wifi\|bt\|audio\|media\|usb\|storage\|net\|notif]` | Cambios en vivo, un JSON por línea (`--pretty` para leerlos mejor; `usb`, `storage`, `net` y `notif` se piden por su nombre; `storage --event` y `notif --event` dan un evento con nombre por cambio). Reconecta solo |
| `nexo pair [TOKEN] [PUERTO]` · `nexo unpair` | Guarda o borra el enlace a mano (`--token-stdin`: el token no queda en el historial) |
| `nexo rekey [TOKEN]` | Cambia el token tras «Token nuevo» en la app y actualiza tus distros |
| `nexo setup-guests [DISTRO…]` | (Termux) copia cliente y enlace a tus distros de proot-distro (`containers/…/rootfs` e `installed-rootfs`), actualiza TODAS las copias de `nexo` que tengan y comprueba cuál ejecuta cada una (`--list`, `--uninstall`, `--private`, `--with-dbus`, `--with-tools`, `--with-usb`, `--no-verify`) |
| `nexo update [RUTA\|ARCHIVO.zip]` | Pone al día `nexo`, `nexo-dbus`, `nexo-tools` y `nexo-usb` desde la carpeta del repositorio (o un `.zip`) y luego tus distros (`--check` solo mira, `--no-guests`) |
| `nexo tools [COMANDO…]` | Archivos entre móviles: `send`, `fetch`, `server`, `discover`, `pair`, `connect`, `browse`, `ls`, `get`, `put`, `web`… ([guía](docs/NEXO-TOOLS.md)) |
| `nexo usb list\|permit\|monitor\|bridge\|status\|stop\|reset` | Arduino, ESP32 y adaptadores USB↔serie conectados al móvil: ver qué ve Android, pedir el permiso, un monitor serie y un puerto serie para `avrdude`, `esptool`, PlatformIO… ([guía](docs/USB.md)). Necesita python3 salvo `list` |
| `nexo usb mounts\|access\|ls\|stat\|cat\|get\|put\|mkdir\|rm\|mv\|df\|eject` | Pendrives, discos duros y SSD que monta Android: ver los discos, dar acceso, listar, copiar en los dos sentidos, crear, borrar, mover, espacio libre y expulsar ([guía](docs/USB-ALMACENAMIENTO.md)). Necesita python3 salvo `mounts` |
| `nexo setup-dbus [--uninstall]` | Activa `nexo-dbus` (música MPRIS, Bluetooth BlueZ, red NetworkManager y notificaciones del móvil), con arranque automático (`--no-start`, `--own-bus`, `--launcher ARCHIVO`, `--system-policy` para un bus del sistema de verdad). Necesita python3 |
| `nexo dbus start\|stop\|restart\|status\|env\|run` | Atajo a `nexo-dbus` (`status` dice qué servicio está activo y por qué no) |
| `nexo start` | (Termux) abre la app Nexo para despertar el puente |
| `nexo doctor [--fix]` | Diagnóstico de todo el enlace; `--fix` intenta repararlo |
| `nexo version [--check]` · `nexo logs [N]` · `nexo config` | Versión (y si cliente y app son compatibles), lo último que anotó la app, ajustes del cliente |
| `nexo ping` · `nexo raw 'JSON'` | Comprobar la app; petición cruda (hace falta `NEXO_ALLOW_RAW=1`) |

**Opciones:** `--json` (el campo `data`) · `--short` · `--env` · `--waybar` · `--polybar` · `--i3status` · `--qml` · `--dunst` · `--tmux` · `--starship` · `--csv` ·
`--pretty` (con `watch`) · `--host H` `--port P` `--timeout S` `--cache S`.

**Códigos de salida:** `0` bien · `1` error · `2` uso incorrecto · `3` hace falta un toque en el móvil, o la conexión no se confirmó ·
`10` sin conexión con la app · `11` token · `12` sin respuesta a tiempo (app congelada por el sistema).

Si la app no contesta, el cliente reintenta **una vez** antes de rendirse (solo repite lo que es seguro repetir: nunca un «siguiente» o un «subir volumen»).

**Claves de WiFi sin dejarlas en el historial:**

```bash
read -rsp "Clave: " P; echo; nexo wifi connect MiCasa --pass-stdin <<<"$P"; unset P
```

(También sirve la variable `NEXO_WIFI_PASSWORD`.) Sin `jq`, Nexo funciona igual, pero muestra el JSON sin formato.

---

## Archivos entre móviles (`nexo tools`)

`nexo tools` pasa y explora archivos **por la red WiFi local**, sin cables ni nube, entre tus móviles (cualquier Termux o distro) y tus PC con Linux. Es independiente del puente.

```bash
nexo tools send foto.jpg                       # móvil A: da una IP y un código de un solo uso
nexo tools fetch 192.168.1.23 K3M9-7QWX-P2TB   # móvil B: lo recibe

nexo tools server ~/storage/shared             # móvil A comparte una carpeta (solo lectura)
nexo tools discover                            # móvil B: ¿qué móviles con Nexo hay aquí?
nexo tools connect 192.168.1.23 --code XXXX-XXXX-XXXX --name Tablet
nexo tools browse Tablet                       # explorador en la terminal  ·  nexo tools web Tablet: en el navegador
```

Ve **todas las carpetas y todas las extensiones** (filtros `--ext`, `--find`, `--types`), baja carpetas enteras de forma reanudable y comprobada con SHA‑256, y —solo si compartes con `--rw` y el otro se empareja con `pair --rw`— sube, crea carpetas y renombra;
**borrar manda a una papelera** (`.nexo-trash`), nunca borra de verdad. Seguridad: certificado propio con huella fijada (*pinning*), código de emparejamiento de un solo uso con prueba HMAC atada al certificado, un token por dispositivo (revocable),
nunca sirve `~/.ssh`, `~/.gnupg` ni lo que guarda Nexo. **Todo está probado entre dos «dispositivos» simulados en una máquina; entre dos móviles reales, no.** Detalles, API y solución de problemas: [`docs/NEXO-TOOLS.md`](docs/NEXO-TOOLS.md).

---

## USB: Arduino, ESP32, adaptadores serie y discos (`nexo usb`)

Conecta una placa o un adaptador USB↔serie al móvil (cable OTG o hub) y úsalo **desde la distro** como si fuera un `/dev/ttyACM0`:

```bash
nexo usb list                      # lo que Android ve por USB (también teclados, ratones, discos y hubs; los puertos serie se usan aquí, los discos más abajo)
nexo usb permit                    # Android pregunta «¿permitir?» en la pantalla del móvil
nexo usb monitor -b 9600           # monitor serie en la terminal (salir: Ctrl+])
nexo usb bridge --rfc2217 0 --detach   # un puerto serie para avrdude, arduino-cli, PlatformIO, screen…, y un servidor RFC 2217 para esptool
```

Una distro de proot no puede abrir `/dev/bus/usb` ni montar nada, así que la **app** abre el dispositivo con la API oficial de Android (con tu permiso) y le pasa a Linux solo los bytes de la línea
serie. Controladores propios para CDC‑ACM (Arduino Uno/Mega/Leonardo, ESP32 con USB nativo, Pico…), CP210x, FTDI y CH340/CH341; el PL2303 se enseña pero no se usa. Emula el **reinicio automático del Arduino**
al abrir el puerto, y si desenchufas el cable **el puerto se queda donde está** y se recupera al volver a enchufarlo. El puerto de la distro es un PTY, no un dispositivo USB: `lsusb` y los IDE que buscan puertos
solos no lo ven (hay que darles la ruta). **Probado contra una app simulada, con pruebas de los controladores en una JVM y con la compilación contra Android; no con una placa ni un móvil reales:**
[`tests/usb_hardware_check.sh`](tests/usb_hardware_check.sh) es la prueba para hacerlo (eco, cargador del Arduino, `esptool`, desenchufar) y da un informe para pegar. Guía, herramientas, límites y solución de problemas: [`docs/USB.md`](docs/USB.md).

### Discos: pendrives, discos duros y SSD

Conecta un disco al móvil (cable OTG o hub): **Android lo monta** y Nexo te deja explorarlo y copiar sus archivos **desde la distro**, sin root:

```bash
nexo usb mounts                              # qué discos montó Android y si Nexo ya puede entrar
nexo usb access                              # solo la primera vez: eliges el disco en el selector de Android → «Usar esta carpeta»
nexo usb ls -l /                             # mira dentro
nexo usb put -r proyecto /Copias/            # de tu distro al disco
nexo usb get -r /Documentos ~/documentos     # del disco a tu distro
nexo usb eject                               # antes de desenchufar
```

No hay `mount` ni `/dev/sda` en la distro (no es root y el kernel es el de Android): la **app** entra en el disco con el *Storage Access Framework* —el selector de carpetas del sistema, **sin pedir «acceso a todos los archivos»**— y le pasa a Linux las operaciones sobre los archivos que tú autorizaste (leer, escribir, crear, borrar, mover, expulsar). Un archivo se escribe con un nombre provisional y se renombra al terminar, así que nunca aparece a medias; `--verify` compara SHA‑256; FAT32 no admite archivos de 4 GiB o más y Android decide qué sistemas de archivos monta (casi siempre FAT32 y exFAT; NTFS y ext4 según el móvil). **Probado contra una app simulada (cada disco es una carpeta), con pruebas de las reglas en una JVM y con la compilación contra Android; no con un móvil ni un disco reales:** [`tests/usb_storage_hardware_check.sh`](tests/usb_storage_hardware_check.sh) es la prueba para hacerlo y da un informe para pegar. Guía, reglas del disco, expulsión y solución de problemas: [`docs/USB-ALMACENAMIENTO.md`](docs/USB-ALMACENAMIENTO.md).

---

## Red y notificaciones del móvil (`nexo net` y `nexo notif`)

**`nexo net`** dice por dónde sale el móvil a internet ahora mismo (lo que Android llama la «red predeterminada»): WiFi, **datos móviles**, cable, Bluetooth o VPN; si esa red tiene internet **de verdad**
(Android lo comprueba por su cuenta, así que distingue un portal cautivo o un WiFi sin salida de uno que funciona) y si es **de pago** (datos limitados). No necesita ningún permiso nuevo ni la ubicación.

```console
$ nexo net
Red: datos móviles + VPN · con internet · de pago (datos limitados)
$ nexo net --short                 # datos móviles + VPN   (también --json, --env, --csv, --waybar, --polybar, --qml…)
$ nexo watch net                   # un evento cada vez que cambia: del WiFi a los datos, una VPN, un portal cautivo…
```

Con `nexo-dbus`, `nmcli` y los applets de red de la distro ven **esa red real** (hasta ahora solo veían el WiFi): conectividad completa, limitada (portal cautivo o sin internet de verdad) o ninguna, y red «medida».

**`nexo notif`** trae las notificaciones del móvil a la distro. **Es opcional y viene apagado de fábrica**, porque lo que dicen tus notificaciones es lo más privado que hay en el móvil:
no sale nada de Android hasta que, en la app, das el **acceso a notificaciones** (el mismo que usa la música) **y** activas el interruptor **«Reenviar notificaciones a Linux»**.

```console
$ nexo notif status
Notificaciones: se reenvían a Linux · 3 en el móvil ahora
$ nexo notif list                  # las más nuevas primero, con la clave de cada una
3 notificaciones
• com.whatsapp · WhatsApp Ana: ¿Vienes a cenar?   (ahora)
    clave: k1
$ nexo notif dismiss k1            # la quita del móvil (o --all)
$ nexo notif watch --pretty        # las que lleguen y se quiten, en vivo
```

Con `nexo-dbus` (`nexo setup-dbus`) salen **solas en el escritorio de la distro** (dunst, mako, swaync, GNOME, KDE…) con el nombre de la app, el título y el texto, y si las cierras allí **se quitan también del móvil**.
Solo viajan por `127.0.0.1` y solo hacia programas con tu token que las piden: **Nexo no las guarda nunca** (ni en el móvil ni en la caché del cliente), nunca reenvía las suyas y `nexo watch` sin tema sigue trayendo solo wifi, bt, audio y media (las notificaciones se piden a propósito: `nexo watch notif`).
Android no deja a una app quitar las notificaciones **fijas** ni las de servicios en marcha: `nexo notif dismiss` te lo dice en vez de fingir. **Probado contra una app simulada, un demonio de avisos simulado y con pruebas de las reglas en una JVM, y compilado contra Android; no en un móvil, ni con dunst, mako, GNOME o KDE de verdad.**
Detalles, privacidad y solución de problemas: [`docs/INTEGRACION-ESCRITORIO.md`](docs/INTEGRACION-ESCRITORIO.md#notificaciones-del-móvil-orgfreedesktopnotifications) y [`docs/PROTOCOLO.md`](docs/PROTOCOLO.md).

---

## Para barras de estado, escritorios y scripts

Cada formato de salida es una opción de cualquier comando de estado (`nexo wifi status --waybar`, `nexo media status --polybar`, `nexo status --qml`…):

| Opción | Para quién | Qué devuelve |
|---|---|---|
| `--short` | prompts, scripts | Una línea corta: `MiCasa`, `60%`, `Canción — Artista` |
| `--env` | scripts de shell | Variables: `eval "$(nexo wifi status --env)"` → `NEXO_WIFI_SSID`, `NEXO_WIFI_RSSI`, `NEXO_WIFI_GATEWAY`… |
| `--json` | cualquier programa | El campo `data` de la respuesta, tal cual |
| `--waybar` | Waybar | `{"text","alt","class","percentage","tooltip"}` |
| `--polybar` | Polybar | Texto con colores y clics (`%{F…}`, `%{A1:…:}`): clic = alternar, rueda = volumen / siguiente |
| `--i3status` | i3bar, i3blocks, swaybar | Un bloque JSON del protocolo i3bar |
| `--qml` | Quickshell y cualquier QML | JSON plano `{"topic","text","icon","glyph","active","tooltip","state","percentage"}` (una línea por tema con `nexo status`) |
| `--dunst` | dunst, mako, swaync | Texto con icono para `notify-send` |
| `--tmux` | tmux | Texto corto para `status-right` |
| `--starship` | starship | Texto para un módulo `custom` (vacío si no hay nada que mostrar) |
| `--csv` | hojas de cálculo, `awk` | CSV en las listas (`wifi scan`, `wifi saved`, `bt paired`, `audio outputs`, `notif list`) |

Las barras (`--waybar`, `--polybar`, `--i3status`, `--qml`, `--tmux`, `--starship`) **nunca fallan**: si la app no contesta (móvil dormido, puente apagado)
muestran el último valor conocido (hasta 15 minutos) o «offline», en lugar de llenar tu barra de errores. Usan una caché pequeña en `~/.cache/nexo/`
(`--cache S` o `NEXO_CACHE_TTL` cambian su vigencia; `0` la apaga). Los iconos son de Nerd Font; `NEXO_ICONS=none` los quita.

```bash
nexo status --short                      # MiCasa · conectado · 60% · Canción — Artista
eval "$(nexo wifi status --env)"         # NEXO_WIFI_CONNECTED=1  NEXO_WIFI_SSID='MiCasa'  NEXO_WIFI_RSSI=-55 …
[ "$NEXO_WIFI_CONNECTED" = 1 ] && echo "Conectado a $NEXO_WIFI_SSID"
nexo watch --pretty                      # wifi  → conectado a MiCasa
notify-send "$(nexo audio status --dunst)"
```

```jsonc
// Waybar: ~/.config/waybar/config
"custom/nexo-wifi": {
    "exec": "nexo wifi status --waybar",
    "return-type": "json",
    "interval": 10,
    "signal": 8,                       // se refresca también con: pkill -RTMIN+8 waybar
    "format": "WiFi {text}"
},
"custom/nexo-media": {
    "exec": "nexo media status --waybar",
    "return-type": "json",
    "interval": 3,
    "on-click": "nexo media playpause",
    "on-scroll-up": "nexo audio volume +5",
    "on-scroll-down": "nexo audio volume -5"
}
```

```ini
; Polybar
[module/nexo-wifi]
type = custom/script
exec = nexo wifi status --polybar
interval = 10

[module/nexo-media]
type = custom/script
exec = nexo media status --polybar
interval = 3
```

```bash
# Refrescar la barra en cuanto cambie algo, sin esperar al intervalo:
nexo watch | while read -r _; do pkill -RTMIN+8 waybar; done
```

```qml
// Quickshell (ejemplo sin probar): una línea JSON por tema
Process {
    id: nexo
    command: ["nexo", "status", "--qml"]
    stdout: SplitParser { onRead: line => root.update(JSON.parse(line)) }
}
Timer { interval: 5000; running: true; repeat: true; triggeredOnStart: true; onTriggered: nexo.running = true }
```

tmux: `set -g status-right '#(nexo status --tmux)'` · starship: `[custom.nexo]` con `command = "nexo status --starship"`.

> De todo esto está probada la salida de `nexo` (formato, JSON, variables, cuando la app no responde). Las configuraciones de Waybar, Polybar, tmux, starship y Quickshell de arriba
> son el formato estándar de esos programas, pero no se han probado en un escritorio real.

---

## Integración universal

Nexo no convierte el móvil en un adaptador WiFi o Bluetooth de Linux: **controla** lo que Android ya tiene y se lo cuenta a tu escritorio.
Esa cuenta llega por la línea de comandos y, desde la 0.3, también por **D‑Bus** (con `nexo-dbus`), que es lo que hablan los programas de Linux. Primero la música, desde la 0.4.0‑beta1 el Bluetooth y el WiFi, y desde la 0.4.3 la red real del móvil (datos móviles incluidos) y las notificaciones (opcionales):

| Programa o protocolo | Cómo se integra | Estado |
|---|---|---|
| Waybar · Polybar · i3bar/i3blocks/swaybar · tmux · starship | Opciones `--waybar`, `--polybar`, `--i3status`, `--tmux`, `--starship` | ✅ v0.2 (formato probado; programa real sin probar) |
| Quickshell y otros shells en QML (p. ej. Quantum OS) | Opción `--qml` | ✅ v0.2 (formato probado; programa real sin probar) |
| dunst · mako · swaync | Opción `--dunst` con `notify-send` | ✅ v0.2 (formato probado) |
| Scripts, hojas de cálculo | `--env`, `--json`, `--csv` | ✅ v0.2 |
| `playerctl`, módulo `mpris` de Waybar, Quickshell, GNOME, KDE (MPRIS) | `nexo-dbus` publica la música del móvil como un reproductor más (`nexo setup-dbus`; [guía](docs/INTEGRACION-ESCRITORIO.md)) | ✅ v0.3 (probado con `busctl` y `gdbus` contra un bus real; los programas reales, sin probar) |
| `bluetoothctl`, Blueman y applets de Bluetooth (BlueZ) | `nexo-dbus` emula `org.bluez`: adaptador, dispositivos emparejados, batería, encender/apagar (conectar un dispositivo pide un toque en el móvil) | 🚧 v0.4.0‑beta1 (probado con `busctl` y `gdbus` contra un bus real; `bluetoothctl`, sin probar) |
| `nmcli`, `nm-applet`, applets de red (NetworkManager) | `nexo-dbus` emula `org.freedesktop.NetworkManager`: `wlan0`, redes a la vista y guardadas, conectar/desconectar, encender/apagar y, desde la 0.4.3, el estado global real del móvil (datos móviles, VPN, red de pago, sin internet de verdad) | 🚧 v0.4.0‑beta1 y 0.4.3 (probado con `busctl` y `gdbus` contra un bus real; `nmcli`, sin probar) |
| Notificaciones del móvil en tu escritorio: dunst · mako · swaync · GNOME · KDE | `nexo-dbus` es cliente de `org.freedesktop.Notifications` (acceso a notificaciones de Android + interruptor «Reenviar notificaciones a Linux», apagado de fábrica); cerrar un aviso en el escritorio lo quita del móvil | 🚧 v0.4.3 (probado con un demonio de avisos simulado y `busctl`; dunst, mako, GNOME y KDE reales, sin probar) |
| `nexo net`, `nexo notif`, `nexo watch net notif` | Línea de comandos, scripts y barras (`--waybar`, `--qml`…) | ✅ v0.4.3 (el cliente, contra la app simulada; la app, sin ejecutar en un móvil) |

El plan completo, con lo que **no** se puede hacer, está en [`docs/ROADMAP.md`](docs/ROADMAP.md) y [`docs/LIMITACIONES.md`](docs/LIMITACIONES.md).

---

## Lo que Android no deja hacer

Nexo **controla** el WiFi, el Bluetooth, el audio y la música de Android; no se los **entrega** a Linux como adaptadores. Lo que Android no permite a una app normal se dice claro, no se disimula
(el detalle, con las causas, está en [`docs/LIMITACIONES.md`](docs/LIMITACIONES.md)):

- **Conectar o desconectar un dispositivo Bluetooth concreto.** Android lo reserva al sistema. `nexo bt connect` valida la dirección y deja una
  notificación que abre los ajustes de Bluetooth (código de salida 3). Sí puedes encender y apagar el Bluetooth, ver los emparejados y saber cuáles están conectados.
- **Desemparejar** (`bt forget`) usa una función de Android que no es pública (se llama por reflexión; solo es posible porque la app apunta a la API 28). Si el sistema la bloquea,
  Nexo cae a «hace falta un toque» y abre los ajustes de Bluetooth. **Renombrar** (`bt rename`) necesita Android 12 o más.
- **Cambiar la salida de audio del sistema** (`audio switch`). Android no deja a una app normal redirigir el audio: Nexo abre el panel de volumen con una notificación.
  El volumen y el silencio de la música sí se controlan directamente.
- **Ver y controlar la música** necesita el «acceso a notificaciones». Sin él, `media status` dice que falta (`listener: false`) y los controles piden el permiso.
- **Notificaciones hacia Linux (0.4.3).** Hace falta ese mismo acceso **y** el interruptor «Reenviar notificaciones a Linux» (apagado de fábrica). Android **no deja quitar** las notificaciones fijas ni las de servicios en marcha
  (reproductores, VPN, «Nexo activo»…): `nexo notif dismiss` dice cuáles no se pudieron quitar. Las nuevas solo llegan en vivo mientras haya alguien suscrito (`nexo notif watch`, `nexo-dbus`): lo que llegó antes no se recupera,
  y `nexo notif list` enseña únicamente lo que el móvil tiene ahora. Si el sistema suelta el servicio de notificaciones (algunos fabricantes lo hacen), Nexo le pide a Android que lo enlace otra vez; si no vuelve, apaga y enciende el acceso en los ajustes.
- **Red del móvil (0.4.3).** `nexo net` cuenta la red **predeterminada** (la que Android usa para salir a internet), no todas las conectadas a la vez: con WiFi y datos móviles encendidos, dirá la que Android esté usando. No da la IP de los datos móviles ni el nombre del operador.
- **Redes solo WPA3 y redes de empresa (802.1X).** La API clásica no permite crearlas: `nexo wifi connect` abre el panel de WiFi con una notificación.
- **Redes guardadas** (`wifi saved`, `wifi forget`): Android 10 o más solo las enseña a apps que apuntan a la API 28 y tienen el permiso de ubicación (por eso Nexo apunta a 28);
  solo puedes olvidar las que el sistema deja borrar a esta app. Si no, hace falta un toque.
- **Encender o apagar el WiFi/Bluetooth en algunos móviles.** Nexo apunta a la API 28 (igual que Termux) justo para que Android se lo permita directamente.
  Si el sistema o el fabricante se niega (modo avión, punto de acceso activo, restricciones de la capa), responde «hace falta un toque»
  (código 3) y deja una notificación que abre el panel correcto.
- **Punto de acceso (hotspot).** La API pública solo permite un hotspot «local» temporal, no el de siempre; Nexo no lo controla.
- **Escaneos de WiFi limitados.** Android admite unos 4 cada 2 minutos; pasado el límite, `wifi scan` devuelve la última lista (`fresh:false`).
  En Opciones de desarrollador existe el interruptor «Wi‑Fi scan throttling» si quieres quitar el límite.
- **El nombre de la red** necesita el permiso de ubicación **y** la ubicación del sistema encendida; si no, sale «(red oculta: falta permiso de ubicación)».
- **USB: puertos serie y discos, no «USB de verdad».** Una distro de proot no puede abrir `/dev/bus/usb` ni montar nada: llegan los puertos serie que la app abre con tu permiso y los archivos de los discos que Android monta y tú autorizas (`nexo usb`). En la distro no hay `/dev/sda`, `lsblk` ni `mount`: a un disco se llega con `nexo usb ls`, `get` y `put`. Teclados, ratones y hubs salen en `nexo usb list` pero no se pasan a la distro. El puerto serie es un PTY, no `/dev/ttyACM0`: `lsusb` y los IDE que buscan puertos solos (Arduino IDE) no lo ven. Las placas de USB nativo que se reprograman con un «toque» a 1200 baudios (Leonardo, Pro Micro) no están cubiertas. Un disco que Android no monta (NTFS o ext4 en muchos móviles) no se puede usar, y la expulsión desde Nexo puede ser rechazada por Android (entonces `nexo usb eject` te lo dice).

---

## Seguridad

- **Solo escucha en `127.0.0.1`**: nunca es visible desde la red.
- Cualquier app del móvil puede abrir un puerto local, así que **cada conexión debe empezar con `hello` y un token** aleatorio de 192 bits (`SecureRandom`).
  Se compara en tiempo constante; un token malo espera 0,8 s antes de recibir el rechazo y se corta; sin autenticarse en 8 s también se corta;
  como máximo 16 clientes a la vez y 64 KiB por línea.
- El único comando que no pide token es `bootstrap`, que entrega el instalador (contenido público) y tiene límite de ritmo (1 cada 2 s, 10 por minuto). **Nunca entrega el token.**
- **El instalador se verifica.** El comando que copia la app lleva la huella SHA‑256 del instalador: si otra app se adelantara a ocupar el puerto y sirviera
  otra cosa, la comprobación falla y no se ejecuta nada.
- El comando de instalación **lleva el token**, así que queda en el historial de esa shell. Es el mismo secreto que guarda `~/.config/nexo/config` (modo 600,
  dentro de los datos privados de Termux). Si lo pegaste donde no debías, pulsa **Token nuevo** en la app y vuelve a enlazar (`nexo rekey`).
  Para no dejarlo en el historial: `nexo pair --token-stdin`.
- La app marca como sensible lo que copia al portapapeles, desactiva las copias de seguridad de Android (`allowBackup=false`) y, mientras el token está a la vista,
  impide las capturas de pantalla (`FLAG_SECURE`).
- En las distros, `setup-guests` deja el enlace en `/etc/nexo/config` (modo 644, para que lo lean todos los usuarios de esa distro; con `--private`, solo root). Queda dentro de los datos privados de Termux,
  protegidos por el aislamiento de Android.
- `nexo raw` (peticiones sin filtrar) está apagado salvo que pongas `NEXO_ALLOW_RAW=1`. No es una barrera de seguridad (quien tiene el token puede hablar con la app a mano), sino un freno a los errores.
- El «acceso a notificaciones» lo concedes tú y se puede quitar en cualquier momento en los ajustes de Android. Para la música Nexo solo usa las sesiones de medios. **Reenviar tus notificaciones a Linux (0.4.3) es aparte y viene apagado**:
  hasta que actives el interruptor de la app no sale ninguna de Android. Activado, solo viajan por `127.0.0.1`, solo a programas con tu token que se suscriben al tema `notif`, **no se guardan** (ni la app ni el cliente las apuntan en ningún sitio, ni en el registro ni en la caché), se limita el ritmo y el tamaño de lo que sale y nunca se reenvían las de la propia Nexo.
  Lo que ya se ha reenviado a tu escritorio queda en manos de tu demonio de avisos (dunst, mako…), que puede guardar su propio historial.
- El permiso `INTERNET` solo sirve para abrir el socket local: la app no se conecta a ningún servidor. Sin anuncios, sin telemetría.
- **Discos USB** (`nexo usb ls`, `get`, `put`…): Nexo **no pide «acceso a todos los archivos»**. El acceso lo concedes **disco por disco** en el selector de carpetas de Android (solo se acepta una carpeta del propio disco; si eliges una subcarpeta, esa es la raíz y Nexo no sale de ella) y se quita con `nexo usb access --revoke`. Las rutas se validan en la app, nunca borra recursivamente de una vez, no abre ningún puerto nuevo y cada operación pasa por la conexión autenticada con el token.
- **Puertos serie** (`nexo usb list`, `monitor`, `bridge`): Android pide el permiso **por dispositivo** y solo la app Nexo lo tiene. El servidor RFC 2217 y el TCP crudo de `nexo usb bridge` **no tienen contraseña** y escuchan solo en `127.0.0.1` (cualquier programa del móvil puede escribir en tu placa mientras estén abiertos: ciérralos con `nexo usb stop`).
- **`nexo tools`** (archivos entre móviles) es aparte del puente y no usa su token: su modelo de seguridad (certificado fijado por huella, códigos de un solo uso con prueba HMAC, tokens por dispositivo, solo lectura por omisión, papelera en vez de borrar, rutas prohibidas, límite de intentos) está en [`docs/NEXO-TOOLS.md`](docs/NEXO-TOOLS.md#emparejamiento-y-seguridad).
- El protocolo completo está en [`docs/PROTOCOLO.md`](docs/PROTOCOLO.md), por si quieres escribir otro cliente.

---

## Que Android no cierre la app

Xiaomi/HyperOS y otras capas cierran (o **congelan**) las apps en segundo plano con más ganas que Android puro. Para que el puente sobreviva:

1. En Nexo, pulsa **Ahorro de batería** y deja la batería de Nexo en «Sin restricciones».
2. Pulsa **Inicio automático (Xiaomi)** y activa Nexo.
3. Bloquéala en la vista de recientes (mantén pulsada su tarjeta) para que «Limpiar todo» no la cierre.
4. Activa **Iniciar con el móvil** si quieres que el puente vuelva solo tras reiniciar.

> **Esto no es opcional.** Si HyperOS congela la app, el socket acepta la conexión pero la app no responde, y el cliente devuelve el error 12.

Nexo ayuda por su parte: el cliente reintenta una vez; las barras enseñan el último valor en vez de fallar; `nexo start` abre la app para despertarla;
`nexo doctor --fix` intenta repararlo todo; el puente comprueba por sí mismo que responde (cada ~45 s) y reinicia su servidor si no; y si el puerto sigue ocupado tras un cierre brusco,
reintenta cada 5 s. Aun así, **nada de esto sustituye** a los ajustes de batería de arriba. Los nombres de los menús cambian de una versión a otra; los botones de la app abren la pantalla correcta.

---

## Solución de problemas

Empieza siempre por `nexo doctor` (y `nexo doctor --fix`): te dice qué entorno ve, si hay token y si la app responde.

| Síntoma | Causa probable | Qué hacer |
|---|---|---|
| `Nexo: La conexión se cortó o no respondió a tiempo` (código 12) | HyperOS ha congelado la app, o el servidor está bloqueado | Asegúrate de tener los permisos de batería configurados (ver arriba). Prueba `nexo start`; si no, fuerza la detención de Nexo, vuelve a abrirla y pulsa **Iniciar puente** |
| `No se puede conectar con Nexo en 127.0.0.1:8765` | Puente apagado, Android cerró la app, o cambiaste el puerto | `nexo start`, o abre Nexo y pulsa **Iniciar puente**. Si cambiaste el puerto, vuelve a copiar el comando de instalación |
| `Nexo rechazó el token` | Pulsaste **Token nuevo** | `nexo rekey` (o pega de nuevo el comando de instalación) |
| El comando de instalación dice «no se pudo instalar» | Puente apagado, otra app usa ese puerto, o tu bash no sabe abrir `/dev/tcp` (raro) | Enciende el puente. Si persiste, cambia el puerto en Nexo y copia el comando otra vez; o instala a mano: `bash termux/install.sh` y `nexo pair TOKEN` |
| `wifi on` / `bt on` sale con código 3 | Android no dejó que Nexo lo hiciera solo | Toca la notificación que dejó Nexo |
| `wifi scan` sale vacío | Ubicación del sistema apagada, o límite de escaneos | Enciende la ubicación; espera un par de minutos |
| El WiFi sale como «red oculta» | Falta el permiso de ubicación, o está apagada la ubicación del sistema | Concede el permiso en Nexo. Si solo falla con la app cerrada, pon la ubicación de Nexo en «Permitir siempre» |
| `media status` dice «falta el acceso a notificaciones» | No has dado a Nexo el acceso a notificaciones | Botón **Dar acceso a notificaciones**; en Android 13+ puede hacer falta «Permitir ajustes restringidos» (ver [Empezar](#2-encender-el-puente)) |
| `media status` dice que no suena nada | Ninguna app tiene una sesión de medios activa | Pon algo a sonar; algunas apps solo crean la sesión al darle a play |
| `bash: nexo: not found` en la distro | Falta `bash` en la distro | Arch: `pacman -S bash jq`. Alpine: `apk add bash jq`. Debian/Ubuntu: `apt install bash jq` |
| La salida sale como JSON sin formato | Falta `jq` | `pkg install jq` (Termux) o instálalo con el gestor de la distro |

Más preguntas y respuestas en [`docs/FAQ.md`](docs/FAQ.md). Para desinstalar el cliente: `nexo unpair && rm "$(command -v nexo)"`.

---

## Desarrollo

Para compilar el APK manualmente (solo desarrolladores):

```bash
cd android
export ANDROID_HOME=/ruta/al/sdk
./gradlew assembleRelease
```

El workflow `.github/workflows/build.yml` compila automáticamente y firma el APK usando los secretos del repositorio, publicándolo en Releases al crear una etiqueta
(`git tag v0.4.3 && git push --tags`; si la etiqueta lleva un guion, la Release se marca como versión preliminar). Cómo preparar la firma y cómo colaborar: [`docs/CONTRIBUIR.md`](docs/CONTRIBUIR.md).

```bash
bash tests/run_tests.sh      # 2555 pruebas: cliente, instalador, nexo-dbus, nexo-tools y nexo-usb (puertos serie y discos, red y notificaciones) contra una app simulada (bash, python3 y jq; las de D-Bus piden además dbus-daemon, busctl y gdbus; las de nexo-tools, openssl)
NEXO_TESTS_ONLY=usb bash tests/run_tests.sh   # solo nexo usb (puertos serie)
NEXO_TESTS_ONLY=storage bash tests/run_tests.sh   # solo los discos USB
NEXO_TESTS_ONLY=net bash tests/run_tests.sh   # solo nexo net y nexo notif (cliente)
NEXO_TESTS_ONLY=dbus NEXO_TESTS_DBUS_PART=notif bash tests/run_tests.sh   # solo las notificaciones de nexo-dbus
cd android && ./gradlew testDebugUnitTest      # 98 pruebas de JVM: controladores USB serie, reglas de los discos, de la red y de las notificaciones (sin móvil)
```

Las pruebas incluyen una comprobación de **contrato** (`tests/check_contract.py`): compara el código Kotlin de la app con la app simulada y con `docs/PROTOCOLO.md`
(comandos, campos de cada respuesta, códigos de error, versiones), porque la app real no se puede ejecutar en CI.

```
android/                       Proyecto de Android (Gradle, Kotlin 2.0, AGP 8.7, JDK 17; minSdk 26, targetSdk 28)
  app/src/main/java/org/nexo/bridge/
    MainActivity.kt            Pantalla (se construye en código, sin layouts XML)
    BridgeService.kt           Servicio en primer plano, avisos de Android → eventos, reintento de puerto y auto-ping
    BridgeServer.kt            Servidor TCP en 127.0.0.1: autenticación, comandos con plazo, eventos, bootstrap
    Commands.kt                Reparte cada comando
    WifiHandler.kt             Habla con WifiManager (estado, escaneo, conexión, redes guardadas)
    BluetoothHandler.kt        Habla con BluetoothAdapter y los perfiles (emparejados, olvidar, alias, info)
    UsbSerial.kt               Controladores USB serie (CDC-ACM, CP210x, FTDI, CH34x): lógica pura, sin Android, probada en JVM
    UsbHandler.kt              USB host: dispositivos, permisos, sesiones y flujo de datos (UsbManager)
    UsbAttachedActivity.kt     El aviso «abrir Nexo cuando se conecte»
    StorageLogic.kt            Discos USB: rutas, reglas de crear/borrar/renombrar y tabla de archivos abiertos (sin Android, probada en JVM)
    StorageSaf.kt              Discos USB: lo que toca el disco (Storage Access Framework: DocumentsContract y lectura/escritura por posición)
    StorageVolumes.kt          Discos USB: qué discos hay (StorageManager) y a cuáles tiene acceso Nexo
    StorageGrantActivity.kt    Discos USB: el selector de carpetas de Android donde das el acceso
    StorageHandler.kt          Discos USB: los comandos storage.* y la expulsión
    AudioHandler.kt            Volumen de música y salidas de audio (AudioManager)
    MediaHandler.kt            Sesiones de medios: qué suena, controles, carátula (MediaSessionManager)
    NexoNotificationListener.kt  El «acceso a notificaciones» que Android exige para ver la música de otras apps (y, si el usuario lo activa, el origen de las notificaciones que se reenvían)
    NotifBridge.kt             Notificaciones → Linux: eventos posted/removed con límite de ritmo, notif.list y notif.dismiss (solo con el reenvío activado)
    NotifLogic.kt              Notificaciones: qué se reenvía y qué no, recortes, claves y motivos de cierre (sin Android, probada en JVM)
    NetHandler.kt              Red del móvil: net.status y el tema net (ConnectivityManager, red predeterminada)
    NetLogic.kt                Red del móvil: de las capacidades de Android al tipo, internet, validada, de pago, VPN y portal cautivo (sin Android, probada en JVM)
    StartActivity.kt           Actividad sin pantalla que enciende el puente (nexo start)
    Bootstrap.kt               Arma el instalador para Termux y su huella SHA-256
    UserAction.kt              Notificaciones «toca para…» cuando Android no deja hacerlo solo
    Prefs.kt · BridgeState.kt · Protocol.kt · Util.kt · BootReceiver.kt
termux/
  bin/nexo                     El cliente
  bin/nexo-dbus                Servicios D-Bus (MPRIS, BlueZ, NetworkManager); un solo archivo de Python 3, sin librerías
  bin/nexo-tools               Archivos entre móviles (servidor HTTPS, descubrimiento, emparejamiento, explorador, gestor web); bash con Python 3 embebido
  bin/nexo-usb                 Arduino, ESP32, adaptadores USB↔serie (monitor, puerto PTY, RFC 2217, TCP) y discos USB (mounts, ls, get, put…); un solo archivo de Python 3, sin librerías
  install.sh                   El instalador (también --uninstall)
  oneliner.tpl                 Plantilla del comando de una línea que copia la app
tests/                         App simulada (fake_app.py) y demonio de avisos simulado (fake_notifd.py), pruebas (run_tests.sh, dbus_tests.sh, dbus_system_tests.sh, dbus_notif_tests.sh, net_notif_tests.sh, tools_tests.sh, usb_tests.sh, usb_storage_tests.sh, ui_tests.py, dbus_probe.py, dbus_hold.py, tools_probe.py, usb_client.py),
                               las pruebas con hardware real (usb_hardware_check.sh y usb_storage_hardware_check.sh), la referencia de velocidades (ref_baud.py) y la comprobación de contrato (check_contract.py)
android/app/src/test/          Pruebas de JVM de los controladores USB (UsbSerialTest.kt), de las reglas de los discos (StorageLogicTest.kt), de la red (NetLogicTest.kt) y de las notificaciones (NotifLogicTest.kt)
docs/                          PROTOCOLO · LIMITACIONES · ANDROID-VERSIONES · FAQ · CONTRIBUIR · ROADMAP · INTEGRACION-ESCRITORIO · NEXO-TOOLS · USB · USB-ALMACENAMIENTO
.github/workflows/build.yml    Pruebas del cliente + compilación del APK
```

El cliente, `nexo-dbus`, `nexo-tools`, `nexo-usb` y el instalador viajan dentro del APK como *assets* (el `build.gradle.kts` apunta a la carpeta `termux/`), y el servidor los entrega por `bootstrap`.

---

## Estado y lo que falta

**Versión 0.4.3.**

- ✅ **Comprobado en móvil real (v0.1):** Xiaomi 25078RA3EL (Android 16 / SDK 36). El APK compila y se firma automáticamente con un Keystore propio a través de GitHub Actions.
  El cliente lee el WiFi/Bluetooth reales y se comunica sin problemas desde Termux Monet y desde proot-distro (probado en Arch Linux). Se corrigió un bloqueo del hilo de red
  (enviando la respuesta TCP antes de actualizar la interfaz) y se documentó la necesidad de desactivar el ahorro de batería de HyperOS.
- ✅ **Comprobado aquí (v0.2):** el cliente `nexo` y el instalador (en esa versión eran 399 pruebas: caracteres raros en nombres y claves, eventos en vivo, reintentos, app congelada, un «Termux» simulado con otro nombre de paquete,
  distros de proot, un impostor que intenta colarse en el puerto, todos los formatos de salida) y el **contrato** entre el código de la app, la app simulada y el protocolo.
  Todo el Kotlin compila sin errores contra la API real de Android.
- ✅ **Comprobado aquí (v0.3):** `nexo-dbus` con un `dbus-daemon` de verdad y dos clientes independientes (`busctl` y `gdbus`): su propio empaquetado de mensajes D‑Bus (30 tipos), el reproductor MPRIS completo
  (propiedades, metadatos, carátula, controles, `Seek`, volumen, cambios desde Android, 30 clientes a la vez), aparecer y desaparecer según haya música, app caída y vuelta, bus reiniciado, token cambiado y modo pasivo;
  `nexo setup-dbus`, `setup-guests --with-dbus` y el instalador. Las pruebas encontraron y corrigieron un fallo real (el reproductor no volvía a registrarse tras caerse la app).
- ✅ **Comprobado aquí (0.4.0‑beta1):** en un bus del sistema de pruebas (un `dbus-daemon` real, visto con `busctl` y `gdbus`): **BlueZ** (árbol de objetos, propiedades y tipos, escrituras y errores, señales, encender y apagar,
  `StartDiscovery`/`StopDiscovery`, `RemoveDevice`), **NetworkManager** (objetos, redes con intensidad y seguridad, conectar y desconectar incluidos los fallos, WiFi apagado, olvidar una red, estado global),
  cada servicio con su conexión al bus (un fallo no arrastra al otro), modo pasivo ante un BlueZ/NetworkManager de verdad o systemd, **la política del bus** (un bus que lo niega todo → `nexo setup-dbus --system-policy` → `nexo-dbus` ocupa el nombre solo),
  el bus propio (`--own-bus`, también el «del sistema» que falte dentro de un proot) y `nexo dbus status` por servicio. La batería entera se pasó como `root` y como usuario sin privilegios (`nobody`, sin `sudo`). Las pruebas encontraron y corrigieron varios fallos propios (p. ej. que la app falsa no coincidía con la real en un panel que abre, que dos pruebas «de apagado» no probaban nada porque el demonio salía antes, o que el cliente pedía `sudo` aunque la carpeta de la política fuera del propio usuario).
- ✅ **Comprobado aquí (0.4.0‑beta2):** **`nexo tools`**: servidor y cliente por HTTPS real entre dos «dispositivos» simulados en la misma máquina (cada uno con su `HOME`, su certificado y su estado): emparejamiento (código bueno, malo, gastado, caducado, 5 fallos; huella cambiada), descubrimiento por UDP,
  listados con filtros y paginación, descargas reanudables con SHA‑256, `--all`, modo escritura (subir, carpetas, renombrar, papelera, revocar), `send`/`fetch`, rutas prohibidas, enlaces simbólicos, límite de intentos y un cliente TLS lento (**175 pruebas**, en `tests/tools_tests.sh`), y el gestor web en un Chromium sin pantalla (**31 comprobaciones**, con `python3 tests/ui_tests.py`: entrar, carpetas, filtros por extensión, imágenes y textos, un HTML con `<script>` que se ve como texto y no se ejecuta, crear/subir/renombrar/borrar, pantalla de móvil de 390 px, una sesión de solo lectura y ningún error en la consola);
  **`setup-guests`** con las dos disposiciones de proot-distro, copias viejas repetidas, un `proot-distro` simulado que dice qué copia gana, enlaces propios de usuarios con el token viejo, `--with-tools`/`--uninstall`; **`nexo update`** desde carpeta, `termux/`, `.zip` y `NEXO_REPO`, con un script roto rechazado sin tocar nada y sin dejar temporales.
- ✅ **Comprobado aquí (0.4.1):** **`nexo usb`** contra la app simulada (`tests/fake_app.py`, con «chips» que imitan un CDC‑ACM, un CP210x, un FTDI, un CH340, un Arduino con su cargador STK500 y un eco): `list`, `permit` (concedido, denegado, sin contestar), `monitor`, `bridge` con el puerto PTY (todos los valores de byte, en los dos sentidos, velocidad y formato que cambia el programa, DTR/RTS), el reinicio automático del Arduino (con `inotify`, con `/proc` y sin vigilar), el servidor RFC 2217 y el TCP crudo (reinicio al primer cliente), desenchufar y volver a enchufar (el puerto se queda donde está), varios puentes a la vez, `--detach`/`status`/`stop`/`reset`, estados viejos y procesos ajenos, app caída, token malo y app anterior sin USB;
  el instalador, `setup-guests --with-usb` y `nexo update` con `nexo-usb`; **37 pruebas de JVM** de los controladores (las órdenes de control de cada chip y sus cuentas de velocidad, que además se comparan con una transcripción independiente de libftdi y de `ch341.c`: `tests/ref_baud.py`); el código de Kotlin compila contra la API real de Android; y `tests/usb_hardware_check.sh` (la prueba con hardware real) funciona contra la app simulada.
- ✅ **Comprobado aquí (0.4.2):** **los discos de `nexo usb`** contra la app simulada (cada disco es una carpeta de verdad, con su etiqueta, UUID, estado, espacio y acceso concedido o no): `mounts` (uno, varios, expulsado, sin acceso, solo lectura), `access` (concedido, denegado, sin contestar, `--revoke`), `ls` (`-lahR`, `--json`, miles de archivos paginados, nombres con acentos, espacios, emojis y `:`), `stat`, `cat` (también con la tubería cerrada), `get` y `put` (archivos de todos los tamaños, de 0 bytes a varios MiB, árboles, `-f`/`-n`, `ORIGEN/`, `--verify`, `--fix-names`, enlaces, sin espacio, disco lleno, solo lectura, desenchufar a media copia, app caída, nada a medias bajo su nombre), `mkdir`, `rm`, `mv`, `df` y `eject` (expulsado, rechazado, con error); **cada orden por los dos caminos** (por la app y directa por la ruta) **comparando resultados en ~75 casos**; `nexo watch storage` y sus eventos; que no queden archivos abiertos ni restos `.nexo-part-*`; y **35 pruebas de JVM** de las reglas de los discos (`StorageLogicTest.kt`). El código de Kotlin compila contra la API real de Android y coincide con la app simulada y con el protocolo 1.4. `tests/usb_storage_hardware_check.sh` (la prueba con un disco real) funciona contra la app simulada (también con `--unplug`, `--eject`, `--speed` y `--big`, con discos de solo lectura, casi llenos, con errores o con el límite de FAT32, y al pararlo con una señal borra su carpeta del disco).
- ✅ **Comprobado aquí (0.4.3):** **`nexo net` y `nexo notif`** contra la app simulada (`tests/fake_app.py`, protocolo 1.5): `nexo net` en todos los formatos y con WiFi, datos móviles, VPN, portal cautivo, red sin internet de verdad y sin red, con una app anterior (sin `net.status`), `nexo watch net` (reconecta, junta ráfagas y avisa si la app no ofrece el tema), las barras que nunca fallan y la caché;
  `nexo notif status`, `list` (las más nuevas primero, hasta 40), `dismiss` y `--all` (con notificaciones fijas que Android no deja quitar y claves que ya no existen, y las cuentas exactas de las que se quitaron y las que no), `watch notif` (`--pretty`, `--event` y los motivos de cierre), sin el acceso o con el reenvío apagado (código 3 y los avisos de `nexo doctor`), **que ninguna notificación llegue a la caché del cliente**, sin `jq`, por otro transporte y con la app apagada.
  **`nexo-dbus`** contra un demonio de avisos simulado (`tests/fake_notifd.py`, visto con `busctl`): llegar, reemplazar, quitar, cerrar en el escritorio y que se quite del móvil (sin bucles), urgencias y categorías, etiquetas, caracteres de control y textos enormes, un demonio que se cae, se reinicia o rechaza un aviso, ningún demonio, reenvío apagado, sin acceso y app anterior;
  y **NetworkManager con la red real** (datos móviles = red de pago, VPN, WiFi sin salida y portal cautivo = conectividad limitada, sin red) con una app nueva y con una anterior. **26 pruebas de JVM nuevas** de las reglas de la app (`NetLogicTest` y `NotifLogicTest`: nombres de transporte, VPN sobre una red real, recortes que no parten un emoji, qué se reenvía y qué no, motivos de cierre, tamaño de la lista, repetidos y límite de ritmo);
  el código de Kotlin compila contra la API real de Android y coincide con la app simulada y con el protocolo 1.5 (`tests/check_contract.py`). **Las pruebas se probaron a sí mismas:** se estropeó a propósito el cliente de 10 maneras distintas y las pruebas nuevas cazaron las 10. Al pasar la batería entera, además, saltaron pruebas antiguas que daban por hecho que la app simulada era «1.4», y se corrigieron.
- ⚠️ **Sin comprobar (0.4.3): TODO lo que necesita un móvil y un escritorio de verdad.** El código nuevo de la app (`NetHandler`, `NotifBridge` y el servicio de notificaciones: qué entrega de verdad Android, con qué claves, motivos de cierre y `cancelNotification`, y cuáles de las notificaciones fijas se resisten en HyperOS/Android 16),
  que el sistema o HyperOS suelte el servicio de notificaciones con el ahorro de batería, `nexo-dbus` contra un **dunst, mako, swaync, GNOME o KDE de verdad** (el demonio simulado imita la especificación; cada demonio real tiene sus manías: iconos, acciones, urgencia, historial), `nmcli` y los applets de red con la red del móvil, y el consumo de batería de vigilar la red.
  `shellcheck` no se pudo ejecutar aquí (lo hace GitHub Actions).
- ⚠️ **Sin comprobar (0.4.2): TODO lo que necesita un móvil y un disco de verdad.** El código nuevo de la app (`StorageManager`, el selector de carpetas, el permiso que Android recuerda, la lectura y escritura por `DocumentsContract`, los avisos de montaje, la expulsión con `ejectRoot`), la velocidad real, qué sistemas de archivos monta tu móvil (FAT32, exFAT, NTFS, ext4), el selector de HyperOS/Android 16 con un disco USB, discos de varios cientos de miles de archivos, hubs y la batería. La copia directa por ruta (`--via direct`) solo se probó con carpetas normales. Para probarlo: [`tests/usb_storage_hardware_check.sh`](tests/usb_storage_hardware_check.sh) (ver [`docs/USB-ALMACENAMIENTO.md`](docs/USB-ALMACENAMIENTO.md#probarlo-en-tu-móvil)).
- ⚠️ **Sin comprobar (0.4.1): TODO lo que necesita un móvil o una placa de verdad.** El código nuevo de la app (`UsbManager`, el permiso, las transferencias bulk y de control), los controladores con chips reales (ATmega16U2 de un Uno, CH340, CP2102, FT232, ESP32‑S3 por USB nativo), un `avrdude`, `arduino-cli`, `esptool` o PlatformIO reales contra los puertos que ofrece `nexo usb bridge`, hubs, el aviso de permiso en HyperOS/Android 16 y la duración de la batería.
  Para probarlo: [`tests/usb_hardware_check.sh`](tests/usb_hardware_check.sh) (ver [`docs/USB.md`](docs/USB.md#probarlo-en-tu-móvil)).
- ⚠️ **Sin comprobar (0.4.0‑beta2):** `nexo tools` **entre dos móviles reales**, con el router de tu casa (difusión UDP, aislamiento de clientes), con los navegadores de Android, con archivos de varios GB, con tarjetas SD en FAT/exFAT y con el ahorro de batería de HyperOS;
  `setup-guests` y `nexo update` con un `proot-distro` real (las pruebas usan uno simulado que reproduce el orden de `PATH` de proot-distro y la estructura de carpetas de proot-distro 5).
- ⚠️ **Sin comprobar (v0.3 y 0.4.0‑beta1):** `bluetoothctl`, `nmcli`, Blueman, `nm-applet`, `libnm`, `playerctl`, Waybar, Polybar, Quickshell, GNOME y KDE con `nexo-dbus` (en GitHub Actions hay un trabajo que prueba `playerctl`; no bloquea),
  el comportamiento dentro de proot en un móvil real, instalar la política en el `/etc/dbus-1/system.d` de un sistema de verdad con `sudo` (las pruebas usan un bus de pruebas y una carpeta propia) y Python anteriores a 3.13 en ejecución (el código está escrito para 3.7+).
- ⚠️ **Sin comprobar en un móvil:** el código nuevo de la app (audio, música y su carátula, redes guardadas, olvidar/renombrar Bluetooth, plazos por comando, auto-ping y reintento de puerto).
  Espera algún ajuste según el fabricante y la versión de Android (sobre todo `bt forget`, que usa una función no pública, y la lista de redes guardadas en Android recientes).
- ⚠️ **Limitaciones del entorno:** El encendido/apagado directo de WiFi/Bluetooth depende de las restricciones de cada fabricante (HyperOS puede pedir un toque manual).
  Las redes con señal muy débil (ej. -87 dBm) pueden hacer que Android reporte un `connected: false` momentáneo mientras re-negocia la conexión.
  HyperOS puede congelar la app: se mitiga, no se puede evitar desde dentro de la app (ver [Que Android no cierre la app](#que-android-no-cierre-la-app)).
- ❌ **Sin hacer:** un explorador interactivo de discos y la emulación de UDisks2 para los gestores de archivos de Linux, Shizuku/`rish` integrado (solo hay acceso directo por ruta si el proceso ya la ve), teclados y ratones USB en la distro, el PL2303 y las placas que se reprograman con un «toque» a 1200 baudios (Leonardo, Pro Micro), los paquetes (AUR, `.deb`, `.rpm`, `APKBUILD`) y F‑Droid (ver [ROADMAP](docs/ROADMAP.md)).

Ideas sin explorar: un azulejo de Ajustes rápidos para encender y apagar el puente; conectar dispositivos Bluetooth de verdad mediante ADB inalámbrico o Shizuku.

---

## Licencia

GPL‑3.0‑or‑later. Ver [`LICENSE`](LICENSE).
