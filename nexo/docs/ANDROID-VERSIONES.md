# Nexo y las versiones de Android

Nexo se compila con `minSdk 26` (Android 8.0) y `targetSdk 28` (Android 9) a propósito: ver [LIMITACIONES](LIMITACIONES.md#encender-y-apagar-wifi-y-bluetooth).
Esta tabla resume **qué cambia en cada versión de Android y qué hace Nexo al respecto**.

> **Honestidad sobre lo comprobado:** la versión 0.1 se probó en un móvil real con **Android 16 (SDK 36)** y HyperOS. Del resto de versiones, lo que sigue sale de la documentación de Android
> y de la lectura del código, **no de pruebas en cada versión**. Si algo no coincide en tu móvil, dínoslo (ver [CONTRIBUIR](CONTRIBUIR.md)).

| Android (API) | Qué cambia | Qué hace Nexo |
|---|---|---|
| **8.0 / 8.1** (26 / 27) | Mínimo de Nexo. Los servicios en primer plano se arrancan con `startForegroundService` y las notificaciones necesitan canal. | Usa ambos. |
| **9** (28) | Es el `targetSdk` de Nexo. Aparecen las restricciones a funciones no públicas («lista gris»): siguen permitidas a las apps que apuntan a 28. Límite de escaneos WiFi: 4 cada 2 min en primer plano. | `bt forget` y la batería de Bluetooth usan funciones no públicas por reflexión; fallan con elegancia. |
| **10** (29) | Las apps que apuntan a 29+ **no pueden** encender/apagar el WiFi ni leer las redes guardadas. Las actividades no se abren desde segundo plano. Aparecen los paneles de ajustes (`Settings.Panel`, p. ej. el de volumen). | Al apuntar a 28 conserva el control. Para «hace falta un toque» usa **notificaciones** (no abre pantallas de golpe) y, para el volumen, el panel de volumen. |
| **11** (30) | Visibilidad de paquetes (solo afecta a quien apunta a 30+). `BluetoothDevice.getAlias()` pasa a ser pública. | Sin efecto al apuntar a 28; lee el alias. |
| **12 / 12L** (31 / 32) | Permisos de Bluetooth nuevos (`BLUETOOTH_CONNECT`, `BLUETOOTH_SCAN`); `setAlias` es pública. Android puede negar el arranque de servicios en primer plano desde segundo plano. | La pantalla de permisos pide `BLUETOOTH_CONNECT` (a una app que apunta a 28 el sistema suele concedérselo solo, junto con `BLUETOOTH`; se pide por si acaso). `bt rename` funciona desde aquí. Si no puede arrancar solo, deja una notificación «Toca para encender el puente». |
| **13** (33) | Permiso de notificaciones en tiempo de ejecución. **«Ajustes restringidos»**: las apps instaladas desde un APK no pueden recibir el acceso a notificaciones hasta que el usuario lo permite. `NEARBY_WIFI_DEVICES` (inútil para quien apunta a menos de 33). `getAudioDevicesForAttributes` (qué salida suena). | Pide los avisos; explica el paso de «Permitir ajustes restringidos» en la app, en el README y en el error de `media`. Usa la API nueva para saber qué salida suena. |
| **14** (34) | Los servicios en primer plano deben declarar un tipo (solo para apps que apuntan a 34+). Las apps que apuntan a menos de 23 no se instalan. | Declara `connectedDevice` en el manifiesto y lo usa al arrancar el servicio. |
| **15** (35) | Mínimo de `targetSdk` 24 para instalar. | 28 queda por encima. |
| **16** (36) | Versión del móvil de pruebas (HyperOS 3). | Probado con la 0.1: leer WiFi y Bluetooth, comandos; el encendido directo depende de HyperOS. |

## Fabricantes

| Capa | Qué hay que saber |
|---|---|
| **Xiaomi / Redmi / POCO (HyperOS, MIUI)** | Congela apps en segundo plano. Imprescindible: batería «Sin restricciones», «Inicio automático», candado en recientes. Sin eso, el puente deja de contestar (código 12). El botón **Ahorro de batería** de la app lo explica. |
| **Samsung (One UI)** | Pon Nexo en «Apps sin restricción» (Batería › Límites de uso en segundo plano) y quítala de «Apps en reposo». |
| **Otros (OnePlus, Oppo, Vivo, Huawei…)** | Suelen tener su propio «Inicio automático» y gestor de batería. Mismo principio: sin restricciones, inicio automático permitido. |
| **Android «puro» / Pixel** | Lo normal es que baste con «Sin restricciones» en la batería. |

Los nombres de los menús cambian de una versión a otra; por eso la app abre directamente la pantalla de ajustes y no depende de rutas.
