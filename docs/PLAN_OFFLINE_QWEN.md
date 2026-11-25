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

### Investigación inicial (2026-11-23)

| Dato | Resultado | Implicación |
|---|---|---|
| Nombres oficiales | El repositorio oficial de Qwen enumera `Qwen3.5-0.8B` y `Qwen3.5-2B` entre las variantes publicadas el 2026-03-02. | Los nombres pedidos corresponden a tamaños oficiales; en el producto mostraremos nombres oficiales y trataremos `qwen3.5:0.8b`/`:2b` solo como alias solicitados, no como IDs de artefacto. |
| Runtime | Qwen declara que `llama.cpp` soporta Qwen3.5 texto+visión y recomienda GGUF; el árbol de `llama.cpp` contiene implementación `src/models/qwen35.cpp` y conversión/tokenizer Qwen35. | `llama.cpp` es candidato viable para el spike; aún falta probar los archivos exactos y su API embebida en un teléfono Android. |
| Android | `llama.cpp` publica guía de Android, ejemplo Kotlin/AAR y workflow de compilación. Su ejemplo AAR actual declara `minSdk = 33`; este app declara `minSdk = 24`. La guía CMake usa API 28 como baseline ilustrativo para builds portables por NDK y ABI. | Baseline provisional de trabajo: API 28 con binding JNI/FFI propio; validar dispositivo/emulador API 28 antes de fijarlo definitivamente. No usar el AAR de ejemplo (requiere API 33) ni cambiar minSdk sin medir el impacto. |
| ABI de ChronoxAI | La configuración Android actual mantiene filtros para `arm64-v8a` y `x86_64`; `llama.cpp` documenta builds Android para ambas familias. | Compilar el backend offline solo para las ABI que el APK ya declara; probar ARM64 físico primero y x86_64 solo si se mantiene como objetivo del producto. |
| Licencia | El repositorio público de Qwen3.8 declara Apache-2.0; resultados de las fichas GGUF indican `apache-2.0` para los derivados de Unsloth y enlazan la licencia base de Qwen. | Candidato compatible con Apache-2.0, pendiente copiar/verificar los LICENSE de cada revisión fijada y conservar atribuciones de Qwen y Unsloth antes de distribuir. |

Fuentes consultadas: [Qwen official repository and model list](https://github.com/QwenLM/Qwen3.8), [Qwen model license file](https://github.com/QwenLM/Qwen3.8/blob/main/LICENSE), [llama.cpp Qwen3.5 implementation](https://github.com/ggml-org/llama.cpp/blob/master/src/models/qwen35.cpp), [llama.cpp Android guide](https://github.com/ggml-org/llama.cpp/blob/master/docs/android.md), [llama.cpp Android example Gradle config](https://github.com/ggml-org/llama.cpp/blob/master/examples/llama.android/lib/build.gradle.kts), [llama.cpp Android example](https://github.com/ggml-org/llama.cpp/tree/master/examples/llama.android), [tarjeta GGUF 0.8B](https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF), [archivo 0.8B Q4_K_M fijado](https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/blob/6ab461498e2023f6e3c1baea90a8f0fe38ab64d0/Qwen3.5-0.8B-Q4_K_M.gguf), [tarjeta GGUF 2B](https://huggingface.co/unsloth/Qwen3.5-2B-GGUF), [archivo 2B Q4_K_M fijado](https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/blob/f6d5376be1edb4d416d56da11e5397a961aca8ae/Qwen3.5-2B-Q4_K_M.gguf). Las páginas de archivos reportan tamaños y SHA-256 recogidos en la tabla; falta comprobar esos bytes desde una descarga real controlada.

### Estado del gate

**EN PROGRESO: la verificación documental avanzó, pero la Fase 1 aún no está desbloqueada.** Ya hay mapeo candidato con IDs de base, revisiones GGUF, quant `Q4_K_M`, tamaños y hashes reportados; se confirmó el tipo `qwen35` y soporte upstream en llama.cpp. Pendiente: comprobar los bytes/hash descargando ambos archivos desde las revisiones fijadas, leer los LICENSE y metadatos/tokenizer/chat template de esas revisiones, y validar carga/generación en hardware Android ARM64. API 28 queda como baseline provisional para el spike, con JNI/FFI propio; el nivel mínimo final depende de prueba real.

1. Descargar cada candidato a almacenamiento temporal controlado, verificar longitud y SHA-256, y no guardar los pesos grandes en Git.
2. Inspeccionar GGUF metadata/tokenizer/chat template/contexto y LICENSE de las revisiones fijadas; guardar los metadatos esenciales y atribuciones, no los pesos.
3. Compilar `llama.cpp` en CI para las ABI nativas del producto y probar carga/generación en Android ARM64 API 28; medir RAM además del tamaño del archivo.
4. Acordar dispositivos objetivo y umbrales de latencia/RAM/almacenamiento antes de aprobar el gate.

Las etiquetas de Ollama son solo alias de UX; el plan fija IDs de repositorio/archivo/revisión de GGUF y no depende de Ollama ni de un servidor.

### Candidatos fijados para la prueba (no redistribuir hasta verificar)

Se propone empezar con las cuantizaciones `Q4_K_M` del repositorio GGUF de Unsloth, cuyo modelo base es el modelo oficial Qwen y que están destinadas a `llama.cpp`:

| Alias solicitado | ID oficial del modelo base | Archivo GGUF candidato | Tamaño reportado | SHA-256 reportado | Revisión fijada |
|---|---|---|---:|---|---|
| `qwen3.5:0.8b` | `Qwen/Qwen3.5-0.8B` | `Qwen3.5-0.8B-Q4_K_M.gguf` | 532,517,120 bytes (≈533 MB) | `bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517` | `6ab461498e2023f6e3c1baea90a8f0fe38ab64d0` |
| `qwen3.5:2b` | `Qwen/Qwen3.5-2B` | `Qwen3.5-2B-Q4_K_M.gguf` | 1,280,835,840 bytes (≈1.28 GB) | `aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223` | `f6d5376be1edb4d416d56da11e5397a961aca8ae` |

Candidatos upstream: [Unsloth 0.8B GGUF pinned file](https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/6ab461498e2023f6e3c1baea90a8f0fe38ab64d0/Qwen3.5-0.8B-Q4_K_M.gguf) y [Unsloth 2B GGUF pinned file](https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/f6d5376be1edb4d416d56da11e5397a961aca8ae/Qwen3.5-2B-Q4_K_M.gguf). Las páginas de los artefactos reportan los SHA anteriores. Los modelos base oficiales se enlazan desde la [colección oficial de Qwen](https://huggingface.co/collections/Qwen/qwen35); los resultados publicados reportan Apache-2.0 para los modelos base, pero antes de distribuir se debe conservar/verificar el archivo LICENSE de cada tarjeta y las atribuciones de la conversión Unsloth.

Se adopta provisionalmente `Q4_K_M` para mantener el archivo en un rango viable para descarga móvil. El tamaño del archivo **no** es el requisito de RAM: habrá que medir memoria de pesos + KV cache + runtime. Aunque el modelo anuncia contexto largo (hasta ~262K tokens según sus fichas), ChronoxAI empezará con contexto local acotado y configurable, no con el máximo teórico.

**Gate:** los identificadores, archivos, revisiones y SHA-256 quedan propuestos con evidencia de las tarjetas; todavía hay que descargar temporalmente cada candidato en CI/harness controlado, comparar su SHA-256 real, inspeccionar metadatos/tokenizer/chat template y licencia de cada tarjeta, y cargar/generar con ellos en ARM64 al nivel Android mínimo elegido. Si algo no coincide, no pasar a Fase 1 ni actualizar el catálogo. Se adopta API 28 como baseline de trabajo para el spike, sujeto a prueba real; se usará binding JNI/FFI propio, no el AAR que declara API 33.

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
