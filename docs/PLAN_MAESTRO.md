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
- [x] Persistencia de ajustes del proveedor (`shared_preferences`): sin esto no
      hay tareas programadas ni reanudación tras reinicio (CI de tests y análisis
      verde en el run `45288298184`)

## Fase 1 — Ficheros de instrucciones del proyecto (`AGENTS.md` / `CLAUDE.md`)

dsh lee `AGENTS.md` y `CLAUDE.md` del workspace y los inyecta en el prompt.

- [x] `ProjectInstructions`: carga `AGENTS.md`, `CLAUDE.md` y
      `.chronox/instructions.md` desde la raíz del workspace (con límite de
      tamaño y precedencia documentada)
- [x] `PromptBuilder` incluye las instrucciones del proyecto en el system prompt
- [x] `AgentLoop` acepta un cargador inyectable y lo usa en cada turno
- [x] Tests: precedencia, límite de tamaño e inclusión en el prompt (240 tests
      pasaron en CI, run `45288494058`)

## Fase 2 — Plan mode real

Hoy `exit_plan_mode` solo devuelve texto: el loop **no se detiene**.

- [x] `PlanProposedEvent` (efímero) y `PlanDecisionEvent` (durable)
- [x] `AgentLoop` intercepta `exit_plan_mode`: emite el evento, espera la
      decisión del usuario y, si se rechaza, cierra el turno con `rejected`
- [x] UI: hoja de plan con el Markdown del plan y botones Aprobar/Rechazar
- [x] Tests explícitos: aprobación continúa, rechazo detiene el turno y sin
      handler se rechaza por defecto (240 tests pasaron en CI, run `45288494058`)

## Fase 3 — UI de sesiones (resume, fork, search, Trajectory)

El dominio ya tiene `fork`/`rewind`/`stats`; falta la superficie.

- [x] Pantalla de sesiones: lista desde `sessions/*.jsonl` con título, fecha,
      turnos y tokens
- [x] Abrir (resume) una sesión existente con los ajustes de proveedor/mode
      elegidos en Ajustes
- [x] Fork desde la sesión activa y desde la lista
- [x] Búsqueda de texto sobre los eventos de todas las sesiones
- [x] Vista Trajectory: línea temporal de pasos con tokens, TTFT y tiempo de
      herramientas (de `SessionStats` + `StepEndEvent`)
- [x] Tests de listado, búsqueda y fork de dominio: CI pasó en el run
      `45289493568` (Analyze, Tests y Runtime Linux).

## Fase 4 — Búsqueda web (`web_search`)

dsh Standard incluye búsqueda web; aquí solo hay `web_fetch`.

- [x] Herramienta `web_search` sobre el endpoint HTML de DuckDuckGo (sin clave),
      con parseo de resultados a `título · URL · extracto`
- [x] Plugin `core-web` la registra junto a `web_fetch`
- [x] Tests con HTML de muestra (244 tests pasaron; CI `45290083703`)

## Fase 5 — Proveedores nativos (Anthropic y Gemini)

Hoy solo existe el adaptador OpenAI-compatible.

- [x] `AnthropicClient`: Messages API con streaming SSE, bloques `tool_use`,
      cabeceras `x-api-key` / `anthropic-version`, uso de tokens
- [x] `GeminiClient`: `streamGenerateContent?alt=sse`, `functionDeclarations`,
      partes `functionCall` / `functionResponse`
- [x] Ajustes: selector de tipo de proveedor (OpenAI-compatible / Anthropic /
      Gemini) con campos por tipo
- [x] Tests con cliente HTTP falso para ambos adaptadores (246 tests en verde,
      run `45290686923`)

## Fase 6 — Cliente MCP (Model Context Protocol)

dsh trae cliente MCP; aquí no hay nada.

- [x] `McpClient` mínimo sobre Streamable HTTP: `initialize`, `tools/list`,
      `tools/call`, sesión (`Mcp-Session-Id`), respuestas SSE
- [x] Plugin `core-mcp`: conecta con el servidor configurado y registra sus
      herramientas como `mcp_<herramienta>` (un servidor por configuración)
- [x] Ajustes: URL del servidor MCP
- [x] Tests con servidor HTTP falso (248 tests en verde, CI `45291585423`)

## Fase 7 — Hooks (`hooks.json`)

dsh acepta `hooks.json` con puntos de intercepción.

- [x] `HookConfig` + `HookRunner`: ejecuta comandos del contenedor en los
      puntos `on_turn_start`, `on_turn_end`, `on_tool_call` (puede bloquear),
      `on_tool_result` y `on_approval_request`
- [x] Variables de entorno con el contexto (`CHRONOX_TOOL_NAME`, etc.) y timeout
- [x] Integración en `AgentLoop` (inyectable; sin hooks configurados queda
      desactivado)
- [x] Tests con seam de shell falso (252 tests en verde, CI `45298027578`)

## Fase 8 — Subagentes con herramientas y en paralelo

`runSubagent` hoy es una única llamada sin herramientas.

- [x] Subagente con **turno completo**: registry read-only propio con un
      subconjunto de herramientas, log temporal aislado, mismo proveedor
- [x] Herramienta `subagents` (plural): ejecuta hasta cuatro subagentes en
      paralelo con `Future.wait`
- [x] Tests: el subagente usa herramientas y no contamina el log principal
      (253 tests en verde, CI `45298338994`)

## Fase 9 — Plugins cargables en runtime (sin recompilar)

Los plugins actuales son Dart compilado en el APK. dsh instala plugins en
runtime desde npm/comunidad.

- [x] Protocolo JSON-RPC 2.0 por stdio (líneas) para plugins externos:
      `initialize`, `tools/list`, `tools/call`, `shutdown`
- [x] `ExternalPluginProcess`: proceso persistente dentro del contenedor
      (proot vía `Process.start`, como ya hace `LocalRuntime.run`)
- [x] `ExternalPluginLoader`: escanea `<workspace>/.chronox/plugins/<id>/`
      (`manifest.json` + `plugin.py`), registra herramientas con aprobación
      obligatoria y las monta como plugins de sesión
- [x] Plugin de ejemplo en `assets/plugins/echo/` + documentación en
      `docs/PLUGINS.md` (limitaciones de seguridad incluidas)
- [x] Tests del framing JSON-RPC con transporte falso (CI `45305665733` en verde)

## Fase 10 — Endurecimiento del sandbox

proot **no** es un sandbox (confirmado por su documentación y por burrow):
el límite real es el sandbox de la app Android (UID + SELinux + seccomp-bpf
del sistema) más la política de aprobación. Se endurece lo endurecible y se
documenta lo demás.

- [x] `SandboxPolicy`: bloquea patrones destructivos evidentes (`rm -rf /`,
      `mkfs`, `dd ... of=/dev/`, fork bombs); es defensa heurística, no sandbox
- [x] `SandboxPolicy` se aplica en `ProotShellSeam` antes de ejecutar
- [x] Binds de proot revisados en `ProotCommandBuilder`; solo `/dev`, `/proc`,
      `/sys`, workspace, home y tmp
- [x] Modelo de seguridad honesto documentado en `docs/PLUGINS.md`
- [x] Tests de patrones bloqueados y comandos seguros (CI `45305864897` en verde)

## Fase 11 — Tareas programadas y trabajos en segundo plano

dsh tiene tareas programadas (experimental) y jobs en segundo plano.

- [x] Modelo `ScheduledTask` (prompt + hora + repetición) y `ScheduledTaskStore`
      con escritura atómica JSON; tests de round-trip y datos inválidos
- [x] Canal Android `app.chronoxai/scheduler` + `AlarmManager`
      inexacto y `BroadcastReceiver` con notificación para precargar el prompt
- [x] Pantalla de tareas programadas (crear, listar, borrar)
      (CI `45306569789` en verde; channel fake test incluido)
- [x] Vista de trabajos en segundo plano: terminales activas (consulta cada
      3 s y cierre desde UI; CI `45307188877` en verde)
- [x] Fase 11 validada íntegramente en CI `45307188877`
- [x] Tests del store JSON (CI `45306207341` en verde)

## Fase 12 — Entrada de voz

dsh la marca experimental; aquí se implementa con el reconocimiento del sistema.

- [x] Canal `app.chronoxai/voice` usando reconocimiento de voz del sistema
- [x] Permiso `RECORD_AUDIO` solicitado al primer uso
- [x] Botón de micrófono en el composer: dicta y rellena el campo
- [x] Tests del lado Dart con canal falso (CI `45307427771` en verde)

## Fase 13 — Compatibilidad con plugins DSH y MCP del ecosistema npm

La investigación del contrato DSH muestra que `dsh.bundle` declara uno o más
`cordis.patch.yml`, cuyo perfil carga plugins Node que exportan `apply(ctx)`;
MCP puede servirse por stdio o Streamable HTTP. No son el mismo protocolo ni es
posible prometer que un plugin UI arbitrario de Cordis sea portable a Flutter.
Compatibilidad por capas: herramientas/skills declarativas, servidores MCP npm,
y API shim para módulos Node; los slots/UI/servicios exclusivos de Cordis se
rechazan con diagnóstico, no se ejecutan como si fueran compatibles.

Fuentes: `docs/user/develop/basic/publish.md` del repo oficial
`deepseek-ai/deepseek-harness`; documentación MCP y pruebas con paquetes reales.

- [x] MCP stdio: initialize/initialized, tools/list/call, timeout, logs stderr,
      cierre y tests con transporte falso (CI `45312414820`; 263 tests en verde)
- [x] Sesión admite varios servidores (URL HTTP o comando stdio por línea),
      asigna namespace de herramientas por servidor; configuración guardada en provider
      settings (CI `45313077839` en verde)
- [x] Deshabilitar una entrada individual MCP anteponiendo `#` en Ajustes
- [x] Variables secretas por servidor cifradas con Android Keystore e inyectadas
      a procesos stdio (CI `45315887115` Analyze/Tests/Format en verde)
- [x] Modo `npm-package` aislado con pin semver exacto, package-lock validado
      (registry.npmjs.org + integridad), `npm ci` y scripts de instalación off
- [x] Límites para procesos stdio (CPU, tamaño de archivos, descriptores) y
      timeout de 10 minutos para instalación npm
- [x] Mostrar y aprobar package-lock (nombre/versión de dependencias) antes
      de `npm ci`; se vuelve a verificar que no cambie tras la aprobación
- [x] Política de aprobación por servidor: predeterminada por llamada, con `!`
      explícito para confiar en un servidor y omitir prompts
- [ ] Límite de almacenamiento total y permisos finos por herramienta/capacidad
- [ ] Adaptador de paquetes `dsh.bundle`: leer package.json + patches declarados,
      soportar filas de plugins de herramientas/skills mediante shim Node
- [x] Diagnóstico de preflight `DshBundleDiagnostic` con clasificación MCP
      candidata, sugerencia segura `npm-package` si package.json es publicable,
      y lista explícita de capacidades Cordis incompatibles (no instala)
- [x] Inspección acotada de ZIP `.dsh.bundle` (sin extraer/ejecutar) y fixture
      sintético en pruebas
- [ ] Fixtures reales seleccionados, formatos alternativos, compatibilidad
      declarada por capability y shim MCP ejecutable; no ejecutar silenciosamente
- [ ] Fixtures y pruebas de compatibilidad con MCP npm y bundles DSH seleccionados
- [ ] UI de catálogo/instalación, permisos, actualización y desinstalación

## Fase 14 — Firma y publicación

- [x] Versión `0.2.0` en `pubspec.yaml` y notas de release actualizadas
- [ ] Configurar secrets de firma en GitHub Actions (`KEYSTORE_BASE64`,
      `KEYSTORE_PASSWORD`, `KEY_PASSWORD`, `KEY_ALIAS`). El build actual
      `45308310906` compiló y verificó un APK con la clave DEBUG porque esos
      secrets no están disponibles; no es publicable ni actualizable como release.
- [ ] Tras restaurar la clave `chronoxai`, ejecutar build firmado y verificar
      su certificado SHA-256; entonces crear tag `v0.2.0` para publicar el APK
      firmado en GitHub Releases

---

## Estado de verificación

- CI (`.github/workflows/ci.yml`): Analyze, Format, Tests, Runtime Linux y
  Build APK release. Sin toolchain local, **ninguna fase se marca `[x]` sin
  un run en verde**.
- Sin probar en dispositivo real hasta que el usuario lo haga: SELinux,
  páginas de 16 KB, `SpeechRecognizer`, alarmas exactas.
