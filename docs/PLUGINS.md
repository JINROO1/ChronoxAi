# Escribir un plugin de Chronox AI

> Filosofía heredada de **DeepSeek Harness**: *todo es un plugin*. Herramientas, modos de
> trabajo, adaptadores de modelo, packs de instrucciones y **pantallas completas** son
> piezas que se montan y se desmontan sin tocar el motor.

---

## 1. Las tres garantías

El kernel (`PluginHost`) promete tres cosas, y las tres están cubiertas por tests:

1. **Composabilidad temporal** — desmontar un plugin revierte **exactamente** sus registros.
   No quedan herramientas huérfanas ni pantallas fantasma.
2. **Composabilidad espacial** — un plugin declara sus dependencias (`requires`) y el host
   monta primero lo que haga falta.
3. **Mínimo privilegio** — un plugin solo recibe las capacidades que declara. Si intenta usar
   otra, recibe `PluginCapabilityDenied`, no un acceso silencioso.

## 2. Anatomía

```dart
class MiPlugin extends ChronoxPlugin {
  static PluginManifest get manifest => const PluginManifest(
    id: 'mi-plugin',                    // kebab-case, único
    name: 'Mi plugin',
    version: '1.0.0',
    kind: PluginKind.surface,           // tool | skill | mode | provider | surface
    description: 'Qué hace, en una línea.',
    capabilities: <PluginCapability>[
      PluginCapability.shell,           // lo que necesito, nada más
    ],
    icon: 'storage',
    surfaceLabel: 'Mi pantalla',        // solo si kind == surface
    surfaceOrder: 200,
    enabledByDefault: false,
  );

  @override
  Future<void> mount(PluginContext context) async {
    // 1. Una herramienta para el agente
    context.provideTool(PluginTool(
      name: 'mi_herramienta',
      description: 'Qué hace y cuándo usarla.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'texto': <String, Object?>{'type': 'string'},
        },
        'required': <String>['texto'],
      },
      execute: (args) async => ToolOutcome(content: 'hecho'),
    ));

    // 2. Su propia pantalla
    context.provideSurface(PluginSurface(
      label: 'Mi pantalla',
      icon: Icons.widgets_outlined,
      builder: (context, scope) => MiVista(scope: scope),
    ));
  }
}
```

Todo lo que se registra con `context.provide*` se revierte solo al desmontar. Si el plugin
abre procesos, timers o `StreamController` propios, hay que cerrarlos en `unmount()`.

## 3. La pantalla del plugin

Un plugin **nunca** crea `Scaffold` ni `AppBar`: eso lo aporta `PluginSurfaceHost`. El plugin
solo devuelve contenido y hereda automáticamente:

* la paleta y la tipografía de la app,
* el `SafeArea` y la barra con el nombre del plugin,
* un `PluginSurfaceScope` con `setState`, `showSnackBar` y `openTerminal`.

Si el `builder` lanza una excepción, el host lo captura y muestra una pantalla de error con
botón de reintentar: **un plugin roto no tumba la app**.

```dart
Widget build(BuildContext context) {
  return Column(children: [
    Text('Contenido', style: Theme.of(context).textTheme.titleSmall),
    FilledButton(
      onPressed: () { hacerAlgo(); scope.setState(); },
      child: const Text('Hacer algo'),
    ),
  ]);
}
```

## 4. Tipos de plugin

| `PluginKind` | Aporta | Aparece en |
|---|---|---|
| `tool` | herramientas invocables por el modelo | prompt del agente |
| `skill` | instrucciones reutilizables | system prompt |
| `mode` | un modo de trabajo nuevo | selector de modos |
| `provider` | un adaptador de modelo | Ajustes → Proveedores |
| `surface` | **una pantalla completa** | navegación principal |

## 5. Capacidades

| Capacidad | Da acceso a | Riesgo |
|---|---|---|
| `fileSystem` | `ctx.fs`: leer/escribir en `/workspace` | medio |
| `shell` | `ctx.shell`: ejecutar comandos | **alto** |
| `terminals` | `ctx.terminals`: terminales persistentes | alto |
| `llm` | `ctx.llm`: llamar al modelo | medio (coste) |
| `session` | `ctx.session`: leer el log | bajo |
| `network` | `ctx.network`: peticiones salientes | medio |

La UI de Ajustes muestra esta lista antes de activar un plugin, con las de riesgo alto
marcadas. Un plugin sin `shell` físicamente **no puede** ejecutar nada: no es una convención,
es una excepción en el seam.

## 6. Modos de trabajo

Un modo es **solo datos**: la lista de plugins que se montan.

```dart
PluginMode(
  id: 'mi-modo',
  name: 'Mi modo',
  description: 'Para qué sirve.',
  pluginIds: <String>['core-fs', 'core-shell'],
  systemPromptPrefix: 'Instrucciones adicionales para el modelo.',
  icon: 'tune',
)
```

Los cuatro modos de dsh ya están implementados en `work_modes.dart`:

| Modo | Plugins | Uso |
|---|---|---|
| **Standard** | 9 (fs, shell, terminal, search, editing, todo, plan, subagent, web) | por defecto |
| **Code (PTC)** | Standard + `code-mode` → herramienta `run_code` | tareas multi-paso |
| **Minimal** | 2 (`base-shell`, `base-editor`) | medir el modelo |
| **Creator** | Standard + `cordis_inspect` + `plugin_manager` | escribir plugins |

## 7. Probar un plugin

```dart
test('mi plugin registra su herramienta y la retira al desmontar', () async {
  final services = makeServices();          // helper del repo
  final host = PluginHost(services: services, events: AgentEventBus());
  host.register(MiPlugin.manifest, MiPlugin());

  await host.mount('mi-plugin');
  expect(services.registry.contains('mi_herramienta'), isTrue);

  await host.unmount('mi-plugin');
  expect(services.registry.contains('mi_herramienta'), isFalse);
});
```

## 8. Plugins externos en runtime (experimental)

Chronox puede cargar un plugin de herramientas desde
`<workspace>/.chronox/plugins/<id>/` sin recompilar el APK. Cada carpeta contiene:

- `manifest.json`: `PluginManifest` JSON, con `kind: "tool"` y capacidades declaradas.
- `plugin.py`: proceso Python del rootfs Debian que habla JSON-RPC 2.0, una petición JSON
  por línea en stdin y una respuesta por línea en stdout.

El host envía `initialize`, `tools/list`, `tools/call` y al cerrar `shutdown`. La salida
no-JSON de logs debe ir a stderr. Todas las herramientas externas exigen aprobación del
usuario aunque el plugin pida lo contrario. Ejemplo funcional:
`chronoxai/assets/plugins/echo/`.

**Límite de seguridad:** proot no es un sandbox. El proceso corre con el UID de la app,
con los binds del runtime y el confinamiento del sistema de archivos al workspace; un plugin
malicioso podría intentar abusar de ese entorno. Instala solo plugins que hayas revisado.
El APK no evalúa código Python dentro del proceso Flutter: el script corre como proceso
separado dentro de Debian. Android sin root no ofrece Landlock/Seatbelt para convertirlo en
una frontera de seguridad fuerte.

### MCP npm por stdio

El campo «Servidor MCP» admite una URL HTTP(S) o comando stdio por línea.
También admite `stdio:npx --yes <paquete>` o
`stdio:node /workspace/ruta/server.js`, si `node`/`npm`/`npx` están instalados
por el usuario en Debian. El cliente negocia MCP, descubre `tools/list` y llama
`tools/call`; cada herramienta remota requiere aprobación. `npx` puede descargar
código arbitrario y ejecutarlo: Chronox no lo instala silenciosamente; revisa el
paquete y sus scripts antes de autorizarlo. Ajustes permite varias entradas,
una URL o comando por línea; anteponer `#` deshabilita una entrada sin borrarla.
La gestión de variables de entorno seguras, lockfiles y aprobación por servidor
queda como trabajo pendiente de compatibilidad.
