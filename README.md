# Chronox AI

**Agente de codificación para Android con terminal Linux (proot) integrada.**
Flutter + Dart 3, sin dependencias de servidor: todo corre en el dispositivo.

> Estado: `0.1.0-alpha` — el agente funciona de punta a punta sobre el runtime;
> falta el instalador del rootfs y conectar la terminal interactiva.

---

## Qué es

Chronox AI es un *harness* de agente (al estilo DeepSeek Harness / Claude Code / OpenHands)
pensado para móvil:

| Pieza | Qué hace |
|---|---|
| **Harness del agente** | Loop de tool-calling con streaming SSE, cancelación que aborta la petición, política de aprobación por herramienta y compactación de contexto. |
| **Runtime Linux** | Ejecuta un rootfs de Debian con `proot` (sin root, sin desbloquear el bootloader), desde binarios empaquetados en el APK. |
| **Terminal** | Emulador ANSI real (`xterm`) conectado a un `bash` persistente *dentro* del contenedor. `apt/apk install`, `git`, `python`, `node`… funcionan. |
| **UI** | Material 3 oscuro con glassmorphism, tipografía mono para el código, tarjetas de tool-call colapsables con diff. |
| **Proveedor LLM** | Cualquier API compatible con OpenAI: DeepSeek, OpenRouter, Groq, Together, Ollama/LM Studio locales. |
| **Modos de trabajo** | Los cuatro de DeepSeek Harness: **Standard**, **Code (PTC)**, **Minimal** y **Creator**. |
| **Plugins** | Todo es un plugin: herramientas, skills, modos y **pantallas completas**. Un plugin puede aportar su propio apartado de UI. |

```
┌──────────────────────────── Chronox AI (Flutter) ────────────────────────────┐
│                                                                              │
│   UI (chat · terminal · setup)                                               │
│        │                                                                     │
│        ├── AgentController ──► LlmClient (SSE streaming, tool_calls)         │
│        │        │                                                            │
│        │        └──► ToolRegistry                                            │
│        │                 ├── read_file / write_file / list_dir (dart:io)     │
│        │                 ├── run_shell  ─┐                                   │
│        │                 └── apply_patch ─┴──► ProotRuntime                  │
│        │                                          │                          │
│   TerminalScreen ──► ShellSession ────────────────┤                          │
│                                                   ▼                          │
│                             proot -r rootfs -b workspace:/workspace          │
│                                    bash · apk · python3 · git                │
└──────────────────────────────────────────────────────────────────────────────┘
```

## Estructura

```
chronoxai/
├── lib/
│   ├── main.dart / app.dart
│   ├── core/            tema, tokens, utilidades
│   ├── data/
│   │   ├── models/      ChatMessage · ToolCall · AgentEvent · AppSettings
│   │   ├── llm/         LlmClient · OpenAiCompatibleClient
│   │   └── storage/     SettingsStore · SessionStore
│   ├── domain/
│   │   ├── agent/       AgentLoop · prompts · políticas de aprobación
│   │   ├── tools/       ToolContract · ToolRegistry · builtins
│   │   └── terminal/    ProotRuntime · ProotBootstrap · ShellSession
│   ├── state/           providers (Riverpod)
│   └── ui/
│       ├── screens/     home · chat · terminal · settings · setup
│       └── widgets/     glass_card · tool_call_card · diff_view · composer
└── android/             targetSdk 28 (requisito de proot en Android 10+)
```

## Requisitos

* Flutter **3.24+** (Dart 3.5)
* Android **7.0 (API 24)** o superior, ABI `arm64-v8a` recomendada
* ~150 MB libres para el rootfs + espacio para tus paquetes

## Puesta en marcha

```bash
cd chronoxai
flutter pub get
flutter run --release      # release: el árbol de app es más rápido y estable
```

Primera vez en la app:

1. **Settings → Proveedor**: base URL + API key + modelo (ej. `https://api.deepseek.com`, `deepseek-chat`).
2. **Linux**: elige Alpine (rápido, ~4 MB) o Ubuntu (completo, ~30 MB) → *Instalar*.
3. **Terminal**: `apk add git python3 neovim` y a trabajar.
4. **Chat**: pídele algo y observa las tool-calls en vivo.

## Modelo de seguridad

* El rootfs y el workspace viven en el **almacenamiento privado** de la app
  (`/data/data/app.chronoxai/files/...`), sin permisos de almacenamiento.
* `proot` da una **jaula de sistema de archivos**, *no* un sandbox de seguridad:
  los procesos ven lo que se les enlaza con `-b`. Solo se enlazan `workspace`, `tmp`,
  `dev`, `proc` y `sys`.
* Toda tool de escritura/ejecución pasa por la **política de aprobación**
  (`ask` por defecto): el agente propone, tú confirmas.
* La API key se guarda en `SharedPreferences` del sandbox de la app. Para producción,
  muévela a `flutter_secure_storage` (ver `docs/ROADMAP.md`).

## Notas técnicas importantes

Decisiones derivadas de [`docs/INVESTIGACION.md`](docs/INVESTIGACION.md), no de intuición:

1. **`targetSdkVersion = 28`.** Desde Android 10, SELinux (W^X) prohíbe `execve()` sobre
   ficheros bajo `/data/data/<pkg>/` a apps con `targetSdk ≥ 29`. La excepción de
   compatibilidad `untrusted_app_27` (≤ 28) es la que permite ejecutar el runtime.
   Es la misma razón por la que Termux no está en Play Store: esta app se distribuye por
   **F-Droid / GitHub Releases**.
2. **`proot` de Termux** (`5.1.107.x`), no el de `proot-me` (ese está enlazado a glibc y no
   arranca en Android). Se descargan los `.deb` de `proot`, `libtalloc` y `libandroid-shmem`,
   se desempaquetan en el directorio privado y se ejecuta con `LD_LIBRARY_PATH` y
   `PROOT_UNBUNDLE_LOADER` apuntando ahí.
3. **PTY real** (`flutter_pty`) sobre un emulador VT completo (`xterm.dart`), así que `vim`,
   `htop`, `less` y las peticiones de TTY de `apt`/`sudo` funcionan de verdad.
4. **Debian bookworm arm64 por defecto**, no Alpine: glibc es lo que da compatibilidad con
   binarios precompilados, wheels `manylinux` y extensiones nativas. Alpine (musl) queda como
   opción experimental marcada como tal.
5. **Páginas de 16 KB**: Android 15+ puede arrancar con páginas de 16 KB y cualquier ELF con
   `LOAD` alineado a 4 KB falla con `SIGBUS`. Se verifica en runtime y se avisa en el Setup.

## Modos de trabajo

Heredados de DeepSeek Harness. Un modo es **solo datos** (qué plugins se montan), no una rama
en el motor:

| Modo | Qué monta | Para qué |
|---|---|---|
| **Standard** | edición, shell, terminal, búsqueda, planificación, subagentes, web | uso diario |
| **Code (PTC)** | Standard + `run_code`: el modelo escribe un programa que orquesta varias herramientas en una sola llamada | tareas multi-paso |
| **Minimal** | solo `bash` + `str_replace_editor` | medir el modelo sin ayuda |
| **Creator** | Standard + `cordis_inspect` + `plugin_manager` | escribir plugins |

## Plugins

Chronox AI implementa la filosofía de dsh con tres garantías verificadas por tests:

* **composabilidad temporal** — desmontar un plugin revierte exactamente sus registros;
* **composabilidad espacial** — dependencias declaradas y resueltas antes de montar;
* **mínimo privilegio** — usar una capacidad no declarada lanza `PluginCapabilityDenied`.

Un plugin de tipo `surface` **aporta su propia pantalla**: el host añade la entrada en la
navegación y le da tema, barra y ámbito de estado. Ver [`docs/PLUGINS.md`](docs/PLUGINS.md).

## CI / Release

Todo se compila y verifica en **GitHub Actions** (`.github/workflows/ci.yml`):

| Job | Qué hace |
|---|---|
| `format` | aplica `dart format` y commitea el resultado |
| `analyze` | `flutter analyze --fatal-infos` (limpio: 0 errores, 0 avisos) |
| `test` | 136 tests con cobertura |
| `runtime` | descarga y **valida el runtime proot** (AArch64 + alineación 16 KB) |
| `build` | APK release firmada, verificación con `apksigner`, publicación al crear un tag `v*` |

Si faltan los secretos de firma, el build avisa y firma con debug — nunca publica un APK
mal firmado fingiendo que es una release.

## Documentación

* [`docs/INVESTIGACION.md`](docs/INVESTIGACION.md) — **evidencia y fuentes** de cada decisión técnica.
* [`docs/PLAN.md`](docs/PLAN.md) — plan por fases con criterios de aceptación (checklist).
* [`docs/ARQUITECTURA.md`](docs/ARQUITECTURA.md) — flujo del agente, protocolo de tools, ciclo de vida de proot.
* [`docs/PLUGINS.md`](docs/PLUGINS.md) — escribir un plugin, capacidades, modos y pantallas propias.
* [`docs/FIRMA.md`](docs/FIRMA.md) — clave de firma, backups y firma en CI.
* [`docs/RELEASE_NOTES.md`](docs/RELEASE_NOTES.md) — notas de la versión que usa el CI como cuerpo de la release.

## Licencia

MIT.
