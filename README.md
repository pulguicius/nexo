# Nexo

**El WiFi y el Bluetooth reales de tu móvil, dentro de Termux y de tus distros de proot.**

Nexo tiene dos piezas:

- una **app de Android** (Kotlin, sin librerías de terceros, sin anuncios ni telemetría) que habla con el WiFi y el Bluetooth del móvil;
- un **cliente de línea de comandos, `nexo`** (un solo script de bash), que la propia app instala en Termux con un comando que ella misma copia.

Funciona con **Termux de F‑Droid, de GitHub, Termux Monet y cualquier otro fork**: no depende del nombre del paquete de Termux,
de rutas fijas, de Termux:API ni de root. Dentro de una distro de `proot-distro` (Arch, Debian, Ubuntu, Alpine…) funciona igual.

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

`proot` comparte la red del móvil, así que el `127.0.0.1` de una distro es el mismo que el de Termux y el de la app.
Por eso no hacen falta sockets Unix ni `socat`.

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

> **Estado: versión 0.1.** El código Kotlin compila contra la API real de Android y el cliente pasa 66 pruebas contra una app simulada,
> pero **la app todavía no se ha compilado con Gradle ni se ha ejecutado en un móvil real**. Lee [Estado y lo que falta](#estado-y-lo-que-falta).

---

## Empezar

### 1. Conseguir el APK

Todavía no hay un APK publicado: lo compilas tú, sin Android Studio, con GitHub Actions (gratis).
Los pasos están en [Compilar el APK](#compilar-el-apk). Al instalarlo, si Android pide permiso para «instalar apps desconocidas»,
concédelo a la app desde la que lo abres; si Play Protect avisa, elige «Instalar de todos modos».

### 2. Encender el puente

1. Abre **Nexo** y pulsa **Conceder permisos** (ubicación, avisos y Bluetooth).
   Nexo **no lee tu ubicación**: Android solo entrega el nombre del WiFi y las redes cercanas a apps que tienen ese permiso.
2. Pulsa **Iniciar puente**. Queda una notificación fija «Nexo activo»: es lo que mantiene la app viva.
3. En Xiaomi/HyperOS y otras capas, mira [Que Android no cierre la app](#que-android-no-cierre-la-app).

### 3. Enlazar Termux

1. En Nexo, pulsa **Copiar comando de instalación**.
2. Pégalo en Termux y pulsa Enter. Instala `nexo` (y `jq`, opcional, que da formato a la salida), guarda el enlace y comprueba que la app responde.
3. Prueba: `nexo status`.

El comando es el mismo para cualquier Termux: descarga el instalador **de la propia app** (sin internet) y comprueba su huella SHA‑256 antes de ejecutarlo.

### 4. Tus distros de proot-distro

En Termux, `nexo setup-guests` copia el cliente y el enlace a todas tus distros
(o a la que indiques: `nexo setup-guests $PREFIX/var/lib/proot-distro/installed-rootfs/debian`).
Dentro de la distro, el comando es el mismo: `nexo status`. En Alpine hace falta `bash` (`apk add bash`); `setup-guests` te avisa.

---

## Comandos

| Comando | Qué hace |
|---|---|
| `nexo status` | Resumen de WiFi y Bluetooth |
| `nexo wifi status` · `nexo bt status` | Estado de cada uno |
| `nexo wifi on` · `nexo wifi off` | Enciende o apaga el WiFi |
| `nexo wifi scan` | Redes cercanas: nombre, señal, seguridad y banda |
| `nexo wifi connect NOMBRE [CLAVE]` | Se conecta a una red abierta o WPA/WPA2 personal |
| `nexo wifi disconnect` | Se desconecta de la red actual |
| `nexo bt on` · `nexo bt off` | Enciende o apaga el Bluetooth |
| `nexo bt paired` | Dispositivos emparejados y cuáles están conectados ahora |
| `nexo bt connect\|disconnect DIRECCIÓN` | Android lo reserva al sistema: Nexo deja una notificación que abre los ajustes de Bluetooth |
| `nexo watch [wifi\|bt]` | Cambios en vivo, un JSON por línea (`--pretty` para leerlos mejor). Reconecta solo |
| `nexo pair TOKEN [PUERTO]` · `nexo unpair` | Guarda o borra el enlace a mano |
| `nexo setup-guests` | (Termux) copia cliente y enlace a tus distros de proot-distro |
| `nexo doctor` | Diagnóstico de todo el enlace |
| `nexo ping` · `nexo raw 'JSON'` · `nexo version` | Comprobar la app, enviar una petición cruda, ver la versión |

**Opciones:** `--json` (el campo `data`) · `--short` (una línea, para barras) · `--waybar` · `--env` · `--pretty` (con `watch`) ·
`--host H` `--port P` `--timeout S`.

**Códigos de salida:** `0` bien · `1` error · `2` uso incorrecto · `3` hace falta un toque en el móvil, o la conexión no se confirmó ·
`10` sin conexión con la app · `11` token · `12` sin respuesta a tiempo.

**Claves de WiFi sin dejarlas en el historial:**

```bash
read -rsp "Clave: " P; echo; nexo wifi connect MiCasa --pass-stdin <<<"$P"; unset P
```

(También sirve la variable `NEXO_WIFI_PASSWORD`.) Sin `jq`, Nexo funciona igual, pero muestra el JSON sin formato.

---

## Para barras de estado y scripts

```bash
nexo status --short                      # MiCasa · conectado
eval "$(nexo wifi status --env)"         # NEXO_WIFI_CONNECTED=1  NEXO_WIFI_SSID='MiCasa'  NEXO_WIFI_RSSI=-55 …
[ "$NEXO_WIFI_CONNECTED" = 1 ] && echo "Conectado a $NEXO_WIFI_SSID"
nexo watch --pretty                      # wifi  → conectado a MiCasa
```

`--waybar` devuelve el JSON que espera un módulo `custom` de Waybar: `{"text","alt","class","percentage","tooltip"}`
(`alt` y `class` valen `connected`, `disconnected` u `off` en el WiFi; `connected`, `on` u `off` en el Bluetooth). Necesita `jq`.

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

Polybar: `type = custom/script`, `exec = nexo status --short`, `interval = 10`.
tmux: `set -g status-right '#(nexo status --short)'`.

> De todo esto está probada la salida de `nexo` (formato, JSON, variables). Las configuraciones de Waybar, Polybar y tmux de arriba
> son el formato estándar de esos programas, pero no se han probado en un escritorio real.

---

## Lo que Android no deja hacer

Nexo **controla** el WiFi y el Bluetooth de Android; no se los **entrega** a Linux como adaptadores. Lo que Android no permite a una app normal se dice claro, no se disimula:

- **Conectar o desconectar un dispositivo Bluetooth concreto.** Android lo reserva al sistema. `nexo bt connect` valida la dirección y deja una
  notificación que abre los ajustes de Bluetooth (código de salida 3). Sí puedes encender y apagar el Bluetooth, ver los emparejados y saber cuáles están conectados.
- **Redes solo WPA3 y redes de empresa (802.1X).** La API clásica no permite crearlas: `nexo wifi connect` abre el panel de WiFi con una notificación.
- **Encender o apagar el WiFi/Bluetooth en algunos móviles.** Nexo apunta a la API 28 (igual que Termux) justo para que Android se lo permita directamente.
  Si el sistema o el fabricante se niega (modo avión, punto de acceso activo, restricciones de la capa), responde «hace falta un toque»
  (código 3) y deja una notificación que abre el panel correcto.
- **Escaneos de WiFi limitados.** Android admite unos 4 cada 2 minutos; pasado el límite, `wifi scan` devuelve la última lista (`fresh:false`).
  En Opciones de desarrollador existe el interruptor «Wi‑Fi scan throttling» si quieres quitar el límite.
- **El nombre de la red** necesita el permiso de ubicación **y** la ubicación del sistema encendida; si no, sale «(red oculta: falta permiso de ubicación)».
- **El puente necesita la app en marcha** (servicio en primer plano). Si Android la cierra, `nexo` dice que no puede conectar.
- **No hay BlueZ ni NetworkManager dentro de la distro.** Las apps de Linux no ven un adaptador WiFi ni Bluetooth, y no hay audio Bluetooth para ellas.
  Para programas que leen el estado por D‑Bus (`nmcli`, `bluetoothctl`, applets de escritorio) todavía no hay emulación; ver [Estado y lo que falta](#estado-y-lo-que-falta).
- **API 28.** Android 14 empezó a bloquear la instalación de apps con un `targetSdk` demasiado antiguo: mínimo 23 en Android 14 y 24 de Android 15 en adelante
  ([fuente](https://bayton.org/android/android-minimum-targetsdk-matrix/)). 28 queda por encima, pero si algún día Android sube ese mínimo, Termux tendría el mismo problema
  y Nexo tendría que subir su `targetSdk` (y perder parte del control directo). No se publica en Google Play.

---

## Seguridad

- **Solo escucha en `127.0.0.1`**: nunca es visible desde la red.
- Cualquier app del móvil puede abrir un puerto local, así que **cada conexión debe empezar con `hello` y un token** aleatorio de 192 bits (`SecureRandom`).
  Se compara en tiempo constante; un token malo espera 0,8 s antes de recibir el rechazo y se corta; sin autenticarse en 8 s también se corta;
  como máximo 16 clientes a la vez y 64 KiB por línea.
- El único comando que no pide token es `bootstrap`, que entrega el instalador (contenido público). **Nunca entrega el token.**
- **El instalador se verifica.** El comando que copia la app lleva la huella SHA‑256 del instalador: si otra app se adelantara a ocupar el puerto y sirviera
  otra cosa, la comprobación falla y no se ejecuta nada.
- El comando de instalación **lleva el token**, así que queda en el historial de esa shell. Es el mismo secreto que guarda `~/.config/nexo/config` (modo 600,
  dentro de los datos privados de Termux). Si lo pegaste donde no debías, pulsa **Token nuevo** en la app y vuelve a enlazar.
- La app marca como sensible lo que copia al portapapeles y desactiva las copias de seguridad de Android (`allowBackup=false`), para que el token no salga del móvil.
- En las distros, `setup-guests` deja el enlace en `/etc/nexo/config` (modo 644, para que lo lean todos los usuarios de esa distro). Queda dentro de los datos privados de Termux,
  protegidos por el aislamiento de Android.
- El permiso `INTERNET` solo sirve para abrir el socket local: la app no se conecta a ningún servidor. Sin anuncios, sin telemetría.
- El protocolo completo está en [`docs/PROTOCOLO.md`](docs/PROTOCOLO.md), por si quieres escribir otro cliente.

---

## Que Android no cierre la app

Xiaomi/HyperOS y otras capas cierran las apps en segundo plano con más ganas que Android puro. Para que el puente sobreviva:

1. En Nexo, pulsa **Ahorro de batería** y deja la batería de Nexo en «Sin restricciones».
2. Pulsa **Inicio automático (Xiaomi)** y activa Nexo.
3. Bloquéala en la vista de recientes (mantén pulsada su tarjeta) para que «Limpiar todo» no la cierre.
4. Activa **Iniciar con el móvil** si quieres que el puente vuelva solo tras reiniciar.

Los nombres de los menús cambian de una versión a otra; los botones de la app abren la pantalla correcta.

---

## Solución de problemas

Empieza siempre por `nexo doctor`: te dice qué entorno ve, si hay token y si la app responde.

| Síntoma | Causa probable | Qué hacer |
|---|---|---|
| `No se puede conectar con Nexo en 127.0.0.1:8765` | Puente apagado, Android cerró la app, o cambiaste el puerto | Abre Nexo y pulsa **Iniciar puente**. Si cambiaste el puerto, vuelve a copiar el comando de instalación |
| `Nexo rechazó el token` | Pulsaste **Token nuevo** | Pega de nuevo el comando de instalación (o `nexo pair TOKEN`) y, en Termux, `nexo setup-guests` |
| El comando de instalación dice «no se pudo instalar» | Puente apagado, otra app usa ese puerto, o tu bash no sabe abrir `/dev/tcp` (raro) | Enciende el puente. Si persiste, cambia el puerto en Nexo y copia el comando otra vez; o instala a mano: `bash termux/install.sh` y `nexo pair TOKEN` |
| `wifi on` / `bt on` sale con código 3 | Android no dejó que Nexo lo hiciera solo | Toca la notificación que dejó Nexo |
| `wifi scan` sale vacío | Ubicación del sistema apagada, o límite de escaneos | Enciende la ubicación; espera un par de minutos |
| El WiFi sale como «red oculta» | Falta el permiso de ubicación, o está apagada la ubicación del sistema | Concede el permiso en Nexo. Si solo falla con la app cerrada, pon la ubicación de Nexo en «Permitir siempre» |
| `bash: nexo: not found` en Alpine | Falta `bash` en la distro | `apk add bash` |
| La salida sale como JSON sin formato | Falta `jq` | `pkg install jq` (Termux) o instálalo con el gestor de la distro |

Para desinstalar el cliente: `nexo unpair && rm "$(command -v nexo)"`.

---

## Compilar el APK

El APK no se compiló donde se escribió el proyecto (no había acceso al SDK de Android), así que la primera compilación la haces tú. Hay dos caminos.

### Opción A — GitHub Actions (recomendada, sin ordenador)

Desde Termux:

```bash
pkg install git gh unzip
unzip nexo.zip && cd nexo
git config --global user.name "Tu nombre" && git config --global user.email "tu@correo"
gh auth login                            # GitHub.com → HTTPS → sigue los pasos
git init -b main && git add -A && git commit -m "Nexo 0.1"
gh repo create nexo --private --source=. --push
gh run watch                             # elige la ejecución y espera (unos minutos)
gh run download -n nexo-apk              # baja el APK (queda aquí o en la carpeta nexo-apk/)
termux-open nexo-main.apk                # lo abre para instalarlo
```

Sin `gh`, crea un repositorio vacío en github.com y empuja con `git push` (usa un token de acceso personal como contraseña).
El workflow `.github/workflows/build.yml` se ejecuta solo en cada `push` a `main`, y también a mano desde la pestaña **Actions**.
Con una etiqueta (`git tag v0.1.0 && git push --tags`) el APK se publica además en **Releases**.

### Opción B — Android Studio o línea de comandos

Abre la carpeta `android/` en Android Studio (JDK 17) y usa *Build → Build APK(s)*. O, con el SDK de Android instalado (plataforma 35):

```bash
cd android
export ANDROID_HOME=/ruta/al/sdk
./gradlew assembleRelease
# → app/build/outputs/apk/release/app-release.apk
```

### Firma estable (muy recomendable)

Sin firma propia, cada compilación de GitHub lleva una clave de depuración **distinta**: para actualizar tendrás que desinstalar la versión anterior
y volver a enlazar Termux. Con una firma propia, cada versión se instala encima de la anterior.

```bash
keytool -genkeypair -v -keystore nexo.jks -alias nexo -keyalg RSA -keysize 2048 -validity 10000
gh secret set NEXO_KEYSTORE_BASE64   < <(base64 -w0 nexo.jks)
gh secret set NEXO_KEYSTORE_PASSWORD            # la contraseña del almacén
gh secret set NEXO_KEY_ALIAS                    # nexo
gh secret set NEXO_KEY_PASSWORD                 # la misma contraseña (con PKCS12 coinciden)
```

Guarda `nexo.jks` y su contraseña en un sitio seguro: sin ellos no podrás publicar actualizaciones que se instalen encima.
Para compilar en local con tu clave, define `NEXO_KEYSTORE`, `NEXO_KEYSTORE_PASSWORD`, `NEXO_KEY_ALIAS` y `NEXO_KEY_PASSWORD`.

---

## Desarrollo

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

El cliente y el instalador viajan dentro del APK como *assets* (el `build.gradle.kts` apunta a la carpeta `termux/`), y el servidor los entrega por `bootstrap`.

---

## Estado y lo que falta

**Versión 0.1.0.**

- ✅ **Comprobado:** el cliente `nexo` y el instalador (66 pruebas: caracteres raros en nombres y claves, eventos en vivo, un «Termux» simulado con otro nombre de paquete,
  distros de proot, y un impostor que intenta colarse en el puerto). Todo el Kotlin compila sin errores ni avisos contra la API real de Android (API 37).
- ⚠️ **Sin comprobar:** el APK no se ha compilado con Gradle y la app no se ha ejecutado en un móvil real. Espera algún ajuste en la primera compilación y en cómo
  responde cada fabricante (sobre todo el encendido directo de WiFi y Bluetooth en HyperOS y Android recientes; el aviso con notificación está previsto para esos casos).
  Tampoco se ha probado con un Termux real, Monet incluido: lo que está probado es que no depende de ningún nombre de paquete ni ruta.
- ❌ **Sin hacer: emulación D‑Bus.** Un pequeño servicio por distro que simule `org.freedesktop.NetworkManager` y `org.bluez` para que `nmcli`, `bluetoothctl` y los applets de
  escritorio vean el estado real del móvil. El protocolo ya entrega todo lo que haría falta (estado, redes, emparejados y eventos); falta diseñarlo y probarlo en un móvil.

Ideas sin explorar: un azulejo de Ajustes rápidos para encender y apagar el puente; conectar dispositivos Bluetooth de verdad mediante ADB inalámbrico o Shizuku.

---

## Licencia

GPL‑3.0‑or‑later. Ver [`LICENSE`](LICENSE).
