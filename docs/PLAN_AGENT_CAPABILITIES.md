# Plan de capacidades avanzadas del agente

Estado: secuencia incremental; completar y validar una fase antes de empezar la siguiente. No se considera una fase terminada hasta que sus pruebas y criterios de aceptación pasan.

## Principios comunes

- Mantener compatibilidad con los cuatro modos de trabajo y con plugins desactivados.
- Herramientas nuevas deben declarar capacidades mínimas, límites de entradas/salidas y política de aprobación adecuada.
- No ocultar fallos: cada resultado debe conservar estado, salida útil y causa recuperable.
- Probar lógica con seams falsos, UI con widget tests y llamadas de plataforma/runtime con pruebas de integración cuando corresponda.
- Respetar cancelación, timeout y límites de contexto; no instalar dependencias automáticamente fuera de la política activa.

## Fase 1 — Verificación automática del proyecto (en curso)

1. Detectar el ecosistema con archivos de configuración del workspace, sin ejecutar comandos exploratorios arbitrarios.
2. Elegir comandos conocidos para tests, análisis y formato; detectar scripts disponibles y no inventar tareas ausentes.
3. Ejecutar cada comprobación con timeout acotado, registrar nombre, código de salida y salida truncada de forma explícita.
4. Permitir solicitar `tests`, `analyze`, `format` o `all`; seguir aunque una comprobación falle y producir un resumen acumulado.
5. Nunca instalar herramientas ni dependencias en esta fase; devolver una recomendación accionable si falta un ejecutable.

Criterios: detección reproducible; entradas limitadas; comandos deterministas; código de salida verificable; errores por chequeo aislados; tests unitarios con fake FS/shell; CI analyze y suite completos.

## Fase 2 — Diagnóstico estructurado y recuperación

1. Normalizar errores de herramientas a categorías estables (argumentos/ruta/dependencia/permisos/timeout/red/ejecución).
2. Adjuntar a la respuesta para el modelo el comando, exit code, stdout/stderr separados y contexto limitado.
3. Sugerir recuperación concreta como metadatos, sin convertir una sugerencia en ejecución automática.
4. Permitir reintentos acotados y evitar repetir exactamente la misma llamada fallida.
5. Probar cada categoría y garantizar que el rechazo del usuario detiene acciones privilegiadas.

## Fase 3 — Edición segura, diff y reversión

1. Calcular diff real para write/edit/patch y mostrarlo en aprobación.
2. Validar todos los cambios de un lote antes de escribir el primero.
3. Guardar snapshot temporal de workspace, con cleanup incluso ante cancelación/error.
4. Añadir operación explícita de rollback, limitada a cambios de la sesión y con aprobación.
5. Probar rollback, cambios parciales, archivos nuevos, Unicode, rutas fuera del workspace y crash-safe cleanup.

## Fase 4 — Índice de workspace y referencias

1. Indexado incremental con exclusiones y límites por tamaño/extensión.
2. Extraer símbolos/imports con parser específico cuando exista; fallback de texto marcado como aproximado.
3. Herramientas de símbolos/referencias con rutas y rangos reproducibles.
4. Invalidar índice al detectar cambios de archivos y al reiniciar sesiones.
5. Comparar resultados contra fixtures de varios lenguajes; medir memoria, latencia y falsos positivos.

## Fase 5 — Memoria de proyecto entre sesiones

1. Separar hechos del proyecto, preferencias y memoria de conversación.
2. Guardar solo hechos útiles y con fuente/fecha/confianza; no persistir secretos.
3. Mostrar, editar, exportar y borrar memoria desde UI.
4. Inyectar fragmentos con presupuesto y permitir excluir archivos/temas.
5. Probar persistencia, migración, privacidad, aislamiento entre workspaces y borrado completo.

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
