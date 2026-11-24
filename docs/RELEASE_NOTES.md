# Chronox AI 0.2.0

Primera versión pública candidata de Chronox AI: agente de codificación Android
con runtime Linux local y capacidades de trabajo extensibles.

## Novedades

- Runtime Debian con `proot`, terminal interactiva, sesiones y trabajos activos.
- Modos de trabajo, plan mode, búsqueda web, proveedores OpenAI-compatible,
  Anthropic y Gemini, además de MCP.
- Hooks de proyecto y subagentes con herramientas de solo lectura, incluyendo
  ejecución paralela limitada.
- Plugins externos experimentales por JSON-RPC, con aprobación obligatoria.
- Tareas programadas y entrada de voz del sistema Android.
- Política heurística que bloquea algunos comandos destructivos obvios.

## Seguridad y compatibilidad

- Android 7 o superior; requiere un ABI compatible incluido en el APK.
- No requiere root. El runtime Linux necesita descargar Debian durante la
  configuración inicial.
- `proot` no es un sandbox de kernel. Ejecuta únicamente plugins de confianza.
- La entrada de voz requiere permiso de micrófono; la notificación de tareas
  programadas depende del permiso de notificaciones de Android.
