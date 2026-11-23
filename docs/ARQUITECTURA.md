# Arquitectura — Chronox AI

> Referencia conceptual: **DeepSeek Harness (dsh)** — MIT, `github.com/deepseek-ai/deepseek-harness`.
> Chronox AI no es un port de dsh (dsh es TypeScript/Node; esto es Dart/Flutter), sino una
> implementación de **los mismos principios** adaptada a un runtime Android+proot.
>
> Fuente de los conceptos: `docs/architecture.md`, `docs/capability-seams.md` y
> `docs/tool-catalog.md` del repo oficial (consultados 2026-11-23).

---

## 1. El principio: "todo es un plugin"

dsh se construye sobre **Cordis**, un meta-framework de *composabilidad espaciotemporal*:

* **Espacial**: un componente declara sus dependencias de otros y reacciona a ellos.
* **Temporal**: al retirar un componente, **sus efectos se revierten por completo**.

Nada es un núcleo privilegiado: el adaptador de modelo, el registro de herramientas, el log de
sesión y **el propio bucle del agente** son plugins. Se extiende dsh montando un plugin al lado
de los demás, no parcheando el core.

### Cómo se traduce a Dart

| dsh (Cordis) | Chronox AI (Dart) |
|---|---|
| `ctx` compartido con servicios | `PluginContext` (registro tipado de servicios) |
| `ctx.llm`, `ctx.tools`, `ctx.fs`… | getters tipados en `PluginContext` |
| registro = efecto que se revierte al desmontar | `Disposable` devuelto por cada registro; `unmount()` los ejecuta en orden inverso |
| `bundle` (config + código) | `PluginManifest` + `plugin.dart` |
| `profile` (capas de bundles + patches) | `Flavor` = lista ordenada de plugin IDs |
| `cordis.patch.yml` | `PluginsConfig` persistida (activar/desactivar/configurar) |
| evento tipado (`agent/*`, `tools/*`) | `AgentEventBus` tipado con `Stream<T>` |

## 2. Los 36 *seams* (capacidades intercambiables)

dsh declara estas capacidades como sustituibles. Están tomadas literalmente de
`capability-seams.md`; la columna "Chronox" dice si está implementada:

| dsh seam | Chronox | Notas |
|---|---|---|
| `ctx.llm` | ✅ | adaptadores OpenAI-compatible + Anthropic |
| `ctx.tools` | ✅ | registro con ámbito + pipeline con guards |
| `ctx.shell` | ✅ | vía `ProotRuntime` |
| `ctx.terminals` | ✅ | PTY persistente (`flutter_pty`) |
| `ctx.fs` | ✅ | confinado a `/workspace` |
| `ctx.subprocess` | ✅ | `Process.start` en el contenedor |
| `ctx.approval` | ✅ | política read-only / guarded / yolo |
| `ctx.sessions` + `ctx.sessionPersistence` | ✅ | log *append-only* en JSONL |
| `ctx.compaction` | ✅ | compactación de contexto por presupuesto |
| `ctx.skills` | ✅ | packs de instrucciones reutilizables |
| `ctx.subagents` | ✅ | agente hijo con ámbito propio |
| `ctx.jobs` | ⬜ | jobs en background |
| `ctx.sandbox` | ➖ | el sandbox **es** proot; no hay otro backend en móvil |
| `ctx.ptcRuntime` | 🔶 | Code Mode limitado: `run_code` en Python dentro del contenedor |
| `ctx.web` (search/fetch) | 🔶 | `web_fetch` sí; `web_search` requiere API key de buscador |
| `ctx.storage` | 🔶 | disco local únicamente (no S3) |
| `ctx.mcpResources` | ⬜ | cliente MCP |
| `ctx.browserUse` / `ctx.computerUse` | ❌ | imposible: no hay navegador ni escritorio bajo proot |
| `ctx.lsp` | ⬜ | diagnósticos de lenguaje |
| `ctx.workflowEngine` | ⬜ | workflows multi-paso |
| `ctx.officeKit`, `ctx.speechToText`, `ctx.forge`, `ctx.worktrees`, `ctx.credentials`, `ctx.sessionQuery`, `ctx.sessionTelemetry`, `ctx.sessionTitle`, `ctx.userQuestions`, `ctx.spillStore`, `ctx.directoryPicker`, `ctx.fileReferences`, `ctx.attachments`, `ctx.authorization`, `ctx.connection*`, `ctx.deepseek*` | parcial | varias no aplican a una app móvil |

Leyenda: ✅ implementado · 🔶 parcial · ⬜ pendiente · ➖ no aplica · ❌ imposible en Android

> Esto es deliberado: **declarar lo que falta es parte del diseño**. Un seam que no existe se
> declara ausente y la UI lo muestra como "no disponible en móvil", en lugar de fallar de forma
> silenciosa cuando el modelo intente usarlo.

## 3. Modos de trabajo (los 4 de dsh)

| Modo | Qué monta | Para qué |
|---|---|---|
| **Standard** | Todo: edición, shell, terminal, búsqueda, skills, planificación, subagentes | Uso diario |
| **Code (PTC)** | Standard + `run_code`: el modelo escribe un programa Python que orquesta varias tools en una sola llamada | Tareas multi-paso; ahorra round-trips |
| **Minimal** | Solo `bash` + `str_replace_editor` | Medir el modelo sin ayuda del harness |
| **Creator** | Standard + `cordis_inspect`: inspeccionar el runtime, montar/desmontar plugins en caliente | Escribir plugins |

Un modo es simplemente un **flavor**: una lista de IDs de plugin. No hay código especial por
modo, lo que garantiza que un modo nuevo sea configuración y no una rama en el motor.

## 4. Flujo de un turno

Adaptado de `turn flow` de dsh, simplificado a lo que necesita una app móvil:

```
turn/start
  ├─ ensamblar contexto: system prompt + secciones + esquemas de tools admitidas
  ├─ agent/pre-step        (waterfall: puede aceptar, reescribir o rechazar)
  ├─ step/start
  │   ├─ agent/request → llamada al LLM (streaming, cancelable)
  │   ├─ chunk* → UI (tokens en vivo)
  │   ├─ tool/call* → tools/pre-execute → tools/execute → tools/post-execute
  │   └─ tool/result*
  ├─ step/end
  └─ ¿otra tool o nuevo input? → siguiente step
turn/end
```

`turn/start`, `step/start|end`, `user/message`, `assistant/message`, `tool/*` son eventos
**durables** (van al log). Los `chunk` son efímeros: solo alimentan la UI.

## 5. Log de sesión: la única fuente de verdad

dsh: *"model-visible means logged"* — todo lo que llega al modelo debe poder reconstruirse
desde el log.

* Formato: **JSONL append-only**, un evento por línea, en `filesDir/sessions/<id>.jsonl`.
* Beneficios que se obtienen gratis: reanudar, **fork** (copiar el prefijo), **rewind**
  (truncar a un `eventCount`), exportar transcripción, y telemetría (tokens, duración).
* Regla de implementación: la UI **nunca** guarda estado propio que no esté derivado del log.

## 6. Pipeline de ejecución de herramientas

dsh tiene un pipeline con guards. En Chronox, cada tool pasa por:

```
validar JSON-schema → aprobación (ctx.approval) → ejecutar → truncar salida → log
```

* **Aprobación**: tres niveles (`readOnly`, `guarded`, `yolo`) y, dentro de `guarded`, una
  decisión por herramienta con vista previa (diff para escrituras, comando para shell).
* **Truncado**: la salida se corta a un presupuesto de caracteres con marcador explícito; si
  el modelo necesita más, pide el rango siguiente. Evita quemar contexto con un `ls -R`.
* **Cancelación**: aborta el proceso real, no solo la UI.

## 7. Sistema de plugins

Un plugin es una carpeta con:

```
plugins/<id>/
├── manifest.json     id, nombre, versión, autor, tipo, capabilities que requiere
├── plugin.dart       punto de entrada (para plugins internos, compilados)
└── assets/           opcional: iconos, plantillas
```

Tipos:

| Tipo | Qué aporta | UI propia |
|---|---|---|
| `tool` | una o más herramientas | no |
| `skill` | instrucciones + ejemplos (pack de prompt) | no |
| `mode` | un flavor nuevo | no |
| `provider` | un adaptador de modelo | no |
| `surface` | una **pantalla completa** con su propio widget | **sí** |

`surface` es lo que pedías: un plugin puede **declarar su propio apartado de UI**. El host
descubre `PluginManifest.surface` y añade una entrada en la navegación, montando el widget en
un `PluginHost` aislado. El plugin recibe un `PluginSurfaceContext` con acceso **solo** a lo que
declaró en `capabilities` (principio de mínimo privilegio).

Plugins de terceros: para v1 solo se admiten plugins **Dart compilados** (seguros, sin eval).
La carga de plugins en lenguaje interpretado sería una superficie de ataque inaceptable en un
runtime que ya ejecuta binarios de Linux.

## 8. Capas de la app

```
UI (Flutter)  ──►  AgentController (state)  ──►  AgentLoop (plugin)
                                                   ├─ ctx.llm      → OpenAiCompatibleClient
                                                   ├─ ctx.tools    → ToolRegistry
                                                   ├─ ctx.approval → ApprovalPolicy
                                                   ├─ ctx.fs/shell → ProotRuntime
                                                   ├─ ctx.terminals→ ShellSession (PTY)
                                                   └─ ctx.sessions → JsonlSessionLog
```

## 9. Instalación del sistema Linux

El rootfs no viaja en el APK (una imagen de Debian ocupa más que la app entera y
casi nadie la usaría en el 90 % de los arranques). Se descarga la primera vez
desde Ajustes → *Contenedor Debian*.

```
Ajustes → InstallScreen
             │
             ▼
        RootfsInstaller ──► OciRegistryClient ──► registry-1.docker.io
             │                    │  índice multiarquitectura → variante del dispositivo
             │                    ▼
             │              capa N (tar.gz, ~120 MB en total)
             │                    │
             │        ┌───────────┴────────────┐
             │        ▼                        ▼
             │   sha256 en streaming      gunzip por trozos
             │   (se compara con el       (dart:io,
             │    digest del manifiesto)   startChunkedConversion)
             │                                │
             └────────────► TarExtractor ◄────┘
                                 │  escribe en <rootfs>.partial
                                 ▼
                        rename atómico a <rootfs>/
```

Decisiones que no son obvias:

| Decisión | Por qué |
|---|---|
| Se extrae en `.partial` y se renombra al final | Un corte de red a mitad no puede dejar un rootfs incompleto que `looksInstalled` dé por bueno. |
| El `sha256` se verifica **mientras** se descarga | Guardar la capa en disco para comprobarla después duplicaría el espacio necesario y añadiría una lectura completa. |
| `gzip` por trozos, no `gzip.decode` | `decode` exige la capa entera en memoria; una capa de 100 MB en un móvil termina en cierre por falta de memoria. |
| Extractor de `tar` propio | Hay que rechazar rutas absolutas y `..` (las capas vienen de la red) y respetar los whiteouts de OCI. `package:archive` no expone ninguna de las dos cosas. |
| Escritura de cada entrada por trozos de 128 KiB | Una `libc` de 20 MB no pasa por RAM. |
| Whiteouts aplicados aunque la entrada traiga datos | Es como una capa borra ficheros de la anterior; ignorarlo deja ficheros fantasma. |
| Cancelar aborta la petición HTTP y borra lo parcial | El botón tiene que dejar el dispositivo como estaba. |

Al terminar se escribe `<rootfs>/.chronox-image.json` con repositorio, etiqueta,
arquitectura, digests de las capas y fecha: sirve para el diagnóstico y para
detectar actualizaciones sin volver a descargar la imagen.

Pruebas: `test/gzip_stream_test.dart`, `test/tar_extractor_test.dart` y
`test/rootfs_installer_test.dart` (este último contra un registro OCI falso, sin
red, cubriendo hash incorrecto, imagen sin shell, cancelación y orden de capas).

## 10. Terminal interactiva sin PTY nativo

El invitado necesita un **PTY** de verdad: sin él, `isatty(0)` es falso, `bash`
funciona en modo no interactivo (sin prompt, sin historial, sin Ctrl+C por
carácter) y editores como `nano` o `vim` se niegan a arrancar.

La vía habitual —`openpty(3)` desde JNI— no está disponible en Android:

| Intento | Por qué falla |
|---|---|
| `android.system.Os.ioctlInt` para `TIOCSPTLCK`/`TIOCGPTN` | Está marcado `@hide`: solo enlaza contra el SDK de plataforma, no contra el público. |
| `libandroid.so` exportando `openpty` | No lo exporta; `openpty` vive en `libutil`, que no existe en Android. |
| Abrir `/dev/ptmx` y negociar a mano | Requiere los `ioctl` anteriores, así que es el mismo callejón. |

La solución es no crear el PTY desde Android, sino **dentro del contenedor**:
`script(1)` (paquete `bsdutils`) abre un PTY maestro/esclavo y ejecuta el shell
sobre el esclavo. Android solo ve dos tuberías y el invitado ve un terminal.

```
Dart                          Android (Kotlin)              Invitado
────                          ────────────────              ────────
PtySession.write(bytes) ──►   Process                                   ┌──────────┐
                              stdin  ──────────► proot ──► /bin/sh -c ──►│ script -q│
                              stdout ◄────────── proot ◄────           │  -f -e   │
PtySession.output ◄──────                                  ▼           └────┬─────┘
                                                     /dev/pts/N  ◄──────────┘
```

Decisiones que no son obvias:

| Decisión | Por qué |
|---|---|
| `script` y no un PTY por JNI | Ver la tabla anterior. Es una dependencia de `bsdutils`, `Essential: yes` en Debian: siempre está instalado. |
| Se comprueba dónde está antes de abrir | En bookworm es `/usr/bin/script`; en otras imágenes puede ser `/bin/script`. Se prueban ambas y, si no aparece, se dice con un mensaje en vez de abrir una consola muda. |
| La entrada cruza como `Uint8List`, nunca como `String` | Un `String` en el canal se codifica y decodifica varias veces por el camino y rompe secuencias UTF-8 que caen a mitad de trozo. Dart manda `utf8.encode(texto)` y el invitado recibe bytes. |
| La salida la interpreta `TerminalBuffer` | `script` manda ANSI real (movimientos de cursor, `ESC[K`, colores, buffer alternativo). Sin emulador, `nano` deja la pantalla hecha un jeroglífico. |
| `TERM=xterm-256color` | Los programas eligen la secuencia por `TERM`; con `dumb` no dibujan nada, con un tipo desconocido ensucian la salida. |
| El invitado cree tener 80 columnas | No hay `TIOCSWINSZ` desde Android, así que el ancho real de la pantalla no se puede comunicar. La UI envuelve las líneas ella misma. |
| `--kill-on-exit` en proot | Al cerrar la pestaña se mata el grupo entero; con `script` en medio, un `destroy()` del proceso padre no basta por sí solo. |
| Sin eco local | La entrada va por líneas y el eco lo pone el invitado, como en un terminal de verdad. Añadir edición local daría un eco duplicado en cuanto el PTY respondiera. |

El emulador (`TerminalBuffer`) mantiene estado entre trozos: un `ESC[` puede
llegar partido en dos lecturas, y un carácter UTF-8 también. El parser guarda su
estado y el decodificador es incremental, porque `utf8.decode` por trozo lanzaría
con las `ñ` en cuanto cayeran en la frontera.

## 11. Verificación en CI

Los tests corren en cada empujón, pero durante un tiempo el paso llevaba
`continue-on-error: true`. El job salía en verde con tests fallando: las
anotaciones lo decían, pero nadie mira anotaciones de un check verde.

Se quitó, y al quitar la red aparecieron fallos reales que el verde ocultaba:

| Fallo | Qué pasaba |
|---|---|
| `setUp(() { await ... })` sin `async` en dos tests | No compilaban; el fichero entero se saltaba en silencio. |
| Whiteouts de OCI con `substring(3)` | `.wh.viejo.txt` borraba `.viejo.txt`: las capas nuevas nunca eliminaban nada de las anteriores. |
| Salto de línea automático del buffer | El cursor se iba a la columna 81 y `ESC[K` borraba la línea entera. |
| `PtySession.write` con `codeUnits` | Cada tilde viajaba como dos bytes sueltos. |

La regla que se sigue ahora: si un test falla, el check falla. Nada de
`continue-on-error` en pasos que verifican.
