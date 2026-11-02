# Protocolo Nexo (versión 1)

Lo que hablan la app Android y los clientes (`nexo`, o el tuyo). Es deliberadamente simple para que se
pueda usar desde bash, Python, Node, QML o lo que tengas dentro de una distro.

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
{"id":"1","ok":true,"data":{"app":"nexo","version":"0.1.0","proto":1,"android_sdk":35,"target_sdk":28,"device":"Google Pixel 8","wifi":true,"bluetooth":true}}
```

`wifi` y `bluetooth` dicen si el móvil tiene esa radio. El token se muestra en la app y se guarda con `nexo pair TOKEN`
(archivo `config` con modo 600). Se invalida con «Token nuevo».

## Peticiones y respuestas

Petición: `{"id": <texto o número>, "cmd": "<comando>", ...parámetros al mismo nivel}`.
La respuesta repite el `id`.

```json
{"id":"7","ok":true,"data":{ ... }}
{"id":"7","ok":false,"error":"needs_user_action","message":"…","action":"notification","opens":"wifi_panel"}
```

### Códigos de error

| `error` | Significa |
|---|---|
| `unauthorized` | Falta `hello` o el token es incorrecto (se cierra la conexión) |
| `bad_request` | JSON inválido o faltan parámetros |
| `unknown_command` | Ese `cmd` no existe |
| `permission_denied` | Falta un permiso de Android; `permission` dice cuál cuando se sabe (`ACCESS_FINE_LOCATION`, `BLUETOOTH_CONNECT`) |
| `needs_user_action` | Android no deja hacerlo solo. La app dejó una **notificación** que abre el panel adecuado: la respuesta trae `"action":"notification"` y `"opens"` = `wifi_panel`, `bluetooth_enable` o `bluetooth_settings` |
| `wifi_disabled` / `bluetooth_disabled` | El comando necesita la radio encendida |
| `not_paired` | El dispositivo Bluetooth no está emparejado en Android |
| `unsupported` | Este móvil no tiene esa radio |
| `failed` | Android rechazó la operación |
| `internal` | Error inesperado de la app |

## Comandos

### Generales
| Comando | Parámetros | `data` |
|---|---|---|
| `hello` | `token`, `client?` | información de la app (arriba) |
| `ping` | — | `{"pong":true,"t":<ms>}` |
| `subscribe` | `topics?` = `["wifi","bt"]` | `{"topics":[…]}`, y después un evento inicial por tema |
| `unsubscribe` | — | — |
| `bootstrap` | — | **No es JSON**: ver más abajo. No necesita token |

### WiFi
| Comando | Parámetros | `data` |
|---|---|---|
| `wifi.status` | — | `available, enabled, state, connected, ssid, ssid_hidden, bssid, rssi, level (0‑4), frequency, band, link_speed, ip, permission_location, location_enabled` |
| `wifi.enable` / `wifi.disable` | — | el estado resultante (espera hasta 4 s a que cambie) |
| `wifi.scan` | `fresh?` (true), `timeout_ms?` (4000; entre 500 y 15000) | `networks:[{ssid,bssid,rssi,level,frequency,band,security,secured}], fresh, hidden_count, hint?` |
| `wifi.connect` | `ssid`, `password?`, `hidden?` (false), `wait_ms?` (12000; máx. 30000) | `requested, network_id, ssid, connected, hint?` |
| `wifi.disconnect` | — | `{"requested":true}` |

- `state` es `enabled`, `enabling`, `disabling`, `disabled` o `unknown`. Si el móvil no tiene WiFi: `{"available":false}`.
- Con el WiFi apagado o sin conexión, `ssid`, `bssid`, `rssi`, `level`, `frequency`, `band`, `link_speed` e `ip` son `null`.
- `ssid` es `null` y `ssid_hidden` es `true` si Android lo oculta (falta el permiso de ubicación o la ubicación del sistema está apagada).
- `security` es `OPEN`, `OWE`, `WEP`, `WPA`, `WPA2` o `WPA3` (una red mixta WPA2/WPA3 aparece como `WPA3`).
- `wifi.scan` devuelve una entrada por nombre de red (la de señal más fuerte). `hidden_count` cuenta las redes sin nombre. `hint` solo viene si no hubo resultados.
  Android limita los escaneos (unos 4 cada 2 minutos): pasado el límite devuelve la lista anterior con `fresh:false`.
- `wifi.connect` sin `password` usa la red ya guardada en el móvil; si no existe, la crea como red abierta.
  Devuelve `connected:false` si pasado `wait_ms` no se confirmó la conexión (clave mala, sin cobertura…).
  Las redes que usan **solo** WPA3 no se pueden crear con la API que permite Android a una app normal: responde `needs_user_action` y abre el panel de WiFi.

### Bluetooth
| Comando | Parámetros | `data` |
|---|---|---|
| `bt.status` | — | `available, enabled, state, name, connected, bonded_count, permission_missing?` |
| `bt.enable` / `bt.disable` | — | el estado resultante (espera hasta 5 s) |
| `bt.paired` | — | `devices:[{name,address,connected,profiles,type,class}]` |
| `bt.connect` / `bt.disconnect` | `address` | ver abajo: siempre `needs_user_action` |

- `state` es `on`, `off`, `turning_on`, `turning_off` o `unknown`. `connected` es `true` si hay algún dispositivo conectado (audio, manos libres, teclado/ratón o BLE).
- En `bt.paired`: `profiles` puede incluir `a2dp`, `headset`, `hid` y `gatt`; `type` es `classic`, `le`, `dual` o `unknown`;
  `class` es `audio`, `phone`, `computer`, `peripheral`, `wearable`, `health`, `imaging`, `networking`, `toy`, `other` o `unknown`. `name` puede ser `null`.
- `bt.connect` / `bt.disconnect`: Android no deja que una app normal conecte o desconecte dispositivos Bluetooth. Tras validar `address`
  (`bad_request`), que el Bluetooth esté encendido (`bluetooth_disabled`) y que el dispositivo esté emparejado (`not_paired`),
  la app responde `needs_user_action` y deja una notificación que abre los ajustes de Bluetooth del móvil.

## Eventos

Tras `subscribe`, la app envía líneas **sin `id`**:

```json
{"event":"wifi","data":{ …igual que wifi.status… }}
{"event":"bt","data":{ …igual que bt.status… }}
```

Se juntan las ráfagas (300 ms) y no se emiten cambios de intensidad de señal. El cliente `nexo watch` envía un `ping` cada 30 s sin actividad
y reconecta solo si se corta.

## `bootstrap`: instalar el cliente sin internet

```json
{"cmd":"bootstrap"}
```

La app responde con **un script de bash en texto plano** (no JSON) y cierra la conexión. Contiene el cliente (en base64) y el instalador,
**nunca el token**. El comando de una línea que copia la app comprueba el **SHA‑256** del script antes de ejecutarlo; así, otra app que
se hubiera adelantado a ocupar el puerto no puede colarte código.

## Ejemplo mínimo con bash puro

```bash
exec 3<>/dev/tcp/127.0.0.1/8765
printf '%s\n' '{"id":"1","cmd":"hello","token":"TU_TOKEN"}' >&3;  read -r -t 5 l <&3; echo "$l"
printf '%s\n' '{"id":"2","cmd":"wifi.status"}'               >&3;  read -r -t 5 l <&3; echo "$l"
exec 3>&-
```

## Versionado

`proto` en la respuesta a `hello`. Dentro de la versión 1 solo se añaden campos y comandos; un cliente debe ignorar lo que no conozca.
