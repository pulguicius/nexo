# Preguntas frecuentes

## ¿Qué es el código 12?

`nexo` devolvió **12** = «sin respuesta a tiempo». El puerto aceptó la conexión pero la app no contestó. En Xiaomi/HyperOS casi siempre significa que **el sistema congeló la app**
(otras capas también lo hacen). No es un fallo del cliente ni del protocolo.

Qué hacer, en este orden:

1. `nexo start` (abre la app y la despierta) y repite.
2. `nexo doctor --fix`: diagnostica y arregla lo que puede (despertar la app, volver a enlazar, actualizar distros).
3. Ajustes de batería de Nexo: **Sin restricciones**, **Inicio automático**, **candado** en recientes. Es lo único que lo evita de verdad (README → «Que Android no cierre la app»).
4. Si nada funciona: fuerza la detención de Nexo, ábrela y pulsa **Iniciar puente**.

El cliente ya reintenta una vez, y las barras (`--waybar`, `--polybar`…) enseñan el último valor en vez de fallar. Nexo solo repite lo que es seguro repetir: nunca un «siguiente» o un «subir volumen».

## ¿Y el código 10, el 11 y el 3?

| Código | Significa | Qué hacer |
|---|---|---|
| `3` | Hace falta un toque en el móvil (o la conexión no se confirmó) | Toca la notificación que dejó Nexo |
| `10` | No hay conexión con la app (puente apagado, o la app cerrada) | `nexo start`, o abre Nexo y pulsa **Iniciar puente** |
| `11` | El token no vale (pulsaste «Token nuevo») | `nexo rekey` o pega el comando de instalación otra vez |

## ¿Qué es el token y dónde está?

Es una clave aleatoria de 192 bits que genera la app. Sin ella ninguna otra app del móvil puede hablar con el puente. Está en la app (botón **Mostrar token**) y en `~/.config/nexo/config` (modo 600).
`nexo config list` lo muestra oculto (`********`). Para cambiarlo: **Token nuevo** en la app y `nexo rekey`.
Para enlazar sin dejar el token en el historial: `nexo pair --token-stdin`.

## ¿Por qué pide permiso de ubicación? ¿Me sigue?

No te sigue ni lee tu posición. Android **solo entrega el nombre de la red WiFi y las redes cercanas a apps con ese permiso** (con la ubicación del sistema encendida): es una exigencia del sistema.
Sin el permiso, el WiFi aparece como «red oculta» y `wifi scan` sale vacío.

## ¿Por qué pide «acceso a notificaciones»? ¿Lee mis notificaciones?

Para poder ver y controlar **la música** (qué suena, pausa, siguiente, carátula): Android solo enseña las sesiones de medios de otras apps a quien tiene ese acceso.
En esta versión Nexo **no lee ni guarda ninguna notificación**. Puedes quitar el acceso cuando quieras (Ajustes › Notificaciones › Acceso a notificaciones); lo demás sigue funcionando.

**El interruptor sale en gris (Android 13 o más):** al instalar el APK a mano, Android lo bloquea. Ajustes › Aplicaciones › Nexo › ⋮ (arriba a la derecha) › **Permitir ajustes restringidos**, y vuelve a intentarlo.

## `media status` dice que no suena nada, pero sí suena

Nexo solo ve apps que publican una *sesión de medios*. Casi todas las de música y vídeo lo hacen, pero algunas solo la crean al pulsar play, o la cierran al pausar un rato.
Si el acceso a notificaciones está dado y sigue sin verse, prueba con otra app para comprobar que el problema es de esa app.

## ¿Para qué sirve la notificación fija «Nexo activo»?

Android exige una notificación a los servicios en primer plano, y es lo que mantiene el puente vivo. No la puedes quitar sin que Android lo cierre. Su botón **Detener** apaga el puente.

## ¿Por qué `bt connect` no conecta?

Android reserva la conexión de dispositivos Bluetooth al sistema (necesita un permiso que solo tienen las apps de sistema). Nexo valida la dirección y abre los ajustes de Bluetooth con una notificación (código 3).
Lo que sí hace: encender/apagar el Bluetooth, listar emparejados, ver cuáles están conectados, `bt forget`, `bt rename` (Android 12+) y `bt info`. Más en [LIMITACIONES](LIMITACIONES.md).

## ¿Puedo usar Nexo sin `jq`?

Sí, pero la salida sale como JSON sin formato y los formatos de barra (`--waybar`, `--polybar`…) no funcionan. `pkg install jq` (Termux), `pacman -S jq`, `apk add jq`, `apt install jq`.

## ¿Funciona con otros Termux (F‑Droid, GitHub, Monet…)?

Sí. No depende del nombre del paquete de Termux ni de rutas fijas. El comando que copia la app es el mismo para todos; la prueba con otro nombre de paquete forma parte de las pruebas automáticas
(el Termux «de verdad» sí está probado: Monet, con Arch en proot-distro).

## ¿Y en mi distro de proot-distro?

`nexo setup-guests` (en Termux) copia el cliente y el enlace a tus distros. Dentro, instala `bash` y `jq`. `nexo setup-guests --list` enseña cuáles ya lo tienen (y qué versión); `--uninstall` las limpia; `--private` deja el enlace solo para root;
`--with-dbus` les copia también `nexo-dbus` (la música del móvil como reproductor para `playerctl`, Waybar, etc.; ver [INTEGRACION-ESCRITORIO](INTEGRACION-ESCRITORIO.md)) y `--with-tools`, `nexo-tools` (archivos entre móviles; ver [NEXO-TOOLS](NEXO-TOOLS.md)).
Reconoce las dos disposiciones de proot-distro (`containers/NOMBRE/rootfs` e `installed-rootfs/NOMBRE`).

## Actualicé `nexo` a mano y la distro sigue con la versión vieja

Casi siempre es que la distro tiene **dos copias** de `nexo` (por ejemplo `/usr/local/bin/nexo`, la que dejó una versión anterior de `setup-guests`, y `/usr/bin/nexo`, la que copiaste tú) y **gana la otra** según el `PATH`.
Lo ves con `nexo setup-guests --list` (enseña la versión de cada copia) o, dentro de la distro, con `type -a nexo`. La solución: `nexo setup-guests` (actualiza **todas** las copias y luego ejecuta `nexo version` dentro de cada distro para decirte cuál se usa de verdad),
o `nexo update` para actualizar también Termux. Si `nexo-dbus` ya estaba en marcha en esa distro, reinícialo allí: `nexo dbus restart`.

## ¿Cómo paso un archivo de un móvil a otro?

Con `nexo tools`: en el que envía, `nexo tools send foto.jpg` (te da una IP y un código); en el que recibe, `nexo tools fetch IP CÓDIGO`. Para ver todas las carpetas de otro móvil: `nexo tools server` en uno, `nexo tools discover` y `nexo tools connect IP --code CÓDIGO` en el otro,
y luego `nexo tools browse NOMBRE` (terminal) o `nexo tools web NOMBRE` (navegador). Es independiente del puente (no necesita la app Nexo), va por la red WiFi local y cifrado, y **solo ve lo que el otro comparte y permite**. Guía: [NEXO-TOOLS](NEXO-TOOLS.md).
`nexo tools discover` no encuentra el móvil: muchos routers aíslan a los clientes WiFi o bloquean la difusión UDP; usa `nexo tools connect IP --code CÓDIGO` (la IP la da `nexo tools status` en el otro).

## ¿Puedo usar Nexo con `nmcli`, `bluetoothctl` o `playerctl`?

- **`playerctl` y todo lo que lee MPRIS** (el módulo `mpris` de Waybar, Quickshell, GNOME, KDE…): **sí, desde la v0.3.** `nexo setup-dbus` activa `nexo-dbus`, que publica la música del móvil como un reproductor más
  (`playerctl -p nexo play-pause`). Guía: [INTEGRACION-ESCRITORIO](INTEGRACION-ESCRITORIO.md).
- **`bluetoothctl` (BlueZ) y `nmcli` (NetworkManager): desde la 0.4.0‑beta1, en beta.** `nexo-dbus` finge ser `org.bluez` (con los dispositivos emparejados en Android) y `org.freedesktop.NetworkManager` (con el WiFi del móvil como `wlan0`),
  en el bus del sistema; en proot, `nexo setup-dbus --own-bus`. Comprobado con `busctl` y `gdbus`, **todavía no con `bluetoothctl` ni `nmcli` reales**; y Android limita lo que se puede hacer
  (no se pueden conectar dispositivos Bluetooth ni leer las claves WiFi). Guía y límites: [INTEGRACION-ESCRITORIO](INTEGRACION-ESCRITORIO.md).
- Mientras tanto, Nexo también se integra por línea de comandos (formatos para Waybar, Polybar, i3bar, Quickshell, tmux, starship…).

## `bluetoothctl` o `nmcli` no ven nada

`nexo dbus status` (o `nexo doctor`) dice qué servicio está activo y, si no, por qué: «pasivo» (ya hay un BlueZ/NetworkManager de verdad: es lo esperado), «el bus no deja a este usuario ocupar org.bluez»
(hace falta `nexo setup-dbus --system-policy`), o sin bus del sistema (en proot, `nexo setup-dbus --own-bus` y `eval "$(nexo-dbus env)"` en la terminal). La tabla «Si no funciona» de
[INTEGRACION-ESCRITORIO](INTEGRACION-ESCRITORIO.md) lo desarrolla.

## `playerctl -l` no muestra «nexo»

Casi siempre es una de tres cosas: no suena nada en el móvil (el reproductor solo existe mientras haya una sesión de medios), falta el acceso a notificaciones de la app,
o `nexo-dbus` no está en el mismo bus de sesión que tu barra o tu `playerctl`. `nexo dbus status` y `nexo doctor` lo cuentan; la tabla «Si no funciona» de
[INTEGRACION-ESCRITORIO](INTEGRACION-ESCRITORIO.md) lo desarrolla.

## ¿Por qué `targetSdk` 28? ¿No es viejo?

Es a propósito, igual que Termux: Android 10 o más le quita a las apps que apuntan a 29+ la posibilidad de encender/apagar el WiFi, leer las redes guardadas, etc. Con 28 Nexo puede hacerlo directamente.
Android 14 y 15 siguen instalando apps con 28 (mínimo 23 y 24). Por eso Nexo no está en Google Play. Más en [LIMITACIONES](LIMITACIONES.md#encender-y-apagar-wifi-y-bluetooth).

## ¿Por qué no pide `NEARBY_WIFI_DEVICES`?

Porque con `targetSdk` 28 Android sigue exigiendo el permiso de ubicación para los escaneos; `NEARBY_WIFI_DEVICES` solo cuenta para apps que apuntan a Android 13 (33) o más. Si algún día Nexo sube su `targetSdk`, se añadirá.

## ¿Qué datos salen del móvil?

Ninguno. El puente solo escucha en `127.0.0.1`; la app no se conecta a ningún servidor (el permiso `INTERNET` solo sirve para abrir el socket local). Sin anuncios, sin telemetría, sin cuentas.

## ¿Cómo actualizo la app?

Instala el APK nuevo encima (mientras esté firmado con la misma clave no hace falta desinstalar). Después, en Termux: `nexo version --check` te dice si cliente y app son compatibles;
si el cliente es antiguo, copia otra vez el comando de instalación desde la app o, si tienes la carpeta del repositorio (o el `.zip`) en el móvil, `nexo update` (actualiza `nexo`, `nexo-dbus`, `nexo-tools` y tus distros).

## ¿Cómo desinstalo todo?

- Cliente: `nexo unpair && rm "$(command -v nexo)"` (o `bash install.sh --uninstall`, que quita también `nexo-dbus`, `nexo-tools` y el arranque automático; lo que guarda `nexo-tools` —certificado y dispositivos emparejados— lo deja salvo que añadas `--purge`).
- Si activaste `nexo-dbus`: `nexo setup-dbus --uninstall` (lo para y quita el arranque automático; hazlo dentro de cada distro donde lo activaste).
- Distros: `nexo setup-guests --uninstall` (antes de borrar el cliente).
- App: desinstálala como cualquier otra.
