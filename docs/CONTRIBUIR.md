# Cómo colaborar en Nexo

Gracias por querer ayudar. Esta guía cubre lo práctico: cómo correr las pruebas, cómo añadir un comando, cómo añadir un formato de salida y cómo compilar y firmar el APK.
Si solo quieres informar de un fallo, abre un *issue* con la salida de `nexo doctor` y `nexo version --check` (no llevan el token).

## Reglas del proyecto

- **Texto para el usuario en español** (mensajes, ayuda, documentación). Los nombres de comandos, campos del protocolo y códigos de error van en inglés.
- **Honestidad ante todo:** si algo no se ha probado en un móvil real, la documentación y el README lo dicen. No se marca como «hecho» lo que solo compila.
- **Sin dependencias en el móvil**: el cliente es bash (jq es opcional) y la app no usa librerías de terceros. No se añade telemetría, anuncios ni accesos a internet.
- **Saltos de línea LF** siempre (`.gitattributes` lo fuerza): un script con CRLF no arranca en Termux.
- Quien tiene el token no debe verlo en ningún registro, mensaje de error ni salida: hay pruebas para eso; no las quites.

## Correr las pruebas

```bash
bash tests/run_tests.sh              # todo (necesita bash, python3 y jq; ~3 min)
NEXO_TESTS_ONLY=dbus bash tests/run_tests.sh   # solo nexo-dbus y setup-dbus
python3 -I tests/check_contract.py . # solo el contrato app ↔ app simulada ↔ protocolo
python3 -I tests/ui_tests.py         # el gestor web de nexo-tools en un Chromium sin pantalla (pip install playwright; playwright install chromium); sale con 77 si no hay navegador
```

Para repetir solo una parte de `nexo-dbus` (con `NEXO_TESTS_ONLY=dbus`): `NEXO_TESTS_DBUS_PART=mpris|system` (el reproductor, o BlueZ y NetworkManager),
y dentro de `system`, `NEXO_TESTS_SYSTEM_ONLY=bluez|nm`. `NEXO_TESTS_DBUS=skip` se salta todo lo que necesita un bus real.

Las pruebas de `nexo-dbus` (`tests/dbus_tests.sh`) usan un `dbus-daemon` de verdad y, como clientes independientes, `busctl` y `gdbus`; sin esos tres programas se omiten con un aviso
(en Debian/Ubuntu: `apt install dbus systemd libglib2.0-bin`; en Arch: `pacman -S dbus systemd glib2`).

`tests/fake_app.py` es una **app Nexo falsa** que implementa el protocolo entero: es la especificación ejecutable. El cliente se prueba contra ella (no hace falta móvil) y
`tests/check_contract.py` compara el código Kotlin de la app con ella y con `docs/PROTOCOLO.md`: lista de comandos, campos de cada respuesta, códigos de error, versiones, el formato del instalador.
Si cambias un lado y no el otro, esa comprobación te lo dice.

Las pruebas copian el cliente a un directorio temporal y lo ejecutan con `bash` explícito: no dependen del bit de ejecución (en Windows, con `core.filemode=false`, git no lo guarda).
Pasan igual **como root y como usuario normal** (sin `sudo`): si añades una prueba, no supongas ninguno de los dos. Los sockets de D‑Bus tienen un límite de unos 100 caracteres en su ruta: si cambias `TMPDIR`, que sea corto (p. ej. `/tmp/x`).

Para comprobar que el Kotlin compila sin Gradle (sin SDK completo) basta `kotlinc` con `android.jar` en el classpath; la compilación de verdad la hace el workflow de GitHub (`.github/workflows/build.yml`).

## Añadir un comando nuevo

Ejemplo: `audio balance`. El orden que evita que se descuadre todo:

1. **Protocolo** (`docs/PROTOCOLO.md`): describe la petición, la respuesta y los errores nuevos. Si el cambio es compatible hacia atrás, sube `MINOR` (y `CLIENT_MINOR` en el cliente cuando lo use).
2. **App simulada** (`tests/fake_app.py`): añade el comando a `NEW_COMMANDS` y su rama en `dispatch()`. Ahora la «especificación» ya lo tiene.
3. **App Android**: método en el manejador que toque (`WifiHandler`, `BluetoothHandler`, `AudioHandler`, `MediaHandler`…), nombre en `Commands.NAMES` y rama en `Commands.handle()`.
   Los errores se lanzan con `CmdException("código", "mensaje en español")`; si Android no deja hacerlo solo, `UserAction.open(...)` + `needs_user_action` (con `opens`). Usa solo APIs ≤ 35 (la de `compileSdk`).
4. **Cliente** (`termux/bin/nexo`): la función del comando, su línea en `help`, y —si muestra un estado— su vista en `JQ_LIB`. Los comandos que **no** se pueden repetir sin riesgo (cambian algo relativo: «+5», «siguiente») ponen `NO_RETRY=1`.
5. **Pruebas** (`tests/run_tests.sh`): éxito, error, argumentos malos, y —si cambia algo— que NO pase en una app antigua (`--old`) con un mensaje claro.
6. Corre `bash tests/run_tests.sh`. Si el contrato falla, el mensaje dice qué falta en qué lado.

## Añadir un servicio D‑Bus a `nexo-dbus`

`termux/bin/nexo-dbus` es un solo archivo, organizado de arriba abajo en: registro (`Log`), códec del protocolo de D‑Bus (`Writer`, `Reader`, `Message`), modelo de objetos
(`Interface` con `.method()`, `.prop()` y `.signal()`; `Tree` para el `ObjectManager`), conexión al bus (`Bus`), enlace con la app (`Bridge`) y los servicios:
`Mpris` (bus de sesión) y, sobre la base `NameService`, `Bluez` y `NetworkManager` (bus del sistema; `SYSTEM_SERVICES` los lista). `Daemon` da a cada servicio **su propia conexión** al bus (`Slot`): un fallo de uno no arrastra al otro. Para añadir un servicio:

1. Si usa un tipo de D‑Bus nuevo, añádelo a la lista de `tests/dbus_probe.py` y a las pruebas «tipos D‑Bus»: `busctl` tiene que devolver exactamente lo que se mandó.
2. Hereda de `NameService` y rellena `NAME`, `LABEL`, `TOPICS` (los temas de la app que necesita), `OM_PATH` y, si lo tiene, `SYSTEMD_UNIT`. Sobrescribe los ganchos: `_have_data` (¿hay algo que servir?), `_desired` (los objetos que deben existir ahora, con sus interfaces),
   `_on_acquired`/`_on_released`, `_on_tick` y `on_event` (los eventos de la app). La base se encarga de pedir el nombre, del **modo pasivo** (si ya lo tiene un programa de verdad, no lo pisa), de reintentar si el bus lo niega, de ceder si se lo reclaman y de emitir `InterfacesAdded/Removed`.
   Para un servicio de sesión como `Mpris`, mira cómo pide el nombre con `request_name` y cómo emite `PropertiesChanged`.
3. Todo lo que hable con la app va con `slow=True` (se ejecuta en una cola aparte, para no bloquear la lectura del bus); la lectura de propiedades debe contestar al instante desde el estado en memoria.
   Lo que no se pueda hacer sin un toque en el móvil devuelve el error `org.nexo.Error.NeedsUserAction`; lo que no se pueda hacer nunca, `org.freedesktop.DBus.Error.NotSupported` (con un texto que diga por qué).
4. Pruebas: `tests/dbus_tests.sh` (sesión) o `tests/dbus_system_tests.sh` (sistema) con la app falsa: lee y escribe propiedades con `busctl` **y** con `gdbus`, ciclo de vida (app caída, bus reiniciado, nombre ya tomado, política que lo niega) y un bus **de verdad** (`dbus-daemon`), no un simulacro.
5. Si el servicio ocupa un nombre en el bus del sistema, añade sus líneas `<allow own=…/>` y `<allow send_destination=…/>` en `dbus_policy_text` del cliente (`termux/bin/nexo`) y una prueba contra el bus estricto (hay una en `tests/dbus_system_tests.sh`).
6. El archivo debe seguir siendo válido para **Python 3.7** (hay una prueba de sintaxis) y usar solo la biblioteca estándar.

## Añadir un formato de salida (preset)

Todo formato sale de un **modelo de vista** común en jq (`JQ_LIB` en el cliente): por cada tema (`wifi`, `bt`, `audio`, `media`) calcula `state`, `short`, `long`, `tip`, `pct`, `icon`, `glyph`, `color` y `active`.
Para añadir, por ejemplo, `--eww`:

1. En `JQ_LIB`, rama nueva en `out($p)` (`elif $p == "eww" then ...`) que construya el texto o JSON a partir de ese modelo.
2. En `main()`, la opción: `--eww) FMT=eww ;;`; si es de barra (no debe fallar nunca), añádelo a `is_bar()`.
3. Una línea en `help` y en la tabla del README.
4. Pruebas: salida normal, con la app apagada (una barra debe mostrar «offline», no un error) y con caracteres raros (`ñ`, comillas).

Reglas del jq: debe funcionar con **jq 1.6** (siempre `else`, sin `pick` ni `abs`), y los iconos Nerd Font van como secuencias UTF‑8 octales porque el script fija `LC_ALL=C`.

## Compilar y firmar el APK

```bash
cd android
export ANDROID_HOME=/ruta/al/sdk       # plataforma 35
./gradlew assembleRelease              # → app/build/outputs/apk/release/app-release.apk
```

Sin firma propia el APK se firma con una clave de depuración **distinta en cada compilación**: para actualizar habría que desinstalar la anterior. Con firma propia, cada versión se instala encima:

```bash
keytool -genkeypair -v -keystore nexo.jks -alias nexo -keyalg RSA -keysize 2048 -validity 10000
gh secret set NEXO_KEYSTORE_BASE64   < <(base64 -w0 nexo.jks)
gh secret set NEXO_KEYSTORE_PASSWORD            # la contraseña del almacén
gh secret set NEXO_KEY_ALIAS                    # nexo
gh secret set NEXO_KEY_PASSWORD                 # la misma contraseña (con PKCS12 coinciden)
```

Guarda `nexo.jks` y su contraseña en un sitio seguro: sin ellos no podrás publicar actualizaciones que se instalen encima.
Para compilar en local con tu clave, define `NEXO_KEYSTORE`, `NEXO_KEYSTORE_PASSWORD`, `NEXO_KEY_ALIAS` y `NEXO_KEY_PASSWORD`.
Una etiqueta `v*` (`git tag v0.4.0-beta2 && git push --tags`; si la etiqueta lleva un guion, la Release se marca como versión preliminar) hace que el workflow publique el APK en **Releases**.

## Estructura

Está en el README (sección «Desarrollo»). Lo más importante: `termux/bin/nexo` (cliente), `termux/bin/nexo-dbus` (servicios D‑Bus), `android/…/BridgeServer.kt` (servidor), `android/…/Commands.kt` (reparto de comandos),
`docs/PROTOCOLO.md` (contrato) y `tests/fake_app.py` (especificación ejecutable).
