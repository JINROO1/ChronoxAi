# Plan de implementación — Chronox AI

> Base técnica: [`INVESTIGACION.md`](INVESTIGACION.md). Cada bloque tiene criterio de aceptación.
> Marca `[x]` cuando esté hecho y verificado en dispositivo.

**Decisiones cerradas (no reabrir sin evidencia nueva):**
Debian bookworm arm64 por defecto · `proot` de Termux 5.1.107.x + `libtalloc` + `libandroid-shmem` **empaquetados en el APK** (`jniLibs`) → **cero dependencia de la app Termux, funciona offline** · PTY real con `flutter_pty` + `xterm` · rootfs vía capa OCI (tar+gzip) · verificación de páginas de 16 KB en runtime · `targetSdk 28` como vía garantizada, con *flavor* `playstore` experimental (§10.1 de la investigación).

---

## Fase 0 — Fundaciones del proyecto

- [x] `pubspec.yaml` con Dart 3.5 / Flutter 3.24 (Riverpod, http, xterm, flutter_pty, archive, crypto, path_provider, shared_preferences)
- [x] `analysis_options.yaml` estricto
- [x] Gradle + `AndroidManifest.xml` con `minSdk 24` / `targetSdk 28`, `extractNativeLibs`, permisos de servicio en primer plano y notificaciones
- [x] Sistema de diseño (`core/theme.dart`): paleta, radios, tipografía mono, Material 3
- [x] **Clave de firma única** generada (RSA-4096, v1+v2+v3, 30 años) + `tools/generate_keystore.sh` + `docs/FIRMA.md`; secretos excluidos de Git; build avisa si compila release sin clave
- [x] Corregir README (el borrador afirmaba que se usa el `proot` estático de `proot-me`; es glibc y no sirve)
- [x] **`flutter analyze --fatal-infos` limpio** (0 errores, 0 avisos) verificado en CI
- [ ] `./tools/fetch_runtime.sh` en la máquina de desarrollo (necesita red a los mirrors de Termux)
- **Aceptación:** `flutter analyze` limpio; `flutter run` arranca en un móvil/emulador arm64.

## Fase 1 — Runtime Linux (el corazón del proyecto)

- [x] `LinuxPaths`: resuelve `filesDir/linux/{runtime,rootfs,home,overlay}`
- [x] `tools/fetch_runtime.sh`: descarga `proot` + `libtalloc` + `libandroid-shmem` (deb de Termux, ABI `aarch64`), los coloca en `jniLibs/arm64-v8a/` y verifica hashes (corre en dev/CI, **nunca en el teléfono**)
- [x] Parser ELF de verificación aplicado en el script: rechaza el build si algún `.so` no está alineado a 16 KB o no es `EM_AARCH64`
- [ ] `NativeRuntimeLocator`: obtiene `ApplicationInfo.nativeLibraryDir` en Android y localiza `libproot.so`; en escritorio cae a `assets/runtime` (para poder depurar la lógica sin teléfono)
- [ ] `THIRD_PARTY_NOTICES.md` + pantalla de Licencias (GPLv2 de proot exige ofrecer el fuente)
- [x] `ElfInspector` + `AndroidRuntimeChannel` (páginas de 16 KB, ABI, SELinux): detecta `PAGE_SIZE`; parser ELF mínimo (`e_phoff`, `p_align` de `LOAD`); valida `proot` y `/bin/bash` del rootfs
- [ ] `RootfsInstaller`: `manifest.json` de distro (url, sha256, size, familia) + descarga con progreso cancelable
- [ ] `OciLayerFetcher`: resuelve `library/debian:bookworm` en Docker Hub (token anónimo → manifest → capa) para tener una fuente mantenida sin depender de un CDN propio
- [ ] `RootfsExtractor`: gunzip (`dart:io`) + `archive` en **isolate** con progreso, soporte de `tar.xz` vía `xz` del runtime (fallback)
- [x] `ProotCommandBuilder`: genera el argv canónico (flags de §2 de la investigación) desde `LinuxConfig`
- [ ] `ProotRuntime`: `Process.start` de `proot` desde `nativeLibraryDir`, entorno (`LD_LIBRARY_PATH` → `nativeLibraryDir`, `PROOT_UNBUNDLE_LOADER`, `PROOT_TMP_DIR` → `filesDir`, `HOME`, `TERM`, `PROOT_NO_SECCOMP`)
- [x] `AndroidRuntimeChannel`: canal de plataforma mínimo (Kotlin) que expone `nativeLibraryDir`, `PAGE_SIZE`, `abi`, `sdkInt`, `isSelinuxEnforcing`
- [ ] `RuntimeHealth`: smoke test (`uname -a`, `whoami`, `ls /`), diagnóstico accionable de fallos (SELinux, ABI, 16 KB, mirrors)
- [ ] Limpieza de sesiones huérfanas al arrancar (PID guardado en `SessionStore`)
- **Aceptación:** en un Pixel/Samsung arm64 se instala Debian y `whoami` devuelve `root` dentro del contenedor, **con el móvil en modo avión** después de instalar el rootfs (prueba de autocontención).
- **Aceptación extra (hipótesis §10.1):** con el *flavor* `playstore` (`targetSdk 34`), el mismo flujo funciona. Si falla, se documenta por qué y se queda `targetSdk 28`.

## Fase 2 — Terminal

- [ ] `ShellSession` sobre `flutter_pty` (`Pty.start` con el argv de proot, `rows/cols` reales)
- [ ] `TerminalController` de `xterm` + puente bidireccional (bytes ⇄ `Terminal`)
- [ ] Redimensionado real en rotación y con teclado abierto
- [ ] Barra de teclas extra: `Ctrl`, `Alt`, `Esc`, `Tab`, flechas, `Ctrl-C`, `/`, `-`, `|`
- [ ] Sesión persistente + reconexión tras volver del background (servicio en primer plano)
- [ ] `ForegroundTerminalService` (Kotlin) con notificación y `WAKE_LOCK`
- [ ] Scrollback, selección/copia, `paste`, fuentes mono ajustables, temas claro/oscuro del terminal
- **Aceptación:** `htop`, `vim` y `apt install cowsay` funcionan con la UI correcta.

## Fase 3 — Kernel de plugins y modos de trabajo

- [x] `plugin_api.dart`: `PluginManifest`, `PluginKind` (tool/skill/mode/provider/**surface**), `PluginCapability`, `PluginContext` con `Disposable` reversible
- [x] `plugin_runtime.dart`: `PluginHost` (montar/desmontar/dependencias/flavor), `AgentEventBus` tipado, los seams `FileSystem/Shell/Terminals/Llm/Session/Network`
- [x] **Mínimo privilegio real**: acceder a una capacidad no declarada lanza `PluginCapabilityDenied` (no es convención, es runtime)
- [x] `work_modes.dart`: los 4 modos de dsh (Standard, Code/PTC, Minimal, Creator) como **datos** (lista de plugin IDs), no como ramas de código
- [x] `builtin_plugins.dart`: ~30 herramientas con los nombres de dsh (`read`, `write`, `edit`, `bash`, `glob`, `grep`, `terminal_*`, `todo_write`, `exit_plan_mode`, `subagent`, `web_fetch`, `apply_patch`, `run_code`, `cordis_inspect`, `plugin_manager`)
- [x] `agent_events.dart`: eventos durables vs efímeros, con `fromJson` para replay
- [x] `session_log.dart`: log append-only JSONL, fork, rewind, compactación, estadísticas, export Markdown
- [x] UI: `PluginSurfaceHost` + `PluginSurfaceGrid` — un plugin declara su pantalla y el host aporta el andamiaje
- [x] Plugin de ejemplo con pantalla propia (`disk_usage`)
- [ ] `AgentLoop` (el driver): turn/step, streaming, cancelación, presupuesto, compactación automática
- [ ] `ApprovalPolicy` con los tres niveles de dsh (`read-only`, `guarded`, `yolo`) y "recordar para esta sesión"
- [ ] Cargador de plugins de usuario desde `filesDir/plugins/<id>/manifest.json`
- [ ] Pantalla Ajustes → Plugins: activar/desactivar, ver capacidades, ver pantallas
- **Aceptación:** cambiar de Standard a Minimal reduce las herramientas expuestas al modelo a 2, verificable en el prompt enviado; y un plugin desactivado desaparece tanto del menú como del prompt.

## Fase 3b — Compilación y release en GitHub Actions

- [x] `.github/workflows/ci.yml` con 4 jobs: `analyze` (formato + `flutter analyze --fatal-infos`), `test` (cobertura), `runtime` (descarga y valida proot 16 KB), `build` (APK firmada)
- [x] El build **falla a propósito** si la clave restaurada está vacía (error típico de `base64` sin `-w0`)
- [x] Verificación de firma con `apksigner` en CI + resumen en `$GITHUB_STEP_SUMMARY`
- [x] Si no hay secretos de firma: compila con debug y lo advierte (`::warning`), nunca finge
- [x] Publicación automática de APKs al crear un tag `v*`
- [x] **Repo conectado y CI en verde**: analyze, tests, runtime y formato automático funcionando
- [x] Formato delegado a CI (job `format` lo aplica y commitea; no hay formateador fuera de un SDK)

## Fase 4 — Harness del agente

- [ ] Modelos: `ChatMessage`, `ToolCall`, `ToolResult`, `AgentEvent`, `Usage`
- [ ] `LlmClient` con **SSE streaming** + ensamblado de `tool_calls` fragmentados + cancelación cooperativa
- [ ] Proveedores: OpenAI-compatible (DeepSeek/OpenRouter/Groq/Together/local) y **Anthropic** (formato distinto, mensajes/tools)
- [x] `ToolRegistry` + validación JSON-schema (required, tipos, enum, objetos anidados)
- [ ] Tools: `read_file`, `write_file`, `edit_file` (diff unificado), `list_dir`, `grep`, `glob`, `run_terminal`, `web_fetch`
- [ ] `AgentLoop`: máx. iteraciones, presupuesto de tokens, reintentos con backoff, compactación de contexto
- [x] Persistencia de sesiones: `SessionLog` JSONL con fork/rewind/compactación/estadísticas
- [ ] Política de aprobación: `ask` / `auto-safe` / `auto-all` + confirmación por comando con vista del diff
- [ ] Cancelación real (aborta el `Pty`/proceso, no solo la UI) y `Ctrl-C` al agente
- **Aceptación:** "crea un script de Python que ordene archivos por extensión, pruébalo" se completa end-to-end con aprobaciones.

## Fase 5 — UI / UX (la parte "hermosa")

- [ ] `HomeScreen`: estado del runtime, sesiones recientes, accesos rápidos, saludo contextual
- [ ] `ChatScreen`: burbujas asimétricas, streaming token a token, cursor animado, scroll anclado
- [ ] `ToolCallCard`: colapsable, estado (pendiente/ejecutando/ok/error), duración, salida truncada con "ver todo", **diff coloreado** para `edit_file`
- [ ] `TerminalScreen`: pestañas por sesión, `xterm` a pantalla completa, teclado no obstructivo
- [ ] `SetupScreen`: wizard (distro → descarga con progreso → verificación → smoke test)
- [ ] `SettingsScreen`: proveedor, API key, modelo, temperatura, política de aprobación, fuente del terminal, tema
- [ ] Glassmorphism sutil, animaciones `flutter_animate`-style nativas, `Hero` entre setup y home
- [ ] Icono de app y splash (vectorial, coherente con la paleta)
- [ ] Accesibilidad: escalado de texto, contraste AA, `Semantics`, navegación con teclado físico
- **Aceptación:** 60 fps en scroll de chat largo en un móvil de gama media.

## Fase 6 — Robustez y entrega

- [x] Tests: `ElfInspector` (10 casos) + `ProotCommandBuilder` (17 casos) — *escritos, pendientes de ejecutar con SDK*
- [x] Validación empírica del script con ELF sintéticos (`--check`) y `.deb` de prueba
- [x] **`flutter test` ejecutado en CI**: 27 tests de ELF/argv + 26 de plugins/sesiones/modos, todos en verde
- [ ] Tests unitarios: parser `ar`/tar, ensamblado de `tool_calls`
- [ ] Tests de widget: burbujas, tarjetas de tool-call, composer
- [ ] Golden tests de la UI principal
- [ ] Manejo de errores de red (timeout, 401, 429, contexto excedido) con mensajes humanos
- [ ] `flutter_secure_storage` para la API key (sustituir `SharedPreferences`)
- [ ] Verificar el *flavor* `playstore` (`targetSdk 34`) en hardware y decidir la vía de distribución
- [ ] Logging local rotativo + "exportar diagnóstico" (sin secretos) para reportar bugs
- [ ] CI: `flutter analyze` + `flutter test` + build APK release en GitHub Actions
- [ ] Release firmada en GitHub Releases + F-Droid metadata
- [ ] README final con capturas, requisitos, instalación y limitaciones

---

## Orden de trabajo sugerido

```
Fase 0 (cerrar) → Fase 1 (runtime, lo más arriesgado) → Fase 2 (terminal)
     → Fase 3 (kernel de plugins) → Fase 3b (CI) → Fase 4 (harness) → Fase 5 (UI)
     → Fase 6 (robustez)
```

Lo riesgoso va primero: si el runtime no valida en *tu* dispositivo, el resto del proyecto
cambia de forma. La Fase 1 tiene que probarse en hardware real, no solo compilar.

## Fuera de alcance (v1)

- GUI de escritorio dentro del contenedor (VNC/noVNC)
- Contenedores anidados / Docker
- `systemd`
- Build para Google Play (requiere la vía C y su propia rama)
- iOS
