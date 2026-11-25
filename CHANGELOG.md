# Cambios

Solo lo que cambia para quien usa Nexo. Qué está probado y qué no, en el [README](README.md#estado-y-lo-que-falta).

## 0.4.3

- **Nuevo: `nexo net`** — por dónde sale el móvil a internet ahora mismo: WiFi, **datos móviles**, cable, Bluetooth u otra (la «red predeterminada» de Android), si hay **VPN**, si Android comprobó que hay **internet de verdad** (distingue un WiFi sin salida o un portal cautivo de uno que funciona) y si es **de pago** (datos limitados).
  Mismos formatos que lo demás (`--json`, `--short`, `--env`, `--csv`, `--waybar`, `--polybar`, `--i3status`, `--qml`, `--dunst`, `--tmux`, `--starship`) y `nexo watch net` para recibir los cambios. **Sin permisos nuevos** (`ACCESS_NETWORK_STATE` ya estaba). No dice la IP de los datos móviles ni el operador.
- **Nuevo: `nexo notif`** — las **notificaciones del móvil** en la distro: `status`, `list` (las más nuevas primero), `dismiss CLAVE`, `dismiss --all` y `watch` (`--pretty`, `--event`: un evento con nombre por cambio, con el motivo del cierre: tocada, descartada, cancelada, caducada).
  **Es opcional y viene apagado**: hace falta el «acceso a notificaciones» de Android (el de la música) **y** el nuevo interruptor **«Reenviar notificaciones a Linux»** de la app. Solo viajan por `127.0.0.1` a programas con tu token que las piden (`nexo watch notif`; `nexo watch` sin tema no las trae),
  **no se guardan nunca** (ni la app ni la caché del cliente), se limita el ritmo (hasta 40 avisos por 10 s, sin repetir uno idéntico) y el tamaño (título 160, texto 500), y no se reenvían las de Nexo, los resúmenes de grupo ni los controles de reproductor. Android no deja quitar las **fijas** ni las de servicios en marcha: `dismiss CLAVE` da el error y `dismiss --all` cuenta cuántas no pudo quitar, en vez de fingir.
  Sin el acceso o con el reenvío apagado, los comandos dicen qué botón pulsar y salen con el código 3 (`nexo doctor` lo cuenta).
- **Nuevo: las notificaciones del móvil en tu escritorio.** `nexo-dbus` es ahora también **cliente de `org.freedesktop.Notifications`** (no ocupa ningún nombre): lo que llega al móvil sale en dunst, mako, swaync, GNOME o KDE con el nombre de la app, el título y el texto, **y si lo cierras con la ✕ se quita también del móvil**.
  Urgencia según la importancia (alarmas y llamadas, crítica), las fijas y las de importancia mínima no se enseñan, el texto se escapa según lo que admita el demonio, y se recupera si el demonio se cae o se reinicia. Queda activo por omisión al arrancar `nexo-dbus` (`nexo setup-dbus`); se apaga con `--no-notify` o `NEXO_DBUS_NOTIFY=0`
  (`NEXO_DBUS_NOTIFY_ALL=1` enseña también las fijas; `NEXO_DBUS_NOTIFY_DISMISS=0` hace que cerrar aquí no las quite del móvil). `nexo dbus status` tiene una línea «Notificaciones». También `NEXO_DBUS_SESSION_SOCKET=RUTA` (el socket del bus de sesión, para distros raras y pruebas).
  Guía: [`docs/INTEGRACION-ESCRITORIO.md`](docs/INTEGRACION-ESCRITORIO.md#notificaciones-del-móvil-orgfreedesktopnotifications).
- **Mejora: NetworkManager ve la red real del móvil.** El estado global que emula `nexo-dbus` (`State`, `Connectivity`, `Metered`) sale ahora de `net.status`: con **datos móviles** y sin WiFi conectado, `nmcli` y los applets dicen «conectado» (antes decían «desconectado», y los programas que hacen caso a NetworkManager —Firefox, por ejemplo— podían creerse sin internet);
  la red de pago sale como `Metered = yes`; un WiFi sin salida o un portal cautivo, como «conectado (solo sitio)» con conectividad limitada; sin red, «desconectado». Con una app anterior a la 0.4.3 se sigue deduciendo del WiFi, como antes, y `NEXO_DBUS_NM_ASSUME_ONLINE=1` sigue existiendo para ese caso (con la 0.4.3 ya no hace falta).
- **App Android:** `NetHandler.kt` y `NetLogic.kt` (la red predeterminada con `registerDefaultNetworkCallback`), `NotifBridge.kt` y `NotifLogic.kt` (qué se reenvía, límites y claves), `NexoNotificationListener.kt` ampliado, y el interruptor «Reenviar notificaciones a Linux» en la pantalla de Nexo.
  **Sin permisos nuevos** en el manifiesto. Versión 0.4.3 (código 8).
- **Protocolo 1.5** (revisión 5): `net.status`, `notif.status`, `notif.list` y `notif.dismiss`; los temas de eventos `net` y `notif` (opcionales: hay que pedirlos, y una app anterior simplemente los ignora); y `opens: "nexo_app"` en `needs_user_action` (cuando lo que falta es un interruptor de la propia app).
  Una app anterior y un cliente nuevo (o al revés) se entienden: `nexo net` y `nexo notif` piden instalar el APK nuevo y el resto sigue como siempre. Detalles en [`docs/PROTOCOLO.md`](docs/PROTOCOLO.md).
- **Corregido: `nexo usb`** — si la app moría a mitad de una copia o de un puente, el mensaje dependía de qué hilo se daba cuenta antes («no pude escribir…» o «se perdió la conexión…»); ahora siempre dice «Se perdió la conexión con la app Nexo». Lo encontraron las pruebas.
- **CI:** `tests/ci_annotate.sh` convierte las líneas `FALLA` de cada trabajo en anotaciones de GitHub con su detalle (así un fallo se lee en el resumen sin abrir el registro); `shellcheck` incluye los archivos de prueba nuevos y cada uno lleva su `#!`/directiva.
- Pruebas: 343 comprobaciones más (de 2212 a 2555) sobre `nexo net` y `nexo notif` (`tests/net_notif_tests.sh`), las notificaciones de `nexo-dbus` contra un demonio simulado (`tests/dbus_notif_tests.sh`, `tests/fake_notifd.py`) y NetworkManager con la red real;
  la app simulada habla ya el protocolo 1.5 por omisión (`--minor2`…`--minor5` fuerzan una anterior; `--reqlog` apunta cada petición), 26 pruebas de JVM nuevas (`NetLogicTest`, `NotifLogicTest`: 98 en total) y la comprobación de contrato ampliada (`tests/check_contract.py`: comandos, campos, errores, temas y documentación de la 1.5).
  Se probaron las pruebas: se estropeó a propósito el cliente de 10 maneras y las pruebas nuevas detectaron las 10.
  **Probado contra la app simulada, un demonio de avisos simulado, `busctl`/`gdbus` y pruebas de las reglas en una JVM, y compilado contra Android; todavía no con un móvil ni con dunst, mako, GNOME o KDE de verdad.**

## 0.4.2

- **Nuevo: almacenamiento USB (los discos en `nexo usb`)** — pendrives, discos duros y SSD externos **dentro de tu distro**. Android los monta y los enseña; Nexo entra solo en lo que tú autorizas en el selector de carpetas del sistema
  (sin «acceso a todos los archivos» y sin root): `nexo usb mounts` (qué discos hay y si Nexo puede entrar), `access` (el selector; una vez por disco), `ls`, `stat`, `cat`, `get` y `put` (copiar en los dos sentidos: carpetas con `-r`,
  `-f` para sustituir, `-n` para saltar, `--verify` con SHA‑256, `ORIGEN/` para copiar el contenido), `mkdir`, `rm`, `mv`, `df` y `eject`. Un archivo se escribe con un nombre provisional y se renombra al terminar, así que nunca queda uno a medias con su nombre;
  los nombres que los discos no admiten se rechazan antes (o `put --fix-names` los cambia por `_`); FAT32 no admite archivos de 4 GiB (el mensaje lo dice). Guía: [`docs/USB-ALMACENAMIENTO.md`](docs/USB-ALMACENAMIENTO.md).
  **Probado contra la app simulada (cada disco es una carpeta), con pruebas de las reglas en una JVM y con la compilación contra Android; todavía no con un móvil ni un disco de verdad.** `tests/usb_storage_hardware_check.sh` es la prueba para hacerlo y da un informe para pegar.
- **Nuevo: `nexo watch storage`** (y `nexo watch usb`, que faltaba): avisa cuando se monta, se expulsa o se quita un disco, cambia su estado o Nexo gana o pierde el acceso (`--pretty`: «disco → MI DISCO (montado)»; `--event`: un evento con nombre por cambio).
  Los temas `usb` y `storage` se piden por su nombre: sin tema, `nexo watch` sigue mirando `wifi bt audio media`.
- **Cambia: `nexo usb ls`** ya no es otro nombre de `nexo usb list`: ahora lista una carpeta de un disco. Para ver los dispositivos USB, `nexo usb list`.
- **Acceso directo opcional:** si el proceso donde ejecutas `nexo usb` ya ve la carpeta del disco (`/storage/UUID`: con root, con Shizuku/`rish`, o en un Android que lo permita), `--via direct`/`--via auto` trabaja sobre esa ruta sin pasar por la app, con las mismas reglas y mensajes.
  En un Termux normal no se ve y se usa la app. Nexo no integra Shizuku por su cuenta (todavía).
- **App Android:** `StorageLogic.kt`, `StorageSaf.kt`, `StorageVolumes.kt`, `StorageGrantActivity.kt` y `StorageHandler.kt`; un botón «Dar acceso a un disco USB» en la pantalla de Nexo y una notificación que abre el selector cuando un comando lo necesita.
  **Sin permisos nuevos** en el manifiesto: solo el acceso por carpeta que concede el usuario y Android recuerda.
- **Protocolo 1.4** (revisión 4): `storage.status`, `storage.access`, `storage.revoke`, `storage.list`, `storage.stat`, `storage.open`, `storage.read`, `storage.write`, `storage.sync`, `storage.close`, `storage.mkdir`, `storage.delete`, `storage.rename`, `storage.eject`,
  el tema de eventos `storage` (también en la suscripción por omisión) y el campo `storage` en `hello`; los datos viajan en trozos de base64 por la conexión JSON. Códigos de error nuevos: `no_access`, `unavailable`, `bad_path`, `exists`, `not_dir`, `is_dir`, `not_empty`, `read_only`,
  `no_space`, `too_big`, `io_error` y `limit`. Una app anterior y un cliente nuevo (o al revés) se entienden: `nexo usb` dice «actualiza la app». El estado de la red móvil y las notificaciones pasan a la 1.5 (0.4.3).
- Pruebas y CI: 587 comprobaciones más (de 1625 a 2212) sobre los discos (el cliente por los dos caminos comparando resultados, copias de todos los tamaños, nombres raros, 4500 archivos paginados, discos de solo lectura, llenos o expulsados, desenchufar y caerse la app a media copia, `watch storage`, `nexo usb` desde el cliente `nexo`),
  35 pruebas de JVM de las reglas de los discos (`StorageLogicTest.kt`), `tests/usb_storage_hardware_check.sh` y la comprobación de contrato ampliada (comandos, campos, errores y revisión del protocolo entre la app, la app simulada y la documentación).

## 0.4.1

- **Nuevo: `nexo usb`** — Arduino, ESP32 y adaptadores USB↔serie (CH340, CP210x, FTDI) **dentro de tu distro**. Los conectas al móvil (cable OTG o hub) y salen como un puerto serie:
  `nexo usb list` (todo lo que Android ve por USB, también teclados, ratones, discos y hubs, aunque solo se usan los puertos serie), `permit` (el permiso de Android), `monitor` (monitor serie),
  `bridge` (un puerto PTY para `avrdude`, `arduino-cli`, PlatformIO, `minicom` y `screen`; un servidor RFC 2217 para `esptool` y pyserial; TCP crudo para `avrdude -P net:`), `status`, `stop` y `reset`.
  Emula el **reinicio automático del Arduino** al abrir el puerto, y si desenchufas el cable el puerto se queda donde está y se recupera al volver a enchufar. Controladores propios, sin librerías:
  CDC‑ACM, CP210x, FTDI y CH34x (el PL2303 se enseña pero no se usa). Guía: [`docs/USB.md`](docs/USB.md).
  **Probado contra la app simulada y con pruebas de los controladores en una JVM; todavía no con un móvil ni una placa de verdad.** `tests/usb_hardware_check.sh` es la prueba para hacerlo (eco TX↔RX, cargador STK500 del Arduino, `esptool`, desenchufar) y da un informe para pegar.
- **Programa nuevo `nexo-usb`** (Python 3.7+, sin dependencias): el comando de instalación de la app instala ahora cuatro archivos; `nexo setup-guests --with-usb` y `nexo update` lo llevan a las distros (`--with-usb` también en `update`);
  `--uninstall` lo quita y `--purge` borra sus registros. `nexo doctor` lo muestra y dice si el móvil tiene USB host; `nexo usb list` funciona hasta sin Python.
- **App Android:** `UsbSerial.kt`, `UsbHandler.kt` y `UsbAttachedActivity.kt` (el aviso «abrir Nexo cuando se conecte»); `android.hardware.usb.host` se declara como no obligatorio (el APK se instala igual en móviles sin OTG).
- **Protocolo 1.3** (revisión 3): `usb.status`, `usb.permission`, `usb.open`, `usb.setup`, `usb.control`, `usb.close`, `usb.attach` (una segunda conexión que pasa a bytes crudos), el tema de eventos `usb` y el campo `usb` en `hello`.
  Una app anterior y un cliente nuevo (o al revés) se entienden: `nexo usb` dice «instala el APK nuevo». El estado de la red móvil y las notificaciones pasan a una revisión posterior (0.4.3).
- Pruebas y CI: 370 comprobaciones más (de 1255 a 1625) sobre `nexo usb` (monitor, puentes PTY/RFC 2217/TCP, reinicio del Arduino, desenchufar y volver a enchufar, instalador, `setup-guests`, `update`, `doctor`),
  37 pruebas de JVM de los controladores (`./gradlew testDebugUnitTest`), `tests/ref_baud.py` (las velocidades de FTDI y CH34x contra una transcripción independiente de libftdi y del kernel) y `tests/usb_hardware_check.sh`;
  trabajo `usb` en GitHub Actions (no bloquea).

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
- Protocolo: sin cambios (1.2). El estado de la red móvil y las notificaciones (protocolo 1.4) pasan a la 0.4.3.

## 0.4.0‑beta1

- `nexo-dbus` emula **BlueZ** (`org.bluez`: adaptador, dispositivos emparejados, batería, encender/apagar) y **NetworkManager** (`org.freedesktop.NetworkManager`: `wlan0`, redes a la vista y guardadas, conectar/desconectar) en el bus del sistema, para `bluetoothctl`, `nmcli` y los applets.
- `nexo setup-dbus --system-policy`, `--own-bus`, modo pasivo ante un BlueZ/NetworkManager de verdad, `nexo dbus status` por servicio.

## 0.3.0

- `nexo-dbus`: la música del móvil como reproductor **MPRIS** (`playerctl`, Waybar, Quickshell, GNOME, KDE); `nexo setup-dbus`; `setup-guests --with-dbus`.

## 0.2

- Audio (`nexo audio`), música (`nexo media`), redes guardadas, olvidar/renombrar Bluetooth, formatos para barras (`--polybar --i3status --qml --dunst --tmux --starship --csv`), `doctor --fix`, auto-recuperación.

## 0.1

- WiFi y Bluetooth por línea de comandos desde Termux y proot-distro; instalador de una línea que viaja dentro de la app.
