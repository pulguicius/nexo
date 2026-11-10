# Hoja de ruta

Estado: **v0.4.0‑beta1** (la última versión cerrada es la 0.3.0). Cada versión es independiente de las siguientes y deja Nexo usable. Lo marcado ✅ está hecho y comprobado como se indica en el README; lo demás es plan, no promesa.

| Versión | Entregable | Qué desbloquea | Estado |
|---|---|---|---|
| **0.1** | WiFi y Bluetooth por línea de comandos; instalador; distros de proot | `nexo status`, `wifi`, `bt`, `watch`, barras básicas | ✅ probada en móvil real |
| **0.2** | Formatos de salida (`--polybar --i3status --qml --dunst --tmux --starship --csv`), `audio`, `media`, `bt forget/rename/info`, `wifi saved/forget/reconnect`, `doctor --fix`, auto-recuperación | Cualquier barra o script que ejecute un comando | ✅ cliente y contrato comprobados · ⚠️ app sin probar en móvil |
| **0.3** | `nexo-dbus` con **MPRIS**: la música del móvil como un reproductor más; `nexo setup-dbus`; `setup-guests --with-dbus` | `playerctl`, widgets de música de Waybar/Quickshell, KDE, GNOME | ✅ comprobada con un bus D‑Bus real (`busctl`, `gdbus`) · ⚠️ sin probar con `playerctl`/Waybar/… ni en móvil |
| **0.4.0** | `nexo-dbus` con **BlueZ** y **NetworkManager** (bus del sistema), `nexo setup-dbus --system-policy`, `nexo dbus status` por servicio; después, notificaciones móvil → escritorio y la red móvil (protocolo 1.3) | `bluetoothctl`, Blueman, `nmcli`, `nm-applet`, applets de red y Bluetooth; dunst, mako, swaync | 🚧 **beta 1** (BlueZ y NetworkManager: comprobados con `busctl`/`gdbus` contra un bus real · ⚠️ sin probar con `bluetoothctl`/`nmcli` ni en móvil) · beta 2: notificaciones y `net.status` |
| **0.4.1** | Puente USB serie para Arduino/ESP32 desde proot (un PTY que Nexo conecta al USB‑OTG del móvil) | `arduino-cli`, `esptool`, `screen`, `minicom` | 🕓 |
| **0.4.2** | Almacenamiento USB: `nexo usb list/mount`, UDisks2 emulado y Shizuku (`rish`) | gestores de archivos, `udisksctl` | 🕓 |
| **0.5** | Empaquetado (AUR, `.deb`, `.rpm`, `APKBUILD`) y CI completo | Instalar en cualquier distro con su gestor de paquetes | 🕓 |
| **0.6** | `nexo setup-guests --all`, `doctor --fix` ampliado, documentación de compatibilidad (`--with-dbus` ya existe desde la 0.3) | Instalación «en un paso» | 🕓 |
| **1.0** | Todo estable, pruebas de la app (Robolectric), README reescrito, F‑Droid | «Universal» | 🕓 |
| **2.0** | (Futuro) Root/Magisk: conectar Bluetooth de verdad, redirigir audio, IP estática | Lo que Android bloquea | 💭 idea |

## Decisiones de diseño

- **`nexo-dbus` en Python, sin librerías**: un solo archivo con su **propia implementación del protocolo de D‑Bus** (mensajes, tipos, autenticación, objetos). Se descartó `pydbus` (necesita GObject, está sin mantenimiento y no se podía probar aquí);
  la implementación propia se prueba contra `busctl` y `gdbus`, dos clientes independientes. Si crece o hay que quitar Python, se migrará a Go. Mientras tanto es **opcional**: el CLI no lo necesita.
- **Un daemon por distro**: cada proot tiene su propio bus. Arranca con la sesión del usuario (no con la distro, porque no hay systemd de sistema en proot):
  `nexo setup-dbus` deja un servicio de systemd de usuario si lo hay, el arranque automático del escritorio, o una línea en un script tuyo (`--launcher`).
- **MPRIS con metadatos completos** (`xesam:album`, `mpris:artUrl`, `mpris:length`…): cuesta lo mismo y desbloquea más. *(Hecho en la 0.3.)*
- **El reproductor solo existe mientras haya una sesión de medios en Android** (`NEXO_DBUS_ALWAYS=1` lo cambia): un reproductor muerto en `playerctl -l` confunde más de lo que ayuda.
- **BlueZ: `Adapter1`, `Device1` y `Battery1`** (más el `ObjectManager` y un `AgentManager1` que no hace nada). No se emula `Media1`, `Network1` ni GATT: lo que Android no deja hacer, no se finge.
  `Connect`/`Disconnect` devuelven `org.nexo.Error.NeedsUserAction` y la app deja una notificación que abre los ajustes; `StartDiscovery` solo enciende el Bluetooth (Nexo no busca dispositivos nuevos). *(Hecho en la 0.4.0‑beta1.)*
- **NetworkManager: campos completos** (puntos de acceso, conexiones, IP) y `ActivateConnection` real, que responde cuando Android confirma. Las claves guardadas no se pueden leer, así que `GetSecrets` va vacío. *(Hecho en la 0.4.0‑beta1.)*
- **Dos buses, dos conexiones**: MPRIS va al bus de sesión; BlueZ y NetworkManager al del sistema, cada servicio con su propia conexión, para que un fallo en uno no arrastre a los demás.
  Un bus del sistema de verdad exige una política (`nexo setup-dbus --system-policy`); en proot, `--own-bus` crea uno propio.
- **Modo pasivo**: si en la distro ya existe un NetworkManager o un BlueZ de verdad (o systemd los gestiona), `nexo-dbus` **no** los suplanta (se puede forzar con `NEXO_DBUS_FORCE=1`). *(Hecho en la 0.4.0‑beta1.)*
- **Notificaciones**: opcionales y con permiso explícito; el acceso a notificaciones se concede aparte y se puede quitar.
- **Root**: no en la 1.0; se documentará en `docs/ROOT.md` como opción futura.
- **Nombre**: se queda «Nexo».

## Lo que no va a llegar sin root

Conectar/desconectar Bluetooth a un dispositivo concreto, redirigir el audio del sistema a una salida, cambiar IP/DNS/proxy/MTU. Se documenta en [LIMITACIONES](LIMITACIONES.md); Nexo ofrece la notificación que abre el ajuste como alternativa.

## Ideas sin explorar

- Azulejo de Ajustes rápidos para encender y apagar el puente.
- Conectar dispositivos Bluetooth de verdad mediante ADB inalámbrico o Shizuku.
- Hotspot local (`startLocalOnlyHotspot`) para que la distro se pueda conectar al móvil sin pasar por un router (sin internet; sin compromiso).
- GATT/BLE genérico, WiFi Direct (API pública pero poco usada).
