# nexo usb — pendrives, discos duros y SSD dentro de tu distro

Desde la 0.4.2 puedes conectar al móvil, con un cable OTG o con un hub, un pendrive, un disco duro o un SSD externo y **explorar y copiar sus archivos desde
Ubuntu, Arch, Debian…**: `nexo usb mounts`, `ls`, `get`, `put`, `cat`, `mkdir`, `rm`, `mv`, `df` y `eject`. La idea es la de enchufar un disco a un
ordenador, con la diferencia de que aquí **no hay un `mount`** (abajo se explica por qué) y que Android decide qué sistemas de archivos monta.

> **Estado, sin adornos.** Implementado: la parte de Android (lista de discos con `StorageManager`, acceso que concede el usuario con el selector de carpetas del
> sistema, operaciones sobre archivos con `DocumentsContract` y `ParcelFileDescriptor`, expulsión y avisos), el protocolo 1.4, `nexo usb` (los doce comandos de discos)
> y `nexo watch storage`. Probado: contra la **app simulada** (`tests/fake_app.py`, donde cada disco es una carpeta de verdad: más de 500 comprobaciones, entre ellas
> copias de archivos grandes, nombres raros, discos de solo lectura o llenos, desenchufar a media copia y la misma orden por dos caminos distintos comparando resultados),
> con **pruebas de las reglas en una JVM** (`StorageLogicTest.kt`: rutas, crear, borrar y renombrar, tabla de archivos abiertos) y con la compilación contra el SDK de
> Android. **No se ha probado todavía con un móvil ni con un disco de verdad**: ni el selector de carpetas, ni la lectura y escritura a través de Android, ni la
> expulsión, ni la velocidad. Para eso está [`tests/usb_storage_hardware_check.sh`](../tests/usb_storage_hardware_check.sh) (al final de esta página): lo ejecutas con
> tu disco conectado y me pasas el informe.
>
> Teclados, ratones y hubs siguen sin pasarse a la distro (solo salen en `nexo usb list`).

## En un minuto

```bash
nexo usb mounts                              # ¿qué discos montó Android y puede entrar Nexo?
nexo usb access                              # solo la primera vez: eliges el disco en el selector de Android → «Usar esta carpeta»
nexo usb ls -l /                             # mira dentro
nexo usb mkdir /Copias                       # crea una carpeta
nexo usb put -r proyecto /Copias/            # de tu distro al disco (queda en /Copias/proyecto)
nexo usb get -r /Documentos ~/documentos     # del disco a tu distro
nexo usb eject                               # antes de desenchufar
```

```
$ nexo usb mounts
ID         NOMBRE    ESTADO   ESPACIO                    NEXO PUEDE ENTRAR  RUTA EN ANDROID
1111-2222  MI DISCO  montado  8.0 GiB libres de 8.0 GiB  sí                 /storage/1111-2222
Listo para: nexo usb ls · get · put · cat · mkdir · rm · mv · df · eject

$ nexo usb put -r proyecto /Copias/
  proyecto/datos.bin → MI DISCO:/Copias/proyecto/datos.bin  (293.0 KiB)
  proyecto/main.c → MI DISCO:/Copias/proyecto/main.c  (26 B)
put: 2 archivos, 293.0 KiB en 0.1 s (5.0 MiB/s)

$ nexo usb ls -lh /Copias/proyecto
-w   293.0 KiB  2026-11-20 03:11  datos.bin
-w        26 B  2026-11-20 03:11  main.c

$ nexo usb eject
«MI DISCO» expulsado: ya puedes desenchufarlo.
```

(Esa salida es real, pero de la app simulada: con tu móvil verás tus discos y sus velocidades. En `ls -l`, `d` es carpeta y `w` quiere decir que se puede escribir.)

## Qué necesitas

- Un móvil con **USB host (OTG)** y un cable OTG o un hub. Un disco duro mecánico suele pedir más corriente de la que da el móvil: usa un hub con alimentación propia.
  En algunos Xiaomi/HyperOS hay un interruptor «OTG» en Ajustes → Ajustes adicionales que se apaga solo si no hay nada conectado.
- La app Nexo 0.4.2 o más nueva (protocolo 1.4 o más) y el cliente de la misma versión en Termux (`nexo version --check` lo comprueba). Para usarlo **dentro de una distro**: `nexo setup-guests --with-usb`
  (copia `nexo-usb` y necesita `python3` en la distro; `nexo usb mounts` funciona hasta sin Python, pero solo ese y `list`).
- Un disco que **Android monte**. Casi todos los móviles montan FAT32 y exFAT; NTFS y ext4 dependen del móvil. Android no dice qué sistema de archivos tiene un disco ni si es
  USB o tarjeta, así que Nexo tampoco puede decirlo. Si el disco sale en `nexo usb mounts` con un estado distinto de `montado`, la tabla explica qué le pasa
  (`no se puede montar`, `sin sistema de archivos`…) y qué hacer.

## Cómo funciona (y por qué no es un `mount`)

Una distro de proot **no puede** abrir `/dev/bus/usb`, ni ver `/dev/sda`, ni montar nada: no es root y el kernel es el de Android. Pero Android sí monta los discos USB por su
cuenta y se los enseña a las apps con el **Storage Access Framework** (el selector de carpetas del sistema). Así que Nexo hace de puente:

```
 Android                                                                 127.0.0.1:8765              Termux / tu distro
 vold monta el disco ───► StorageManager (qué discos hay)
 tú eliges el disco en el selector ──► permiso que Android recuerda (SAF)
 DocumentsContract + lectura/escritura por posición ◄──► storage.*  (JSON, datos en base64) ◄──►  nexo usb ls · get · put · cat · …
```

Nexo **no pide «acceso a todos los archivos»**: solo tiene lo que tú le concedes, disco por disco, en el selector, y lo puedes quitar con `nexo usb access --revoke`. Consecuencias:

- `lsblk`, `mount`, `/dev/sda1`, `df` y `ls /mnt/…` de la distro **no ven el disco**. La forma de llegar a él es `nexo usb …`. Para llevarlo a un programa de la distro,
  una tubería sirve: `nexo usb cat /Copias/copia.tar | tar xf -`.
- No hay carpeta que se pueda abrir con un gestor de archivos de Linux. Copiar es `get` y `put`; el explorador interactivo es una idea para más adelante (ver [ROADMAP](ROADMAP.md)).
- Las lecturas y escrituras viajan por el TCP local en trozos (48 KiB al leer, 32 KiB al escribir, tres peticiones a la vez). Es más lento que un disco de verdad; **la velocidad real en un móvil
  no se ha medido** (el informe de `tests/usb_storage_hardware_check.sh --speed` la mide por ti).

## Comandos

| Comando | Qué hace |
|---|---|
| `nexo usb mounts [--all] [--json] [--wait S]` | Los discos que Android montó: estado, espacio y si Nexo ya puede entrar. `--all` muestra también los que Android marca como primarios (se ocultan por omisión). `--wait S` espera hasta S segundos a que enchufes uno. |
| `nexo usb access [DISCO] [--revoke] [--timeout S]` | Abre en el móvil el selector de carpetas de Android para dar acceso a un disco (una vez por disco; Android lo recuerda). `--revoke` lo quita. |
| `nexo usb ls [-lahR] [RUTA…]` | Lista carpetas: `-l` detalle, `-a` ocultos, `-h` tamaños legibles, `-R` recursivo, `--json`. |
| `nexo usb stat RUTA…` | Tipo, tamaño, fecha, si se puede escribir y tipo MIME. |
| `nexo usb cat RUTA…` | Escribe archivos del disco en la salida estándar (para tuberías). |
| `nexo usb get [-rfn] [--verify] ORIGEN… DESTINO` | Copia del disco a tu distro. Conserva la fecha de modificación. |
| `nexo usb put [-rfn] [--verify] [--fix-names] ORIGEN… DESTINO` | Copia de tu distro al disco. |
| `nexo usb mkdir [-p] RUTA…` | Crea carpetas (`-p`: también las de en medio, y no falla si ya existen). |
| `nexo usb rm [-rfv] RUTA…` | Borra: `-r` carpetas con todo lo que llevan, `-f` ignora lo que no existe. La raíz del disco no se borra. |
| `nexo usb mv [-fv] ORIGEN… DESTINO` | Renombra o mueve, **dentro del mismo disco** (entre discos: `get` y `put`). `-f` sustituye lo que haya. |
| `nexo usb df [DISCO] [--all] [--json]` | Espacio total, usado y libre. |
| `nexo usb eject [DISCO]` | Cierra los archivos abiertos y le pide a Android que expulse el disco. |

Opciones comunes: `--vol DISCO` (qué disco), `--via app|direct|auto` (ver más abajo), `--no-ask` (no abrir el selector de Android si falta el acceso), `--timeout S` (cuánto esperar
a que lo elijas: 120) y `--json` en `mounts`, `access`, `ls`, `stat`, `df`, `eject`, `get` y `put`.

Códigos de salida: 0 bien · 1 error (en `get`/`put`: algún archivo falló) · 2 uso · 3 hace falta un toque en el móvil (el selector) · 4 no hay disco (o no está montado) · 5 se desenchufó ·
10 la app no responde · 11 token · 12 sin respuesta a tiempo · 141 la tubería de `cat` se cerró (como cualquier programa).

### Qué disco y qué ruta

- Una **ruta** empieza en la raíz del disco: `/Música/rock`. Con el disco delante: `PENDRIVE:/Música` (su nombre o su UUID; si el nombre lleva espacios, entre comillas: `"MI DISCO":/Música`).
- Sin indicar disco se usa el **único disco USB montado**. Si hay varios: `--vol NOMBRE|UUID`, o el prefijo `NOMBRE:`. El nombre puede ser el UUID, la etiqueta, el principio de cualquiera
  o un trozo (`1111`, `mi`), mientras sea único; si no, te dice cuáles encajan.
- Un `:` antes de la primera `/` marca el disco (`PENDRIVE:/ruta`); por eso un nombre que lleve `:` tiene que empezar por `/`: `nexo usb ls /a:b`.
- Las rutas llevan la barra `/`, nunca `..`, y los nombres no pueden pasar de 255 bytes.

### Copiar con `get` y `put`

- Si el destino **ya existe**, es un fallo (`Ya existe en el disco … (usa -f para sustituirlo, o -n para saltarlo)`: se cuenta, se sigue con lo demás y el código de salida final es 1).
  `-f` lo sustituye; `-n` lo salta sin quejarse.
- `-r` copia carpetas, con la semántica de `cp -r`: si el destino **no existe**, pasa a ser la copia (`put -r proyecto /Copias` crea `/Copias` con el contenido de `proyecto`); si **existe**,
  la carpeta entra dentro (`/Copias/proyecto`). Un origen que es carpeta y **acaba en `/`** copia lo de dentro y no la carpeta (como `rsync`): `nexo usb put -r proyecto/ /Copias`.
- La carpeta de destino de un `put` tiene que existir (`mkdir` o `mkdir -p`); `put archivo /Carpeta/` con la carpeta ausente falla, como `cp`.
- Un archivo se escribe con un nombre provisional (`.nexo-part-PID-N`) y se **renombra al terminar**: nunca aparece a medias con su nombre de verdad. Si se corta la conexión con la
  app justo en medio, puede quedar un `.nexo-part-…` en el disco (bórralo con `nexo usb rm`).
- `--verify` vuelve a leer lo copiado y compara SHA‑256. Ojo: Android puede servir esa relectura desde su caché, así que es una comprobación útil pero no definitiva del disco.
- `put` **no puede poner la fecha de modificación** (el Storage Access Framework no ofrece ninguna forma): el archivo queda con la hora de la copia. `get` sí la conserva.
- `put` omite los enlaces simbólicos (y lo dice). `--fix-names` cambia por `_` los caracteres que el disco no admite (abajo) en vez de fallar.
- Una copia que se queda sin espacio, o con el disco en solo lectura, o con el disco desenchufado, **se detiene** en seco (no sigue probando con el resto); un archivo que falla por otra causa
  (un nombre que no vale, un permiso) se anota y se continúa.

### Las reglas del propio disco

- **FAT32** no admite archivos de 4 GiB o más (`too_big`; el mensaje lo dice). exFAT, NTFS y ext4 no tienen ese límite.
- Los **nombres nuevos** no pueden llevar `" * : < > ? \` ni la barra vertical, ni acabar en punto o en espacio. Android los cambiaría por `_` sin avisar y el archivo acabaría con otro nombre,
  así que Nexo lo rechaza antes (o lo cambia él, con `put --fix-names`, y te lo cuenta). Lo que ya existe con esos nombres (en un disco ext4, por ejemplo) se lee, se mueve y se borra igual.
- FAT y exFAT **no distinguen mayúsculas**: `Foto.jpg` y `foto.jpg` son el mismo archivo (`ya existe`).
- `rm` sin `-r` no borra carpetas. Nexo **nunca borra recursivamente de una sola vez**: `rm -r` recorre el árbol y borra elemento a elemento (Android borraría una carpeta entera sin avisar).
- Un disco montado en **solo lectura** deja leer y copiar hacia fuera (`get`, `cat`, `ls`), pero no crear, escribir ni borrar (`solo lectura`).

### Expulsar antes de desenchufar

`nexo usb eject` cierra los archivos que haya abiertos en ese disco (vaciando antes lo escrito) y le pide a Android que lo expulse. **Una app normal puede no tener permiso para eso**: en ese caso Android
lo ignora sin avisar, así que `eject` mira el estado del disco unos segundos después y sale con 0 **solo si de verdad se expulsó**. Si no, te dice qué hacer a mano (el botón «Expulsar» de la
notificación del disco, o Ajustes → Almacenamiento) y sale con 1. Espera siempre a que acabe un `put` antes de desenchufar. Después de expulsarlo, el disco sigue en `nexo usb mounts` como `no montado`
hasta que lo desenchufes y vuelvas a enchufar.

### Aviso de cambios: `nexo watch storage`

```bash
nexo watch storage --pretty        # una línea por cambio:  disco → MI DISCO (montado)
nexo watch storage --event         # un evento con nombre por cambio, en JSON
```

```
{"type":"storage","event":"mounted","volume":"1111-2222","label":"MI DISCO","state":"mounted","readonly":false}
{"type":"storage","event":"access_granted","volume":"1111-2222","label":"MI DISCO"}
{"type":"storage","event":"removed","volume":"1111-2222","label":"MI DISCO"}
```

Los eventos son `mounted`, `present` (el disco estaba al empezar), `removed`, `unmounted`, `state` (cambió su estado: `checking`, `unmountable`, solo lectura…), `access_granted` y `access_revoked`.
`nexo watch` sin tema sigue mirando `wifi bt audio media`: `usb` y `storage` se piden por su nombre.

### Acceso directo (`--via direct`)

Si el proceso donde ejecutas `nexo usb` **ya puede ver la carpeta del disco** (`/storage/1111-2222`: con root, con Shizuku/`rish`, o en un Android que lo permita), `--via direct` trabaja sobre
esa ruta sin pasar por la app, y `--via auto` (lo normal) elige ese camino solo si la carpeta existe y se puede leer. En un Termux sin privilegios **no se ve**, y se usa la app. Las dos rutas siguen las
mismas reglas y mensajes (las pruebas comparan sus resultados en unos 75 casos), pero la directa **solo se ha probado contra carpetas normales**, no con un disco de verdad. Nexo no integra todavía
Shizuku por su cuenta (ver [ROADMAP](ROADMAP.md)).

## Seguridad

- Android pide el acceso **por disco**, en su propio selector, y solo la app Nexo lo recibe. Nexo no entra en un disco sin que lo pidas con un comando y lo hayas concedido. La app solo acepta una carpeta
  **del propio disco** (rechaza cualquier otra) y, si eliges una subcarpeta en vez del disco entero, esa carpeta es la raíz: Nexo no puede salir de ella.
- Todo pasa por la conexión autenticada con el token de siempre. No se abre ningún servicio nuevo ni ningún puerto: no hay un servidor de archivos escuchando.
- Las rutas se validan en la app (no existe `..`, ni caracteres de control, ni nombres que se salgan del disco) además de en el cliente.
- Los archivos abiertos tienen tope (64 en total, 16 por conexión) y se cierran solos al irse el cliente, al desmontar el disco o al quitar el acceso.
- Un programa malicioso de tu móvil que conozca el token podría hacer lo mismo que `nexo usb` en los discos a los que Nexo tiene acceso (el token es el único candado, igual que con el resto del protocolo).
  Quita el acceso (`nexo usb access --revoke`) de los discos que no estés usando.

## Si algo no funciona

| Síntoma | Qué mirar |
|---|---|
| `nexo usb mounts` dice «No hay ningún disco USB» | El cable (¿es OTG y de datos?), el interruptor OTG de Xiaomi, la corriente (disco duro sin hub con alimentación). `nexo usb list` dice si Android ve el dispositivo aunque no lo monte. |
| El disco sale con estado `no se puede montar` o `sin sistema de archivos` | Android no entiende su formato (NTFS o ext4 en un móvil que no los monta) o está dañado. En un PC, cópialo y formatéalo en exFAT. |
| Sale `montado` pero `NEXO PUEDE ENTRAR` dice `no` | `nexo usb access` y elige el disco en el móvil. Código 3 = hace falta tu toque. |
| `access` no hace nada | La pantalla tiene que estar encendida; si el selector no se abre solo, tira de la notificación «Nexo: acceso al disco» o usa el botón «Dar acceso a un disco USB» de la app. |
| El selector no deja elegir el disco entero | Elige una carpeta del disco: Nexo trabajará dentro de ella (`scope` en `mounts --json`). |
| `Ya existe en el disco …` al copiar | Es el comportamiento normal: `-f` sustituye, `-n` salta. En FAT/exFAT las mayúsculas no cuentan. |
| `Los discos USB no admiten el carácter «:» en un nombre nuevo` | El nombre lleva algo que los discos USB no admiten: cámbialo, o `put --fix-names`. |
| `El sistema de archivos del disco no admite un archivo tan grande` | FAT32 y archivos de 4 GiB o más: formatea el disco en exFAT o parte el archivo (`split -b 4000M`). |
| `El disco está en solo lectura` | Android montó el disco de solo lectura (un NTFS sin cerrar bien, el interruptor de protección de un pendrive…). |
| `eject` dice que Android no lo dejó | Expúlsalo con el botón de Android; a partir de ahí se puede desenchufar. |
| «Se perdió la conexión con la app» (10) | La app Nexo se cerró o Android la durmió: `nexo doctor`. |

`nexo doctor`, `nexo logs 30` (lo último que anotó la app) y `nexo usb mounts --json` son lo primero que hay que mirar.

## Probarlo en tu móvil

Todo lo de arriba se probó contra una app simulada. Lo que falta es un móvil y un disco de verdad. [`tests/usb_storage_hardware_check.sh`](../tests/usb_storage_hardware_check.sh)
lo hace por ti: busca el disco, te pide el acceso si hace falta, crea **una carpeta propia** (`nexo-check-XXXX`) donde escribe archivos de distintos tamaños, nombres con acentos, espacios y emojis,
un árbol de carpetas, copia todo de ida y vuelta comparando SHA‑256, renombra, mueve y borra, comprueba que los nombres prohibidos se rechazan, y al terminar **borra su carpeta** y comprueba que no queda
nada. Opcionalmente mide la velocidad, prueba la expulsión y te pide desenchufar a media copia. Al final imprime un informe para copiar (sin tu token).

```bash
cd /storage/emulated/0/claude/nexo            # o donde tengas el repositorio
bash tests/usb_storage_hardware_check.sh --help
bash tests/usb_storage_hardware_check.sh                  # lo básico con el único disco montado
bash tests/usb_storage_hardware_check.sh --speed 64       # además, mide leer y escribir 64 MiB
bash tests/usb_storage_hardware_check.sh --eject --unplug # además, la expulsión y el desenchufado a media copia
bash tests/usb_storage_hardware_check.sh "MI DISCO" --big 4200   # (su nombre o su UUID) un archivo de 4,1 GiB: en FAT32 debe rechazarse
```

Para saber si todo va bien basta con que no salga ninguna línea `FALLA`. Si sale alguna, **pégame el informe entero**: lleva el estado del disco tal como lo ve Android, lo que contestó cada orden y
lo último de los registros. La prueba solo toca su carpeta `nexo-check-*` (y el `.nexo-part-*` de lo suyo): **no modifica ni borra nada más del disco**. Lo que **no** cubre: tu modelo concreto de disco
con cada hub, discos con cientos de miles de archivos, y el consumo de batería.

## Para quien programa

- El protocolo (`storage.status`, `storage.access`, `storage.revoke`, `storage.list`, `storage.stat`, `storage.open`, `storage.read`, `storage.write`, `storage.sync`, `storage.close`, `storage.mkdir`,
  `storage.delete`, `storage.rename`, `storage.eject` y el tema de eventos `storage`) está en [`PROTOCOLO.md`](PROTOCOLO.md#discos-usb-almacenamiento). La app simulada (`tests/fake_app.py`) es la especificación ejecutable.
- Android: `StorageLogic.kt` (las reglas, sin Android: probadas en JVM con un árbol en memoria en `StorageLogicTest.kt`), `StorageSaf.kt` (lo que toca el disco: `DocumentsContract` y `ParcelFileDescriptor`),
  `StorageVolumes.kt` (qué discos hay y a cuáles entra Nexo), `StorageGrantActivity.kt` (el selector de carpetas) y `StorageHandler.kt` (une todo y habla el protocolo).
- Cliente: `termux/bin/nexo-usb` (Python 3.7+, sin dependencias): dos *backends* con la misma interfaz, `AppFs` (por la app) y `DirectFs` (por la ruta, si este proceso la ve). Las pruebas son
  `tests/usb_storage_tests.sh` (se carga desde `tests/run_tests.sh`; `NEXO_TESTS_ONLY=storage bash tests/run_tests.sh` corre solo estas) y comparan los dos caminos entre sí.
- Para hablar con la app desde otro lenguaje, mira el ejemplo de bash puro de la sección del protocolo.

## Referencias

- Android: [Storage Access Framework](https://developer.android.com/guide/topics/providers/document-provider), [`DocumentsContract`](https://developer.android.com/reference/android/provider/DocumentsContract)
  y [`StorageManager`](https://developer.android.com/reference/android/os/storage/StorageManager).
- Android: [cambios de almacenamiento en Android 11](https://developer.android.com/about/versions/11/privacy/storage) (qué carpetas no deja elegir el selector).
- Android: [Descripción general del host USB](https://developer.android.com/develop/connectivity/usb/host) (la parte serie de Nexo; los discos no usan esa API, los monta el sistema).
