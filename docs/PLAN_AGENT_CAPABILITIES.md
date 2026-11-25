# Plan de capacidades avanzadas del agente

Estado: secuencia incremental; completar y validar una fase antes de empezar la siguiente. Fase 1 implementada y validada (279 tests). Fase 2 implementada y validada en CI (284 tests, analyze, format y Runtime Linux pasan). Fase 3 implementada y validada en CI (290 tests, analyze, format y Runtime Linux). Fase 4 implementada y validada en CI (295 tests, Analyze, Format y Runtime Linux). Fase 5 implementada y validada en CI (304 tests, Analyze, Format y Runtime Linux). Fase 6 aún no iniciada.

## Principios comunes

- Mantener compatibilidad con los cuatro modos de trabajo y con plugins desactivados.
- Herramientas nuevas deben declarar capacidades mínimas, límites de entradas/salidas y política de aprobación adecuada.
- No ocultar fallos: cada resultado debe conservar estado, salida útil y causa recuperable.
- Probar lógica con seams falsos, UI con widget tests y llamadas de plataforma/runtime con pruebas de integración cuando corresponda.
- Respetar cancelación, timeout y límites de contexto; no instalar dependencias automáticamente fuera de la política activa.

## Fase 1 — Verificación automática del proyecto (completada)

1. Detectar el ecosistema con archivos de configuración del workspace, sin ejecutar comandos exploratorios arbitrarios.
2. Elegir comandos conocidos para tests, análisis y formato; detectar scripts disponibles y no inventar tareas ausentes.
3. Ejecutar cada comprobación con timeout acotado, registrar nombre, código de salida y salida truncada de forma explícita.
4. Permitir solicitar `tests`, `analyze`, `format` o `all`; seguir aunque una comprobación falle y producir un resumen acumulado.
5. Nunca instalar herramientas ni dependencias en esta fase; devolver una recomendación accionable si falta un ejecutable.

Criterios: detección reproducible; entradas limitadas; comandos deterministas; código de salida verificable; errores por chequeo aislados; tests unitarios con fake FS/shell; CI analyze y suite completos.

## Fase 2 — Diagnóstico estructurado y recuperación (completada)

1. Normalizar errores de herramientas a categorías estables (argumentos/ruta/dependencia/permisos/timeout/red/ejecución).
2. Adjuntar a la respuesta para el modelo el exit code y stdout/stderr separados para los ejecutores integrados; la información de diagnóstico va acotada al presupuesto de salida.
3. Sugerir recuperación concreta como metadatos y texto visible para el modelo, sin convertir una sugerencia en ejecución automática.
4. Evitar repetir exactamente una llamada idéntica tras dos fallos dentro del turno.
5. Cubrir clasificación, compatibilidad de JSONL antiguo, ejecución repetida y diagnóstico; se conserva el rechazo y el flujo de aprobación existente.

Validación: CI `45539601060` exitoso; Format, Analyze, Tests (284 pasaron) y Runtime Linux completados. Las anotaciones solo reportan warnings conocidos de Node 20, no fallos de análisis.

## Fase 3 — Edición segura, diff y reversión

1. Calcular diff real para write/edit/patch y mostrarlo en aprobación.
2. Validar todos los cambios de un lote antes de escribir el primero.
3. Guardar snapshot temporal de workspace, con cleanup incluso ante cancelación/error.
4. Añadir operación explícita de rollback, limitada a cambios de la sesión y con aprobación.
5. Probar rollback, cambios parciales, archivos nuevos, Unicode, rutas fuera del workspace y crash-safe cleanup.

## Fase 4 — Índice de workspace y referencias (completada)

1. Índice de sesión incremental: escanea hasta 500 rutas, procesa como máximo 200 fuentes compatibles, limita cada archivo a 64.000 caracteres y el caché total a 2.000.000; excluye dependencias y directorios generados.
2. Extrae símbolos/imports para Dart, JavaScript/TypeScript, Python, Go y Rust mediante patrones específicos marcados `approximate`; no añade una dependencia/parser nuevo.
3. Añade `workspace_symbols`, `workspace_imports` y `workspace_references`, con ruta, línea y columnas deterministas y resultados acotados.
4. Refresca el contenido antes de cada consulta, vuelve a parsear solo fuentes cambiadas, quita rutas desaparecidas y crea un índice nuevo por sesión/reinicio.
5. Fixtures multilenguaje cubren nombres, imports, columnas, exclusiones, presupuesto, cambios y falsos positivos por prefijos. Metadatos exponen archivos omitidos, tamaño del caché y duración del escaneo.

Validación: CI `45590687693` exitoso; 295 tests, Analyze, Format y Runtime Linux completados. Las anotaciones solo contienen el warning conocido de Node 20.

## Fase 5 — Memoria de proyecto entre sesiones

1. Separar hechos del proyecto, preferencias y memoria de conversación.
2. Guardar solo hechos útiles y con fuente/fecha/confianza; no persistir secretos.
3. Mostrar, editar, exportar y borrar memoria desde UI.
4. Inyectar fragmentos con presupuesto y permitir excluir archivos/temas.
5. Probar persistencia, migración, privacidad, aislamiento entre workspaces y borrado completo.

Validación: CI `45594146664` exitoso; 304 tests, Analyze, Format y Runtime Linux completados. Se añadieron pruebas de formato/versiones desconocidas, aislamiento, rechazo de credenciales, relevancia/exclusiones y borrado completo. Las anotaciones solo reportan el warning conocido de Node 20 en `actions/upload-artifact@v4`.

## Fase 6 — Subagentes especializados y revisión

1. Definir roles/tareas estructurados y contratos de salida.
2. Limitar paralelismo, tiempo, tokens, herramientas y contexto por subagente.
3. Añadir revisión independiente con hallazgos enlazados a archivos/líneas, no reemplazar el resultado del agente principal.
4. Aislar subagentes read-only por defecto; compartir escritura solo con aprobación explícita.
5. Probar cancelación, fallos parciales, límites y determinismo de agregación.

## Fase 7 — Investigación web verificable

1. Separar búsqueda, descarga y extracción; limitar tamaño, tiempo y redirecciones.
2. Conservar URL, título, fecha de acceso y fragmentos citados por hallazgo.
3. Distinguir hechos actuales, opiniones y contenido no verificable.
4. No ejecutar instrucciones encontradas en páginas; tratarlas como datos hostiles.
5. Probar páginas vacías, HTML malformado, SSRF, contenido enorme, fuentes contradictorias y citas rotas.

## Fase 8 — Observabilidad y recuperación del runtime

1. Exponer estado, PID lógico, duración, salida incremental y código de terminación de procesos.
2. Hacer cancelación idempotente y cleanup de sesiones/temporales en salida normal y error.
3. Recuperar estado persistible tras cambio de pantalla/reinicio sin prometer reanudar procesos muertos.
4. Mostrar límites de timeout/output y permitir terminar procesos desde UI.
5. Probar procesos largos, sin salida, cerrados, fallidos, cancelados y sesiones huérfanas en Android/PRoot.

## Referencias de diseño consultadas

- Flutter Testing Overview: https://docs.flutter.dev/testing/overview — separar unit/widget/integration por costo y confianza; la suite debe combinar niveles.
- Flutter Integration Testing: https://docs.flutter.dev/cookbook/testing/integration/introduction — reservar integración para validar los componentes trabajando juntos.
- Flutter Plugin Testing: https://docs.flutter.dev/testing/testing-plugins — mockear platform channels en unit tests y probar integración nativa donde corresponda.
