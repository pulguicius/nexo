# nexo usb — Arduino, ESP32 y adaptadores serie USB dentro de tu distro

Desde la 0.4.1 puedes conectar al móvil, con un cable OTG o con un hub, una placa (Arduino, ESP32…) o un adaptador USB↔serie (CH340, CP210x, FTDI) y
verla **dentro de Ubuntu, Arch, Debian…** como un puerto serie: `nexo usb list`, un monitor serie y un puerto para `avrdude`, `arduino-cli`, `esptool`,
PlatformIO, `minicom` o `screen`.

> **Estado, sin adornos.** Implementado: la parte de Android (permisos, controladores CDC‑ACM, CP210x, FTDI y CH34x, avisos de enchufar/desenchufar), el
> protocolo, `nexo usb` y los puertos que ve Linux. Probado: contra la **app simulada** (`tests/fake_app.py`, con «chips» que imitan a un Arduino con su
> cargador STK500, a un eco, etc.), con **pruebas de los controladores en una JVM** (las órdenes que mandan y sus cuentas de velocidad) y con la compilación
> contra el SDK de Android. **No se ha probado todavía con un móvil ni con una placa de verdad.** Para eso está
> [`tests/usb_hardware_check.sh`](../tests/usb_hardware_check.sh) (al final de esta página): lo ejecutas con tu placa conectada y me pasas el informe.
>
> Teclados, ratones, discos y hubs **salen en la lista**, pero esta versión solo usa los puertos serie. Los discos llegan en la 0.4.2.

## En un minuto

```bash
nexo usb list                      # ¿qué ve Android?
nexo usb permit                    # Android pregunta «¿permitir?»: Aceptar (y «Usar siempre»)
nexo usb monitor -b 9600           # el monitor serie de siempre (salir: Ctrl+])
nexo usb bridge --detach           # un puerto serie para tus herramientas, en segundo plano
nexo usb status                    # …y dónde quedó
nexo usb stop --all                # cerrarlo
```

```
$ nexo usb list
ID    VID:PID    TIPO           CONTROLADOR  PERMISO  DISPOSITIVO
1001  2341:0043  serie          cdc-acm      no       Arduino Uno · Arduino (www.arduino.cc) · serie 85735313437351E0E1E1
1002  303a:1001  serie          cdc-acm      no       USB JTAG/serial debug unit · Espressif · serie 7C:DF:A1:00:00:00
1003  046d:c31c  teclado/ratón               no       USB Keyboard · Logitech
1004  05e3:0610  hub                         no       USB2.0 Hub · GenesysLogic
Siguiente paso: nexo usb permit   (Android te pregunta una vez; marca «Usar siempre»)

$ nexo usb bridge 2341:0043 --rfc2217 0 --detach
✔ Arduino Uno (2341:0043) · cdc-acm · 115200 8N1
  Puerto serie:  ~/.local/state/nexo/usb/usb0.tty
                 úsalo donde pondrías /dev/ttyACM0 (avrdude -P, arduino-cli -p, minicom -D, screen, pyserial…)
                 al abrirlo un programa, el Arduino se reinicia (como en un PC); --no-auto-reset lo evita
  RFC2217:       rfc2217://127.0.0.1:34397   (esptool --port rfc2217://127.0.0.1:34397 · pyserial serial_for_url)
  Para cerrarlo: nexo usb stop usb0
```

(Esa salida es de la app simulada; con tu móvil verás tus dispositivos.)

## Qué necesitas

- Un móvil con **USB host (OTG)** y un cable OTG (o un hub; si cuelgan varias cosas, mejor con alimentación propia: el móvil da poca corriente).
  `nexo doctor` dice si Android declara USB host.
- La app Nexo 0.4.1 (protocolo 1.3) y el cliente 0.4.1 en Termux. Para usarlo **dentro de una distro**: `nexo setup-guests --with-usb`
  (copia `nexo-usb` y necesita `python3` en la distro; `nexo usb list` funciona hasta sin Python).
- En algunos Xiaomi/HyperOS hay un interruptor «OTG» en Ajustes → Ajustes adicionales que se apaga solo si no hay nada conectado: si el móvil no ve el
  dispositivo, mira ahí primero.

## Cómo funciona (y por qué hace falta un puente)

Una distro de proot **no puede** abrir `/dev/bus/usb`, ni montar nada, ni crear `/dev/ttyACM0`: no es root y el kernel es el de Android. Lo que sí puede
hacer una app es abrir el dispositivo con la API oficial (`UsbManager`) cuando el usuario lo autoriza. Así que:

```
 Android (app Nexo)                          127.0.0.1:8765                     Termux / tu distro
 UsbManager ── permiso ──► ┌─ conexión de control (JSON, dueña de la sesión) ◄──►  nexo usb bridge
 UsbDeviceConnection ────► └─ conexión de datos (bytes crudos, usb.attach)  ◄──►     ├─ PTY      ~/.local/state/nexo/usb/usb0.tty
   (bulk in/out, DTR/RTS…)                                                           ├─ RFC 2217  rfc2217://127.0.0.1:PUERTO
                                                                                      └─ TCP crudo 127.0.0.1:PUERTO
```

La app habla con el chip y pasa a Linux **solo los bytes de la línea serie** y las órdenes de control (velocidad, formato, DTR, RTS, ruptura). El puerto
que ves en la distro **no es un dispositivo USB**: es un PTY (o un servidor de red local) detrás del cual está el chip. Consecuencias:

- `lsusb`, `udevadm` y los programas que **buscan** puertos solos (`/dev/ttyACM*`, `/dev/ttyUSB*`: el IDE de Arduino, `arduino-cli board list`) no lo ven.
  Hay que darles la ruta (la de `nexo usb status`) o, si tu distro te deja escribir en `/dev`, crearla ahí con `--link /dev/ttyUSB0`.
- DTR y RTS no viajan por un PTY de Linux. Por eso `nexo usb` **emula** lo que hacen las herramientas (ver «El reinicio del Arduino»), y para `esptool`
  ofrece RFC 2217, que sí los lleva.

## Comandos

| Comando | Qué hace |
|---|---|
| `nexo usb list [--json\|--lsusb]` | Lo que Android ve por USB, con tipo, controlador y si ya hay permiso. `--json` es la respuesta de `usb.status`; `--lsusb` imita `lsusb`. |
| `nexo usb permit [DISP]` | Pide a Android el permiso (sale un aviso en la pantalla del móvil). Sin permiso no se puede abrir nada. |
| `nexo usb monitor [DISP]` | Monitor serie en la terminal. `-b 9600`, `--format 8N1`, `--hex`, `-T` (marcas de hora), `--send 'texto\n'`, `--until REGEX`, `--seconds N`, `--json`. Salir: `Ctrl+]`. |
| `nexo usb bridge [DISP]` | Crea el puerto para tus herramientas. `--link RUTA`, `--rfc2217 [HOST:]PUERTO`, `--tcp [HOST:]PUERTO`, `--detach`, `--name`, `--no-auto-reset`, `--no-reconnect`, `--wait`. |
| `nexo usb status [--json]` | Los puentes en marcha: estado, puerto, URL RFC 2217, registro. |
| `nexo usb stop [NOMBRE…\|--all]` | Los cierra (el chip vuelve a quedar libre). |
| `nexo usb reset [NOMBRE]` | Un pulso de reinicio a la placa de un puente en marcha. |

`DISP` es el **id** de `nexo usb list`, un **VID:PID** (`2341:0043`) o parte del nombre o del número de serie. Sin él se usa el único adaptador serie conectado.
`nexo usb help` lo explica todo. Códigos de salida: 0 bien · 1 error · 2 uso · 3 hace falta un toque en el móvil · 4 no hay dispositivo (o no sirve) ·
5 se desenchufó · 10 la app no responde · 11 token · 12 sin respuesta a tiempo. En `list`, `monitor` y `status` también existe `--json` para scripts.

## Usarlo con tus herramientas

Arranca el puente una vez (`nexo usb bridge --detach --rfc2217 0 --tcp 0`; el `0` elige un puerto libre y lo imprime) y usa lo que corresponda.
`RUTA` es el «puerto serie» que dice `nexo usb status` (por omisión `~/.local/state/nexo/usb/usb0.tty`; en archivos de configuración escríbela entera, sin `~`).

| Herramienta | Cómo |
|---|---|
| `screen`, `minicom`, `picocom` | `screen ~/.local/state/nexo/usb/usb0.tty 9600` |
| `avrdude` (Uno, Nano, Mega, Pro Mini) | `avrdude -c arduino -p atmega328p -P ~/.local/state/nexo/usb/usb0.tty -b 115200 -U flash:w:blink.hex:i`  (un Nano con el cargador antiguo: `-b 57600`) |
| `avrdude` por red | `avrdude -c arduino -p atmega328p -P net:127.0.0.1:PUERTO -U flash:w:blink.hex:i` (con `--tcp`; la placa se reinicia al conectar el primer cliente) |
| `arduino-cli` | `arduino-cli upload -p ~/.local/state/nexo/usb/usb0.tty --fqbn arduino:avr:uno MiSketch` |
| `esptool` (ESP32, ESP8266) | `esptool --port rfc2217://127.0.0.1:PUERTO chip_id` · `esptool --port rfc2217://127.0.0.1:PUERTO write_flash 0x0 firmware.bin` |
| PlatformIO | `upload_port = RUTA` (AVR) · `upload_port = rfc2217://127.0.0.1:PUERTO` (ESP32) |
| pyserial | `serial.Serial("RUTA", 9600)` · `serial.serial_for_url("rfc2217://127.0.0.1:PUERTO")` |

**Qué se ha probado de esa tabla:** el puerto PTY, el servidor RFC 2217 y el TCP crudo se probaron con clientes propios (el protocolo, los datos, el reinicio y
la desconexión) y contra la app simulada. **Ningún `avrdude`, `arduino-cli`, `esptool` ni PlatformIO reales** se han ejecutado contra ellos todavía: las filas
de arriba son lo que debería funcionar según cómo hablan esos programas, no algo verificado. Si alguna no funciona, dímelo con el informe de
`tests/usb_hardware_check.sh`.

Las velocidades que acepta cada chip y qué formatos (5‑8 bits, paridad, 1/1,5/2 de parada) están en «Chips».

## El reinicio del Arduino

Un Arduino Uno/Nano/Mega se reinicia cuando alguien activa DTR al abrir el puerto, y esa es la ventana en la que el cargador acepta un programa nuevo
(la que usan el IDE y `avrdude`). En Linux real eso lo hace el kernel; en un PTY no existe. `nexo usb bridge` lo **emula**:

- Cuando un programa **abre** el puerto por primera vez (lo detecta con `inotify`; si no hay, mira `/proc`) hace el pulso en DTR/RTS. Al cerrar el último
  programa suelta DTR y RTS. Sigue los cambios de velocidad y formato que haga el programa (`termios`).
- En RFC 2217 los cambios de DTR/RTS del cliente llegan tal cual al chip (es lo que necesita `esptool`).
- En TCP crudo no hay forma de pedirlo: se reinicia al conectar el primer cliente (y espera 150 ms).
- `--no-auto-reset` lo desactiva (para no reiniciar una placa que está funcionando). `nexo usb reset` da el pulso a mano. `monitor` también reinicia al
  abrir, salvo con `--no-reset`.
- Esto es el reinicio de las placas con un chip USB↔serie en medio (Uno, Nano, Mega, Pro Mini). Las de **USB nativo** se reprograman de otra manera y **no
  están cubiertas** por esta emulación: las ESP32 usan secuencias de DTR/RTS que hace `esptool` (por RFC 2217 deberían llegar al chip; sin verificar), y las
  Leonardo/Pro Micro se reinician con un «toque» a 1200 baudios y reaparecen con **otro VID:PID**, que el puente todavía no sigue.

## Desenchufar y volver a enchufar

Si desenchufas el cable, **el puente no se cae**: el puerto serie se queda donde está, el programa que lo tenga abierto no recibe un error de golpe, y el
puente espera. Al volver a enchufar la misma placa (la reconoce por VID, PID y número de serie) la reabre con la misma velocidad y formato y sigue.
Android puede volver a preguntar el permiso (si no marcaste «Usar siempre»): contesta en el móvil. Con `--no-reconnect` el puente termina (código 5) en
vez de esperar. `nexo usb status` muestra `conectado` o `esperando`.

## Chips

Los controladores son propios (sin librerías de terceros) y siguen las especificaciones de cada fabricante.

| Familia | Dispositivos | Notas |
|---|---|---|
| **CDC‑ACM** (`cdc-acm`) | Cualquier cosa que se presente como puerto serie USB estándar: Arduino Uno R3/Mega/Leonardo, ESP32‑S2/S3/C3 por USB nativo, Raspberry Pi Pico, Teensy… | 5‑8 bits, paridad ninguna/impar/par/marca/espacio, 1, 1,5 y 2 de parada. DTR, RTS y ruptura. Nexo le manda la velocidad al firmware (`SET_LINE_CODING`); en las de USB nativo no importa. |
| **CP210x** (`cp210x`) | Silicon Labs CP2102/CP2104/… (`10c4:ea60`, `ea70`, `ea71`) | No admite 1,5 de parada. |
| **FTDI** (`ftdi`) | FT232R, FT232H, FT2232, FT4232, FT‑X (`0403:6001`, `6010`, `6011`, `6014`, `6015`) | La velocidad real sale de un divisor: puede diferir un poco de la pedida (no más de ~2 % en las normales). |
| **CH34x** (`ch34x`) | CH340/CH341, los Nano y ESP32 baratos (`1a86:7523`, `7522`, `5523`) | Igual: divisor. No admite 1,5 de parada. |
| PL2303 | `067b:2303` | **Sin controlador**: sale en la lista con una nota y `bridge`/`monitor` responden «no sirve» (código 4). |

Las cuentas de velocidad de FTDI y CH34x se comprobaron con una transcripción independiente en Python de `libftdi` y del controlador `ch341.c` de Linux
(`tests/ref_baud.py`; `python3 tests/ref_baud.py --check android/app/src/test/java/org/nexo/bridge/UsbSerialTest.kt` verifica que las tablas del test
sean las de la referencia), y los valores de FTDI a 9600/19200/38400/115200 coinciden con la nota técnica AN232B‑05 de FTDI.

## Seguridad

- Android pide el permiso **por dispositivo** y solo la app Nexo lo tiene. Nexo no abre nada sin que lo pidas con un comando y Android lo haya concedido.
- El **puente RFC 2217 y el TCP crudo no tienen contraseña** y escuchan por omisión solo en `127.0.0.1`: cualquier programa de tu móvil que abra ese puerto
  mientras el puente está en marcha puede escribir en tu placa. Ciérralo con `nexo usb stop` al terminar. Si pones otra dirección
  (`--rfc2217 0.0.0.0:2217`) `nexo usb` te avisa de que la placa queda al alcance de toda la red.
- La conexión que habla con la app sí está autenticada con el token de siempre. Los archivos de estado y los registros de `nexo usb` son privados (0600).
- Nexo no cambia nada en el dispositivo por su cuenta: no escribe su memoria ni reprograma nada; eso lo hace la herramienta que tú uses.

## Si algo no funciona

| Síntoma | Qué mirar |
|---|---|
| `nexo usb list` dice «Android no ve ningún dispositivo USB» | El cable (¿es OTG y de datos, no solo de carga?), el interruptor OTG de Xiaomi, el hub sin alimentación. |
| Sale en la lista pero con `permiso no` | `nexo usb permit` y contesta Aceptar en la pantalla del móvil. Código 3 = hace falta tu toque. |
| `permit` no hace nada | La pantalla tiene que estar encendida y desbloqueada. Si el aviso no sale, abre antes la app Nexo y, en Xiaomi/HyperOS, prueba a darle el permiso de ventanas emergentes en segundo plano (Ajustes → Aplicaciones → Permisos); eso último no está verificado. |
| «no sirve como puerto serie» (4) | Es un PL2303, un teclado, un disco o un hub. Mira la nota de `nexo usb list`. |
| El monitor sale con símbolos raros | La velocidad no es la del sketch (`-b 9600`, `-b 115200`…). |
| `avrdude` no sincroniza (`stk500_getsync()`) | La velocidad del cargador (`-b 115200` en un Uno, `-b 57600` en un Nano viejo) o un sketch que ya tiene ocupado el puerto. `nexo usb reset` y repite. |
| El IDE de Arduino no ve el puerto | No busca en rutas de PTY: usa `arduino-cli`/PlatformIO con la ruta, o prueba `--link /dev/ttyUSB0`. |
| «Se perdió la conexión con la app» (10) | La app Nexo se cerró o Android la durmió: `nexo doctor`. |

`nexo doctor` y `nexo logs 30` (lo último que anotó la app) y el registro del puente (`nexo usb status` dice dónde está) son lo que hay que mirar primero.

## Probarlo en tu móvil

Todo lo de arriba se probó contra una app simulada. Lo que falta es un móvil y una placa de verdad. [`tests/usb_hardware_check.sh`](../tests/usb_hardware_check.sh)
lo hace por ti: mira que Android vea el dispositivo, pide el permiso, abre el puerto, y según lo que le pidas prueba el **eco** (unes TX con RX en un
adaptador), el **cargador del Arduino** (le pregunta «¿estás ahí?» por STK500 tras el reinicio automático; no escribe nada en la placa), **esptool** por RFC 2217
y **desenchufar y volver a enchufar**. Al final imprime un informe para copiar (sin tu token).

```bash
cd /storage/emulated/0/claude/nexo            # o donde tengas el repositorio
bash tests/usb_hardware_check.sh --help
bash tests/usb_hardware_check.sh --arduino --unplug       # un Arduino Uno/Nano/Mega con su cargador de fábrica
bash tests/usb_hardware_check.sh --loopback               # un adaptador CH340/CP210x/FTDI con TX unido a RX
bash tests/usb_hardware_check.sh 303a:1001 --esp32        # un ESP32 (hace falta: pip install esptool)
```

Con una placa conectada a la vez que otra cosa, indica cuál (`2341:0043`, el id o parte del nombre). Un Nano con el cargador antiguo: `--baud 57600`.
Para saber si todo va bien basta con que no salga ninguna línea `FALLA`. Si sale alguna, **pégame el informe entero**: lleva el dispositivo tal como lo ve
Android, las órdenes que mandó el controlador y lo último de los registros.

Esas pruebas **no escriben en la memoria de la placa** (el reinicio sí reinicia el programa que estuviera corriendo). Lo que **no** cubren: que `avrdude`, `arduino-cli` o `esptool` reales programen de verdad (eso lo ves cuando
subas tu primer sketch o firmware), el reconocimiento de tu modelo concreto de adaptador con cada hub, y el consumo de batería.

## Para quien programa

- El protocolo (`usb.status`, `usb.permission`, `usb.open`, `usb.setup`, `usb.control`, `usb.close`, `usb.attach` y el evento del tema `usb`) está en
  [`PROTOCOLO.md`](PROTOCOLO.md#usb-serie). La app simulada (`tests/fake_app.py`) es la especificación ejecutable.
- Android: `UsbSerial.kt` (lógica pura de los chips, probada en JVM), `UsbHandler.kt` (permisos, sesiones, hilos) y `UsbAttachedActivity.kt`
  (el aviso «abrir Nexo cuando se conecte»). `./gradlew testDebugUnitTest` corre las pruebas de JVM.
- Cliente: `termux/bin/nexo-usb` (Python 3.7+, sin dependencias). Las pruebas son `tests/usb_tests.sh` (se carga desde `tests/run_tests.sh`;
  `NEXO_TESTS_ONLY=usb bash tests/run_tests.sh` corre solo estas) y `tests/usb_client.py`.
- Comparar con lo que hace el kernel de Linux ayuda a entender los chips: `drivers/usb/class/cdc-acm.c`, `drivers/usb/serial/{ch341,cp210x,ftdi_sio}.c`.

## Referencias

- Android: [Descripción general del host USB](https://developer.android.com/develop/connectivity/usb/host).
- CDC‑ACM: USB‑IF, *Class definitions for Communication Devices 1.2* (PSTN120: `SET_LINE_CODING`, `SET_CONTROL_LINE_STATE`, `SEND_BREAK`).
- Silicon Labs, [AN571 – CP210x Virtual COM Port Interface](https://www.silabs.com/documents/public/application-notes/AN571.pdf).
- FTDI, [AN232B‑05 – Configuring FT232R, FT2232 and FT232B baud rates](https://www.ftdichip.com/Support/Knowledgebase/an232b_05intro.htm) y `ftdi_to_clkbits()` de libftdi.
- CH340/CH341: el cálculo de `ch341.c` del kernel de Linux.
- [RFC 2217](https://www.rfc-editor.org/rfc/rfc2217) (Telnet COM Port Control Option) y la documentación de pyserial sobre `rfc2217://`.
- [usb-serial-for-android](https://github.com/mik3y/usb-serial-for-android): otra implementación de estos mismos controladores, útil para comparar.
