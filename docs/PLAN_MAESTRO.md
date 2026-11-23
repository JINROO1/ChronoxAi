# Plan maestro — Chronox AI a la par de DeepSeek Harness

Objetivo: cerrar todas las brechas detectadas frente a DeepSeek Harness
(dsh), **excepto** modo headless / CLI / SDK Python, que el usuario no quiere.

Cada fase se implementa, se prueba en CI (único canal de verificación: no hay
toolchain local) y se marca `[x]` solo cuando el CI está en verde.

---

## Fase 0 — Fundación

- [x] Plan maestro escrito (`docs/PLAN_MAESTRO.md`)
- [x] Investigación: sandbox Android sin root, clientes MCP en Dart, APIs
      nativas de Anthropic/Gemini, convención `AGENTS.md`, hooks de dsh
- [ ] Persistencia de ajustes del proveedor (`shared_preferences`): sin esto no
      hay tareas programadas ni reanudación tras reinicio

## Fase 1 — Ficheros de instrucciones del proyecto (`AGENTS.md` / `CLAUDE.md`)

dsh lee `AGENTS.md` y `CLAUDE.md` del workspace y los inyecta en el prompt.

- [ ] `ProjectInstructions`: carga `AGENTS.md`, `CLAUDE.md` y
      `.chronox/instructions.md` desde la raíz del workspace (con límite de
      tamaño y precedencia documentada)
- [ ] `PromptBuilder` incluye las instrucciones del proyecto en el system prompt
- [ ] `AgentLoop` acepta un cargador inyectable y lo usa en cada turno
- [ ] Tests: precedencia, límite de tamaño, inclusión en el prompt

## Fase 2 — Plan mode real

Hoy `exit_plan_mode` solo devuelve texto: el loop **no se detiene**.

- [ ] `PlanProposedEvent` (efímero) y `PlanDecisionEvent` (durable)
- [ ] `AgentLoop` intercepta `exit_plan_mode`: emite el evento, espera la
      decisión del usuario y, si se rechaza, cierra el turno con `rejected`
- [ ] UI: hoja de plan con el Markdown del plan y botones Aprobar/Rechazar
- [ ] Tests: aprobación continúa, rechazo detiene el turno

## Fase 3 — UI de sesiones (resume, fork, search, Trajectory)

El dominio ya tiene `fork`/`rewind`/`stats`; falta la superficie.

- [ ] Pantalla de sesiones: lista desde `sessions/*.jsonl` con título, fecha,
      turnos y tokens
- [ ] Abrir (resume) una sesión existente
- [ ] Fork desde la sesión activa y desde la lista
- [ ] Búsqueda de texto sobre los eventos de todas las sesiones
- [ ] Vista Trajectory: línea temporal de pasos con tokens, TTFT y tiempo de
      herramientas (de `SessionStats` + `StepEndEvent`)
- [ ] Tests: listado, búsqueda, fork

## Fase 4 — Búsqueda web (`web_search`)

dsh Standard incluye búsqueda web; aquí solo hay `web_fetch`.

- [ ] Herramienta `web_search` sobre el endpoint HTML de DuckDuckGo (sin clave),
      con parseo de resultados a `título · URL · extracto`
- [ ] Plugin `core-web` la registra junto a `web_fetch`
- [ ] Tests con HTML de muestra

## Fase 5 — Proveedores nativos (Anthropic y Gemini)

Hoy solo existe el adaptador OpenAI-compatible.

- [ ] `AnthropicClient`: Messages API con streaming SSE, bloques `tool_use`,
      cabeceras `x-api-key` / `anthropic-version`, uso de tokens
- [ ] `GeminiClient`: `streamGenerateContent?alt=sse`, `functionDeclarations`,
      partes `functionCall` / `functionResponse`
- [ ] Ajustes: selector de tipo de proveedor (OpenAI-compatible / Anthropic /
      Gemini) con campos por tipo
- [ ] Tests con cliente HTTP falso para ambos adaptadores

## Fase 6 — Cliente MCP (Model Context Protocol)

dsh trae cliente MCP; aquí no hay nada.

- [ ] `McpClient` mínimo sobre Streamable HTTP: `initialize`, `tools/list`,
      `tools/call`, sesión (`Mcp-Session-Id`), respuestas SSE
- [ ] Plugin `core-mcp`: conecta con el servidor configurado y registra sus
      herramientas como `mcp_<servidor>_<herramienta>`
- [ ] Ajustes: URL del servidor MCP
- [ ] Tests con servidor HTTP falso

## Fase 7 — Hooks (`hooks.json`)

dsh acepta `hooks.json` con puntos de intercepción.

- [ ] `HookConfig` + `HookRunner`: ejecuta comandos del contenedor en los
      puntos `on_turn_start`, `on_turn_end`, `on_tool_call` (puede bloquear),
      `on_tool_result` y `on_approval_request`
- [ ] Variables de entorno con el contexto (`CHRONOX_TOOL_NAME`, etc.) y timeout
- [ ] Integración en `AgentLoop` (inyectable, desactivable)
- [ ] Tests con seam de shell falso

## Fase 8 — Subagentes con herramientas y en paralelo

`runSubagent` hoy es una única llamada sin herramientas.

- [ ] Subagente con **turno completo**: registry propio con un subconjunto de
      herramientas, log propio, mismo proveedor
- [ ] Herramienta `subagents` (plural): ejecuta varios subagentes en paralelo
      con `Future.wait`
- [ ] Tests: el subagente usa herramientas y no contamina el log principal

## Fase 9 — Plugins cargables en runtime (sin recompilar)

Los plugins actuales son Dart compilado en el APK. dsh instala plugins en
runtime desde npm/comunidad.

- [ ] Protocolo JSON-RPC 2.0 por stdio (líneas) para plugins externos:
      `initialize`, `tools/list`, `tools/call`, `shutdown`
- [ ] `ExternalPluginProcess`: proceso persistente dentro del contenedor
      (proot vía `Process.start`, como ya hace `LocalRuntime.run`)
- [ ] `ExternalPluginLoader`: escanea `<soporte>/plugins/<id>/` (`manifest.json`
      + `plugin.py`), registra adaptadores `ChronoxPlugin` y los monta como
      cualquier otro plugin
- [ ] Plugin de ejemplo en `assets/plugins/` + documentación del protocolo
- [ ] Tests del framing JSON-RPC con proceso falso

## Fase 10 — Endurecimiento del sandbox

proot **no** es un sandbox (confirmado por su documentación y por burrow):
el límite real es el sandbox de la app Android (UID + SELinux + seccomp-bpf
del sistema) más la política de aprobación. Se endurece lo endurecible y se
documenta lo demás.

- [ ] `SandboxPolicy`: lista de patrones destructivos evidentes en comandos de
      shell (`rm -rf /`, `mkfs`, `dd ... of=/dev/`, fork bombs) que se
      bloquean o escalan a aprobación obligatoria
- [ ] `SandboxPolicy` se aplica en el seam de shell antes de ejecutar
- [ ] Binds de proot revisados: solo `/dev`, `/proc`, `/sys`, workspace, home
      y tmp (ya es así; se deja constancia en un test)
- [ ] §12 en `docs/ARQUITECTURA.md`: modelo de seguridad honesto (qué protege
      cada capa y qué no)
- [ ] Tests de la política

## Fase 11 — Tareas programadas y trabajos en segundo plano

dsh tiene tareas programadas (experimental) y jobs en segundo plano.

- [ ] `ScheduledTask` (prompt + hora + repetición) persistido en JSON
- [ ] Canal `app.chronoxai/scheduler` + `AlarmManager` (inexactas, sin permiso
      especial) y `BroadcastReceiver` que abre la app con el prompt
      precargado y publica notificación
- [ ] Pantalla de tareas programadas (crear, listar, borrar)
- [ ] Vista de trabajos en segundo plano: terminales activas (ya existe
      `terminal_list`; se expone en UI)
- [ ] Tests del store

## Fase 12 — Entrada de voz

dsh la marca experimental; aquí se implementa con el reconocimiento del sistema.

- [ ] Canal `app.chronoxai/voice` sobre `SpeechRecognizer` de Android
- [ ] Permiso `RECORD_AUDIO` en el manifest
- [ ] Botón de micrófono en el composer: dicta y rellena el campo
- [ ] Tests del lado Dart (canal falso)

## Fase 13 — Firma y publicación

- [ ] Versión `0.2.0` en `pubspec.yaml` y notas de release actualizadas
- [ ] Commit con `[apk]` + tag `v0.2.0` → el CI firma con la clave de release
      (secrets `KEYSTORE_*`) y publica el APK en GitHub Releases
- [ ] Verificación: release creada con el APK firmado (huella SHA-256 de la
      clave `chronoxai`)

---

## Estado de verificación

- CI (`.github/workflows/ci.yml`): Analyze, Format, Tests, Runtime Linux y
  Build APK release. Sin toolchain local, **ninguna fase se marca `[x]` sin
  un run en verde**.
- Sin probar en dispositivo real hasta que el usuario lo haga: SELinux,
  páginas de 16 KB, `SpeechRecognizer`, alarmas exactas.
