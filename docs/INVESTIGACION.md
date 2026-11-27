# Investigación técnica: terminal Linux en Android con `targetSdk 35`

> Actualizado: 2026-11-24. Este documento reemplaza las decisiones antiguas que proponían
> `targetSdk 28`. Chronox no baja el target y no requiere Termux ni otra app instalada.

## Qué aprendimos de proyectos existentes

| Proyecto/fuente | Diseño relevante | Conclusión para Chronox |
|---|---|---|
| [Termux PRoot package](https://github.com/termux/termux-packages/blob/master/packages/proot/build.sh) | Compila PRoot con `PROOT_UNBUNDLE_LOADER` como directorio de instalación y coloca el loader bajo `libexec/proot`. | `PROOT_UNBUNDLE_LOADER` no es el override runtime; no debe recibir una ruta a archivo desde la app. |
| [PRoot upstream/Termux](https://github.com/termux/proot) | PRoot sustituye la ejecución guest por su propio loader; el override de ejecución es `PROOT_LOADER`. | Empaquetar PRoot y su loader host para cada ABI. Ejecutar ambos desde `nativeLibraryDir`. |
| [Termux execution environment](https://github.com/termux/termux-packages/wiki/Termux-execution-environment) y [termux-exec](https://github.com/termux/termux-exec) | Android 10+ aplica restricciones de ejecución a archivos `app_data_file` con targets modernos; `dlopen` y `execve` no son equivalentes. | No ejecutar el binario invitado directamente desde `filesDir`; no confundir `dlopen` de un `.so` con permiso para `execve`. |
| [UserLAnd](https://github.com/CypherpunkArmory/UserLAnd) | App de Linux sin root basada en PRoot; sus guías históricas de Android preceden a las restricciones de target actuales. | Referencia útil para el ciclo de rootfs y PRoot, no evidencia suficiente de compatibilidad moderna por sí sola. |
| [Termoso PR #95](https://github.com/termoso/termoso/pull/95) | Propone PRoot/loader en `jniLibs`, target moderno y smoke test en emulador API 34. | Confirma la dirección de diseño; es una propuesta de integración, no una prueba de Chronox. |

## Arquitectura adoptada

1. **APK por ABI.** `libproot.so`, `libproot_loader.so`, `libtalloc.so` y
   `libandroid-shmem.so` están en `jniLibs/<abi>/`. Gradle usa `extractNativeLibs=true`
   y empaquetado legacy para que Android los instale en `ApplicationInfo.nativeLibraryDir`.
2. **Arranque host permitido.** Kotlin `ProcessBuilder` ejecuta `nativeLibraryDir/libproot.so`;
   el sistema ejecuta el host desde la ubicación instalada por Package Manager.
3. **Loader guest permitido.** Se exporta `PROOT_LOADER` con la ruta absoluta a
   `nativeLibraryDir/libproot_loader.so`. PRoot usa ese ejecutable para cargar los ELF del
   rootfs. No se ejecuta el ELF guest directamente mediante Android `execve` sobre `filesDir`.
4. **Variables distintas.** `PROOT_UNBUNDLE_LOADER` es un directorio fijado al compilar el
   PRoot de Termux; el override runtime es `PROOT_LOADER`. `PROOT_TMP_DIR` queda en datos
   privados escribibles para temporales; `LD_LIBRARY_PATH` incluye los JNI y el alias de SONAME.
5. **Sin QEMU para la misma arquitectura.** Los ABI soportados (arm64 y x86_64) usan un rootfs
   de la ABI correspondiente; PRoot + su loader proporcionan la mediación de ejecución. Añadir
   QEMU aquí duplicaba la capa de ejecución y ocultaba errores de empaquetado del loader.
6. **Fallo cerrado.** El empaquetador y CI deben fallar si no encuentran o no incluyen el loader;
   el diagnóstico de runtime no debe tratar un loader ausente como opcional ni anunciar éxito.

## Límites y aceptación

- La compilación, los tests Dart y la inspección ZIP no demuestran que SELinux permita el
  arranque, que PRoot pueda `ptrace` en cada kernel OEM, ni que el loader pueda iniciar el rootfs.
- Aceptación pendiente: instalar el APK en un dispositivo API 29+ arm64, instalar Debian/Ubuntu,
  y validar `uname -m`, `id`, `/bin/sh`, `apt` y un comando hijo; repetir en emulador x86_64.
- Deben adjuntarse a los resultados el modelo, versión de Android, `targetSdk`, ABI y logcat
  de cualquier fallo. No se marcará como soportado por inferencia desde una build CI.

## Referencias adicionales

- [Android 10 behavior changes: execute permission](https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission)
- [Termux technical notes on `system_linker_exec`](https://github.com/termux/termux-exec-package/blob/master/site/pages/en/projects/docs/technical/index.md)
- [PRoot documentation](https://proot-me.github.io/)
