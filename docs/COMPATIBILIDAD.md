# Compatibilidad de dispositivos

Chronox AI ejecuta un rootfs Linux mediante PRoot empaquetado dentro del APK.
La app usa `targetSdk 35`: el proceso host arranca desde `nativeLibraryDir` y
PRoot ejecuta los ELF invitados mediante su loader nativo, también empaquetado
en `nativeLibraryDir`. No se ejecutan directamente ELF del rootfs desde `filesDir`.

Esta página resume qué funciona, qué no, y qué hacer en cada caso. La app tiene la
misma información en **Ajustes → Diagnóstico**, pero medida en *tu* dispositivo en
lugar de deducida.

---

## Resumen

| Requisito | Valor | Por qué |
|---|---|---|
| Android | **7.0 (API 24) o superior** | Es el mínimo del proyecto y donde `proot` funciona de forma fiable. |
| Arquitectura | **ARM64** (`arm64-v8a`) | El rootfs y los binarios de Termux se empaquetan para AArch64. `x86_64` solo para emuladores. |
| Ejecución | **PRoot + loader nativo** | `libproot.so` y `libproot_loader.so` se extraen del APK a `nativeLibraryDir`; el rootfs queda en almacenamiento privado y PRoot intercepta la ejecución. |
| Páginas de memoria | 4 KB o **16 KB** | Desde Android 15 hay dispositivos con páginas de 16 KB; los ELF deben estar alineados a ese tamaño. |

## Ejecución con `targetSdk 35`

Android 10+ bloquea `execve` directo de los archivos de `filesDir` para una app
con target moderno. Por eso **no** se usa `ProcessBuilder` sobre un binario del
rootfs ni se rebaja el target. La cadena soportada es:

1. El APK incluye `libproot.so`, `libproot_loader.so` y dependencias Bionic bajo
   `jniLibs/<abi>/`; Android las extrae a `ApplicationInfo.nativeLibraryDir`.
2. Gradle usa `useLegacyPackaging = true` y el manifiesto declara
   `extractNativeLibs="true"`; CI inspecciona el APK final y exige ambos ELF.
3. La app ejecuta `libproot.so` desde `nativeLibraryDir`, configura
   `PROOT_LOADER` con el loader instalado allí y `PROOT_TMP_DIR` en almacenamiento
   privado escribible. `PROOT_UNBUNDLE_LOADER` **no** es una variable runtime:
   Termux la fija al compilar PRoot como directorio de instalación.
4. PRoot intercepta los `execve` invitados y sustituye cada ELF por su loader,
   que carga el programa y sus bibliotecas del rootfs. No se usa QEMU para una
   distro de la misma arquitectura, ni se ejecuta directamente el ELF invitado
   mediante el kernel Android.

Esta arquitectura debe validarse con el APK instalado en dispositivos API 29+
(arm64 y emulador x86_64). La build/los tests no reemplazan esa prueba en hardware.
## Páginas de 16 KB (Android 15+)

Algunos dispositivos con Android 15, sobre todo con kernels 6.6+, usan páginas de
memoria de 16 KB. Un ELF alineado solo a 4 KB **no se puede cargar** ahí, y el
error es un `ENOEXEC` poco descriptivo.

Medidas adoptadas:

- El rootfs de Debian se compila con `-Wl,-z,max-page-size=16384`, así que sus
  binarios sirven en ambos casos.
- `tools/fetch_runtime.sh` **rechaza el build** si algún `.so` de proot no está
  alineado a 16 KB.
- La app lee `sysconf(_SC_PAGESIZE)` y vuelve a verificar la alineación del ELF
  instalado; si no cuadra, lo dice en el diagnóstico en lugar de fallar al
  arrancar el contenedor.

## Fabricantes con gestión agresiva de batería

No es un problema de permisos sino de política de ahorro: el sistema congela o
mata el proceso y con él `proot`. La app mantiene un servicio en primer plano con
`PARTIAL_WAKE_LOCK`, pero algunas ROMs lo ignoran si la app no está en la lista de
excepciones.

| ROM | Ajuste a cambiar |
|---|---|
| RedMagic OS (Nubia/ZTE) | Ajustes → Batería → Chronox AI → **Sin restricciones**; y en la pantalla de apps recientes, bloquear la app (candado). |
| MIUI / HyperOS (Xiaomi) | Ajustes → Apps → Chronox AI → Ahorro de batería → **Sin restricciones**; activar «Inicio automático». |
| ColorOS / realme UI (OPPO) | Ajustes → Batería → Optimización → Chronox AI → **No optimizar**. |
| One UI (Samsung) | Ajustes → Batería → Límites de uso en segundo plano → **Apps que nunca se suspenden**. |
| OriginOS / Funtouch (vivo) | Ajustes → Batería → Consumo en segundo plano → **Permitir**. |

La app abre directamente el diálogo del sistema correspondiente desde
**Ajustes → Diagnóstico → Sin restricciones de batería**.

## Matriz de dispositivos

Verificado en CI (compilación, tests y binarios); la columna «runtime» indica si
el contenedor puede arrancar según las reglas anteriores, no una prueba física.

| Dispositivo / caso | Android | Runtime | Notas |
|---|---|---|---|
| RedMagic 8S Pro | 15 | ✅ esperado | ARM64; ROM agresiva → configurar batería. |
| Pixel 6-9 | 13–15 | ✅ | Sin capas de fabricante. |
| Samsung Galaxy S21-S24 | 12–14 | ✅ | One UI: excluir de optimización. |
| Xiaomi / Redmi recientes | 12–14 | ✅ | HyperOS: activar inicio automático. |
| Cualquier ARM64 con Android 7–15 | 24–35 | ✅ | Requisito real: `untrusted_app_27` y binarios alineados. |
| Móvil de 32 bits (`armeabi-v7a`) | cualquiera | ❌ | No hay rootfs AArch64 para 32 bits. |
| Emulador x86_64 | cualquiera | ✅ | Compilar con `runtime_arch=x86_64`. |
| Android con páginas de 16 KB y binarios 4 KB | 15+ | ❌ | Bloqueado con mensaje claro en Diagnóstico. |

## Cómo comprobarlo en tu dispositivo

1. Instala el APK.
2. **Ajustes → Diagnóstico**.
3. La tarjeta superior dice si el contenedor puede ejecutarse, y debajo aparece el
   dato medido: dominio SELinux, si se permite ejecutar desde la app, tamaño de
   página y `targetSdk`.

Si sale «Android bloquea ejecutar programas de la app» con un dominio distinto de
`untrusted_app_27`, desinstala la app **por completo** (no basta con reinstalar) y
vuelve a instalarla: el dominio puede haber quedado fijado por una instalación
previa o por otra app con el mismo uid.
