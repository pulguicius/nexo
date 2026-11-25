# Lo que Nexo no puede hacer (y por qué)

Nexo es una app normal de Android, sin root y sin permisos de sistema. Esta página dice **qué le niega Android**, **por qué**, **qué hace Nexo en su lugar** y,
cuando existe, **cómo se puede conseguir de otra forma**. Si algo de aquí te sorprende, es un fallo de la documentación: abre un *issue*.

Leyenda: ✅ funciona · 🟡 funciona con un toque tuyo o con condiciones · ❌ no es posible sin root o permisos de sistema.

| Función | Estado | Qué hace Nexo | Detalle |
|---|---|---|---|
| Ver el estado de WiFi, Bluetooth, audio y música | ✅ | Lo lee y lo entrega | [WiFi](#wifi) · [Bluetooth](#bluetooth) · [Audio](#audio) · [Música](#música-media) |
| Encender/apagar WiFi y Bluetooth | 🟡 | Directo en la mayoría; si el móvil se niega, notificación (código 3) | [Encender y apagar](#encender-y-apagar-wifi-y-bluetooth) |
| Escanear y conectarse a una red WPA/WPA2 u abierta | ✅ | `wifi scan`, `wifi connect` | [WiFi](#wifi) |
| Redes WPA3‑solo y de empresa (802.1X/EAP) | 🟡 | Abre el panel de WiFi con una notificación | [WiFi](#wifi) |
| Ver, olvidar y reconectar redes guardadas | 🟡 | `wifi saved`, `wifi forget`, `wifi reconnect` | [Redes guardadas](#redes-guardadas) |
| Hotspot (punto de acceso) | ❌ | No lo controla | [Hotspot](#hotspot-punto-de-acceso) |
| IP estática, DNS, proxy, MTU | ❌ | Solo los **lee** (ip, puerta de enlace, máscara, DNS) | [WiFi](#wifi) |
| Conectar/desconectar un dispositivo Bluetooth | 🟡 | Notificación que abre los ajustes (código 3) | [Bluetooth](#bluetooth) |
| Desemparejar y renombrar un dispositivo Bluetooth | 🟡 | `bt forget` (función no pública), `bt rename` (Android 12+) | [Bluetooth](#bluetooth) |
| Volumen y silencio de la música | ✅ | `audio volume` | [Audio](#audio) |
| Cambiar la salida de audio del sistema | 🟡 | Notificación que abre el panel de volumen | [Audio](#audio) |
| Controlar la música (play, pausa, siguiente, saltar) y ver qué suena | 🟡 | `media …`; necesita el «acceso a notificaciones» | [Música](#música-media) |
| Saber por dónde sale el móvil a internet (datos móviles, VPN, internet de verdad, de pago) | ✅ | `nexo net`: la red **predeterminada**, sin IP ni operador | [Red del móvil](#red-del-móvil-nexo-net) |
| Las notificaciones del móvil en Linux | 🟡 | `nexo notif` y, con `nexo-dbus`, en el escritorio; **opcional y apagado de fábrica**; no puede quitar las fijas | [Notificaciones](#notificaciones-nexo-notif) |
| Que Linux vea un adaptador WiFi/Bluetooth «de verdad» | ❌ | Lo emula por D‑Bus: la música (MPRIS) desde la v0.3; BlueZ y NetworkManager después (ver [ROADMAP](ROADMAP.md)) | [Emulación](#emulación-no-hardware) |
| Mantener la app viva siempre | 🟡 | Servicio en primer plano + ajustes de batería + auto-recuperación | [La app se congela](#la-app-se-congela-código-12) |

---

## Encender y apagar WiFi y Bluetooth

Desde Android 10, una app que apunta a la API 29 o más **no puede** encender ni apagar el WiFi. Nexo apunta a la **API 28 a propósito** (igual que Termux) para poder hacerlo.
Aun así, el sistema o el fabricante pueden negarse (modo avión, punto de acceso activo, restricciones de HyperOS/MIUI…). En ese caso Nexo **no falla en silencio**:
devuelve «hace falta un toque» (código de salida 3) y deja una notificación que abre el panel correcto.

Efectos secundarios de apuntar a la API 28:

- Android 14 y 15 bloquean instalar apps con un `targetSdk` demasiado bajo (mínimo 23 y 24). 28 queda por encima. Si algún día el mínimo sube, Nexo (y Termux) tendrán que subir el suyo y se perderá parte del control directo.
- Las apps que apuntan a 28 **no se pueden publicar en Google Play**. Nexo se distribuye por Releases de GitHub y, a partir de la 1.0, F‑Droid.
- Con `targetSdk` 28 el permiso `NEARBY_WIFI_DEVICES` (Android 13) **no sirve de nada**: el sistema sigue comprobando el de ubicación para las apps que apuntan a menos de 33. Por eso Nexo no lo pide.

## WiFi

- **Nombre de la red y redes cercanas** (`wifi status`, `wifi scan`): Android solo los entrega a apps con el permiso de **ubicación** y con la **ubicación del sistema encendida**.
  Nexo no lee tu ubicación; es una exigencia de Android. Sin eso, el nombre sale como «(red oculta: falta permiso de ubicación)» y los escaneos salen vacíos.
- **Límite de escaneos**: unos 4 cada 2 minutos. Pasado el límite, `wifi scan` devuelve la última lista con `fresh:false`. En Opciones de desarrollador está «Wi‑Fi scan throttling» para quitarlo.
- **Conectarse** (`wifi connect`): redes abiertas y WPA/WPA2 personal. WPA3‑solo y 802.1X (empresa, universidades) no se pueden crear con la API clásica: Nexo abre el panel de WiFi.
- **Datos de red** (`wifi status`): ip, puerta de enlace, máscara, prefijo y DNS **se leen**; **no se pueden cambiar**. Cambiar la IP, el DNS, el proxy o el MTU necesita root o ser la app de sistema.
- **Señal débil**: con redes muy débiles (por ejemplo −87 dBm) Android puede informar `connected: false` un instante mientras renegocia.

### Redes guardadas

`wifi saved` necesita el permiso de ubicación y solo funciona porque la app apunta a la API 28: Android 10 o más devuelve una lista **vacía** a las apps que apuntan a 29 o más.
`wifi forget` solo puede borrar las redes que el sistema deje borrar a esta app; si Android se niega, Nexo abre el panel de WiFi (código 3) para que la olvides tú.
Todo esto está comprobado contra la API, **no en un móvil real**: si en tu móvil la lista sale vacía, es probable que el fabricante la oculte.

### Hotspot (punto de acceso)

La API pública solo permite un hotspot «local» temporal (`startLocalOnlyHotspot`, Android 8+): sin internet, con nombre y clave aleatorios, y exige el permiso de ubicación.
El hotspot de siempre (compartir internet) pertenece al sistema. Nexo **no** lo controla; está anotado como idea en el [ROADMAP](ROADMAP.md) (¿hotspot local para que el móvil sea punto de acceso de la distro?) pero no hay compromiso.

## Bluetooth

- **Conectar/desconectar** un dispositivo ya emparejado necesita un permiso que Android reserva al sistema (`BLUETOOTH_PRIVILEGED`). `bt connect` y `bt disconnect` validan la dirección y abren los ajustes de Bluetooth con una notificación.
  Lo que sí se puede: encender/apagar la radio, ver los emparejados, saber cuáles están conectados y por qué perfiles.
- **Desemparejar** (`bt forget`): `BluetoothDevice.removeBond()` no es API pública. Nexo la llama por reflexión; solo funciona porque la app apunta a la API 28 (Android bloquea esas funciones a las apps nuevas).
  Si el sistema la bloquea, cae a «hace falta un toque» y abre los ajustes. **Sin comprobar en un móvil real.**
- **Renombrar** (`bt rename`): el alias lo permite la API pública desde Android 12 (API 31). En Android 11 o menos responde `unsupported`.
- **Batería del dispositivo** (`bt info`): usa una función no pública; si el dispositivo o el sistema no la dan, el campo sale `null`.
- **Audio Bluetooth para Linux**: no hace falta nada. Si conectas unos auriculares en Android, todo el audio del móvil (y el de Termux, que sale por el móvil) va a ellos.
  No existe «audio Bluetooth independiente para Linux» y no hace falta.

## Audio

- Nexo controla el volumen y el silencio de la **música** (el canal que usan Spotify, YouTube, VLC, Termux…), no el del timbre ni el de las llamadas. `audio status` sí informa del modo timbre (`normal`, `vibrate`, `silent`).
- **Cambiar la salida** del sistema (`audio switch`): `setPreferredDevice` solo afecta al audio de la propia app y las funciones de enrutamiento del sistema son de sistema. Nexo valida que la salida existe y abre el panel de volumen para que la elijas.
  La salida que «suena ahora» se lee con la API del sistema en Android 13+ y se estima (Bluetooth > cable > USB > altavoz) en versiones anteriores.
- Algunos móviles (HyperOS incluido) no envían a las apps los avisos de cambio de volumen; Nexo vigila además los ajustes del sistema, pero un evento puede tardar o llegar duplicado.

## Música (media)

- Ver qué suena y controlarlo exige el **acceso a notificaciones**. Nexo lo usa **solo** para las sesiones de medios; no lee ni guarda notificaciones (el reenvío de notificaciones a Linux es, desde la 0.4.3, opcional y aparte: ver [Notificaciones](#notificaciones-nexo-notif)).
- En **Android 13 o más**, si instalaste el APK a mano, el interruptor del acceso a notificaciones sale en gris hasta que pulsas Ajustes › Aplicaciones › Nexo › ⋮ › **Permitir ajustes restringidos**.
- Solo aparece la música de apps que publican una *sesión de medios* (casi todas las de música y vídeo; algunas la crean al darle a play). Los controles dependen de lo que la app permita: `can_next`, `can_seek`… lo dicen.
- La **posición** no se transmite en los eventos (cambiaría cada segundo): se calcula al preguntar. `media seek` funciona si la app lo admite.
- La **carátula** (`media art`) se reduce a ≤ 320 px y ~40 KB. Si la app solo da una dirección de internet, no se descarga (Nexo no usa la red): solo imágenes incluidas en la sesión o en un `content://` de la propia app.

## Red del móvil (`nexo net`)

- Cuenta la red **predeterminada** de Android (la que usa para salir a internet), no todas las que estén conectadas a la vez: con el WiFi y los datos móviles encendidos dice la que Android esté usando en ese momento (normalmente el WiFi).
- Es un **resumen**: tipo (WiFi, datos móviles, cable, Bluetooth u otra), si hay VPN, si Android validó que hay internet, si la red es de pago y si hay portal cautivo. **No** da la IP de los datos móviles, el operador, la intensidad ni la velocidad (para el WiFi, `nexo wifi status` sigue dando los detalles).
- «Internet de verdad» lo decide **Android** con su propia comprobación (Nexo no hace ninguna petición a internet): una red que bloquea esa comprobación puede salir como «sin internet de verdad» aunque con ella se pueda navegar. `nexo net` solo cuenta lo que Android dice.
- No cambia nada: solo mira. Con una app anterior a la 0.4.3 no existe (`nexo net` pide el APK nuevo).
- **Sin probar en un móvil** (solo con la app simulada y con pruebas de las reglas en una JVM): cómo cuenta cada transporte tu Android (HyperOS, datos duales, WiFi + datos a la vez, VPN que se enciende y apaga).

## Notificaciones (`nexo notif`)

- Es **opcional y viene apagado**: hace falta el «acceso a notificaciones» de Android (el mismo de la música; en Android 13 o más, quizá antes **Permitir ajustes restringidos**, ver [Música](#música-media)) **y** el interruptor **«Reenviar notificaciones a Linux»** de la app. Sin cualquiera de los dos no sale nada de Android.
- **Quien tenga tu token puede leerlas.** Activado el reenvío, cualquier programa de Termux o de una distro que lea la configuración de Nexo puede suscribirse y ver tus notificaciones (y quitarlas): lo que decía arriba para WiFi y Bluetooth, pero con datos más privados. Por eso viene apagado y solo viaja por `127.0.0.1`.
- **Nexo no las guarda** (ni la app ni la caché del cliente). Lo que ya llegó a tu escritorio queda en manos de tu demonio de avisos (dunst, mako, GNOME, KDE…), que puede tener su propio historial.
- **No se pueden quitar las fijas** ni las de servicios en marcha (reproductores, VPN, una llamada en curso, «Nexo activo»): Android no deja que una app de terceros las cierre. Se ven en `nexo notif list`, pero `nexo notif dismiss` dice que no se pudo; en el escritorio no se enseñan (salvo `NEXO_DBUS_NOTIFY_ALL=1`).
- **Solo texto**: llegan el nombre de la app, el título, el texto (recortes de 160 y 500 caracteres), la hora, la categoría y la importancia. **No** pasan los iconos, las imágenes, los botones de acción ni las respuestas rápidas: no se puede responder un mensaje ni abrir la app del móvil desde Linux.
- **Solo en vivo y solo lo de ahora.** Los avisos nuevos llegan mientras haya alguien suscrito (`nexo notif watch`, `nexo-dbus`): lo que llegó antes no se recupera. `nexo notif list` enseña las que Android tiene **ahora** (las 40 más nuevas como mucho); no hay historial.
- Se **omiten** las de la propia Nexo, los resúmenes de grupo y los controles de reproductor; no se repite un aviso idéntico en menos de 10 s y no salen más de 40 eventos cada 10 s (una app que repite avisos no satura tu terminal ni tu escritorio).
- Cerrar un aviso en el escritorio con la ✕ lo quita del móvil; si **caduca solo** o lo cierra el propio programa, el móvil no se entera.
- Si el sistema o el fabricante **suelta** el servicio de notificaciones (pasa en algunos con el ahorro de batería), Nexo le pide a Android que lo enlace otra vez; si no vuelve, apaga y enciende el acceso en los ajustes. `nexo notif status` y `nexo doctor` dicen si está activo.
- **Sin probar en un móvil ni con un demonio de avisos de verdad** (solo con la app simulada, un demonio simulado y pruebas de las reglas en una JVM): qué entrega Android exactamente en HyperOS 3 / Android 16, qué hace cada demonio (iconos, acciones, urgencia, historial, notificaciones que se reemplazan) y cuáles de las fijas se resisten.

## Emulación, no hardware

Nexo **controla** el WiFi y el Bluetooth de Android; no se los **entrega** a Linux. Dentro de proot no hay controladores de kernel, `rfkill` ni `hci0`: herramientas como `iw`, `hcitool` o `iwlist` no van a ver nada, ni siquiera con `nexo-dbus`.
Lo que sí es posible (desde la v0.3 y la 0.4.0‑beta1) es que programas que hablan D‑Bus (`playerctl`, `bluetoothctl`, `nmcli`, applets de escritorio) lean el estado del móvil porque `nexo-dbus` finge ser MPRIS, BlueZ y NetworkManager.
Esa emulación es **fiel solo en lo que Android permite**: estado, listas, eventos y las acciones que Nexo sí puede hacer.

**Lo que hay hoy (v0.3): MPRIS.** `nexo-dbus` publica la sesión de medios activa de Android como `org.mpris.MediaPlayer2.nexo` (guía: [INTEGRACION-ESCRITORIO](INTEGRACION-ESCRITORIO.md)). Sus límites:

- Solo existe **mientras haya música en Android** y la app tenga el acceso a notificaciones. Sin eso no hay reproductor (a propósito: un «Nexo» muerto confunde a los widgets).
- Es **un** reproductor: la sesión de medios que Android considera activa. Si suenan dos apps a la vez, no ves las dos.
- No se publican `LoopStatus`, `Shuffle`, `TrackList` ni `Playlists` (son opcionales en MPRIS y el protocolo de Nexo todavía no transporta esos datos); `OpenUri` responde «no soportado»; `Rate` es de solo lectura.
- La carátula llega solo si la app que suena la incluye en su sesión (Nexo no usa internet).
- Cada distro de proot tiene **su** bus de sesión: `nexo-dbus` tiene que estar en el mismo que tu barra o tu escritorio. Un escritorio de otra distro, o el de Termux, no ve el reproductor de esta.
- Necesita **python3** en la distro (un solo archivo, sin librerías).

**Lo que hay desde la 0.4.0‑beta1: BlueZ y NetworkManager** (en el bus del **sistema**; guía: [INTEGRACION-ESCRITORIO](INTEGRACION-ESCRITORIO.md)). Sus límites:

- **Bluetooth.** Salen los dispositivos **ya emparejados en Android**: Nexo no busca dispositivos nuevos (`bluetoothctl scan on` solo enciende el Bluetooth) ni empareja (`Pair` responde «no soportado»).
  **Conectar y desconectar un dispositivo no se puede sin root**: `connect`/`disconnect` devuelven `org.nexo.Error.NeedsUserAction` y la app deja una notificación que abre los ajustes de Bluetooth del móvil.
  La dirección del adaptador es inventada (Android no da la del móvil) y `Discoverable`, `Blocked` y el nombre del adaptador no se pueden cambiar desde aquí.
- **WiFi.** `nmcli` ve **un** dispositivo (`wlan0`) y las redes que ve el móvil. Conectar, desconectar, escanear y olvidar redes funcionan; **las claves guardadas no se pueden leer** (`GetSecrets` va vacío),
  no se pueden crear ni editar perfiles (`nmcli connection add/modify` → «no soportado») y no hay VPN, Ethernet, hotspot ni IP estática. La MAC de `wlan0` es inventada. Encender o apagar el WiFi y algunas conexiones piden a veces un toque en el móvil.
  El estado global (`State`, `Connectivity`, `Metered`) sale, con la app 0.4.3, de la red por la que sale el móvil (datos móviles, VPN, WiFi sin salida o portal cautivo incluidos), pero **la red de datos móviles o la VPN no aparecen como dispositivos ni conexiones** en `nmcli`: solo cambian el estado global.
  Con una app anterior mira solo el WiFi y con datos móviles puede decir «desconectado» (`NEXO_DBUS_NM_ASSUME_ONLINE=1` lo evita).
- Un bus del sistema de verdad **exige una política** para que un usuario normal ocupe `org.bluez` o `org.freedesktop.NetworkManager` (`nexo setup-dbus --system-policy`, con root); en proot no hay bus del sistema y se crea uno propio con `--own-bus`.
- Si ya hay un BlueZ o un NetworkManager de verdad (o systemd los gestiona), `nexo-dbus` **no los pisa** (modo pasivo).
- Los programas basados en `libnm` (`nmcli`, `nm-applet`, los paneles de GNOME y KDE) comprueban muchas propiedades: la emulación puede resultarles incompleta. **Está probada con `busctl` y `gdbus`, no con ellos.**

## Archivos entre móviles (`nexo tools`)

- **Solo la red local.** No atraviesa internet ni hace de nube. Los dos dispositivos deben poder verse por IP: muchos routers tienen «aislamiento de clientes» o red de invitados y no lo permiten.
- **El descubrimiento (`discover`) usa difusión UDP**: algunos routers y móviles no la entregan (sobre todo con la pantalla apagada). Siempre queda `nexo tools connect IP --code CÓDIGO`.
- **«Todas las carpetas» son todas las que el programa puede leer.** Sin root, Android no deja a Termux ver `Android/data` y `Android/obb` de otras apps (Android 11 o posterior) ni sus datos privados (`/data/data/…`); para ver el almacenamiento interno hace falta `termux-setup-storage` (y entonces es `~/storage/shared`).
  Compartir `/` solo funciona en solo lectura y nunca enseña `/proc`, `/sys` ni `/dev`.
- **Qué se copia.** Por HTTPS solo el contenido: sin permisos, propietarios, enlaces simbólicos (se muestran, pero no se bajan salvo `NEXO_TOOLS_ALLOW_SYMLINK_DOWNLOAD=1`), enlaces duros ni archivos dispersos. Para copiar un árbol tal cual, `nexo tools rsync-pull`.
- **Escribir en el otro móvil** exige dos permisos a la vez (servidor con `--rw` y emparejamiento con `pair --rw`); **borrar manda a `.nexo-trash`** y no se puede vaciar por la red.
- **Certificado propio.** El navegador avisará de que no es de confianza (es autofirmado a propósito: lo que vale es la huella). `rotate-cert` obliga a emparejar de nuevo.
- **Segundo plano.** Con la pantalla apagada y el ahorro de batería de HyperOS, el móvil que comparte puede dejar de contestar: desactiva el ahorro para Termux y usa `termux-wake-lock`.
- **Sin probar en móviles reales** (solo entre dos «dispositivos» simulados en una máquina): ver [NEXO-TOOLS](NEXO-TOOLS.md#qué-se-ha-probado-y-qué-no).

## USB serie (`nexo usb`)

- **Solo puertos serie (y discos, más abajo).** Android deja a una app abrir un dispositivo USB con `UsbManager` y el permiso del usuario; una distro de proot no puede abrir `/dev/bus/usb`, no puede montar nada y no tiene `CAP_SYS_ADMIN`. Teclados, ratones, discos y hubs **salen en `nexo usb list`** pero no se pasan a la distro
  (los discos tienen su sección, más abajo; Android ya usa el teclado y el ratón para el propio móvil).
- **El puerto es un PTY, no un dispositivo USB.** `lsusb`, `udevadm` y los programas que buscan `/dev/ttyACM*` o `/dev/ttyUSB*` solos (Arduino IDE, `arduino-cli board list`) no lo ven: hay que darles la ruta (`nexo usb status`), o `--link /dev/ttyUSB0` si tu distro deja escribir en `/dev`.
- **DTR y RTS no existen en un PTY de Linux.** `nexo usb bridge` emula el reinicio del Arduino al abrir el puerto y suelta las líneas al cerrar; `esptool` y pyserial deben usar el servidor RFC 2217 (`rfc2217://…`), que sí las lleva. Algo que mire DTR/RTS por otra vía no los verá.
- **Chips:** CDC‑ACM, CP210x, FTDI y CH34x. **PL2303 no** (sale en la lista con una nota). Placas de USB nativo que se reprograman con un «toque» a 1200 baudios (Leonardo, Pro Micro) reaparecen con otro VID:PID y el puente no las sigue.
  FTDI y CH34x calculan un divisor: la velocidad real puede diferir un poco de la pedida (≤ ~2 % en las normales). CP210x y CH34x no admiten 1,5 bits de parada.
- **Un dispositivo, una sesión.** Mientras un puente (o un `monitor`) lo tiene abierto, otro comando responde «ocupado». El puente RFC 2217 y el TCP crudo admiten varios clientes, pero escriben todos al mismo chip.
- **Seguridad:** el RFC 2217 y el TCP crudo **no tienen contraseña** (escuchan en `127.0.0.1`): cualquier programa del móvil que los abra puede escribir en tu placa. Ciérralos con `nexo usb stop`. Android pide el permiso por dispositivo, y puede volver a pedirlo al desenchufar y enchufar si no marcaste «Usar siempre».
- **Energía.** El móvil da poca corriente por OTG: con varias placas o discos, un hub con alimentación. Algunos Xiaomi tienen un interruptor «OTG» que se apaga solo.
- **Sin probar con hardware real** (solo con la app simulada y con pruebas de JVM): ver [USB](USB.md#probarlo-en-tu-móvil) y `tests/usb_hardware_check.sh`.

## Discos USB (`nexo usb mounts`, `ls`, `get`, `put`…)

- **En la distro no hay `mount`, ni `/dev/sda`, ni `lsblk`.** Una distro de proot no es root y el kernel es el de Android. A un disco se llega con `nexo usb ls`, `get`, `put`, `cat`…; lo que espera una carpeta o un dispositivo
  (gestores de archivos de Linux, `udisksctl`, `rsync` o `tar` directos sobre el disco) no lo ve. Una tubería (`nexo usb cat /copia.tar | tar xf -`) o copiar primero a la distro (`get`) lo resuelve; un explorador interactivo y la emulación de UDisks2 están en la [hoja de ruta](ROADMAP.md).
- **Android decide qué se monta.** Nexo solo ve lo que Android montó: FAT32 y exFAT casi siempre; NTFS y ext4 dependen del móvil (muchos no los montan). De un disco con varias particiones salen las que Android monte. Android no dice qué sistema de archivos tiene un disco ni si es USB o tarjeta SD, así que `nexo usb mounts` tampoco lo dice.
- **Hay que elegir el disco una vez en el selector de carpetas de Android** (`nexo usb access`). No se puede evitar: es la forma que ofrece Android a una app normal de escribir en un disco USB **sin** «acceso a todos los archivos». Si el selector de tu móvil no deja elegir el disco entero, se elige una carpeta y esa es la raíz para Nexo.
- **FAT32 no admite archivos de 4 GiB o más** (`too_big`); exFAT, NTFS y ext4 no tienen ese límite. Las rutas, hasta 4096 caracteres; cada nombre, hasta 255 bytes.
- **Nombres.** Los nombres **nuevos** no pueden llevar `" * : < > ? \` ni la barra vertical, ni acabar en punto o espacio: Android los cambiaría por `_` sin avisar y el archivo acabaría con otro nombre; Nexo lo rechaza (o `put --fix-names` los cambia por `_` y te lo cuenta).
  FAT y exFAT no distinguen mayúsculas: `Foto.jpg` y `foto.jpg` son el mismo archivo. Lo que ya existe en el disco con esos nombres se puede leer, mover y borrar. Cambiar **solo las mayúsculas** de un nombre (`Foto.jpg` → `foto.jpg`) depende de Android y del disco: si se niega,
  renómbralo en dos pasos (primero a otro nombre y luego al que quieres).
- **Fechas, permisos y enlaces.** `put` **no puede poner la fecha de modificación** (el Storage Access Framework no tiene forma de hacerlo): el archivo queda con la hora de la copia; `get` sí la conserva. No hay permisos de Unix, propietarios ni enlaces simbólicos (`put` omite los enlaces y lo dice).
- **Expulsar.** `nexo usb eject` le pide a Android que expulse el disco, pero una app normal puede no tener permiso y Android lo ignora **sin avisar**: Nexo mira el estado y, si no se expulsó, dice cómo hacerlo a mano (el botón «Expulsar» de Android) y sale con 1. En Android 8 y 9 (antes de la API 29) la app ni siquiera puede pedirlo: solo cierra los archivos y te lo explica.
  Desenchufar con una copia en marcha deja un `.nexo-part-…` en el disco (se borra con `nexo usb rm`) y puede dejar el disco «sucio» (Android o un PC te pedirán repararlo).
- **Mover.** `nexo usb mv` solo mueve **dentro del mismo disco**; entre discos, `get` y `put`. Mover a otra carpeta **y** cambiar el nombre a la vez lo hace Android en dos pasos: si en esa carpeta ya hay algo con el nombre de origen, responde `ya existe`.
- **Borrar.** `rm -r` recorre el árbol y borra elemento a elemento (no hay un «borrar carpeta entera» en una sola orden: Android la borraría sin avisar). En una carpeta enorme tarda lo que tarden cientos de miles de órdenes.
- **Velocidad.** Los datos pasan por el TCP local en base64, en trozos de 48 KiB (leer) y 32 KiB (escribir): es más lento que un disco directo. **No se ha medido en un móvil**; `tests/usb_storage_hardware_check.sh --speed 64` lo mide.
- **Acceso directo.** `--via direct` solo funciona si el proceso ya ve la carpeta del disco (root, Shizuku/`rish`, o un Android que lo permita); se probó únicamente con carpetas normales. Nexo no integra Shizuku por su cuenta.
- **Seguridad.** Quien conozca el token del puente puede hacer con los discos autorizados lo mismo que tú (es el único candado, como en el resto del protocolo). Quita el acceso (`nexo usb access --revoke`) de los discos que no uses.
- **Teclados, ratones y hubs** siguen sin pasarse a la distro.
- **Sin probar con hardware real** (solo con la app simulada, donde cada disco es una carpeta, y con pruebas de JVM): ver [USB-ALMACENAMIENTO](USB-ALMACENAMIENTO.md#probarlo-en-tu-móvil) y `tests/usb_storage_hardware_check.sh`.

## La app se congela (código 12)

Xiaomi/HyperOS/MIUI y otras capas **congelan** las apps en segundo plano aunque tengan un servicio en primer plano: el puerto acepta la conexión, pero nadie contesta.
Desde dentro de la app no se puede impedir; se mitiga: ajustes de batería, `nexo start`, `nexo doctor --fix`, el reintento del cliente, la caché de las barras y el auto-ping del puente.
Ver [FAQ](FAQ.md#qué-es-el-código-12) y la sección «Que Android no cierre la app» del README.

## Seguridad: lo que no protege

- El token protege frente a **otras apps** del móvil. Quien lo tenga controla WiFi, Bluetooth, audio y música (y, si activas el reenvío, **lee y quita tus notificaciones**): no lo compartas ni lo pegues en chats.
- `proot` comparte la red con Android: el `127.0.0.1` de la distro **es** el de la app. Cualquier proceso dentro de la distro que lea `/etc/nexo/config` puede hablar con la app (con `setup-guests --private`, solo root).
- `nexo raw` es un freno a los errores, no una barrera: quien tiene el token puede escribir peticiones a mano.

## Con root

Con root (Magisk) se podrían desbloquear la conexión real de Bluetooth, redirigir el audio y cambiar la IP estática. No está en la v1.0; la idea está en el [ROADMAP](ROADMAP.md) (v2.0).
