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
bash tests/run_tests.sh              # todo (necesita bash, python3 y jq; ~80 s)
NEXO_TESTS_ONLY=dbus bash tests/run_tests.sh   # solo nexo-dbus y setup-dbus (~45 s)
python3 -I tests/check_contract.py . # solo el contrato app ↔ app simulada ↔ protocolo
```

Las pruebas de `nexo-dbus` (`tests/dbus_tests.sh`) usan un `dbus-daemon` de verdad y, como clientes independientes, `busctl` y `gdbus`; sin esos tres programas se omiten con un aviso
(en Debian/Ubuntu: `apt install dbus systemd libglib2.0-bin`; en Arch: `pacman -S dbus systemd glib2`).

`tests/fake_app.py` es una **app Nexo falsa** que implementa el protocolo entero: es la especificación ejecutable. El cliente se prueba contra ella (no hace falta móvil) y
`tests/check_contract.py` compara el código Kotlin de la app con ella y con `docs/PROTOCOLO.md`: lista de comandos, campos de cada respuesta, códigos de error, versiones, el formato del instalador.
Si cambias un lado y no el otro, esa comprobación te lo dice.

Las pruebas copian el cliente a un directorio temporal y lo ejecutan con `bash` explícito: no dependen del bit de ejecución (en Windows, con `core.filemode=false`, git no lo guarda).

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

`termux/bin/nexo-dbus` es un solo archivo, organizado de arriba abajo en: registro (`log`), códec del protocolo de D‑Bus (`Writer`, `Reader`, `build_message`, `parse_message`), modelo de objetos
(`Interface` con `.method()`, `.prop()` y `.signal()`), conexión al bus (`Bus`), enlace con la app (`Bridge`) y los servicios (`Mpris`; BlueZ y NetworkManager irán igual). Para añadir una interfaz:

1. Si usa un tipo nuevo, añádelo a la lista de `tests/dbus_probe.py` y a las pruebas «tipos D‑Bus»: `busctl` tiene que devolver exactamente lo que se mandó.
2. Escribe el servicio como `Mpris`: crea las `Interface`, exporta los objetos con `bus.export(ruta, interfaz)`, pide el nombre con `request_name` (si ya lo tiene otro de verdad, queda en **modo pasivo**: no lo pisa) y emite `PropertiesChanged` al cambiar el estado.
3. Todo lo que hable con la app va con `slow=True` (se ejecuta en una cola aparte, para no bloquear la lectura del bus); la lectura de propiedades debe contestar al instante desde el estado en memoria.
4. Pruebas en `tests/dbus_tests.sh` con la app falsa: lee y escribe propiedades con `busctl` **y** con `gdbus`, ciclo de vida (app caída, bus reiniciado, nombre ya tomado).
5. El archivo debe seguir siendo válido para **Python 3.7** (hay una prueba de sintaxis) y usar solo la biblioteca estándar.

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
Una etiqueta `v*` (`git tag v0.3.0 && git push --tags`) hace que el workflow publique el APK en **Releases**.

## Estructura

Está en el README (sección «Desarrollo»). Lo más importante: `termux/bin/nexo` (cliente), `termux/bin/nexo-dbus` (servicios D‑Bus), `android/…/BridgeServer.kt` (servidor), `android/…/Commands.kt` (reparto de comandos),
`docs/PROTOCOLO.md` (contrato) y `tests/fake_app.py` (especificación ejecutable).
