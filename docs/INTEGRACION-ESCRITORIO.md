# Integración con el escritorio: `nexo-dbus`

Los programas de Linux (barras, escritorios, `playerctl`, `bluetoothctl`, `nmcli`…) no hablan con Nexo: hablan con **D‑Bus**. `nexo-dbus` es el traductor:
se queda conectado a la app Nexo y publica en D‑Bus lo que Android sabe, con los nombres que esos programas ya conocen.

| Versión | Qué publica | Bus | Quién lo usa |
|---|---|---|---|
| 0.3 | `org.mpris.MediaPlayer2.nexo`: la música del móvil como un reproductor más | sesión | `playerctl`, el módulo `mpris` de Waybar, Quickshell, GNOME, KDE, Plasma, los atajos multimedia… |
| **0.4.0** (beta 1 y 2) | `org.bluez`: el Bluetooth del móvil como un adaptador `hci0` con sus dispositivos emparejados | sistema | `bluetoothctl`, Blueman, applets de Bluetooth |
| **0.4.0** (beta 1 y 2) | `org.freedesktop.NetworkManager`: el WiFi del móvil como un dispositivo `wlan0` (redes a la vista, redes guardadas, conexión actual) | sistema | `nmcli`, `nm-applet`, applets de red |
| **0.4.3** | Las notificaciones del móvil en tu escritorio (`org.freedesktop.Notifications`: `nexo-dbus` es cliente del demonio que ya tengas) y, en NetworkManager, la red por la que sale el móvil (datos móviles incluidos) | sesión (y sistema para la red) | dunst, mako, swaync, GNOME, KDE · `nmcli`, applets de red |

Esta guía describe la **0.4.3** (la 0.4.1 y la 0.4.2 no cambian nada de `nexo-dbus`: traen USB). Qué se ha probado y qué no, al final: **BlueZ y NetworkManager están comprobados con `busctl` y `gdbus`, no con `bluetoothctl` ni `nmcli` reales, y las notificaciones con un demonio de avisos simulado y `busctl`, no con dunst, mako, GNOME ni KDE.**

```
 App Nexo (Android) ──TCP 127.0.0.1:8765──▶ nexo-dbus ──D‑Bus, bus de SESIÓN───▶ playerctl · Waybar · Quickshell · GNOME · KDE      (MPRIS)
   música · WiFi · Bluetooth                (un proceso por distro,                                  ──▶ dunst · mako · swaync · GNOME · KDE   (notificaciones)
   red · notificaciones                      una conexión por bus)  ──D‑Bus, bus del SISTEMA──▶ nmcli · bluetoothctl · Blueman · nm-applet (NetworkManager, BlueZ)
```

- **Un solo archivo de Python 3**, sin librerías (ni `pydbus` ni GObject): lleva su propia implementación del protocolo de D‑Bus.
  Está escrito para Python 3.7 o más nuevo (solo se ha ejecutado con 3.13; ver «Qué está probado»). Es un proceso por distro.
- El reproductor MPRIS **solo aparece mientras haya música en Android** (una sesión de medios activa). Si no hay nada que controlar, no hay reproductor:
  así `playerctl` y los widgets no se llenan de un «Nexo» muerto. (`NEXO_DBUS_ALWAYS=1` lo deja siempre.)
- **BlueZ** y **NetworkManager** aparecen cuando el móvil tiene esa radio y la app responde, y se retiran si la app deja de responder (30 s de margen).
- Las **notificaciones del móvil** son opcionales y vienen apagadas: no sale nada de Android hasta que activas «Reenviar notificaciones a Linux» en la app (ver «Notificaciones del móvil»).
- **Nunca pisa un BlueZ o un NetworkManager de verdad**: si ya hay uno en el bus (o systemd lo gestiona), se queda pasivo y lo dice (ver «Modo pasivo»).
- Todo es local: `nexo-dbus` solo habla con `127.0.0.1` y con los sockets de tus buses de D‑Bus.

## Activarlo

Necesitas tener ya Nexo funcionando (`nexo status` bien). Para la música, además, dar a la app el **acceso a notificaciones** (sin él Android no deja ver qué suena; `nexo doctor` te lo dice).
BlueZ y NetworkManager no lo necesitan.

**En Termux** (el comando de instalación de la app ya trae `nexo-dbus`):

```bash
nexo setup-dbus            # instala python3 si falta, deja el arranque automático y lo arranca ahora
```

**En una distro de proot-distro** (Arch, Debian…): desde Termux las copias, y dentro de la distro lo activas. Como una distro de proot no tiene bus del sistema, lo normal es `--own-bus`
(crea los buses que falten; necesita el paquete `dbus`):

```bash
# en Termux
nexo setup-guests --with-dbus          # copia nexo, el enlace y nexo-dbus a tus distros (o: setup-guests arch --with-dbus)

# dentro de la distro
nexo setup-dbus --own-bus
eval "$(nexo-dbus env)"                # en cada terminal donde uses bluetoothctl, nmcli o playerctl (ver «Los buses»)
```

Si ya habías copiado `nexo-dbus` a una distro, `nexo setup-guests` (y `nexo rekey`) lo mantienen al día sin que repitas `--with-dbus`.

Prueba, dentro de la distro:

```bash
nexo dbus status                  # qué servicio está activo y, si no, POR QUÉ (mismo resumen en «nexo doctor»)
bluetoothctl devices              # los dispositivos Bluetooth emparejados en Android
nmcli device wifi list            # las redes WiFi que ve el móvil
playerctl -l                      # → nexo   (con música sonando en el móvil)
```

`nexo dbus status` dice algo así:

```
nexo-dbus en marcha (PID 4242)
  MPRIS           esperando música: aparece cuando suena algo en Android (--always lo deja siempre)
  BlueZ           org.bluez activo
  NetworkManager  pasivo: ya hay un NetworkManager de verdad en este bus (NEXO_DBUS_FORCE=1 lo reclama)
```

Ninguno de esos programas viene en todas partes: `pacman -S bluez-utils networkmanager playerctl` · `apt install bluez network-manager playerctl` · `apk add bluez networkmanager-cli playerctl`
(instalas solo las **herramientas de cliente**; no hace falta ni conviene arrancar el servicio de verdad). Sin ellas puedes comprobar con
`busctl --system tree org.bluez`, `busctl --system introspect org.freedesktop.NetworkManager /org/freedesktop/NetworkManager` o con `gdbus introspect --system --dest org.bluez --object-path /org/bluez`.

## Los buses de D‑Bus (lo único que puede fallar)

D‑Bus tiene dos buses. El de **sesión** es uno por usuario y escritorio (ahí vive MPRIS); el del **sistema** es uno por equipo (ahí viven BlueZ y NetworkManager).
`nexo-dbus` se conecta a los dos, cada uno con **su propia conexión**: si falta uno, el otro sigue funcionando.

### Bus de sesión (MPRIS)

`nexo-dbus` tiene que conectarse al **mismo bus de sesión** que tu barra o tu escritorio; si no, ellos no ven el reproductor. Lo busca, en este orden, en
`--bus DIRECCIÓN` / `NEXO_DBUS_BUS`, `DBUS_SESSION_BUS_ADDRESS`, `$XDG_RUNTIME_DIR/bus`, `/run/user/UID/bus` (con `NEXO_DBUS_SESSION_SOCKET=RUTA` se usa solo esa), y el bus propio que él mismo creó (ver abajo).

| Tu caso | Qué hacer |
|---|---|
| Escritorio con sesión normal (GNOME, KDE, XFCE, Hyprland con `dbus-run-session`/`uwsm`…) | Nada: `nexo setup-dbus` lo arranca dentro de esa sesión y hereda el bus. |
| Escritorio en proot (VNC, Termux:X11) que arranca su bus con `dbus-launch` o `dbus-run-session` | Arranca `nexo-dbus` **desde esa sesión**: con `--launcher` (más abajo) o a mano en una terminal del escritorio: `nexo dbus start`. |
| Sin escritorio, solo terminal | `nexo setup-dbus --own-bus` crea un bus de sesión propio (hace falta el paquete `dbus`). En cada terminal donde quieras usarlo: `eval "$(nexo-dbus env)"`. |
| Un solo comando, sin instalar nada | `dbus-run-session -- bash` y, dentro, `nexo dbus start`. |

Ojo: con `--own-bus`, solo ven el reproductor los programas que usen **ese** bus (los que arrancaste con `eval "$(nexo-dbus env)"`). Una barra de un escritorio que ya
tiene su propio bus no lo verá: en ese caso usa su bus (primera fila de la tabla).

### Bus del sistema (BlueZ y NetworkManager)

Lo busca en `NEXO_DBUS_SYSTEM_BUS` (una dirección, o `none` para no usar el bus del sistema), `DBUS_SYSTEM_BUS_ADDRESS`, `/run/dbus/system_bus_socket` y `/var/run/dbus/system_bus_socket`
(con `NEXO_DBUS_SYSTEM_SOCKET=RUTA` se usa solo esa), y el bus propio que él mismo creó. `bluetoothctl`, `nmcli`, `blueman` y los applets buscan el suyo en `DBUS_SYSTEM_BUS_ADDRESS` y, si no está,
en `/run/dbus/system_bus_socket`.

| Tu caso | Qué pasa | Qué hacer |
|---|---|---|
| PC con Linux de verdad (Arch, Debian…) con BlueZ y NetworkManager funcionando | `nexo-dbus` se queda **pasivo**: no los pisa y lo dice en `nexo dbus status` | Nada. Si los paraste a propósito y quieres los de Nexo: `NEXO_DBUS_FORCE=1` |
| Linux con systemd donde BlueZ o NetworkManager están instalados pero parados | **Pasivo**: «systemd gestiona bluetooth.service en este equipo» (lo arrancaría systemd al primer uso) | `NEXO_DBUS_BLUEZ=1` / `NEXO_DBUS_NM=1` lo fuerzan |
| Linux con bus del sistema pero **sin** BlueZ ni NetworkManager (PC mínimo, máquina virtual) | El bus **no deja** a un usuario normal ocupar `org.bluez`: falta una política | `nexo setup-dbus --system-policy` (ver abajo) |
| proot-distro o sin escritorio: **no hay** bus del sistema | `nexo setup-dbus --own-bus` crea uno propio (paquete `dbus`) | Si eres `root` (lo normal en proot), queda en `/run/dbus/system_bus_socket` y `bluetoothctl`/`nmcli` lo encuentran solos. Si no, en cada terminal: `eval "$(nexo-dbus env)"` |

**La política (`--system-policy`).** Un bus del sistema de verdad no deja que cualquiera ocupe `org.bluez` ni `org.freedesktop.NetworkManager`; lo permite un archivo de `/etc/dbus-1/system.d`.
`nexo setup-dbus --system-policy` escribe `/etc/dbus-1/system.d/nexo.conf` (necesita root: si no lo eres usa `sudo`; si no puede, te deja el archivo preparado y el comando para copiarlo),
da permiso para ocupar esos dos nombres **y para hablarles solo a tu usuario** (con `--policy-user NOMBRE`, repetible, a otros) y le pide al bus que la relea
(si tu bus no lo recoge solo: `sudo systemctl reload dbus`). `nexo-dbus` reintenta cada 30 s lo que el bus le negó, así que **no hace falta reiniciarlo**.
`nexo setup-dbus --uninstall` la quita (solo si la escribió Nexo). Otros usuarios del equipo no podrán hablar con el BlueZ o el NetworkManager de Nexo.

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

Opciones de `setup-dbus`: `--no-start` (solo el arranque automático), `--own-bus`, `--always` (el reproductor siempre visible), `--launcher ARCHIVO`, `--system-policy` y `--policy-user NOMBRE`, `--uninstall`.

## Bluetooth (BlueZ)

`nexo-dbus` publica `org.bluez` con un adaptador `hci0` (el Bluetooth del móvil) y un `Device1` por cada dispositivo **emparejado en Android**:

```bash
bluetoothctl show                  # el adaptador: encendido o no, «Discovering»…
bluetoothctl devices               # los emparejados: los mismos que ves en los ajustes de Android
bluetoothctl info AA:BB:CC:DD:EE:FF
bluetoothctl power off             # apaga el Bluetooth del móvil (o «on»)
bluetoothctl scan on               # ver abajo: no busca dispositivos nuevos
```

| Parte | Estado |
|---|---|
| `org.freedesktop.DBus.ObjectManager` en `/`, `Adapter1` en `/org/bluez/hci0`, `Device1` en `/org/bluez/hci0/dev_XX_XX_XX_XX_XX_XX`, y `AgentManager1` (que acepta y no hace nada) | ✅ y las señales `InterfacesAdded/Removed` y `PropertiesChanged` cuando algo cambia en Android |
| `Adapter1.Powered` (leer y escribir), `PowerState`, `Discovering`, `Name`, `Class` | ✅ escribir `Powered` enciende o apaga el Bluetooth de Android. El `Address` es **inventado y estable** (`02:…`): Android no da la dirección Bluetooth del móvil |
| `Adapter1.StartDiscovery` / `StopDiscovery` | ⚠️ **Solo encienden el Bluetooth si estaba apagado**; Nexo **no busca dispositivos nuevos** (Android no deja a una app normal hacerlo desde aquí). `Discovering` pasa a `true` y vuelve solo a `false` a los 120 s. `NEXO_DBUS_DISCOVERY_RESTORE=1` hace que `StopDiscovery` vuelva a apagar el Bluetooth si fue `StartDiscovery` quien lo encendió |
| `Device1`: `Address`, `Name`, `Alias`, `Class`, `Icon`, `UUIDs`, `Paired`, `Bonded`, `Connected`, `ServicesResolved`, `Adapter` | ✅ |
| `Device1.Alias` (escribir) | ✅ renombra el dispositivo en Android |
| `Battery1.Percentage` | ✅ en los dispositivos que dan su batería |
| `Device1.Trusted` (escribir) | ⚠️ Android no tiene «dispositivo de confianza»: se recuerda solo mientras `nexo-dbus` está en marcha |
| `Device1.Connect`, `Disconnect`, `ConnectProfile`, `DisconnectProfile` | ⚠️ **Android no deja a una app normal conectar ni desconectar un dispositivo**: devuelven el error `org.nexo.Error.NeedsUserAction` y la app deja una notificación que abre los ajustes de Bluetooth del móvil |
| `Adapter1.RemoveDevice` | ✅ olvida el emparejamiento en Android (`bt.forget`); si Android no lo deja, responde `NeedsUserAction` |
| `Device1.Pair`, `CancelPairing`, `Blocked = true`, `Adapter1.Discoverable = true`, escribir el `Alias` del adaptador | ❌ responden «no soportado» con la explicación (se hace en los ajustes de Android) |
| `Media1`, `Network1`, GATT (`GattManager1`), `LEAdvertisingManager1` | ➖ No se publican: lo que Android no deja hacer, no se finge |

Los dispositivos se releen cuando Android avisa de un cambio y, por si acaso, cada 60 s (`NEXO_DBUS_REFRESH`).

## WiFi (NetworkManager)

`nexo-dbus` publica `org.freedesktop.NetworkManager` con **un** dispositivo, `wlan0` (el WiFi del móvil):

```bash
nmcli general status               # estado global (connected / disconnected)
nmcli device                       # wlan0 y su estado
nmcli device wifi list             # las redes que ve el móvil (SSID, señal, seguridad, canal)
nmcli connection show              # las redes guardadas en Android
nmcli device wifi connect "MiRed" password "la clave"
nmcli connection up "MiRed"        # conectar con una guardada
nmcli device disconnect wlan0
nmcli radio wifi off               # apaga el WiFi del móvil (o «on»)
```

| Parte | Estado |
|---|---|
| Objetos `/org/freedesktop/NetworkManager` (con `GetDevices`, `GetAllDevices`, `GetDeviceByIpIface`, `State`, `Connectivity`, `Version`…), `Devices/1` (`Device` + `Device.Wireless`), `AccessPoint/N`, `Settings` y `Settings/N` (una por red guardada), `ActiveConnection/N`, `IP4Config/N`, `AgentManager` | ✅ con `ObjectManager` y las señales (`StateChanged`, `AccessPointAdded/Removed`, `NewConnection`/`ConnectionRemoved`, `PropertiesChanged`) |
| Puntos de acceso: `Ssid`, `HwAddress` (BSSID), `Strength`, `Frequency`, `Flags/WpaFlags/RsnFlags` (OPEN, WEP, WPA, WPA2, WPA3, OWE), `MaxBitrate` | ✅ salen de `wifi.scan`. `Strength` = dBm → 0‑100 como NetworkManager (‑100 dBm = 0, ‑50 dBm = 100). `MaxBitrate` es orientativo (Android no la da de las redes que no son la actual) |
| Conexión actual: `ActiveConnection`, `IP4Config` (dirección, puerta de enlace, DNS), `Bitrate`, `ActiveAccessPoint`, estado del dispositivo (desconectado / conectando / conectado) | ✅ salen de `wifi.status` |
| `ActivateConnection`, `AddAndActivateConnection` (y `…2`) | ✅ conectan de verdad (`wifi.connect`, hasta 15 s) y **responden cuando Android confirma o no**. Si falla: error `…NetworkManager.Error.Failed` con la causa. Si Android pide un toque del usuario: `org.nexo.Error.NeedsUserAction` |
| `Device.Disconnect`, `DeactivateConnection` | ✅ `wifi.disconnect` |
| `Device.Wireless.RequestScan` | ✅ `wifi.scan` (Android limita los escaneos: si pides muchos, `rate_limited` y se usan los últimos resultados) |
| `WirelessEnabled` (escribir), `nmcli radio wifi on/off` | ✅ enciende o apaga el WiFi; en algunos Android pide un toque (`NeedsUserAction`) |
| `Settings.Connection.Delete` (`nmcli connection delete`) | ✅ olvida la red en Android (`wifi.forget`) |
| `Settings.Connection.GetSettings` | ✅ SSID, tipo de seguridad, `autoconnect`, UUID estable derivado del nombre |
| `GetSecrets` y las claves guardadas | ❌ Android **no deja leer** las claves guardadas: siempre vacío |
| `AddConnection`, `Update`, `Save`, editar una conexión, `WwanEnabled = true`, `Sleep`, VPN, Ethernet, hotspot, IP estática | ❌ «no soportado» con la explicación (`Settings.Error.ReadOnlyConnection` o `…NotSupported`) |
| `State`, `Connectivity` y `Metered` globales | ✅ **con la app 0.4.3** salen de `net.status`, o sea, de la red por la que **sale de verdad** el móvil (también datos móviles o un cable): `connected` + `full` cuando Android comprobó que hay internet; `connected (site only)` + `limited` si hay red pero Android no logra comprobar internet (también un portal cautivo); `connected (local only)` + `none` si la red ni declara salida a internet; `disconnected` sin red. `Metered` = `yes` si es de pago (datos móviles). Con una **app anterior a la 0.4.3** se deducen solo del WiFi como antes (conectado → `connected`; si no, `disconnected`), y con **`NEXO_DBUS_NM_ASSUME_ONLINE=1`** NetworkManager dice «conectado» aunque el WiFi no lo esté (así Firefox no cree que no hay internet si usas datos móviles): con la 0.4.3 ya no hace falta |
| `PrimaryConnection` | ⚠️ Es la conexión WiFi actual; si el móvil sale por datos móviles o por un cable no hay una conexión de ese tipo que enseñar (Nexo solo publica `wlan0`) |

La MAC de `wlan0` es **inventada y estable** (`02:…`): Android no da la del WiFi. La lista de redes se refresca cada 120 s (`NEXO_DBUS_NM_SCAN`), el estado cada 20 s (`NEXO_DBUS_NM_REFRESH`), y al instante cuando Android avisa de un cambio.

## Notificaciones del móvil (`org.freedesktop.Notifications`)

Las notificaciones de Android salen en tu escritorio, en el demonio de avisos que ya uses (dunst, mako, swaync, el de GNOME o el de KDE), y si las cierras allí se quitan también del móvil.

**Es opcional y viene apagado**: lo que dicen tus notificaciones es lo más privado del móvil. No sale de Android hasta que, en la app Nexo, (1) das el **acceso a notificaciones** (el mismo que usa la música) y (2) activas **«Reenviar notificaciones a Linux»**.
Solo viajan por `127.0.0.1`, hacia un cliente con tu token (`nexo-dbus`, o `nexo notif` si lo pides tú); ni la app ni `nexo-dbus` guardan ninguna, y no pasan por la caché de las barras. `nexo dbus status` dice si falta algo:

```
  Notificaciones  reenviando a dunst 1.11.0 (org.freedesktop.Notifications)
  Notificaciones  el reenvío está apagado: actívalo en la app Nexo («Reenviar notificaciones a Linux»)
  Notificaciones  falta el acceso a notificaciones de Android (app Nexo → Permisos → Acceso a notificaciones)
  Notificaciones  no hay un demonio de notificaciones en el bus de sesión (instala dunst, mako o swaync; GNOME y KDE ya traen uno)
```

`nexo-dbus` es aquí un **cliente** del demonio, no un servidor: **no ocupa** el nombre `org.freedesktop.Notifications`, así que no choca con el tuyo ni lo desplaza (por eso no hay «modo pasivo» ni `NEXO_DBUS_FORCE` para esto).
Si no hay demonio en el bus de sesión no se muestra nada (y se anota una sola vez); en cuanto aparece uno, los avisos siguientes salen en él sin reiniciar nada. Si el demonio se reinicia o lo cambias por otro, `nexo-dbus` se da cuenta.

| Qué pasa en Android | Qué pasa en Linux |
|---|---|
| Llega una notificación | Sale en tu escritorio con el nombre de la app, el título y el texto (icono genérico `phone`) |
| La app la actualiza (otro mensaje en la conversación, una barra de progreso) | Se **reemplaza** la misma (`replaces_id`): no salen dos |
| La tocas, la descartas o la retira la app, en el móvil | Desaparece también del escritorio |
| La cierras **aquí** con el ratón (la ✕) | Se quita también **del móvil** (`notif.dismiss`). Si caduca sola, o la cierra el propio programa, el móvil no se entera. `NEXO_DBUS_NOTIFY_DISMISS=0` lo apaga |
| Es una alarma o una llamada (`alarm`, `call`) | Urgencia **crítica** (2) |
| Es poco importante (importancia baja) | Urgencia **baja** (0); el resto, normal (1) |
| Es un mensaje, un correo o una descarga (`msg`, `email`, `progress`) | Lleva la categoría estándar de escritorio (`im.received`, `email.arrived`, `transfer`) |
| Es una **fija** (reproductor, VPN, servicios en marcha) o de importancia mínima | **No se enseña** (te llenarían la pantalla). `NEXO_DBUS_NOTIFY_ALL=1` las enseña (las fijas, sin caducidad: se quedan hasta que se quiten) |

No se reenvían las notificaciones de la propia Nexo, los resúmenes de grupo ni los controles de música (de eso se ocupa MPRIS).

**El texto del móvil llega como texto, no como código.** Se le quitan los caracteres de control, el título se corta en 200 letras y el cuerpo en 1000 (con «…»), y si tu demonio interpreta marcado (`body-markup`) se **escapa**:
una notificación no puede meter negritas, enlaces ni imágenes en tu escritorio, y un `<b>` en un mensaje se ve como `<b>`. (Los `<` y `>` del título y del nombre de la app se cambian por `‹` y `›`, porque algunos demonios interpretan también esos.)

Para probarlo sin esperar a que te escriban: `notify-send "prueba"` (de `libnotify`) confirma que tu demonio funciona; `nexo notif status` dice si el móvil reenvía; y publica una notificación en el móvil.

## Modo pasivo (no pisar lo de verdad)

Si al arrancar, o más tarde, aparece otro programa con el nombre `org.bluez` o `org.freedesktop.NetworkManager` en el bus, `nexo-dbus` **no se lo quita**: se queda pasivo, lo cuenta en `nexo dbus status` y en su registro, y no vuelve a intentarlo.
Lo mismo pasa si el equipo tiene **systemd** y el servicio (`bluetooth.service`, `NetworkManager.service`) está instalado y se activaría solo cuando alguien lo pida: ahí también cede, porque sería ese servicio quien se pondría a ocupar el nombre.
Si de verdad quieres los de Nexo, `NEXO_DBUS_BLUEZ=1` / `NEXO_DBUS_NM=1` (o `NEXO_DBUS_FORCE=1` para todos) reclaman el nombre; y si otro programa lo reclama después, cede (salvo con `FORCE`).
Para apagar uno: `NEXO_DBUS_BLUEZ=0`, `NEXO_DBUS_NM=0`, `NEXO_DBUS_MPRIS=0` o las opciones `--no-bluez`, `--no-nm`, `--no-mpris`.

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

**Waybar, Bluetooth**: su módulo `bluetooth` lee BlueZ del bus del sistema, así que con `nexo-dbus` activo debería mostrar el Bluetooth del móvil (`"bluetooth": { "format": " {status}" }`); no está probado con Waybar real.
**Waybar, WiFi**: su módulo `network` lee el kernel (netlink), **no** NetworkManager, así que no verá el WiFi del móvil; para eso usa el módulo `custom` con el formato que ya trae el cliente:
`"custom/wifi": { "exec": "nexo wifi status --waybar", "return-type": "json", "interval": 5 }`.

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
Sus paneles de WiFi y Bluetooth leen NetworkManager y BlueZ, pero piden muchas cosas más que `nmcli` o `bluetoothctl` (perfiles, agentes, VPN…): **no se han probado y pueden mostrar solo una parte** o quejarse.

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

## Variables de entorno

| Variable | Para qué |
|---|---|
| `NEXO_DBUS_BUS` | Dirección del bus de sesión (si no es la normal): `unix:path=/ruta/bus` (también `--bus`) |
| `NEXO_DBUS_SESSION_SOCKET` | Ruta del socket del bus de sesión; **sustituye** a `$XDG_RUNTIME_DIR/bus` y `/run/user/UID/bus` (sirve en distros raras y para probar «sin bus» en una máquina que tiene uno) |
| `NEXO_DBUS_SYSTEM_BUS` | Dirección del bus del sistema (también `--system-bus`); `none` = no usar el bus del sistema (sin BlueZ ni NetworkManager) |
| `NEXO_DBUS_SYSTEM_SOCKET` | Ruta del socket del bus del sistema; **sustituye** a las rutas habituales (`/run/dbus/system_bus_socket`…) |
| `NEXO_DBUS_MPRIS`, `NEXO_DBUS_BLUEZ`, `NEXO_DBUS_NM` | `0` apaga ese servicio; `1` lo activa aunque haya otro o lo gestione systemd; vacío o `auto` = automático (también `--no-mpris`, `--no-bluez`, `--no-nm`) |
| `NEXO_DBUS_NOTIFY` | `0` apaga las notificaciones del móvil (también `--no-notify`): `nexo-dbus` ni siquiera las pide a la app |
| `NEXO_DBUS_NOTIFY_ALL=1` | Enseña también las notificaciones fijas (reproductor, VPN, servicios en marcha) y las de importancia mínima |
| `NEXO_DBUS_NOTIFY_DISMISS=0` | Cerrar una notificación en el escritorio ya no la quita del móvil |
| `NEXO_DBUS_FORCE=1` | Reclama los nombres aunque ya los tenga otro programa (o los gestione systemd) |
| `NEXO_DBUS_ALWAYS=1` | El reproductor MPRIS se ve aunque no haya música (`Stopped`, sin controles) |
| `NEXO_DBUS_GRACE` | Segundos que espera antes de retirar el reproductor cuando para la música (3) |
| `NEXO_DBUS_GRACE_DOWN` | Ídem para todos los servicios si la app Nexo deja de responder (30): da tiempo a que Android la descongele |
| `NEXO_DBUS_DISCOVERY_RESTORE=1` | `StopDiscovery` vuelve a apagar el Bluetooth si fue `StartDiscovery` quien lo encendió |
| `NEXO_DBUS_DISCOVERY_SECS` | Cuánto dura «Discovering = true» tras `StartDiscovery` (120) |
| `NEXO_DBUS_REFRESH` | Cada cuántos segundos relee los dispositivos Bluetooth aunque no pase nada (60) |
| `NEXO_DBUS_NM_SCAN`, `NEXO_DBUS_NM_REFRESH` | Cada cuántos segundos escanea redes (120, mínimo 10) y relee el estado del WiFi (20, mínimo 2) |
| `NEXO_DBUS_NM_ASSUME_ONLINE=1` | NetworkManager dice «conectado» aunque el WiFi del móvil no lo esté, **solo con una app anterior a la 0.4.3** (que no cuenta qué red usa el móvil; útil con datos móviles) |
| `NEXO_DBUS_DENIED_RETRY` | Cada cuántos segundos reintenta ocupar un nombre que el bus le negó por política (30) |
| `NEXO_DBUS_SYSTEMD_DIR` | Dónde mira si systemd gestiona BlueZ/NetworkManager (`/run/systemd/system`) |
| `NEXO_PORT`, `NEXO_TOKEN`, `NEXO_CONFIG` | Los mismos que el cliente `nexo`: el enlace se lee igual (y se vuelve a leer solo si cambia, p. ej. tras `nexo rekey`) |
| `NEXO_DBUS_POLICY_DIR` | Carpeta de políticas del bus donde `setup-dbus --system-policy` deja `nexo.conf` (`/etc/dbus-1/system.d`) |

## Si no funciona

Empieza por `nexo dbus status` (o `nexo doctor`): dice, servicio por servicio, qué hace `nexo-dbus` y **por qué** no está activo.

| Síntoma | Causa probable | Solución |
|---|---|---|
| `playerctl -l` no dice nada | No hay música en Android, o el acceso a notificaciones no está dado | Pon música; `nexo doctor` y `nexo media status` (`listener: true`). En Android 13+: «Permitir ajustes restringidos» |
| `nexo dbus status` dice que no está en marcha | No arrancó (sin bus, sin token…) | `nexo dbus run -v` lo muestra en la terminal; el motivo sale con una explicación |
| «No encuentro un bus de sesión de D‑Bus» | Estás fuera de la sesión del escritorio | Mira «Los buses» arriba |
| `bluetoothctl` o `nmcli` dicen que no hay Bluetooth/NetworkManager (o «No default controller») | No ven el bus del sistema de `nexo-dbus` (proot con `--own-bus` y no eres `root`) | `eval "$(nexo-dbus env)"` en esa terminal; mira «Bus del sistema» |
| `status` dice «el bus no deja a este usuario ocupar org.bluez» | Un bus del sistema de verdad exige una política | `nexo setup-dbus --system-policy` |
| `status` dice «pasivo: ya hay un BlueZ/NetworkManager de verdad» | En ese equipo ya hay uno funcionando | Es lo esperado. Usa el de verdad o páralo y `NEXO_DBUS_FORCE=1` |
| `bluetoothctl connect …` falla con `NeedsUserAction` | Android no deja a una app conectar dispositivos Bluetooth | Pulsa la notificación de Nexo: abre los ajustes de Bluetooth del móvil |
| `nmcli device wifi connect` tarda y falla | Android no confirmó la conexión en 15 s (clave mala, red fuera de alcance, ajustes restringidos) | Mira el mensaje del error; `nexo wifi status` |
| Firefox y otras apps creen que no hay internet (usas datos móviles) | La app es anterior a la 0.4.3: no cuenta la red móvil y NetworkManager mira solo el WiFi | Instala el APK de la 0.4.3 (o `NEXO_DBUS_NM_ASSUME_ONLINE=1` mientras tanto) |
| No sale ninguna notificación del móvil en el escritorio | Falta el reenvío, el acceso a notificaciones o el demonio de avisos | `nexo dbus status` dice cuál (ver «Notificaciones del móvil»); `nexo notif status` mira el lado del móvil |
| Salen, pero no las fijas del reproductor o de la VPN | Es a propósito: las fijas y las de importancia mínima no se enseñan | `NEXO_DBUS_NOTIFY_ALL=1` |
| Se ve en `busctl` pero no en tu barra | La barra usa **otro** bus | Arranca `nexo-dbus` desde la sesión de la barra (`--launcher`, `exec-once`) |
| «la app Nexo rechazó el enlace» | Cambiaste el token | `nexo rekey` (o `nexo pair`): `nexo-dbus` recoge el nuevo en unos segundos |
| «esta versión de la app Nexo no sabe de música» | APK anterior a la 0.2 | Instala el APK nuevo |
| El reproductor tarda en irse al parar | Es a propósito (margen de 3 s: evita parpadeos entre canciones) | `NEXO_DBUS_GRACE=0` |
| Android congela la app y todo desaparece | HyperOS y otras capas | Ver «Que Android no cierre la app» en el README |

## Qué está probado y qué no

**Probado aquí** (la suite de pruebas del repositorio, con un `dbus-daemon` real y una app Nexo simulada):

- el empaquetado de mensajes de D‑Bus (30 tipos), comprobado contra dos clientes independientes: `busctl` (systemd) y `gdbus` (GLib);
- el reproductor MPRIS completo visto con esos dos clientes: propiedades, metadatos, carátula, controles, `Seek`, `Volume`, cambios hechos desde Android, 30 clientes a la vez;
- **BlueZ** (`org.bluez`) en un bus del sistema de pruebas: el árbol de objetos (`GetManagedObjects`), todas las propiedades con sus tipos, escrituras y errores, las señales (`InterfacesAdded/Removed`, `PropertiesChanged`), encender y apagar, `StartDiscovery`/`StopDiscovery`, `RemoveDevice`;
- **NetworkManager** en el mismo bus: objetos, redes a la vista con intensidad y seguridad, conexión y desconexión (también las que fallan o piden un toque), WiFi apagado y encendido, olvidar una red, estado global con y sin `net.status`;
- las **notificaciones** contra un demonio de avisos **de pruebas** (`tests/fake_notifd.py`: `Notify`, `CloseNotification`, `GetCapabilities`, `GetServerInformation` y las señales) y mirando el bus con `busctl monitor` (otro cliente de D‑Bus: lo que `nexo-dbus` manda lo entiende alguien que no es él): llegar, reemplazar, quitar, cerrar en el escritorio y que se quite del móvil (y que no haya bucle), urgencias y categorías, textos con etiquetas, caracteres de control y textos enormes, demonio que se cae, se reinicia o rechaza un aviso, sin demonio, reenvío apagado, sin acceso, app antigua y `NEXO_DBUS_NOTIFY*`;
- aparecer y desaparecer según haya música, app caída y vuelta, bus reiniciado, token cambiado, modo pasivo cuando otro ya tiene el nombre, systemd, bus que niega el nombre y bus que no existe (cada servicio con su conexión: un fallo no arrastra al otro);
- la **política del bus** contra un `dbus-daemon` que lo niega todo por omisión: sin política, `nexo-dbus` no ocupa el nombre; con `nexo setup-dbus --system-policy`, lo ocupa solo (sin reiniciar) y se puede hablar con él; `--uninstall` la quita (y no toca un `nexo.conf` ajeno);
- el bus propio (`--own-bus`); `nexo setup-dbus` (systemd simulado, autostart, script propio, desinstalar, sin python3), `setup-guests --with-dbus` y el instalador;
- todo lo anterior **dos veces**: como `root` y como un usuario sin privilegios (`nobody`, sin `sudo`), que es lo más parecido a Termux.

**No probado:** `bluetoothctl`, `nmcli`, Blueman, `nm-applet`, `libnm`, `playerctl`, Waybar, Polybar, Quickshell, GNOME, KDE (ningún programa real de escritorio; `busctl` y `gdbus` son los clientes que sí se han usado) y, para las notificaciones, **dunst, mako, swaync, GNOME Shell y KDE Plasma de verdad**: cada uno interpreta a su manera el marcado, los iconos, el reemplazo (`replaces_id`) y la urgencia.
**`nmcli`, `nm-applet` y los paneles de GNOME/KDE usan `libnm`, que comprueba muchas propiedades; si falta alguna pueden mostrar menos de lo esperado o quejarse.** Es lo que más espero que haya que afinar con tu retroalimentación.
Tampoco se ha probado: el comportamiento dentro de proot en un móvil real (permisos del socket del bus, identidad de usuario dentro de proot), instalar la política en el `/etc/dbus-1/system.d` de un sistema de verdad
(con `sudo`: las pruebas usan un bus de pruebas y una carpeta propia, así que ahí no hace falta), Python anteriores a 3.13 en ejecución (solo se comprueba que el código usa sintaxis de 3.7), y todo lo que depende del código de Android (que tampoco se ha ejecutado en un móvil desde la 0.2).
Si algo de esto falla en tu equipo, `~/.cache/nexo/dbus.log`, `nexo dbus status` y `nexo dbus run -v` dicen qué pasó.

## Idea sin probar: el móvil por USB

La app solo escucha en `127.0.0.1` del móvil. Con `adb forward tcp:8765 tcp:8765` ese puerto aparece también en tu PC; con `nexo pair TOKEN` y `nexo setup-dbus` en el PC,
la música del móvil debería verse como reproductor en tu escritorio de Linux de verdad (y, en un PC sin BlueZ ni NetworkManager propios, el Bluetooth y el WiFi del móvil como los de ese equipo: ahí hace falta `--system-policy`).
No se ha probado y no forma parte de lo que Nexo promete.
