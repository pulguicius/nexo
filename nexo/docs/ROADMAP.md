# Hoja de ruta

Estado: **v0.2.0**. Cada versión es independiente de las siguientes y deja Nexo usable. Lo marcado ✅ está hecho y comprobado como se indica en el README; lo demás es plan, no promesa.

| Versión | Entregable | Qué desbloquea | Estado |
|---|---|---|---|
| **0.1** | WiFi y Bluetooth por línea de comandos; instalador; distros de proot | `nexo status`, `wifi`, `bt`, `watch`, barras básicas | ✅ probada en móvil real |
| **0.2** | Formatos de salida (`--polybar --i3status --qml --dunst --tmux --starship --csv`), `audio`, `media`, `bt forget/rename/info`, `wifi saved/forget/reconnect`, `doctor --fix`, auto-recuperación | Cualquier barra o script que ejecute un comando | ✅ cliente y contrato comprobados · ⚠️ app sin probar en móvil |
| **0.3** | `nexo-dbus` con **MPRIS**: la música del móvil como un reproductor más | `playerctl`, widgets de música de Waybar/Polybar/Quickshell, KDE, GNOME | 🕓 siguiente |
| **0.4** | `nexo-dbus` con **BlueZ** (solo `Adapter1` y `Device1`) | `bluetoothctl`, Blueman, applets de Bluetooth | 🕓 |
| **0.5** | `nexo-dbus` con **NetworkManager** | `nmcli`, `nm-applet`, applets de red | 🕓 |
| **0.6** | Notificaciones (protocolo 1.3): móvil → escritorio y escritorio → móvil | `org.freedesktop.Notifications` en la distro | 🕓 |
| **0.7** | Empaquetado (AUR, `.deb`, `.rpm`, `APKBUILD`) y CI completo | Instalar en cualquier distro con su gestor de paquetes | 🕓 |
| **0.8** | `nexo setup-guests --with-dbus`, `doctor --fix` ampliado, documentación completa | Instalación «en un paso» | 🕓 |
| **1.0** | Todo estable, pruebas de la app (Robolectric), README reescrito, F‑Droid | «Universal» | 🕓 |
| **2.0** | (Futuro) Root/Magisk: conectar Bluetooth de verdad, redirigir audio, IP estática | Lo que Android bloquea | 💭 idea |

## Decisiones de diseño

- **`nexo-dbus` en Python**: más rápido de escribir y de depurar; si crece o hay que quitar la dependencia, se migrará a Go. Mientras tanto es **opcional**: el CLI no lo necesita.
- **Un daemon por distro**: cada proot tiene su propio bus. Arranca con la sesión del usuario (no con la distro, porque no hay systemd de sistema en proot).
- **MPRIS con metadatos completos** (`xesam:album`, `mpris:artUrl`, `mpris:length`…): cuesta lo mismo y desbloquea más.
- **BlueZ: solo `Adapter1` y `Device1`.** No se emula `Media1` ni `Network1`: lo que Android no deja hacer, no se finge.
- **NetworkManager: campos completos** (puntos de acceso, conexiones) y `ActivateConnection` real. Es lo que más consumen las barras.
- **Modo pasivo**: si en la distro ya existe un NetworkManager o un BlueZ de verdad, `nexo-dbus` **no** los suplanta (se puede forzar con `NEXO_DBUS_FORCE=1`).
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
