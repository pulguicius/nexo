# Protocolo Nexo (versión 1, revisión 4)

Lo que hablan la app Android y los clientes (`nexo`, `nexo-dbus`, o el tuyo). Es deliberadamente simple para que se
pueda usar desde bash, Python, Node, QML o lo que tengas dentro de una distro.

**Compatibilidad:** dentro de la versión 1 solo se añaden campos, comandos y temas de eventos. Un cliente debe ignorar lo que no
conozca, y una app nueva sigue atendiendo a los clientes viejos. La *revisión* (`minor` en `hello`) sube cuando se añade algo:

| `minor` | App | Novedades |
|---|---|---|
| 1 | 0.1.x | WiFi, Bluetooth, eventos, bootstrap |
| 2 | 0.2.x | audio, media, `wifi.saved/forget/reconnect`, `bt.forget/rename/info`, `logs`, `commands` en `hello`, `gateway/prefix/dns` en `wifi.status` |
| 3 | 0.4.1 | USB serie (Arduino, ESP32, adaptadores USB↔serie): `usb.status`, `usb.permission`, `usb.open`, `usb.setup`, `usb.control`, `usb.close`, `usb.attach`, el tema de eventos `usb` y el campo `usb` en `hello`. Una conexión puede pasar a ser de **bytes** (`usb.attach`) |
| 4 | 0.4.2 | Discos USB (pendrives, discos duros y SSD externos): `storage.status`, `storage.access`, `storage.revoke`, `storage.list`, `storage.stat`, `storage.open`, `storage.read`, `storage.write`, `storage.sync`, `storage.close`, `storage.mkdir`, `storage.delete`, `storage.rename`, `storage.eject`, el tema de eventos `storage` y el campo `storage` en `hello`. Los archivos viajan en trozos de base64 por la misma conexión JSON (no hay conexiones de bytes nuevas) |
| 5 | 0.4.3 (previsto) | `net.status` (qué red usa el móvil) y el tema de eventos `net`; notificaciones: `notif.status`, `notif.list`, `notif.dismiss` y el tema `notif` |

## Transporte

- **TCP en `127.0.0.1`**, puerto **8765** por omisión (se cambia en la app). Nunca escucha en la red.
- Codificación **UTF‑8**. **Un objeto JSON por línea** (`\n` al final). Máximo 64 KiB por línea.
- `proot` comparte la red del móvil, así que `127.0.0.1` es el mismo desde Termux y desde cualquier distro.
- Hasta 16 clientes a la vez; los que sobran se cierran sin respuesta.

## Conexión y autenticación

Cualquier app del móvil puede conectarse a un puerto local, así que **lo primero que debe enviar un cliente es `hello` con el token**.
Si el token es incorrecto, la app espera ~0,8 s, responde `unauthorized` y cierra. Si en 8 s no hay un `hello` válido, cierra.

```json
{"id":"1","cmd":"hello","token":"<48 caracteres hex>","client":"mi-cliente/1.0"}
```
```json
{"id":"1","ok":true,"data":{"app":"nexo","version":"0.4.2","proto":1,"minor":4,"android_sdk":36,"target_sdk":28,"device":"Xiaomi 25078RA3EL","wifi":true,"bluetooth":true,"listener":false,"usb":true,"storage":true,"uptime_s":3120,"commands":["wifi.status","wifi.enable","…"]}}
```

- `wifi` y `bluetooth` dicen si el móvil tiene esa radio.
- `listener` dice si Android le dio a Nexo «acceso a notificaciones» (hace falta para `media.*` y `notif`).
- `usb` (revisión 3) dice si el móvil tiene modo anfitrión USB (OTG). Una app de la revisión 2 no lo envía.
- `storage` (revisión 4) dice si el móvil tiene el servicio de almacenamiento de Android (todos lo tienen). Una app de la revisión 3 no lo envía; los comandos `storage.*` en `commands` son la forma segura de saber si esta app maneja discos.
- `commands` es la lista de comandos que esta app entiende: úsala para detectar capacidades en vez de adivinar por la versión.

El token se muestra en la app y se guarda con `nexo pair TOKEN` (archivo `config` con modo 600). Se invalida con «Token nuevo».

## Peticiones y respuestas

Petición: `{"id": <texto o número>, "cmd": "<comando>", ...parámetros al mismo nivel}`.
La respuesta repite el `id`. Se pueden mandar varias peticiones seguidas por la misma conexión: se contestan en orden.

```json
{"id":"7","ok":true,"data":{ ... }}
{"id":"7","ok":false,"error":"needs_user_action","message":"…","action":"notification","opens":"wifi_panel"}
```

### Códigos de error

| `error` | Significa |
|---|---|
| `unauthorized` | Falta `hello` o el token es incorrecto (se cierra la conexión) |
| `bad_request` | JSON inválido o faltan/sobran parámetros |
| `unknown_command` | Ese `cmd` no existe (una app antigua responde esto a los comandos nuevos) |
| `permission_denied` | Falta un permiso de Android; `permission` dice cuál cuando se sabe (`ACCESS_FINE_LOCATION`, `BLUETOOTH_CONNECT`) |
| `needs_user_action` | Android no deja hacerlo solo. La app dejó una **notificación** que abre el panel adecuado: la respuesta trae `"action":"notification"` y `"opens"` = `wifi_panel`, `bluetooth_enable`, `bluetooth_settings`, `volume_panel` o `notification_listener_settings` |
| `wifi_disabled` / `bluetooth_disabled` | El comando necesita la radio encendida |
| `not_paired` | El dispositivo Bluetooth no está emparejado en Android |
| `not_found` | Lo que pides no existe: red guardada, salida de audio, sesión de medios, carátula, dispositivo o sesión USB; en discos, un disco, un archivo o carpeta, o un archivo abierto (`handle`) que ya no está abierto |
| `busy` | USB: el dispositivo ya está abierto (por otra sesión, por otra app, o Android no deja reclamar su interfaz) o la sesión ya tiene un flujo de datos conectado |
| `unsupported` | Este móvil o esta versión de Android no tiene eso |
| `failed` | Android rechazó la operación |
| `timeout` | El comando tardó más de lo razonable (la app no se quedó colgada: contesta y sigue) |
| `rate_limited` | Solo para `bootstrap` (el instalador): se pidió demasiado seguido (máx. 1 cada 2 s y 10 por minuto en total). Se cierra la conexión; reintenta en unos segundos |
| `no_access` | Discos USB: Nexo todavía no tiene acceso a ese disco. Se pide con `storage.access` (el usuario lo concede en el selector de carpetas de Android). La respuesta lleva `volume` |
| `unavailable` | Discos USB: el disco no está montado. La respuesta lleva `volume` y `state` |
| `bad_path` | Una ruta o un nombre no vale: demasiado largo (4096 caracteres la ruta, 255 bytes un nombre), lleva `..`, caracteres de control o `/` dentro de un nombre; o, en un nombre **nuevo**, un carácter que los discos USB no admiten (`"` `*` `:` `<` `>` `?` `\` y la barra vertical) o un punto o un espacio al final. También: borrar o mover la raíz del disco, o mover una carpeta dentro de sí misma |
| `exists` | Ya existe lo que se quería crear (o el destino de un renombrado) |
| `not_dir` | Se esperaba una carpeta y es un archivo |
| `is_dir` | Se esperaba un archivo y es una carpeta |
| `not_empty` | La carpeta que se quiere borrar no está vacía (`storage.delete` nunca borra de forma recursiva) |
| `read_only` | El disco está montado en solo lectura, o ese archivo se abrió solo para leer |
| `no_space` | El disco está lleno |
| `too_big` | El archivo no cabe en el sistema de archivos del disco (FAT32 no admite archivos de 4 GiB o más) |
| `io_error` | Android o el disco fallaron al leer, escribir o borrar |
| `limit` | Demasiados archivos abiertos a la vez (64 en total, 16 por conexión) |
| `internal` | Error inesperado de la app |

## Comandos

### Generales
| Comando | Parámetros | `data` |
|---|---|---|
| `hello` | `token`, `client?` | información de la app (arriba) |
| `ping` | — | `{"pong":true,"t":<ms>}` |
| `subscribe` | `topics?` = `["wifi","bt","audio","media","usb","storage"]` | `{"topics":[…]}`, y después un evento inicial por tema |
| `unsubscribe` | — | — |
| `logs` | `n?` (50; máx. 200) | `{"lines":[…],"count":N,"uptime_s":S}`: lo último que anotó la app. Nunca lleva el token ni claves |
| `bootstrap` | — | **No es JSON**: ver más abajo. No necesita token |

### WiFi
| Comando | Parámetros | `data` |
|---|---|---|
| `wifi.status` | — | `available, enabled, state, connected, ssid, ssid_hidden, bssid, rssi, level (0‑4), frequency, band, link_speed, ip, gateway, netmask, prefix, dns, permission_location, location_enabled` |
| `wifi.enable` / `wifi.disable` | — | el estado resultante (espera hasta 4 s a que cambie) |
| `wifi.scan` | `fresh?` (true), `timeout_ms?` (4000; entre 500 y 15000) | `networks:[{ssid,bssid,rssi,level,frequency,band,security,secured}], fresh, hidden_count, hint?` |
| `wifi.connect` | `ssid`, `password?`, `hidden?` (false), `wait_ms?` (12000; máx. 30000) | `requested, network_id, ssid, connected, hint?` |
| `wifi.disconnect` | — | `{"requested":true}` |
| `wifi.saved` | — | `networks:[{network_id,ssid,security,hidden,current}]` — las redes guardadas en el móvil |
| `wifi.forget` | `ssid` o `network_id` | `{"removed":N}`; `not_found` si no hay ninguna |
| `wifi.reconnect` | `wait_ms?` (8000; máx. 30000) | `{"requested":true,"connected":bool}` |

- `state` es `enabled`, `enabling`, `disabling`, `disabled` o `unknown`. Si el móvil no tiene WiFi: `{"available":false}`.
- Con el WiFi apagado o sin conexión, `ssid`, `bssid`, `rssi`, `level`, `frequency`, `band`, `link_speed`, `ip`, `gateway`, `netmask`, `prefix` y `dns` son `null`.
- `gateway`, `netmask` e `ip` son texto (`"192.168.1.1"`), `prefix` es un entero (`24`) y `dns` una lista de textos.
- `ssid` es `null` y `ssid_hidden` es `true` si Android lo oculta (falta el permiso de ubicación o la ubicación del sistema está apagada).
- `security` es `OPEN`, `OWE`, `WEP`, `WPA`, `WPA2` o `WPA3` (una red mixta WPA2/WPA3 aparece como `WPA3`).
- `wifi.scan` devuelve una entrada por nombre de red (la de señal más fuerte). `hidden_count` cuenta las redes sin nombre. `hint` solo viene si no hubo resultados.
  Android limita los escaneos (unos 4 cada 2 minutos): pasado el límite devuelve la lista anterior con `fresh:false`.
- `wifi.connect` sin `password` usa la red ya guardada en el móvil; si no existe, la crea como red abierta.
  Devuelve `connected:false` si pasado `wait_ms` no se confirmó la conexión (clave mala, sin cobertura, señal muy débil…).
  Las redes que usan **solo** WPA3 no se pueden crear con la API que permite Android a una app normal: responde `needs_user_action` y abre el panel de WiFi.
- `wifi.saved` necesita el permiso de ubicación; sin él responde `permission_denied`. `current` es `true` para la red a la que está conectado ahora.
- `wifi.forget` borra la red guardada (por nombre o por `network_id`); si es la actual, el móvil se desconecta de ella.

### Bluetooth
| Comando | Parámetros | `data` |
|---|---|---|
| `bt.status` | — | `available, enabled, state, name, connected, bonded_count, permission_missing?` |
| `bt.enable` / `bt.disable` | — | el estado resultante (espera hasta 5 s) |
| `bt.paired` | — | `devices:[{name,address,connected,profiles,type,class}]` |
| `bt.connect` / `bt.disconnect` | `address` | ver abajo: siempre `needs_user_action` |
| `bt.forget` | `address` | `{"removed":true}`: desempareja el dispositivo |
| `bt.rename` | `address`, `name` | `{"address":…,"alias":…}` |
| `bt.info` | `address` | `address, name, alias, type, class, bond_state, connected, profiles, uuids, battery` |

- `state` es `on`, `off`, `turning_on`, `turning_off` o `unknown`. `connected` es `true` si hay algún dispositivo conectado (audio, manos libres, teclado/ratón o BLE).
- En `bt.paired`: `profiles` puede incluir `a2dp`, `headset`, `hid` y `gatt`; `type` es `classic`, `le`, `dual` o `unknown`;
  `class` es `audio`, `phone`, `computer`, `peripheral`, `wearable`, `health`, `imaging`, `networking`, `toy`, `other` o `unknown`. `name` puede ser `null`.
- `bt.connect` / `bt.disconnect`: Android no deja que una app normal conecte o desconecte dispositivos Bluetooth. Tras validar `address`
  (`bad_request`), que el Bluetooth esté encendido (`bluetooth_disabled`) y que el dispositivo esté emparejado (`not_paired`),
  la app responde `needs_user_action` y deja una notificación que abre los ajustes de Bluetooth del móvil.
- `bt.forget` usa `BluetoothDevice.removeBond()`, que **no es API pública** de Android: se llama por reflexión. Si el sistema la bloquea,
  responde `needs_user_action` (abre los ajustes de Bluetooth) en lugar de fallar en silencio.
- `bt.rename` usa `BluetoothDevice.setAlias()` (Android 12 o más; en versiones anteriores, `unsupported`). Con `name` vacío quita el alias.
- `bt.info`: `bond_state` es `bonded`, `bonding` o `none`; `uuids` es la lista de servicios que anuncia; `battery` es el porcentaje que
  informe el dispositivo, o `null` (también por reflexión, y solo si el dispositivo lo expone).

### Audio
| Comando | Parámetros | `data` |
|---|---|---|
| `audio.status` | — | `available, stream, level, min, max, volume (0‑100), muted, output, ringer` |
| `audio.volume` | uno de: `percent` (0‑100), `level`, `delta` (puntos de porcentaje, con signo), `mute` (`true`/`false`/`"toggle"`); y `show_ui?` | el `audio.status` resultante |
| `audio.outputs` | — | `outputs:[{id,type,name,address,active}]` |
| `audio.switch` | `id` o `type` | siempre `needs_user_action` (abre el panel de volumen); `not_found` si esa salida no existe |

- Se controla el volumen de **música** (`stream:"music"`). `volume` es el porcentaje redondeado de `level` entre `min` y `max`.
- `delta` mueve el volumen esos puntos de porcentaje; si el cambio es distinto de cero siempre se mueve, al menos, un escalón (Android tiene ~15).
- `output` es la salida que usaría la música ahora (`{id,type,name,address}`), o `null` si Android no lo dice. `ringer` es `normal`, `vibrate` o `silent`.
- `type` de las salidas: `speaker`, `earpiece`, `wired_headset`, `wired_headphones`, `usb_headset`, `usb_device`, `bluetooth_a2dp`, `bluetooth_sco`,
  `ble_headset`, `ble_speaker`, `hearing_aid`, `hdmi`, `line`, `dock` u `other`.
- `audio.switch`: Android no deja que una app normal redirija el audio del sistema a otra salida (`setPreferredDevice` solo afecta a las
  sesiones de la propia app). La app valida la salida y abre el panel de volumen para que la elijas con un toque.

### USB serie
Arduino, ESP32 y adaptadores USB↔serie (CDC‑ACM, CP210x, FTDI, CH34x) conectados al móvil por OTG o por un hub. Android **no deja** que una distro
de proot abra `/dev/bus/usb` ni monte nada, así que la app abre el dispositivo con la API oficial (`UsbManager`, tras pedirle permiso al usuario) y le
pasa a Linux **solo los bytes de la línea serie**. Los pendrives y los discos tienen su propia sección (justo debajo); teclados y ratones no son parte de esto.

| Comando | Parámetros | `data` |
|---|---|---|
| `usb.status` | — | `host` (¿tiene OTG?), `devices:[{id,path,bus,address,vid,pid,vendor,product,serial,class,kind,driver,serial_capable,permission,note,interfaces:[{id,class,subclass,protocol,endpoints}]}]`, `sessions:[…]` |
| `usb.permission` | `device`, `wait_ms?` (0‑30000) | `{device,granted,requested,denied}` |
| `usb.open` | `device`, y `baud?` (115200), `bits?` (5‑8; 8), `parity?` (`none`, `odd`, `even`, `mark`, `space`), `stop?` (1, 1.5 o 2), `dtr?` y `rts?` (ambas `true`) | la sesión (abajo) + `ep_in, ep_out, packet, steps` |
| `usb.setup` | `session`, y los mismos `baud`, `bits`, `parity`, `stop` | la sesión + `steps` |
| `usb.control` | `session`, y `dtr?`, `rts?`, `brk?` (señal de ruptura) | la sesión + `steps` |
| `usb.close` | `session` | `{"closed":true}` |
| `usb.attach` | `session` | `{"session":…,"raw":true}`, y la conexión **deja de ser JSON** (ver abajo) |

**Orden de uso:** `usb.status` (elige el `id` de un dispositivo con `serial_capable:true`) → `usb.permission` → `usb.open` → una **segunda conexión** que se
autentica con `hello` y manda `usb.attach` → bytes. La conexión de control (la que hizo `usb.open`) debe seguir abierta: **la sesión se cierra con ella**, con `usb.close`
o al desenchufar el dispositivo.

- **Permiso.** `usb.permission` hace que Android muestre su diálogo «¿Permitir que Nexo acceda al dispositivo USB?» en la pantalla del móvil. Si ya había permiso responde
  `granted:true, requested:false`. Con `wait_ms` espera esa cantidad de milisegundos a que el usuario conteste; si no contesta a tiempo, responde `granted:false, requested:true, denied:false`
  y el cliente vuelve a consultar (`usb.status` → `permission`). `denied:true` = el usuario dijo que no. `usb.open` sin permiso falla con `permission_denied` (y el campo `needs_permission` en `true`).
- **Dispositivo.** `id` es el de Android (estable mientras esté enchufado). `vid`/`pid` van en hexadecimal de 4 cifras; `vendor`, `product` y `serial` pueden ser `null`.
  `kind`: `serial`, `hub`, `storage`, `hid`, `audio`, `video`, `printer`, `net` u `other` (solo para mostrar). `driver`: `cdc-acm`, `cp210x`, `ftdi` o `ch34x`, o `null`.
  `serial_capable` es `true` si Nexo tiene controlador para él; si es `false`, `note` puede explicar por qué (p. ej. PL2303) y `usb.open` responde `unsupported`.
- **Sesión.** `session` (`s1`, `s2`…), `device`, `driver`, `baud`, `bits`, `parity`, `stop`, `dtr`, `rts`, `attached` (¿hay un flujo de datos conectado?) y los contadores `rx`/`tx`
  (bytes recibidos del dispositivo y enviados a él). Cada dispositivo admite una sola sesión a la vez (`busy`).
- **`usb.open` además devuelve** `ep_in` y `ep_out` (direcciones de los extremos bulk que usa) y `packet` (tamaño máximo de paquete de entrada). Son informativos.
- **`steps`.** Las órdenes de control que se mandaron al chip: `{op, rc}`, con `rc` = lo que devolvió Android (bytes transferidos, o negativo si falló). Es información para diagnosticar.
  Si falla una orden obligatoria del chip, el comando responde `failed` (con la lista de `steps` en la respuesta de error).
- **`dtr` y `rts`.** Son las líneas de control. En un Arduino, activar `dtr` (el flanco) lo **reinicia**: es lo que hacen el IDE y `avrdude` para entrar en el cargador.
  `brk:true` empieza una señal de ruptura y `brk:false` la termina. `stop:1.5` no lo admiten CP210x ni CH34x (`unsupported`).
- **Velocidad.** FTDI y CH34x calculan un divisor: la velocidad real puede diferir un poco de la pedida (no más de ~2 % en las normales).
- **Flujo de datos (`usb.attach`).** Tras la respuesta `{"ok":true,…,"raw":true}` (una línea JSON), esa conexión ya **no es JSON**: lo que llega del dispositivo se envía tal cual al cliente y lo
  que el cliente escribe se envía al dispositivo, hasta que alguno se cierre. En esa conexión no hay eventos. Se cierra cuando termina la sesión.
  Solo una conexión de datos por sesión (`busy` si ya hay otra). Si el cliente cierra la conexión de datos, la sesión **sigue abierta** (se puede volver a hacer `usb.attach`).

Un cliente de bash puro (para ver lo que manda un Arduino a 9600):

```bash
exec 3<>/dev/tcp/127.0.0.1/8765                                  # conexión de control
printf '%s\n' '{"id":"1","cmd":"hello","token":"TU_TOKEN"}' >&3; read -r -t 5 l <&3
printf '%s\n' '{"id":"2","cmd":"usb.status"}' >&3;              read -r -t 5 l <&3; echo "$l"      # busca el "id" del Arduino
printf '%s\n' '{"id":"3","cmd":"usb.permission","device":1002,"wait_ms":30000}' >&3; read -r -t 35 l <&3
printf '%s\n' '{"id":"4","cmd":"usb.open","device":1002,"baud":9600}' >&3;           read -r -t 10 l <&3; echo "$l"   # anota la "session"
exec 4<>/dev/tcp/127.0.0.1/8765                                  # conexión de datos
printf '%s\n' '{"id":"1","cmd":"hello","token":"TU_TOKEN"}' >&4; read -r -t 5 l <&4
printf '%s\n' '{"id":"2","cmd":"usb.attach","session":"s1"}' >&4; read -r -t 5 l <&4
cat <&4                                                           # …y aquí salen los bytes del Arduino (Ctrl‑C para salir)
```

### Discos USB (almacenamiento)
Pendrives, discos duros y SSD externos conectados por OTG o por un hub. Android monta el disco él solo (`vold`) y lo enseña como un *volumen*; una distro de proot ni lo ve ni
puede montarlo. Nexo **no** pide «acceso a todos los archivos»: el usuario elige el disco en el selector de carpetas de Android (Storage Access Framework), Android recuerda ese
permiso, y la app ofrece a Linux las operaciones sobre archivos **solo** dentro de lo autorizado. Todo viaja por la misma conexión JSON: los datos, en trozos de base64.
Qué está probado y qué no, en [USB-ALMACENAMIENTO.md](USB-ALMACENAMIENTO.md).

| Comando | Parámetros | `data` |
|---|---|---|
| `storage.status` | — | `available`, `volumes:[…]` (abajo), `mass_storage_devices` (dispositivos USB de almacenamiento masivo que ve `UsbManager`), `open_files` |
| `storage.access` | `volume`, `wait_ms?` (0‑30000) | `{volume,granted,requested,denied}` |
| `storage.revoke` | `volume` | `{volume,released}`: Nexo olvida el acceso (cierra antes sus archivos abiertos) |
| `storage.list` | `volume`, `path?` (`/`), `offset?` (0), `limit?` (500; de 1 a 2000) | `{path,entries:[…],total,offset}` |
| `storage.stat` | `volume`, `path?` (`/`) | una entrada (abajo) + `path` |
| `storage.open` | `volume`, `path`, `mode?` (`r`, `w`, `a` o `rw`), `create?`, `truncate?`, `exclusive?` | `{handle,size,writable}` |
| `storage.read` | `handle`, `offset`, `len?` (máx. 49152) | `{n,eof,data}`, con `data` en base64 |
| `storage.write` | `handle`, `offset`, `data` (base64; máx. 32768 bytes ya decodificados) | `{n}` |
| `storage.sync` | `handle` o `volume` | `{synced}`: cuántos archivos de escritura vació al disco |
| `storage.close` | `handle` | `{closed}` (`false` si ya no estaba abierto) |
| `storage.mkdir` | `volume`, `path`, `parents?` (`false`) | `{created:true}` |
| `storage.delete` | `volume`, `path` | `{deleted:true}` |
| `storage.rename` | `volume`, `from`, `to`, `overwrite?` (`false`) | `{renamed:true}` |
| `storage.eject` | `volume` | `{volume,closed_files,attempted,ejected,state,hint?}` |

**Orden de uso:** `storage.status` → (si `granted:false`) `storage.access` → `storage.list` / `storage.stat` → `storage.open` → `storage.read` / `storage.write` → `storage.close`.

- **Volumen.** Los comandos con `volume` aceptan el UUID del disco (`1111-2222`) o su nombre, sin distinguir mayúsculas (`not_found` si no hay ninguno; `bad_request` si dos se llaman igual: usa el UUID).
  `storage.status` lista los discos que Android tiene (la memoria interna del móvil no aparece). Cada uno: `id` (igual a `uuid`), `uuid`, `label`, `state`
  (el de Android: `mounted`, `mounted_ro`, `checking`, `ejecting`, `unmounted`, `removed`, `bad_removal`, `unmountable`, `nofs`, `shared`…), `mounted` (montado, con escritura o sin ella),
  `readonly`, `removable`, `primary`, `path` (dónde lo monta Android, p. ej. `/storage/1111-2222`: solo lo ve quien tenga permiso para ello, no una distro de proot normal),
  `granted` (¿Nexo tiene acceso?), `scope` (la carpeta autorizada dentro del disco; `""` es el disco entero; `null` si no hay acceso), `open_files`, y `total` y `free` en bytes (`null` si Android no los dice).
  Los comandos de archivos con el disco sin montar responden `unavailable`.
- **Acceso.** `storage.access` responde `granted:true, requested:false` si ya lo hay. Si no, abre el selector de carpetas de Android en el móvil (o deja una notificación que lo abre, si la pantalla de Nexo no está a la vista)
  y, con `wait_ms`, espera esa cantidad de milisegundos a que el usuario conteste; si no contesta a tiempo, responde `granted:false, requested:true, denied:false` y se vuelve a consultar con `storage.status`. `denied:true` = dijo que no.
  El usuario debe elegir una carpeta **del propio disco** y pulsar «Usar esta carpeta»; si elige una subcarpeta, esa carpeta pasa a ser la raíz para Nexo (`scope` dice cuál) y no puede salir de ella.
  Android recuerda el permiso aunque se desenchufe el disco; `storage.revoke` lo quita.
- **Rutas.** Siempre con `/` y relativas a la raíz del disco (o de la carpeta autorizada). `..` no existe y las barras repetidas se ignoran. Los errores de nombre son `bad_path` (tabla de errores).
  Los nombres nuevos no admiten `"` `*` `:` `<` `>` `?` `\` ni la barra vertical, ni acabar en punto o espacio: Android los cambiaría por `_` sin avisar y el archivo acabaría con otro nombre.
  Lo que ya existe con esos nombres (por ejemplo, en un disco ext4) se lee, se borra y se mueve igualmente.
- **Entradas.** `{name,type,size,mtime_ms,mime?,writable}`: `type` es `file` o `dir`; `size` y `mtime_ms` (milisegundos desde 1970) valen 0 si Android no los dice; `mime` falta si no se conoce.
  `storage.list` devuelve primero las carpetas y luego los archivos, por nombre sin distinguir mayúsculas, siempre en el mismo orden: se puede paginar con `offset` y `limit`.
- **Abrir.** `mode` `r` lee (por omisión); `w` crea o vacía y escribe; `a` crea si falta y escribe sin vaciar (`size` dice dónde está el final); `rw` lee y escribe uno que ya existe.
  `create`, `truncate` y `exclusive` (falla con `exists` si ya está) ajustan lo que cada modo hace y solo cuentan en los de escritura. Para crear, la carpeta de arriba debe existir: `open` no crea carpetas.
  No hay «posición actual»: cada `storage.read` y `storage.write` lleva su `offset` (como `pread` y `pwrite`). `eof:true` quiere decir que esa lectura llegó al final del archivo.
  Se pueden mandar varias peticiones seguidas sin esperar las respuestas (se contestan en orden): `nexo usb get` y `nexo usb put` mantienen tres en vuelo.
- **Archivos abiertos.** Un `handle` es de la conexión que lo abrió y se cierra solo cuando esa conexión se cierra, cuando el disco se desmonta, cuando se revoca el acceso o al apagar el puente.
  Tope: 64 abiertos en total y 16 por conexión (`limit`). Cerrar un archivo de escritura lo vacía antes al disco (`sync`); si eso falla (p. ej. `no_space`), el archivo se cierra igualmente y el error vuelve en la respuesta de `storage.close`.
  Un `handle` que ya no está abierto responde `not_found`.
- **Borrar y mover.** `storage.delete` borra un archivo o una carpeta **vacía**: nunca de forma recursiva (`not_empty`), porque Android borraría el árbol entero sin avisar; quien quiera borrar un árbol lo recorre (es lo que hace `nexo usb rm -r`).
  La raíz del disco no se borra ni se mueve. `storage.rename` renombra o mueve **dentro del mismo disco**; si el destino existe responde `exists`, y con `overwrite:true` sustituye un archivo por otro archivo o una carpeta vacía por otra carpeta.
- **Expulsar.** `storage.eject` cierra (vaciando antes) los archivos abiertos de ese disco y le pide a Android que lo expulse (`DocumentsContract.ejectRoot`). Una app normal puede no tener permiso para eso y Android lo ignora **sin avisar**:
  por eso la app mira el estado del disco hasta 3 s después. `ejected:true` = ya no está montado; si no, `ejected:false` y `hint` dice qué hacer a mano (el botón «Expulsar» de Android). `attempted` dice si Android aceptó la llamada (no que expulsara nada) y
  `state` es el estado del disco tras el intento (`removed` si ya no está).
- **Eventos.** El tema `storage` (abajo) manda `storage.status` entero cuando se monta, se expulsa o se quita un disco, cambia su estado o Nexo gana o pierde el acceso. No avisa por cada archivo.

```bash
exec 3<>/dev/tcp/127.0.0.1/8765
printf '%s\n' '{"id":"1","cmd":"hello","token":"TU_TOKEN"}' >&3;                              read -r -t 5 l <&3
printf '%s\n' '{"id":"2","cmd":"storage.status"}' >&3;                                        read -r -t 5 l <&3; echo "$l"   # anota el "uuid" del disco
printf '%s\n' '{"id":"3","cmd":"storage.access","volume":"1111-2222","wait_ms":30000}' >&3;    read -r -t 35 l <&3             # solo la primera vez: se concede en el móvil
printf '%s\n' '{"id":"4","cmd":"storage.list","volume":"1111-2222","path":"/"}' >&3;          read -r -t 10 l <&3; echo "$l"
exec 3>&-
```

### Media
Necesita que el usuario conceda a Nexo el **acceso a notificaciones** (Ajustes › Notificaciones › Acceso a notificaciones). Sin él,
`media.status` responde con `listener:false` (no es un error) y los demás comandos responden `needs_user_action` con `opens:"notification_listener_settings"`.

| Comando | Parámetros | `data` |
|---|---|---|
| `media.status` | — | `listener, available, package, app, title, artist, album, album_artist, state, position_ms, duration_ms, speed, track_id, art_hash, can_play, can_pause, can_next, can_prev, can_seek, can_stop` |
| `media.play` · `media.pause` · `media.playpause` · `media.stop` · `media.next` · `media.prev` | — | `{"requested":true,"state":…}` |
| `media.seek` | `delta_ms` o `position_ms` | `{"requested":true,"position_ms":N}` |
| `media.art` | — | `{"hash":…,"mime":"image/jpeg","width":W,"height":H,"data":"<base64>"}` |

- `available` es `true` si hay una app reproduciendo (o en pausa). `state` es `playing`, `paused`, `stopped`, `buffering`, `error` o `none`.
- La app elige la sesión que está sonando; si no hay ninguna, la más reciente. `position_ms` ya viene extrapolada al momento de la respuesta.
- `track_id` es un identificador estable de la pista (para `mpris:trackid`); `art_hash` identifica la carátula: pídela con `media.art` solo cuando cambie.
- `media.art` devuelve la carátula reducida (JPEG, hasta 320 px y ~40 KB para caber en una línea); `not_found` si la app no la ofrece.
- Los comandos de control responden `not_found` si no hay ninguna sesión de medios.

## Eventos

Tras `subscribe`, la app envía líneas **sin `id`**:

```json
{"event":"wifi","data":{ …igual que wifi.status… }}
{"event":"bt","data":{ …igual que bt.status… }}
{"event":"audio","data":{ …igual que audio.status… }}
{"event":"media","data":{ …igual que media.status… }}
{"event":"usb","data":{ …igual que usb.status… }}
{"event":"storage","data":{ …igual que storage.status… }}
```

Se juntan las ráfagas (300 ms) y no se emiten cambios de intensidad de señal ni de posición de la canción
(quien la necesite la extrapola con `position_ms` y `speed`, o la pide con `media.status`). El tema `usb` avisa cuando se enchufa o desenchufa un dispositivo, cambia un permiso o
se abre o se cierra una sesión (no por cada byte: los contadores `rx` y `tx` de un evento son los del momento del aviso).
El tema `storage` avisa cuando se monta, se expulsa o se quita un disco, cambia su estado o Nexo gana o pierde el acceso a él (no por cada archivo).
Sin `topics`, se suscribe a `wifi`, `bt`, `audio`, `media`, `usb` y `storage`. El cliente `nexo watch` envía un `ping` cada 30 s sin actividad
y reconecta solo (con espera creciente) si se corta.

## `bootstrap`: instalar el cliente sin internet

```json
{"cmd":"bootstrap"}
```

La app responde con **un script de bash en texto plano** (no JSON) y cierra la conexión. Contiene el cliente, `nexo-dbus`, `nexo-tools` y `nexo-usb` (cada uno en base64, en las variables de shell `NEXO_CLIENT_B64`, `NEXO_DBUS_B64`, `NEXO_TOOLS_B64` y `NEXO_USB_B64`, sin `export`) y el instalador,
**nunca el token**. El comando de una línea que copia la app comprueba el **SHA‑256** del script antes de ejecutarlo; así, otra app que
se hubiera adelantado a ocupar el puerto no puede colarte código. La app limita la entrega (una cada 2 s, diez por minuto en total).

## Ejemplo mínimo con bash puro

```bash
exec 3<>/dev/tcp/127.0.0.1/8765
printf '%s\n' '{"id":"1","cmd":"hello","token":"TU_TOKEN"}' >&3;  read -r -t 5 l <&3; echo "$l"
printf '%s\n' '{"id":"2","cmd":"wifi.status"}'               >&3;  read -r -t 5 l <&3; echo "$l"
exec 3>&-
```

## Un cliente que se queda conectado: `nexo-dbus`

`nexo-dbus` es un buen ejemplo de cliente persistente (el `nexo watch` del cliente de bash hace algo parecido): abre **una** conexión, envía `hello` con `"client":"nexo-dbus/0.4.0-beta2"`,
y se suscribe con `{"cmd":"subscribe","topics":["media","audio"]}`. Al suscribirse, la app manda el estado inicial de cada tema como eventos, y desde entonces `nexo-dbus` se mueve con ellos; `media.status` solo lo pide para recalibrar la posición (cada 10 s mientras suena).
Para el resto usa `media.play|pause|playpause|stop|next|prev`, `media.seek` (`delta_ms` o `position_ms`), `media.art` (por `art_hash`) y `audio.volume` (`percent`).
Manda un `ping` tras 20 s sin actividad (y da la conexión por muerta si no hay respuesta en 8 s: es lo que pasa cuando Android congela la app), reconecta con espera creciente (1 s hasta 15 s),
y si recibe `unauthorized` espera 30 s **releyendo el archivo de enlace** por si el token cambió (`nexo rekey`). Ignora los campos y eventos que no conoce. Detecta una app anterior a la 0.2 porque `minor` es menor que 2 o `media.status` no está en `commands`.

## Versionado

`proto` en la respuesta a `hello` es la versión mayor (1); `minor` es la revisión. Dentro de la versión 1 solo se añaden campos y comandos; un cliente debe ignorar lo que no conozca.
