# Investigación técnica — Chronox AI

> Fecha: 2026-11-23. Objetivo: determinar **la vía más robusta** para ejecutar un agente de
> codificación con terminal Linux real dentro de una app Flutter en Android, sin root.
>
> Cada afirmación relevante lleva su fuente. Las decisiones tomadas a partir de esto están
> en [`PLAN.md`](PLAN.md), marcadas como **DECISIÓN**.

---

## 0. Resumen ejecutivo (lo que cambió respecto al diseño inicial)

| Tema | Suposición inicial | Realidad verificada | Consecuencia |
|---|---|---|---|
| `proot` a usar | Binario estático de `proot-me/proot` v5.5.0 | Está enlazado a **glibc** (no corre en Android/bionic) y **no** trae las extensiones de Termux (`--link2symlink`, `--sysvipc`, `--kill-on-exit`) ni loader embebido utilizable | **DECISIÓN: usar la cadena de Termux** (`proot` 5.1.107.x + `libtalloc` + `libandroid-shmem` de los repos de Termux) |
| Distro | Alpine (4 MB) por rapidez | Alpine es **musl**: rompe binarios precompilados glibc, wheels manylinux, Ruby/Node nativos, DNS distinto y stack de hilos de 128 KB | **DECISIÓN: Debian es la distro por defecto** (ver §3) |
| Terminal | Pipes (`bash -i`) | Existe PTY real multiplataforma con soporte Android verificado | **DECISIÓN: `flutter_pty` (PTY nativo) + `xterm.dart`** |
| Extracción de rootfs | `tar.gz` con `archive` | El rootfs de Debian se publica como `tar.xz` en algunas fuentes; `dart:io` no tiene xz | **DECISIÓN: consumir la capa OCI de Docker Hub (`tar+gzip`)** → gunzip nativo de Dart, sin dependencias nativas |
| Páginas de 16 KB | No contemplado | Android 15+ puede arrancar con páginas de 16 KB y **todo ELF con `align < 2^14` falla** (`SIGBUS`/`ELF load failed`) | **DECISIÓN: verificar alineación en runtime y avisar** (§4) |
| targetSdk | 28 | Correcto y por la razón correcta, pero tiene coste: **incompatible con Google Play** | **DECISIÓN: targetSdk 28 para la build F-Droid/sideload**; rama Play Store separada (§2) |

---

## 1. Cómo se ejecuta un ELF desde una app Flutter (el problema raíz)

Desde Android 10 (API 29), SELinux aplica **W^X**: un proceso `untrusted_app` **no puede hacer
`execve()`** sobre ficheros con etiqueta `app_data_file` (todo lo que está bajo
`/data/data/<pkg>/`, es decir: `filesDir`, `cacheDir`, y todo lo que descarguemos).

* El dominio `untrusted_app_27` (apps con `targetSdk ≤ 28`) **conserva** `execute_no_trans`
  sobre `app_data_file`. Es una excepción de compatibilidad deliberada.
* Con `targetSdk ≥ 29` solo se permite `dlopen()` (cargar `.so`), no `exec()`.
* Termux mantiene `targetSdkVersion = 28` exactamente por esto, y por eso salió de Play Store.
* Fuente: [Android-Docs / app-data-file-execute-restrictions](https://github.com/agnostic-apollo/Android-Docs/blob/master/site/pages/en/projects/docs/apps/processes/app-data-file-execute-restrictions.md), [termux-app#4120](https://github.com/termux/termux-app/issues/4120), [proot#292](https://github.com/termux/proot/issues/292).

### Alternativas evaluadas

| Vía | Cómo funciona | Veredicto |
|---|---|---|
| **A. `targetSdk = 28`** | Se conserva `execve` sobre el directorio privado | ✅ **Elegida.** Es lo que hace Termux. Simple, sin hacks. Coste: no publicable en Play Store; en Android 14+ algunos OEM pueden subir el suelo de `targetSdk` aceptado |
| B. `nativeLibraryDir` | Empaquetar el binario como `lib*.so` en `jniLibs` → queda en `/data/app/.../lib/arm64/` con etiqueta `apk_data_file` (ejecutable) | Viable, pero solo para **pocos** binarios: el árbol de un rootfs Debian (miles de ELF) no puede empaquetarse así. **Sin embargo**, con `proot` como *único* ELF que necesita `execve` (ver §10), esto puede bastar |
| C. `system_linker_exec` | Ejecutar `/system/bin/linker64 <binario>` y parchear `execve` con `LD_PRELOAD` (`termux-exec`) | Funciona con `targetSdk ≥ 29`, pero **viola políticas de Play**, se puede romper en cualquier release, y añade una capa de interceptación que ya ha causado bugs (Android 14 obligó a interceptar toda la familia `exec()`) |
| D. Root / parchear SELinux | Escribir policy | ❌ Excluido: el objetivo es no requerir root |

**DECISIÓN:** vía A (`targetSdk 28`, `minSdk 24`). Documentar en el README que la app se
distribuye por F-Droid/GitHub Releases, no por Play Store. La vía C queda como *feature flag*
futuro para una build "Play" separada.

## 2. Qué `proot` usar y por qué no el de `proot-me`

* `proot-me/proot` v5.5.0 publica un `proot` **enlazado a glibc** → su `PT_INTERP` es
  `/lib64/ld-linux-aarch64.so.1`, que no existe en Android. No arranca.
* Termux compila su propio fork: `termux/proot` **5.1.107.102**, con:
  * extensiones: `--link2symlink`, `--sysvipc`, `--kill-on-exit`, `--kernel-release`, `-L`;
  * `PROOT_WITH_LIBANDROID_SHMEM=true` → depende de `libandroid-shmem` y `libtalloc`;
  * loader desempaquetado en `$PREFIX/libexec/proot` (`PROOT_UNBUNDLE_LOADER`), porque el
    loader embebido necesita escribirse a disco y eso choca con W^X.
  * build: `termux/termux-packages/packages/proot/build.sh` (verificado).
* Es **dinámico** contra libs de Termux → hay que aportar `libtalloc.so` y `libandroid-shmem.so`
  y apuntar `LD_LIBRARY_PATH` a nuestro directorio.
* **Flags canónicos** (extraídos de `proot-distro` 2026,
  `proot_distro/commands/login/proot_cmd.py`), en este orden:

```
proot
  --kill-on-exit
  --link2symlink
  --sysvipc
  --kernel-release=\Linux\<hostname>\<release>\<uname_m>\localdomain\-1\
  -L
  --change-id=<uid>:<gid>
  --rootfs=<rootfs> --cwd=<cwd>
  --bind=/dev --bind=/proc --bind=/sys
  [binds: /dev/random, storage, system paths, workspace]
  <comando>
```

`-L` corrige el `lstat` para los avisos de symlinks de `dpkg`; `--link2symlink` es
**obligatorio** para que `apt`/`dpkg` funcionen (emula hardlinks que el FS de Android no permite
entre directorios); `--kill-on-exit` evita procesos zombis tras cerrar la sesión.

**DECISIÓN:** descargar los `.deb` de Termux (`proot`, `libtalloc`, `libandroid-shmem`),
desempaquetarlos (formato `ar` + `tar.gz`, ambos soportados en Dart puro) en
`filesDir/runtime/usr/`, y ejecutar con `LD_LIBRARY_PATH=filesDir/runtime/usr/lib` y
`PROOT_UNBUNDLE_LOADER=filesDir/runtime/usr/libexec/proot`.

Repos a usar (con fallback, porque los mirrors caen):
`packages-cf.termux.dev`, `packages.termux.dev`, `mirrors.tuna.tsinghua.edu.cn/termux`,
`grimler.se/termux`.

## 3. Elección de distro: **Debian** (compatibilidad)

La pregunta era "la que presenta mejor compatibilidad en todo". La evidencia es consistente:

* El punto de fricción universal es **libc**: `musl` (Alpine) vs `glibc` (Debian/Ubuntu).
  Alpine rompe: binarios precompilados glibc, wheels `manylinux`, extensiones nativas de
  Python/Node/Ruby, `nokogiri`, `ffi`, DNS con EDNS/search-domains, y su stack de hilos por
  defecto es 128 KB (segfaults en apps multihilo). ["Alpine Linux Alternatives"](https://checkthat.ai/brands/alpine-linux/alternatives), [goranstimac.com](https://goranstimac.com/blog/alpine-linux-production-containers-pros-cons-tradeoffs/), [fly.io](https://fly.io/blog/fly-with-alpine/)
* Debian es el "campeón de compatibilidad": casi todo el software Linux se prueba contra
  glibc y el ecosistema Debian; repos enormes; `apt` es el gestor que más instrucciones
  de instalación asume. [scanrook.io](https://scanrook.io/blog/alpine-vs-debian-vs-distroless), [runxbuild.com](https://www.runxbuild.com/blog/best-linux-distro/)
* Ubuntu LTS ≈ Debian en compatibilidad (mismo libc), pero arrastra más peso y sus
  instrucciones asumen systemd/snap.
* **Argumento decisivo adicional (16 KB):** la toolchain de **arm64 de Debian enlaza con
  `max-page-size=64K`**, así que sus ELF son válidos tanto en dispositivos de 4 KB como de
  16 KB. Alpine arm64 se enlaza a 4 KB y es el primero que se rompe en hardware nuevo.

| Distro | libc | Tamaño base | `apt`/pkg | Compat. software | 16 KB | Veredicto |
|---|---|---|---|---|---|---|
| **Debian 12 (bookworm) arm64** | glibc | ~120 MB | `apt` | ★★★★★ | ✅ (64K align) | **Por defecto** |
| Ubuntu 24.04 base arm64 | glibc | ~110 MB | `apt` | ★★★★☆ | ~ | Alternativa |
| Alpine 3.22 | musl | ~8 MB | `apk` | ★★☆☆☆ | ❌ 4K | Solo "modo rápido", avisado |
| Arch / Fedora | glibc | 200 MB+ | `pacman`/`dnf` | ★★★☆☆ | ~ | Fuera de alcance v1 |

**DECISIÓN:** Debian bookworm arm64 como distro por defecto y única recomendada. Alpine
queda como opción avanzada marcada experimental. En la UI, el selector muestra la advertencia
de compatibilidad de musl.

## 4. Páginas de 16 KB (Android 15+) — riesgo real y silencioso

* Android 15 permite dispositivos con **páginas de 16 KB**; todo ELF con segmentos `LOAD`
  alineados a `2^12` (4 KB) falla con `ELF load failed`, `SIGBUS` o `SIGSEGV`. Regla de
  Google: cada `LOAD` debe estar alineado a `≥ 2^14`.
* Termux añadió soporte de 16 KB en su release de **2025-10-05** y reconstruyó bootstraps y
  paquetes; hoy sus paquetes son 16 KB-safe.
* Fuentes: [Android Developers Blog — 16 KB page size](https://android-developers.googleblog.com/2024/08/adding-16-kb-page-size-to-android.html), [termux-play-store releases](https://github.com/termux-play-store/termux-apps/releases).

**DECISIÓN:** implementar `PageSizeCheck` en Dart:
1. lee `getconf PAGE_SIZE` (o `/proc/self/pagemap`-free: `sysconf`) vía `Process.run`;
2. si es 16384, valida con un parser ELF mínimo (leer `e_phoff`/`p_align` de los `LOAD`)
   el `proot` y el primer binario del rootfs;
3. si algo no está alineado, mostrar un diagnóstico claro en la pantalla de Setup en vez de
   un error opaco de proot.

## 5. Terminal: PTY real, no pipes

* `xterm.dart` (TerminalStudio) es el emulador VT más completo para Flutter: parser ANSI,
  colores, reflow, selección, teclado, `TerminalController`, y lo usan apps de producción.
* Para el proceso, `pty` (puro FFI) **no soporta Android** (su tabla de plataformas solo lista
  Windows/Linux/macOS, y su implementación usa `forkpty` vía FFI bloqueante).
* **`flutter_pty`** (mismo autor) es un plugin nativo con **Android verificado** (tabla de
  plataformas del README: Linux/macOS/Windows/Android ✔), API `Pty.start()`, `output`,
  `write(Uint8List)`, `resize(rows, cols)`, `kill()`.
* Con PTY real funcionan `vim`, `htop`, `less`, `top`, `python -i`, y `sudo`/`apt` que piden
  TTY. Sin PTY, esas herramientas fallan o pierden el prompt.

**DECISIÓN:** `flutter_pty` + `xterm`. Se descarta el enfoque de pipes del borrador anterior.

## 6. Gestión de sesiones y ciclo de vida

* `--kill-on-exit` mata los hijos al cerrar proot, pero si **la app** muere (OOM, swipe),
  el proceso `proot` puede quedar huérfano → hay que matarlo por PID guardado en
  `SessionStore` al arrancar (proot-distro hace lo mismo con su registro de sesiones en JSON).
* Para sesiones largas (`npm run dev`, servidores) hace falta **servicio en primer plano**:
  `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_DATA_SYNC` + notificación persistente y
  `WAKE_LOCK`. Android 14 exige tipo declarado (`dataSync`) y Android 13+ el permiso
  `POST_NOTIFICATIONS` en runtime.
* Un solo `proot` de larga vida + `tmux`/`screen` dentro es MUCHO más eficiente que lanzar
  un `proot` por comando (cada arranque cuesta ~0.5–2 s por el `ptrace`).
* Fuente: [proot-distro README (limitaciones)](https://github.com/termux/proot-distro), [proot#54](https://github.com/termux/proot/issues/54).

**DECISIÓN:** dos modos:
* **Modo terminal:** una sesión PTY persistente (`bash` dentro de proot) sobre la que se
  escribe; las tools del agente ejecutan comandos *en la misma sesión* usando marcadores
  (`echo __CHRONOX_END_$?__`) para delimitar salida y código de salida. Cero arranques extra.
* **Modo tool aislada:** `Process.start` con timeout para comandos cortos sin contaminar el
  shell del usuario.

## 7. Limitaciones aceptadas (y qué se le dice al usuario)

| Limitación | Causa | Mitigación |
|---|---|---|
| No hay `systemd`/`systemctl` | proot no es PID 1 ni tiene namespaces/cgroups | `service`/OpenRC de Debian, o simplemente procesos en background + notificación |
| No hay contenedores anidados | sin namespaces ni cgroups | documentado; `docker` no funciona |
| No se pueden crear device nodes | sin `mknod` real | ya se enlazan `/dev` del host |
| Rendimiento: `ptrace` en cada syscall | proot intercepta todo | un solo proceso persistente; evitar `apt upgrade` masivo frecuente |
| Puertos < 1024 no enlazables | usuario sin privilegios | `-p` de proot para redirigir (p.ej. 22→2022) |
| `link2symlink` puede romper `sudo` | emulación de hardlinks | avisar; dentro de proot ya eres uid 0 |
| GPU / aceleración | Android no expone DRM a proot | nada de GUI nativa; VNC si se quiere escritorio |

## 8. Riesgos abiertos (a vigilar)

1. **Suelo de `targetSdk` en Android 14+/OEMs**: `ro.build.version.min_supported_target_sdk`
   puede impedir instalar targetSdk 28 en el futuro. Plan B: `nativeLibraryDir` para `proot`
   + `system_linker_exec` para el resto (vía C).
2. **`packages.termux.dev` bloqueado/caído** desde algunas redes: se implementan 4 mirrors.
3. **SELinux restrictivo** en algunos OEM (Xiaomi/Huawei): `execve` puede fallar incluso con
   `targetSdk 28`. Se detecta y se muestra diagnóstico (hay dispositivos donde ninguna app
   tipo Termux funciona; el usuario debe saberlo).
4. **`--link2symlink` y `dpkg`**: hay bugs abiertos ([proot#393](https://github.com/termux/proot/issues/393),
   [proot-distro#716](https://github.com/termux/proot-distro/issues/716)) donde el emulador de
   hardlinks confunde `basename`/`uname` durante `apt upgrade`. Mitigación: fijar
   `--no-link2symlink` como toggle avanzado y no hacer `apt upgrade` masivo en el primer arranque.
5. **Tamaño de descarga**: rootfs Debian ~120 MB (capa OCI comprimida ~30 MB). Requiere WiFi
   recomendado y verificación SHA-256.

## 9. Fuentes principales

* Android W^X / restricciones de `execve`: agnostic-apollo, *Android-Docs*; `termux/termux-app` #4120; `termux/proot` #292.
* Flags de proot: `termux/proot-distro` (`proot_distro/commands/login/proot_cmd.py`), `termux/termux-packages/packages/proot/build.sh`.
* Limitaciones proot: `termux/proot-distro` README; r/termux; ivonblog.com.
* Distros: fly.io, goranstimac.com, checkthat.ai, runxbuild.com, scanrook.io.
* 16 KB: Android Developers Blog; primetestlab.com; termux-play-store releases.
* Terminal: `xterm.dart`, `flutter_pty` (README con tabla de plataformas), `pty` (sin Android).

---

## 10. Autocontención: cero dependencia de la app Termux

**Requisito del producto:** Chronox AI debe tener terminal propia y **no depender de ninguna
aplicación externa como Termux**.

### Qué significa exactamente "no depender"

Hay dos cosas distintas que conviene no confundir:

| | Dependencia dura (inaceptable) | Reutilización de binarios (aceptable) |
|---|---|---|
| Qué es | Que el usuario deba instalar Termux, abrirla, o que el runtime viva en `/data/data/com.termux/` | Empaquetar el binario `proot` (GPLv2) compilado por el proyecto Termux |
| ¿La app Termux se instala? | Sí | **No** |
| ¿El usuario la abre? | Sí | **No** |
| ¿El runtime está en nuestro directorio privado? | No | **Sí** |
| ¿Funciona sin conexión? | — | **Sí, si va en el APK** |

Usar el binario de Termux es exactamente lo mismo que usar un `.so` de OpenSSL o una librería
de FFmpeg: software libre, reutilizado. Lo que **no** haremos es invocar la app Termux, su
`$PREFIX`, sus scripts (`proot-distro`) ni sus rutas. Todo el runtime de Chronox vive en
`/data/data/app.chronoxai/files/linux/`.

### DECISIÓN: empaquetar en el APK, no descargar en runtime

El borrador descargaba `proot.deb` + `libtalloc.deb` + `libandroid-shmem.deb` en el primer
arranque. Eso tiene dos problemas:

1. **Dependencia blanda de su infraestructura**: si `packages.termux.dev` cae o está bloqueada
   (redes corporativas, países con censura), la app no arranca. Inaceptable para algo que
   debería ser "instalar y listo".
2. **Superficie de fallo innecesaria**: descarga + verificación + extracción `ar`/`tar` en el
   dispositivo, cuando ese contenido es **estático** y conocido en tiempo de build.

**Nuevo diseño:**

```
chronoxai/
├── android/app/src/main/jniLibs/arm64-v8a/
│   ├── libproot.so                  ← proot renombrado (GPLv2, ver LICENSE nota)
│   ├── libtalloc.so                 ← libtalloc (LGPL)
│   ├── libandroid-shmem.so          ← libandroid-shmem (Apache-2.0)
│   └── libproot_loader.so           ← loader de proot (PROOT_UNBUNDLE_LOADER)
└── tools/
    ├── fetch_runtime.sh             ← descarga y coloca esos .so ANTES de compilar
    └── SHA256SUMS                   ← hashes fijados (build reproducible)
```

`tools/fetch_runtime.sh` corre en la máquina de desarrollo / CI, no en el teléfono. El APK
sale con el runtime dentro → **la app funciona sin red** para todo lo que no sea instalar el
rootfs (que sí necesita WiFi una vez, porque son ~120 MB de Debian).

Ventajas adicionales:
* No hay que firmar como `targetSdk 28` para *ejecutar* estos binarios → **puede que
  recuperemos compatibilidad con Play Store** (§10.1).
* Sin escritura de binarios en `filesDir` no hay carrera con antivirus/OEM.
* Build reproducible y auditable por hash.

### 10.1 Hipótesis abierta: `targetSdk ≥ 29` sigue siendo viable

`nativeLibraryDir` (`/data/app/~~xxx/app.chronoxai-xxx/lib/arm64/`) está etiquetado
`apk_data_file` y **sí permite `execve`** a cualquier `untrusted_app`, sin importar el
`targetSdk`. Ese es el hallazgo de la POC "APK Native Library" de agnostic-apollo.

Dentro de proot, los binarios del rootfs (`/bin/bash`, `apt`, `python3`) **no los ejecuta el
kernel**: los carga el loader de proot (que traduce paths), así que no pasan por la política
`app_data_file`. Por lo tanto el conjunto de ELF que necesita `execve` real se reduce a:

1. `proot` (→ `nativeLibraryDir`) ✅
2. el loader de proot (→ `nativeLibraryDir`) ✅

**Si esto se confirma en hardware, la app puede publicarse en Play Store con `targetSdk 34+`.**
Riesgos a validar:
* la lib `proot` es dinámica: sus dependencias (`libtalloc`, `libandroid-shmem`) deben estar
  en el mismo directorio o en `LD_LIBRARY_PATH`, y **Android 14+ exige que las libs de
  `nativeLibraryDir` estén alineadas a 16 KB**;
* `link2symlink` necesita escribir symlinks y en Android 11+ hay restricciones adicionales;
* SELinux de OEM concretos puede ser más estricto que AOSP.

**Estado:** no verificado. Se implementa primero la vía A (`targetSdk 28`, garantizada) con el
runtime empaquetado, y esta hipótesis se prueba en la Fase 1 con un *flavor* de Gradle
(`playstore`) que sube el `targetSdk`. Si valida, se convierte en la vía principal.

### 10.2 Licencias (importante para distribuir)

* `proot` (Termux fork) → **GPLv2**. Se distribuye como binario separado, invocado por
  proceso (`Process.start`), no enlazado → no contamina el código de la app. Hay que incluir
  el texto de la licencia y **ofrecer el código fuente** (enlace al repo + nuestros parches).
* `libtalloc` → LGPLv3 (enlace dinámico: permitido).
* `libandroid-shmem` → Apache-2.0.
* Debian rootfs → contiene GPL y otras licencias; se descarga en el dispositivo, no se
  redistribuye dentro del APK (evita el problema de redistribuir una distro completa).

Añadir `THIRD_PARTY_NOTICES.md` y una pantalla "Licencias" en Ajustes.
