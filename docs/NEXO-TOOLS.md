# nexo tools — archivos entre móviles (y entre cualquier Termux)

`nexo tools` (el programa `nexo-tools`, que viaja con Nexo desde la 0.4.0‑beta2) pasa y explora archivos **entre dispositivos de la misma red WiFi**: de un Termux a otro, de tu móvil a un PC con Linux, o a la inversa.
No necesita la app Nexo ni el puente: es un programa independiente (bash + python3 + openssl) que se integra con `nexo` para que sea un solo comando.
Es la versión 2.4 de tu `nexo-tools.sh` (la 2.3.0 era el punto de partida): conserva todo lo que ya hacía (servidor HTTPS, token, huella SHA‑256, `rsync`/SSH, menú, TUI) y añade lo que se pidió para la beta 2.

> **Estado honesto.** Todo se ha probado **con dos «dispositivos» simulados en una misma máquina** (cada uno con su propio `HOME`, su certificado y su estado, hablando por HTTPS de verdad) y el gestor web, en un Chromium sin pantalla.
> **No se ha probado entre dos móviles reales**, ni con los navegadores de Android, ni con tu router. Lo que depende de la red (el descubrimiento por difusión UDP, el aislamiento de clientes WiFi, el ahorro de batería de HyperOS) puede comportarse distinto: mira [Si algo no funciona](#si-algo-no-funciona).

---

## En un minuto

**Enviar un archivo a otro móvil** (el caso más corriente, sin copiar tokens ni huellas a mano):

```bash
# En el móvil que envía:
nexo tools send foto.jpg informe.pdf
#   → te da una IP y un código como  K3M9-7QWX-P2TB  y espera a que el otro lo baje (Ctrl‑C para cancelar)

# En el móvil que recibe (otro Termux, otra distro, un PC con nexo-tools):
nexo tools fetch 192.168.1.23 K3M9-7QWX-P2TB
```

`send` solo comparte **eso** que le dices (no ve el resto de tus carpetas), el código vale **una vez** y caduca a los 15 minutos (`--minutes`, `--uses` lo cambian).
Se queda esperando y te va contando lo que pasa (emparejado, descarga…); cuando el otro termine, **pulsa Ctrl‑C**: se cierra el servidor y se borran el código y la lista de lo compartido.
Puedes enviar carpetas enteras (`nexo tools send ~/proyecto`).

**Ver y bajar archivos de otro móvil** (un gestor del dispositivo remoto):

```bash
# En el móvil que comparte (solo lectura por defecto):
nexo tools server ~/storage/shared          # comparte la carpeta; otros móviles con Nexo lo encuentran en la red

# En el otro:
nexo tools discover                         # lista los móviles con Nexo que hay en la red
nexo tools pair                             # (en el que comparte) da un código de emparejamiento  XXXX-XXXX-XXXX
nexo tools connect 192.168.1.23 --code XXXX-XXXX-XXXX --name Tablet
nexo tools browse Tablet                    # explorador en la terminal
nexo tools web Tablet                       # o el gestor en el navegador
```

**Gestor de archivos en el navegador** (de este dispositivo o de uno emparejado):

```bash
nexo tools web --open
```

---

## Todos los comandos

Todo lo que sigue a `nexo tools` es de `nexo-tools`, con sus propias opciones (`--port`, `--json`, `--version`… no los interpreta el cliente `nexo`).
`nexo tools help` los enseña todos.

| Comando | Qué hace |
|---|---|
| `send ARCHIVO…` | Comparte SOLO eso, da un código de un solo uso (15 min) y espera hasta que pulses Ctrl‑C. `--minutes N`, `--uses N`, `--port`, `--name` |
| `fetch IP[:PUERTO] CÓDIGO` | Recibe lo que otro comparte con `send` (se empareja, baja y olvida). `-o CARPETA`, `--keep` (conserva el emparejamiento) |
| `server [CARPETA] [PUERTO]` | Comparte una carpeta por HTTPS. `--rw` permite escribir; `--name NOMBRE`; `--no-announce` no se anuncia en la red |
| `discover [-t SEG] [--json]` | Busca móviles con Nexo en la red (los que tienen `server` o `send` en marcha) |
| `pair [--rw] [--minutes N] [--uses N]` | Genera el código de emparejamiento de este dispositivo |
| `connect IP[:PUERTO] --code CÓDIGO [--name N]` | Se empareja con otro dispositivo y guarda su huella |
| `devices` · `forget NOMBRE` | Dispositivos emparejados / olvidar uno |
| `browse NOMBRE [--dest CARPETA]` | Explorador de terminal: navegar, marcar, bajar |
| `ls NOMBRE [RUTA] [--ext .jpg,.png] [--find 'a*\|b*'] [--types] [--json]` | Lista sin límite, con filtros y conteo por extensión |
| `get NOMBRE RUTA… [-o CARPETA] [--ext …] [--find …] [--all] [--overwrite\|--skip]` | Baja archivos o carpetas (reanudable, con SHA‑256) |
| `put NOMBRE ARCHIVO… [--to RUTA] [--overwrite]` | Sube (solo si el otro te dio escritura) |
| `mkdir` · `mv` · `rm NOMBRE …` | Crear carpeta, mover o renombrar, borrar (va a la papelera del otro: `.nexo-trash`) |
| `web [--rw] [--open] [NOMBRE]` | Gestor en el navegador |
| `authorized` · `revoke ID\|NOMBRE\|--all` | Quién puede entrar en ESTE dispositivo y quitarle el acceso |
| `status [--reveal]` · `stop` · `logs` · `doctor` | Estado, parar el servidor, registros, diagnóstico |
| `rotate-token` · `rotate-cert` | Cambiar el token de solo lectura; renovar el certificado (**obliga a emparejar de nuevo**) |
| `rsync-push` · `rsync-pull` | Sincronizar una carpeta por rsync/SSH (de la 2.3, sin cambios) |

Sin argumentos, `nexo tools` abre el menú (la opción **D** es la de dispositivos).

---

## Todas las carpetas, todas las extensiones

- El explorador **no limita por extensión ni por tamaño de listado**: se muestran todas las carpetas y archivos (también los ocultos, los vacíos, los que no tienen extensión, los de nombres con espacios o con caracteres raros).
  Las listas se paginan solas (hasta 200 000 entradas por carpeta; si hay más, lo dice).
- Para encontrar cosas en carpetas enormes: `--ext .jpg,.png,(none)` (filtra por extensión; `(none)` son los archivos sin extensión), `--find 'IMG_*|*.mp4'` (patrones sin distinguir mayúsculas), `--types` (cuántos archivos hay de cada extensión).
- `get --all` baja todo lo que coincida, carpeta por carpeta; sin `--overwrite` no pisa nada (los conflictos se guardan como copia), con `--skip` omite lo que ya existe.
- **Qué carpeta es «todas»**: la que compartes con `server CARPETA`. En Termux, `~/storage/shared` (tras `termux-setup-storage`) es el almacenamiento interno del móvil; en un Linux, tu `HOME` o `/`.
  Compartir `/` solo funciona en **solo lectura** y nunca muestra `/proc`, `/sys` ni `/dev`.
  **Ojo:** «todas» quiere decir todas las que Termux puede leer. Sin root, Android no le deja ver `Android/data` y `Android/obb` de otras apps (Android 11 o posterior) ni sus datos privados (`/data/data/…`); eso no lo ve ningún programa de Termux, tampoco este.
- Lo que nunca se sirve ni se escribe, aunque compartas la carpeta que lo contiene: el estado de `nexo-tools` (claves y tokens), `~/.ssh`, `~/.gnupg` y `~/.config/nexo`.
  (`NEXO_TOOLS_SHOW_SECRETS=1` lo desactiva; no lo hagas salvo que sepas muy bien por qué.)
- Los enlaces simbólicos se **muestran**, pero no se descargan (podrían apuntar fuera de la carpeta compartida) salvo `NEXO_TOOLS_ALLOW_SYMLINK_DOWNLOAD=1`.
- HTTPS no conserva enlaces simbólicos, duros ni archivos dispersos, ni los permisos: para copiar un árbol tal cual, usa `rsync-pull`.

---

## Emparejamiento y seguridad

**Cómo se confía en otro dispositivo**

1. Cada dispositivo se anuncia con un **certificado propio** (autofirmado). Quien se conecta guarda su **huella SHA‑256** la primera vez y desde entonces solo acepta ese certificado (*pinning*).
   Si la huella cambia, `nexo-tools` **no envía nada** y sale con el código 4.
2. El **código de emparejamiento** (12 caracteres, `XXXX-XXXX-XXXX`, sin letras que se confundan) se muestra en el dispositivo que comparte. Es de un solo uso (o `--uses N`), caduca (`--minutes`, 10 por omisión)
   y se invalida tras 5 intentos equivocados.
3. El código **no viaja**: cada lado demuestra que lo conoce con una prueba HMAC atada a la huella del certificado (en las dos direcciones). Un intermediario que ponga otro certificado no puede completar el emparejamiento.
4. Al terminar, el cliente recibe un **token propio de ese dispositivo**. El servidor guarda solo su hash SHA‑256 (`authorized` lo lista; `revoke` lo quita).

**Roles.** Por omisión todo es de **solo lectura**. La escritura exige las dos cosas: el servidor arrancado con `--rw` y un emparejamiento hecho con `pair --rw`. El token que imprime `server` (el de siempre) es **siempre de solo lectura**.

**Otras defensas**

- Tras 10 tokens malos en 60 s desde una misma IP, el servidor contesta 429 a esa IP (los tokens válidos no se ven afectados; mientras dura, tampoco deja emparejar).
- Los nombres de ruta se comprueban (nada de `..`, ni componentes que sean enlaces simbólicos al escribir); los nombres se limpian antes de anotarlos en el registro.
- Las subidas van a un archivo temporal y, si el cliente manda el SHA‑256 (`X-Nexo-SHA256`), el servidor lo comprueba antes de renombrar (422 si no coincide). Nunca pisa una carpeta ni un enlace.
- **Borrar no borra**: mueve a `.nexo-trash/FECHA/` dentro de la carpeta compartida. No se puede vaciar por la red.
- El gestor web usa una política `Content-Security-Policy` estricta (solo script propio, sin `inline`), enseña los nombres como texto (nunca como HTML) y solo muestra «en línea» imágenes, audio y vídeo; HTML, SVG, PDF y similares se **descargan**.
- Las descargas del navegador usan **tickets** de 10 minutos (el token no va en la URL).

**Lo que NO te protege**

- Quien tenga tu token de lectura/escritura (el del dispositivo emparejado) puede hacer lo que ese rol permita: trátalo como una contraseña (está en `~/.local/state/nexo-tools/known.json`, modo 600).
- El tráfico va cifrado, pero **el nombre del dispositivo y el puerto se anuncian en claro** por la red (para que `discover` funcione). `--no-announce` evita el anuncio.
- Un móvil con la pantalla apagada puede dejar de contestar (ahorro de batería): mira [Que Android no cierre la app](../README.md#que-android-no-cierre-la-app); en Termux ayuda `termux-wake-lock`.

---

## El gestor en el navegador

`nexo tools web` levanta (si hace falta) el servidor de este dispositivo y te da la URL `https://IP:8766/ui`. Desde el **navegador de otro móvil o de un PC** puedes explorar, buscar, filtrar por extensión, ver imágenes, audio y vídeo,
bajar archivos o carpetas y —solo con `--rw`— subir, crear carpetas, renombrar y borrar (a la papelera).

- El navegador avisará de que el **certificado no es de confianza** (es autofirmado, como debe ser): compara la huella que enseña con la que imprime `nexo tools status` y continúa.
- Se entra con el token (el de solo lectura que enseña `server`, o el de un dispositivo emparejado). Con `nexo tools web NOMBRE` se abre ya autenticado: el token va en el fragmento de la URL (`#t=…`), que **no se envía al servidor** y la página borra de la barra de direcciones.
- Verificado en un Chromium de escritorio y en una ventana de tamaño móvil. **No** se ha probado con Chrome, Firefox o el navegador de un móvil Android reales.

---

## La API HTTP (por si quieres otro cliente)

Todo va por HTTPS (TLS 1.2 o superior). Cabecera `Authorization: Bearer TOKEN` (salvo `pair`).

| Petición | Respuesta |
|---|---|
| `GET /api/ping` | `{"name":"NEXO-TOOLS","version":…,"protocol":2,"device":…,"id":…,"role":"ro"\|"rw","rw":bool,"selection":bool,"features":[…]}` |
| `GET /api/list?path=&offset=&limit=&ext=&glob=` | `cwd`, `parent`, `entries` (`name`, `path`, `kind` = `file`\|`directory`\|`symlink`\|`special`, `size`, `mtime`, `downloadable`), `offset`, `limit`, `total`, `has_more`, `truncated`, `ext_counts` |
| `GET /api/download?path=` | El archivo (admite `Range`; cabecera `X-Nexo-SHA256` si se pudo calcular) |
| `POST /api/ticket` `{"path":…,"inline":bool}` | `{"url":"/api/dl/ID","expires_in":600}` (sirve sin token; 10 minutos) |
| `POST /api/pair` | Emparejamiento con prueba HMAC (lo usa `connect`) |
| `PUT /api/upload?path=&overwrite=0\|1` | Sube el cuerpo (necesita `Content-Length`; `X-Nexo-SHA256` opcional) — solo rol `rw` |
| `POST /api/mkdir` `{"path":…}` · `/api/rename` `{"path":…,"to":…}` · `/api/delete` `{"path":…}` | Solo rol `rw` |
| `UDP 8767` (difusión) | `{"nexo":1,"app":"nexo-tools","name","id","port","rw","only","v"}` cada 2 s mientras el servidor está en marcha (a la difusión general, a la de la subred y a las direcciones de `NEXO_TOOLS_BEACON_TO`) |

Códigos: 400 (petición o ruta no válida), 401 (token), 403 (rol, ruta prohibida o enlace simbólico), 404, 409 (ya existe, o el archivo cambió mientras se bajaba), 413 (demasiado grande), 416 (rango no válido),
422 (SHA‑256 distinto), 429 (demasiados intentos; trae `Retry-After`), 503 (demasiadas descargas a la vez; trae `Retry-After`).

---

## Variables de entorno

Las de siempre (`NEXO_TOOLS_PORT`, `NEXO_TOOLS_DEVICE`, `NEXO_TOOLS_RW`, `NEXO_TOOLS_MAX_UPLOAD_BYTES`…, mira `nexo tools help`) y las nuevas de la 2.4:

| Variable | Para qué |
|---|---|
| `NEXO_TOOLS_DISCOVER_PORT` | Puerto UDP del anuncio (8767) |
| `NEXO_TOOLS_IP` | Fuerza la IPv4 que se anuncia y en la que escucha (útil con VPN o varias redes) |
| `NEXO_TOOLS_BEACON_TO` | Direcciones extra a las que anunciarse (separadas por comas) si tu router bloquea la difusión |
| `NEXO_TOOLS_SHOW_SECRETS=1` | Desactiva la lista de rutas prohibidas (no lo hagas) |
| `NEXO_TOOLS_ALLOW_SYMLINK_DOWNLOAD=1` | Permite bajar enlaces simbólicos |
| `NEXO_TOOLS_MAX_LIST` | Máximo de entradas por listado (200 000) |

`nexo tools` dentro de una **distro de proot** se anuncia con el nombre del móvil (se lo pregunta a la app Nexo) y no con `localhost`.

---

## Si algo no funciona

- **`discover` no encuentra nada.** La detección usa difusión UDP; muchos routers aíslan a los clientes WiFi («aislamiento AP», «red de invitados») o la bloquean, y algunos móviles no la entregan en segundo plano.
  Alternativa que siempre funciona: en el que comparte, `nexo tools status` te da su IP; en el otro, `nexo tools connect IP --code CÓDIGO`.
- **El móvil que comparte «desaparece».** Pantalla apagada + ahorro de batería. Desactiva el ahorro para Termux y usa `termux-wake-lock`.
- **«La huella cambió» (código 4).** El otro dispositivo renovó su certificado (`rotate-cert`) o no es quien dice. Verifica la huella por otro medio y vuelve a emparejar (`forget NOMBRE`, `connect …`).
- **Un navegador dice que la conexión no es privada.** Es normal con un certificado autofirmado; compara la huella (ver más arriba).
- **429.** Demasiados intentos con un token o un código malos desde tu IP; espera un minuto.
- **El puerto 8766 está ocupado.** `nexo tools server --port 9000` o `NEXO_TOOLS_PORT`.
- **Dentro de la distro falta algo.** `apt install python3 openssl` (o `pacman -S python openssl`); `nexo doctor` y `nexo tools doctor` lo dicen.

---

## Qué se ha probado y qué no

| | |
|---|---|
| ✅ Probado aquí | Servidor y cliente por HTTPS real entre dos «dispositivos» simulados (cada uno con su `HOME`): emparejamiento (código bueno, malo, gastado, caducado, 5 fallos), huella cambiada, descubrimiento por UDP, listados con filtros y paginación, descargas (rangos, reanudación, SHA‑256, conflictos, `--all`), modo escritura (subir, carpetas, renombrar, papelera, revocar), `send`/`fetch`, límite de intentos, rutas prohibidas, enlaces simbólicos, cliente TLS lento, y el gestor web en un Chromium sin pantalla. **175 pruebas de línea de comandos y HTTP (`tests/tools_tests.sh`) + 31 del navegador (`python3 tests/ui_tests.py`, con pantalla de móvil de 390 px y una sesión de solo lectura).** Esto prueba la página en un Chromium de escritorio; en los navegadores de Android no se ha probado. |
| ⚠️ Sin probar | Entre **dos móviles reales**; con el router de tu casa (difusión UDP, aislamiento de clientes); con los navegadores de Android; archivos de varios GB; sistemas de archivos FAT/exFAT de tarjetas SD y sus nombres (hay una variable, `NEXO_TOOLS_FAT_NAMES`, pensada para ello); ahorro de batería de HyperOS; IPv6. |
| ❌ No hace | Atravesar internet (solo la red local); sincronizar en los dos sentidos (usa `rsync`); conservar permisos, propietarios o enlaces (usa `rsync-pull`). |
