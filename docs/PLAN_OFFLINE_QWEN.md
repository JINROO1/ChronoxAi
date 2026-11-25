# Plan consecutivo — inferencia offline de Qwen en Android

## Objetivo

Añadir a ChronoxAI un proveedor de modelos que ejecute inferencia **dentro de la app y del dispositivo**, sin Ollama, daemon local, API remota ni conexión de red durante la generación. Los dos destinos solicitados son los artefactos llamados `qwen3.5:0.8b` y `qwen3.5:2b`.

La app ya abstrae el modelo detrás de `LlmProvider`; se debe integrar el motor como un proveedor nuevo y reutilizar `AgentLoop`, herramientas, aprobaciones e historial. El plan es estrictamente secuencial: **no se inicia una fase hasta que su gate de validación esté verde**.

## Decisiones y límites

- Ejecución local embebida, no proceso servidor. Candidato inicial para la prueba: `llama.cpp` con su API nativa; la primera fase técnica debe comprobar que soporta exactamente la arquitectura, tokenizer y formato de los artefactos elegidos. No se da por hecho que una etiqueta de Ollama sea un nombre oficial de archivo GGUF.
- Si el runtime no soporta el modelo Qwen 3.5 exacto, parar en el gate y evaluar un runtime alternativo compatible antes de comprometer la arquitectura. No sustituir silenciosamente por otra generación Qwen ni por una variante no equivalente.
- Descargar/importar el modelo separadamente del APK. El peso ocupa mucho más que el código; APK pequeño y modelo instalable a demanda. Después de una descarga completa, inferencia y chat deben funcionar en modo avión.
- Primera entrega solo texto. Visión, audio y funciones multimodales quedan fuera hasta una solicitud explícita.
- Sin telemetría ni fallback remoto automático. Un modelo local descargado no debe causar tráfico externo al generar.
- Comenzar con 0.8B para validar coste de memoria/latencia y luego habilitar 2B. Mantener cuantización y artefacto identificados por variante, tamaño, SHA-256, licencia y origen verificable.

## Fase 0 — Verificar artefactos y compatibilidad (gate de decisión)

1. Resolver qué archivos exactos corresponden a `qwen3.5:0.8b` y `qwen3.5:2b`: formato, versión, tokenizer, contexto, licencia, origen, checksum y requisitos de RAM/almacenamiento.
2. Confirmar compatibilidad del runtime candidato con la arquitectura Qwen 3.5 y el formato/quantización real; confirmar soporte Android NDK para las ABI que compila ChronoxAI.
3. Fijar dispositivos mínimos de prueba (al menos un teléfono ARM64 real) y presupuesto de RAM, almacenamiento y latencia aceptables.
4. Registrar si la etiqueta `:0.8b`/`:2b` es únicamente alias del catálogo Ollama y cuál es el archivo equivalente exacto; no depender del propio Ollama.

**Gate:** matriz de artefactos y compatibilidad revisada; licencias aceptables; prueba de carga/generación con el modelo exacto en ARM64. Si cualquier condición falla, no avanzar ni descargar/construir los modelos completos: seleccionar un runtime o artefacto compatible mediante decisión explícita.

## Fase 1 — Spike nativo mínimo con Qwen 0.8B

1. Añadir el runtime nativo como dependencia fijada a versión/commit, compilado para Android; no incluir un servidor local.
2. Crear un canal pequeño Kotlin/JNI o FFI Dart para cargar/unload, generar tokens y cancelar.
3. Cargar el archivo Qwen 0.8B del gate y generar un prompt fijo desde una pantalla/harness de prueba, sin red.
4. Medir tamaño nativo, tiempo de carga, tokens/segundo, pico de memoria y estabilidad térmica.

**Gate:** ejecución real en teléfono ARM64, salida determinista dentro de tolerancia, cancelación y liberación sin crash; evidencia de que la generación no abre conexiones. Pruebas de host/CI cubren la interfaz Dart con un backend falso.

## Fase 2 — Gestor local de modelos y almacenamiento

1. Definir el directorio privado de modelos y manifiesto versionado con ID, alias visible, archivo, formato, tamaño, checksum, cuantización, licencia y metadatos de contexto.
2. Permitir descargar el archivo desde una fuente explícita o importarlo con el selector de almacenamiento de Android; soportar reintento, cancelación, progreso y falta de espacio.
3. Descargar a temporal, validar longitud/checksum y publicar con rename atómico; no cargar pesos parciales ni sobrescribir un modelo válido antes de validar el nuevo.
4. Añadir eliminar modelo, espacio requerido/libre y protección contra rutas externas al directorio autorizado.
5. No persistir claves de proveedor ni introducir telemetría. Tras completar la descarga, el modo local debe ser usable sin red.

**Gate:** pruebas de checksum incorrecto, interrupción, reanudación/limpieza, duplicados, almacenamiento insuficiente, importación, borrado y offline; integridad validada al reabrir la app.

## Fase 3 — `LocalLlmProvider` y ciclo de vida de inferencia

1. Implementar `LlmProvider` local manteniendo la firma de streaming usada por `AgentLoop`.
2. Mapear mensajes Chronox (system/user/assistant/tool) a plantilla de conversación exacta del artefacto Qwen; incorporar tokenizer/chat template del modelo, no construir el prompt a mano con separadores arbitrarios.
3. Emitir tokens como `TextChunk`; soportar stop, límite de tokens/contexto, timeout, cancelación nativa y cierre idempotente.
4. Gestionar una sola sesión de inferencia por modelo; cerrar contexto y liberar memoria al cambiar modelo, cerrar sesión o recibir presión de memoria.
5. Errores tipados y visibles: archivo inválido, arquitectura no compatible, memoria, cancelación, generación fallida. No reenviar a proveedor remoto automáticamente.

**Gate:** pruebas unitarias del adaptador con backend falso para token streaming, conversión de roles, stop, cancelación, límites, fallo de carga y liberación; generación real de varios turnos sin fugas/crashes.

## Fase 4 — Selector de modelo y experiencia sin conexión

1. Añadir tipo de proveedor `Local` en Ajustes y selector de modelo con 0.8B/2B solo cuando cada artefacto esté instalado y validado.
2. Mostrar progreso de preparación/descarga, origen, checksum abreviado, tamaño, espacio, estado cargado y advertencia de memoria estimada.
3. Permitir abrir una sesión sin proveedor remoto configurado; informar claramente si falta el modelo, sin ocultar el error ni sugerir una llamada de red.
4. Guardar selección persistente como ID de artefacto, no solo el nombre comercial; reiniciar en el modelo elegido.

**Gate:** pruebas de widget para todos los estados (sin modelos, instalando, listo, error, eliminar/en uso) y comprobación manual en Android con modo avión; no hay peticiones de proveedor remoto.

## Fase 5 — Herramientas y ciclo de agente con Qwen

1. Adaptar solicitud de tool calling al formato soportado por el modelo/runtime; si se requiere modo JSON/gramática, habilitarlo de forma acotada y cancelable.
2. Convertir llamadas a las herramientas existentes a `ToolCallChunk`, validar nombre y argumentos con `ToolRegistry` y conservar el flujo actual de aprobación, permisos y diagnóstico.
3. No ejecutar texto que parezca llamada a herramienta si no pasó el parser/validador. En respuesta malformada, devolver error al modelo y permitir una corrección limitada; nunca repetir en bucle.
4. Medir fiabilidad de selección, argumentos y recuperación con tareas de prueba; comparar 0.8B frente a 2B.

**Gate:** corpus de escenarios reproducible cubre lectura/escritura, shell con aprobación, rechazo, argumentos inválidos, llamada inventada, salida truncada y cancelación. Sin bypass de aprobación; tasa mínima de éxito acordada antes de dar por lista la función.

## Fase 6 — Integrar y verificar Qwen 2B

1. Habilitar el artefacto 2B solo tras superar individualmente el gate del 0.8B.
2. Probar su archivo/tokenizer/plantilla exactos, cuantización y límites de contexto en los mismos dispositivos.
3. Medir carga, tokens por segundo, pico de RAM, temperatura y batería con contexto corto y largo.
4. Hacer fallback solo por decisión del usuario al modelo 0.8B si el 2B no cabe o es demasiado lento; nunca cambiar en silencio a la nube.

**Gate:** carga estable en dispositivos objetivo, criterios de rendimiento/RAM documentados, pruebas de agente y herramientas equivalentes al 0.8B, y ciclo unload/reload limpio.

## Fase 7 — Release, seguridad y aceptación final

1. Confirmar que APK contiene solo bibliotecas nativas necesarias, no pesos grandes; revisar ABI, stripping y tamaño.
2. Revisar licencias/atribuciones del runtime y de ambos modelos, suma de verificación, seguridad de descarga e importación y exclusión de archivos privados del export.
3. Probar instalación limpia, actualización, modelo ya descargado, modo avión, cancelación durante generación, cierre forzado y poco almacenamiento en un Android real.
4. Actualizar documentación, diagnósticos, notas de release y CI; mantener tests unitarios automatizados y un smoke test real de hardware registrado.

**Gate:** CI Format/Analyze/Tests/APK en verde y checklist del dispositivo firmado por resultado; solo entonces marcar el soporte offline como completado.

## Criterio global

ChronoxAI puede instalarse y seleccionar cada modelo sin Ollama. Una vez que el artefacto se encuentre en almacenamiento local, conversaciones, generación y uso de herramientas se completan en modo avión; la app no inicia un servidor ni contacta servicios remotos para inferencia. Las capacidades y limitaciones del modelo se declaran y no se ocultan con un fallback cloud.
