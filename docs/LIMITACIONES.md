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
| Que Linux vea un adaptador WiFi/Bluetooth «de verdad» | ❌ | Lo emula por D‑Bus (desde v0.3; ver [ROADMAP](ROADMAP.md)) | [Emulación](#emulación-no-hardware) |
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

- Ver qué suena y controlarlo exige el **acceso a notificaciones**. Nexo lo usa **solo** para las sesiones de medios; no lee ni guarda notificaciones (eso llegará, opcional y aparte, en la v0.6).
- En **Android 13 o más**, si instalaste el APK a mano, el interruptor del acceso a notificaciones sale en gris hasta que pulsas Ajustes › Aplicaciones › Nexo › ⋮ › **Permitir ajustes restringidos**.
- Solo aparece la música de apps que publican una *sesión de medios* (casi todas las de música y vídeo; algunas la crean al darle a play). Los controles dependen de lo que la app permita: `can_next`, `can_seek`… lo dicen.
- La **posición** no se transmite en los eventos (cambiaría cada segundo): se calcula al preguntar. `media seek` funciona si la app lo admite.
- La **carátula** (`media art`) se reduce a ≤ 320 px y ~40 KB. Si la app solo da una dirección de internet, no se descarga (Nexo no usa la red): solo imágenes incluidas en la sesión o en un `content://` de la propia app.

## Emulación, no hardware

Nexo **controla** el WiFi y el Bluetooth de Android; no se los **entrega** a Linux. Dentro de proot no hay controladores de kernel, `rfkill` ni `hci0`: herramientas como `iw`, `hcitool` o `iwlist` no van a ver nada, ni siquiera con `nexo-dbus`.
Lo que sí es posible (v0.3–v0.5) es que programas que hablan D‑Bus (`playerctl`, `bluetoothctl`, `nmcli`, applets de escritorio) lean el estado del móvil porque `nexo-dbus` finge ser MPRIS, BlueZ y NetworkManager.
Esa emulación es **fiel solo en lo que Android permite**: estado, listas, eventos y las acciones que Nexo sí puede hacer.

## La app se congela (código 12)

Xiaomi/HyperOS/MIUI y otras capas **congelan** las apps en segundo plano aunque tengan un servicio en primer plano: el puerto acepta la conexión, pero nadie contesta.
Desde dentro de la app no se puede impedir; se mitiga: ajustes de batería, `nexo start`, `nexo doctor --fix`, el reintento del cliente, la caché de las barras y el auto-ping del puente.
Ver [FAQ](FAQ.md#qué-es-el-código-12) y la sección «Que Android no cierre la app» del README.

## Seguridad: lo que no protege

- El token protege frente a **otras apps** del móvil. Quien lo tenga controla WiFi, Bluetooth, audio y música: no lo compartas ni lo pegues en chats.
- `proot` comparte la red con Android: el `127.0.0.1` de la distro **es** el de la app. Cualquier proceso dentro de la distro que lea `/etc/nexo/config` puede hablar con la app (con `setup-guests --private`, solo root).
- `nexo raw` es un freno a los errores, no una barrera: quien tiene el token puede escribir peticiones a mano.

## Con root

Con root (Magisk) se podrían desbloquear la conexión real de Bluetooth, redirigir el audio y cambiar la IP estática. No está en la v1.0; la idea está en el [ROADMAP](ROADMAP.md) (v2.0).
