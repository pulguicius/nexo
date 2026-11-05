# Protocolo Nexo (versión 1, revisión 2)

Lo que hablan la app Android y los clientes (`nexo`, `nexo-dbus`, o el tuyo). Es deliberadamente simple para que se
pueda usar desde bash, Python, Node, QML o lo que tengas dentro de una distro.

**Compatibilidad:** dentro de la versión 1 solo se añaden campos, comandos y temas de eventos. Un cliente debe ignorar lo que no
conozca, y una app nueva sigue atendiendo a los clientes viejos. La *revisión* (`minor` en `hello`) sube cuando se añade algo:

| `minor` | App | Novedades |
|---|---|---|
| 1 | 0.1.x | WiFi, Bluetooth, eventos, bootstrap |
| 2 | 0.2.x | audio, media, `wifi.saved/forget/reconnect`, `bt.forget/rename/info`, `logs`, `commands` en `hello`, `gateway/prefix/dns` en `wifi.status` |
| 3 | 0.6.x (previsto) | notificaciones: `notify.send`, `notify.close` y el tema de eventos `notif` |

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
{"id":"1","ok":true,"data":{"app":"nexo","version":"0.2.0","proto":1,"minor":2,"android_sdk":36,"target_sdk":28,"device":"Xiaomi 25078RA3EL","wifi":true,"bluetooth":true,"listener":false,"uptime_s":3120,"commands":["wifi.status","wifi.enable","…"]}}
```

- `wifi` y `bluetooth` dicen si el móvil tiene esa radio.
- `listener` dice si Android le dio a Nexo «acceso a notificaciones» (hace falta para `media.*` y `notif`).
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
| `not_found` | Lo que pides no existe: red guardada, salida de audio, sesión de medios, carátula |
| `unsupported` | Este móvil o esta versión de Android no tiene eso |
| `failed` | Android rechazó la operación |
| `timeout` | El comando tardó más de lo razonable (la app no se quedó colgada: contesta y sigue) |
| `rate_limited` | Solo para `bootstrap` (el instalador): se pidió demasiado seguido (máx. 1 cada 2 s y 10 por minuto en total). Se cierra la conexión; reintenta en unos segundos |
| `internal` | Error inesperado de la app |

## Comandos

### Generales
| Comando | Parámetros | `data` |
|---|---|---|
| `hello` | `token`, `client?` | información de la app (arriba) |
| `ping` | — | `{"pong":true,"t":<ms>}` |
| `subscribe` | `topics?` = `["wifi","bt","audio","media"]` | `{"topics":[…]}`, y después un evento inicial por tema |
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
```

Se juntan las ráfagas (300 ms) y no se emiten cambios de intensidad de señal ni de posición de la canción
(quien la necesite la extrapola con `position_ms` y `speed`, o la pide con `media.status`).
Sin `topics`, se suscribe a `wifi`, `bt`, `audio` y `media`. El cliente `nexo watch` envía un `ping` cada 30 s sin actividad
y reconecta solo (con espera creciente) si se corta.

## `bootstrap`: instalar el cliente sin internet

```json
{"cmd":"bootstrap"}
```

La app responde con **un script de bash en texto plano** (no JSON) y cierra la conexión. Contiene el cliente (en base64) y el instalador,
**nunca el token**. El comando de una línea que copia la app comprueba el **SHA‑256** del script antes de ejecutarlo; así, otra app que
se hubiera adelantado a ocupar el puerto no puede colarte código. La app limita la entrega (una cada 2 s, diez por minuto en total).

## Ejemplo mínimo con bash puro

```bash
exec 3<>/dev/tcp/127.0.0.1/8765
printf '%s\n' '{"id":"1","cmd":"hello","token":"TU_TOKEN"}' >&3;  read -r -t 5 l <&3; echo "$l"
printf '%s\n' '{"id":"2","cmd":"wifi.status"}'               >&3;  read -r -t 5 l <&3; echo "$l"
exec 3>&-
```

## Versionado

`proto` en la respuesta a `hello` es la versión mayor (1); `minor` es la revisión. Dentro de la versión 1 solo se añaden campos y comandos; un cliente debe ignorar lo que no conozca.
