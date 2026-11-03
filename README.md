---

Nexo

El WiFi y el Bluetooth reales de tu móvil, dentro de Termux y de tus distros de proot.

Nexo tiene dos piezas:

· una app de Android (Kotlin, sin librerías de terceros, sin anuncios ni telemetría) que habla con el WiFi y el Bluetooth del móvil;
· un cliente de línea de comandos, nexo (un solo script de bash), que la propia app instala en Termux con un comando que ella misma copia.

Funciona con Termux de F‑Droid, de GitHub, Termux Monet y cualquier otro fork: no depende del nombre del paquete de Termux,
de rutas fijas, de Termux:API ni de root. Dentro de una distro de proot-distro (Arch, Debian, Ubuntu, Alpine…) funciona igual.

```
┌─ tu móvil (Android) ────────────────────────────────────────────────────┐
│                                                                         │
│  App Nexo  ── WiFi y Bluetooth reales de Android                        │
│     ▲        escucha solo en 127.0.0.1:8765 (servicio en primer plano)  │
│     │                                                                   │
│     │  TCP local · un JSON por línea · con token                        │
│     │                                                                   │
│     ├── Termux (F-Droid, GitHub, Monet, fork…)   →  nexo status         │
│     └── distro de proot-distro (Arch, Debian…)   →  nexo status         │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

proot comparte la red del móvil, así que el 127.0.0.1 de una distro es el mismo que el de Termux y el de la app.
Por eso no hacen falta sockets Unix ni socat.

```console
$ nexo status
WiFi: conectado a MiCasa · -55 dBm · 5GHz · 192.168.1.23
Bluetooth: encendido · con dispositivos conectados · 2 emparejados

$ nexo wifi scan
RED                                    SEÑAL  SEGUR. BANDA
MiCasa                               -52 dBm  WPA2   5GHz
CafeLuz                              -70 dBm  WPA2   2.4GHz
Invitados                            -81 dBm  OPEN   2.4GHz

$ nexo bt paired
NOMBRE                     DIRECCIÓN          ESTADO     PERFILES
Auriculares ñandú          AA:BB:CC:DD:EE:01  conectado  a2dp,headset
(sin nombre)               AA:BB:CC:DD:EE:02  -
```

Estado: versión 0.1.0. El código Kotlin compila, el cliente pasa las 66 pruebas y el APK ha sido compilado, firmado y probado con éxito en un móvil real (Xiaomi 25078RA3EL con Android 14 / SDK 36). Funciona tanto en Termux Monet como dentro de distros de proot-distro (probado en Arch Linux). Lee Estado y lo que falta.

---

Empezar

1. Conseguir el APK

Descarga el APK ya compilado y firmado directamente desde la pestaña Releases de este repositorio.

Al instalarlo, si Android pide permiso para «instalar apps desconocidas», concédelo a la app desde la que lo abres; si Play Protect avisa, elige «Instalar de todos modos». Al estar firmado con clave propia, podrás actualizar la app en el futuro sin necesidad de desinstalarla.

2. Encender el puente

1. Abre Nexo y pulsa Conceder permisos (ubicación, avisos y Bluetooth).
   Nexo no lee tu ubicación: Android solo entrega el nombre del WiFi y las redes cercanas a apps que tienen ese permiso.
2. Pulsa Iniciar puente. Queda una notificación fija «Nexo activo»: es lo que mantiene la app viva.
3. Muy importante en Xiaomi/HyperOS y otras capas: mira Que Android no cierre la app. Si no se configura bien, el socket se abre pero la app no responde (código de error 12).

3. Enlazar Termux

1. En Nexo, pulsa Copiar comando de instalación.
2. Pégalo en Termux y pulsa Enter. Instala nexo (y jq, opcional, que da formato a la salida), guarda el enlace y comprueba que la app responde.
3. Prueba: nexo status.

El comando es el mismo para cualquier Termux: descarga el instalador de la propia app (sin internet) y comprueba su huella SHA‑256 antes de ejecutarlo.

4. Tus distros de proot-distro

En Termux, nexo setup-guests copia el cliente y el enlace a todas tus distros
(o a la que indiques: nexo setup-guests $PREFIX/var/lib/proot-distro/installed-rootfs/debian).
Dentro de la distro, el comando es el mismo: nexo status.

Dependiendo de la distro, necesitarás instalar bash y jq:

· Arch Linux: pacman -S bash jq
· Alpine: apk add bash jq
· Debian/Ubuntu: apt install bash jq

(setup-guests te avisa si detecta que le falta algo a la distro).

---

Comandos

Comando Qué hace
nexo status Resumen de WiFi y Bluetooth
nexo wifi status · nexo bt status Estado de cada uno
nexo wifi on · nexo wifi off Enciende o apaga el WiFi
nexo wifi scan Redes cercanas: nombre, señal, seguridad y banda
nexo wifi connect NOMBRE [CLAVE] Se conecta a una red abierta o WPA/WPA2 personal
nexo wifi disconnect Se desconecta de la red actual
nexo bt on · nexo bt off Enciende o apaga el Bluetooth
nexo bt paired Dispositivos emparejados y cuáles están conectados ahora
nexo bt connect\|disconnect DIRECCIÓN Android lo reserva al sistema: Nexo deja una notificación que abre los ajustes de Bluetooth
nexo watch [wifi\|bt] Cambios en vivo, un JSON por línea (--pretty para leerlos mejor). Reconecta solo
nexo pair TOKEN [PUERTO] · nexo unpair Guarda o borra el enlace a mano
nexo setup-guests (Termux) copia cliente y enlace a tus distros de proot-distro
nexo doctor Diagnóstico de todo el enlace
nexo ping · nexo raw 'JSON' · nexo version Comprobar la app, enviar una petición cruda, ver la versión

Opciones: --json (el campo data) · --short (una línea, para barras) · --waybar · --env · --pretty (con watch) ·
--host H --port P --timeout S.

Códigos de salida: 0 bien · 1 error · 2 uso incorrecto · 3 hace falta un toque en el móvil, o la conexión no se confirmó ·
10 sin conexión con la app · 11 token · 12 sin respuesta a tiempo (app congelada por el sistema).

Claves de WiFi sin dejarlas en el historial:

```bash
read -rsp "Clave: " P; echo; nexo wifi connect MiCasa --pass-stdin <<<"$P"; unset P
```

(También sirve la variable NEXO_WIFI_PASSWORD.) Sin jq, Nexo funciona igual, pero muestra el JSON sin formato.

---

Para barras de estado y scripts

```bash
nexo status --short                      # MiCasa · conectado
eval "$(nexo wifi status --env)"         # NEXO_WIFI_CONNECTED=1  NEXO_WIFI_SSID='MiCasa'  NEXO_WIFI_RSSI=-55 …
[ "$NEXO_WIFI_CONNECTED" = 1 ] && echo "Conectado a $NEXO_WIFI_SSID"
nexo watch --pretty                      # wifi  → conectado a MiCasa
```

--waybar devuelve el JSON que espera un módulo custom de Waybar: {"text","alt","class","percentage","tooltip"}
(alt y class valen connected, disconnected u off en el WiFi; connected, on u off en el Bluetooth). Necesita jq.

```jsonc
// Waybar: ~/.config/waybar/config
"custom/nexo-wifi": {
    "exec": "nexo wifi status --waybar",
    "return-type": "json",
    "interval": 10,
    "signal": 8,                       // se refresca también con: pkill -RTMIN+8 waybar
    "format": "WiFi {text}"
}
```

```bash
# Refrescar la barra en cuanto cambie algo, sin esperar al intervalo:
nexo watch | while read -r _; do pkill -RTMIN+8 waybar; done
```

Polybar: type = custom/script, exec = nexo status --short, interval = 10.
tmux: set -g status-right '#(nexo status --short)'.

De todo esto está probada la salida de nexo (formato, JSON, variables). Las configuraciones de Waybar, Polybar y tmux de arriba
son el formato estándar de esos programas, pero no se han probado en un escritorio real.

---

Lo que Android no deja hacer

Nexo controla el WiFi y el Bluetooth de Android; no se los entrega a Linux como adaptadores. Lo que Android no permite a una app normal se dice claro, no se disimula:

· Conectar o desconectar un dispositivo Bluetooth concreto. Android lo reserva al sistema. nexo bt connect valida la dirección y deja una
  notificación que abre los ajustes de Bluetooth (código de salida 3). Sí puedes encender y apagar el Bluetooth, ver los emparejados y saber cuáles están conectados.
· Redes solo WPA3 y redes de empresa (802.1X). La API clásica no permite crearlas: nexo wifi connect abre el panel de WiFi con una notificación.
· Encender o apagar el WiFi/Bluetooth en algunos móviles. Nexo apunta a la API 28 (igual que Termux) justo para que Android se lo permita directamente.
  Si el sistema o el fabricante se niega (modo avión, punto de acceso activo, restricciones de la capa), responde «hace falta un toque»
  (código 3) y deja una notificación que abre el panel correcto.
· Escaneos de WiFi limitados. Android admite unos 4 cada 2 minutos; pasado el límite, wifi scan devuelve la última lista (fresh:false).
  En Opciones de desarrollador existe el interruptor «Wi‑Fi scan throttling» si quieres quitar el límite.
· El nombre de la red necesita el permiso de ubicación y la ubicación del sistema encendida; si no, sale «(red oculta: falta permiso de ubicación)».
· El puente necesita la app en marcha (servicio en primer plano). Si Android la cierra o congela, nexo dice que no puede conectar (código 12).
· No hay BlueZ ni NetworkManager dentro de la distro. Las apps de Linux no ven un adaptador WiFi ni Bluetooth, y no hay audio Bluetooth para ellas.
  Para programas que leen el estado por D‑Bus (nmcli, bluetoothctl, applets de escritorio) todavía no hay emulación; ver Estado y lo que falta.
· API 28. Android 14 empezó a bloquear la instalación de apps con un targetSdk demasiado antiguo: mínimo 23 en Android 14 y 24 de Android 15 en adelante
  (fuente). 28 queda por encima, pero si algún día Android sube ese mínimo, Termux tendría el mismo problema
  y Nexo tendría que subir su targetSdk (y perder parte del control directo). No se publica en Google Play.

---

Seguridad

· Solo escucha en 127.0.0.1: nunca es visible desde la red.
· Cualquier app del móvil puede abrir un puerto local, así que cada conexión debe empezar con hello y un token aleatorio de 192 bits (SecureRandom).
  Se compara en tiempo constante; un token malo espera 0,8 s antes de recibir el rechazo y se corta; sin autenticarse en 8 s también se corta;
  como máximo 16 clientes a la vez y 64 KiB por línea.
· El único comando que no pide token es bootstrap, que entrega el instalador (contenido público). Nunca entrega el token.
· El instalador se verifica. El comando que copia la app lleva la huella SHA‑256 del instalador: si otra app se adelantara a ocupar el puerto y sirviera
  otra cosa, la comprobación falla y no se ejecuta nada.
· El comando de instalación lleva el token, así que queda en el historial de esa shell. Es el mismo secreto que guarda ~/.config/nexo/config (modo 600,
  dentro de los datos privados de Termux). Si lo pegaste donde no debías, pulsa Token nuevo en la app y vuelve a enlazar.
· La app marca como sensible lo que copia al portapapeles y desactiva las copias de seguridad de Android (allowBackup=false), para que el token no salga del móvil.
· En las distros, setup-guests deja el enlace en /etc/nexo/config (modo 644, para que lo lean todos los usuarios de esa distro). Queda dentro de los datos privados de Termux,
  protegidos por el aislamiento de Android.
· El permiso INTERNET solo sirve para abrir el socket local: la app no se conecta a ningún servidor. Sin anuncios, sin telemetría.
· El protocolo completo está en docs/PROTOCOLO.md, por si quieres escribir otro cliente.

---

Que Android no cierre la app

Xiaomi/HyperOS y otras capas cierran las apps en segundo plano con más ganas que Android puro. Para que el puente sobreviva:

1. En Nexo, pulsa Ahorro de batería y deja la batería de Nexo en «Sin restricciones».
2. Pulsa Inicio automático (Xiaomi) y activa Nexo.
3. Bloquéala en la vista de recientes (mantén pulsada su tarjeta) para que «Limpiar todo» no la cierre.
4. Activa Iniciar con el móvil si quieres que el puente vuelva solo tras reiniciar.

(Nota: Esto no es opcional. Si HyperOS congela la app, el socket acepta la conexión pero la app no responde, devolviendo un error 12 en el cliente).

---

Solución de problemas

Empieza siempre por nexo doctor: te dice qué entorno ve, si hay token y si la app responde.

Síntoma Causa probable Qué hacer
Nexo: La conexión se cortó o no respondió a tiempo (código 12) HyperOS ha congelado la app, o el servidor está bloqueado Asegúrate de tener los permisos de HyperOS configurados (ver arriba). Fuerza la detención de Nexo, vuelve a abrirla y pulsa Iniciar puente.
No se puede conectar con Nexo en 127.0.0.1:8765 Puente apagado, Android cerró la app, o cambiaste el puerto Abre Nexo y pulsa Iniciar puente. Si cambiaste el puerto, vuelve a copiar el comando de instalación
Nexo rechazó el token Pulsaste Token nuevo Pega de nuevo el comando de instalación (o nexo pair TOKEN) y, en Termux, nexo setup-guests
wifi on / bt on sale con código 3 Android no dejó que Nexo lo hiciera solo Toca la notificación que dejó Nexo
wifi scan sale vacío Ubicación del sistema apagada, o límite de escaneos Enciende la ubicación; espera un par de minutos
El WiFi sale como «red oculta» Falta el permiso de ubicación, o está apagada la ubicación del sistema Concede el permiso en Nexo. Si solo falla con la app cerrada, pon la ubicación de Nexo en «Permitir siempre»
bash: nexo: not found en la distro Falta bash en la distro Arch: pacman -S bash jq. Alpine: apk add bash jq. Debian: apt install bash jq.
La salida sale como JSON sin formato Falta jq pkg install jq (Termux) o instálalo con el gestor de la distro

Para desinstalar el cliente: nexo unpair && rm "$(command -v nexo)".

---

Desarrollo

Para compilar el APK manualmente (solo desarrolladores):

```bash
cd android
export ANDROID_HOME=/ruta/al/sdk
./gradlew assembleRelease
```

El workflow .github/workflows/build.yml compila automáticamente y firma el APK usando los secretos del repositorio, publicándolo en Releases al crear una etiqueta (git tag v0.1.0 && git push --tags).

```bash
bash tests/run_tests.sh      # 66 pruebas del cliente y del instalador contra una app simulada (bash, python3 y jq)
```

```
android/                       Proyecto de Android (Gradle, Kotlin 2.0, AGP 8.7, JDK 17; minSdk 26, targetSdk 28)
  app/src/main/java/org/nexo/bridge/
    MainActivity.kt            Pantalla (se construye en código, sin layouts XML)
    BridgeService.kt           Servicio en primer plano y avisos de Android → eventos
    BridgeServer.kt            Servidor TCP en 127.0.0.1: autenticación, comandos, eventos, bootstrap
    Commands.kt                Reparte cada comando
    WifiHandler.kt             Habla con WifiManager
    BluetoothHandler.kt        Habla con BluetoothAdapter y los perfiles
    Bootstrap.kt               Arma el instalador para Termux y su huella SHA-256
    UserAction.kt              Notificaciones «toca para…» cuando Android no deja hacerlo solo
    Prefs.kt · BridgeState.kt · Protocol.kt · Util.kt · BootReceiver.kt
termux/
  bin/nexo                     El cliente
  install.sh                   El instalador (también --uninstall)
  oneliner.tpl                 Plantilla del comando de una línea que copia la app
tests/                         App simulada (fake_app.py) y pruebas (run_tests.sh)
docs/PROTOCOLO.md              El protocolo
.github/workflows/build.yml    Pruebas del cliente + compilación del APK
```

El cliente y el instalador viajan dentro del APK como assets (el build.gradle.kts apunta a la carpeta termux/), y el servidor los entrega por bootstrap.

---

Estado y lo que falta

Versión 0.1.0.

· ✅ Comprobado en móvil real: Xiaomi 25078RA3EL (Android 14 / SDK 36). El APK compila y se firma automáticamente con un Keystore propio a través de GitHub Actions. El cliente pasa las 66 pruebas, lee el WiFi/Bluetooth reales y se comunica sin problemas desde Termux Monet y desde proot-distro (probado en Arch Linux). Se corrigió un bloqueo del hilo de red (enviando la respuesta TCP antes de actualizar la interfaz) y se documentó la necesidad de desactivar el ahorro de batería de HyperOS.
· ⚠️ Limitaciones del entorno: El encendido/apagado directo de WiFi/Bluetooth depende de las restricciones de cada fabricante (HyperOS puede pedir un toque manual). Las redes con señal muy débil (ej. -87 dBm) pueden hacer que Android reporte un connected: false momentáneo mientras re-negocia la conexión.
· ❌ Sin hacer: emulación D‑Bus. Un pequeño servicio por distro que simule org.freedesktop.NetworkManager y org.bluez para que nmcli, bluetoothctl y los applets de escritorio vean el estado real del móvil. El protocolo ya entrega todo lo que haría falta (estado, redes, emparejados y eventos); falta diseñarlo y probarlo en un móvil.

Ideas sin explorar: un azulejo de Ajustes rápidos para encender y apagar el puente; conectar dispositivos Bluetooth de verdad mediante ADB inalámbrico o Shizuku.

---

Licencia

GPL‑3.0‑or‑later. Ver LICENSE.