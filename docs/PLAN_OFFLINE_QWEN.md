# Plan consecutivo — inferencia offline de Qwen en Android

## Objetivo

Añadir a ChronoxAI un proveedor de modelos que ejecute inferencia **dentro de la app y del dispositivo**, sin Ollama, daemon local, API remota ni conexión de red durante la generación. Los destinos base solicitados son los artefactos llamados `qwen3.5:0.8b` y `qwen3.5:2b`. Los objetivos de producto son solo Qwen3.5-0.8B y Qwen3.5-2B, priorizando dispositivos Android de gama media con 8 GB de RAM. Qwen3.5-4B y Gemma 4 E2B quedan fuera de la ruta principal y, si se retoman, serán experimentos opt-in separados; no se consideran candidatos recomendados para ese perfil de dispositivo ni sustituyen a los modelos pedidos sin superar los mismos tests.

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
| Alternativa ~2B | Google posiciona Gemma 4 E2B (~2.3B efectivos) para móvil/edge; recomienda LiteRT-LM. El archivo `.litertlm` publicado tiene 2,588,147,712 bytes y SHA-256 `181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c`. Google informa <1.5 GB de memoria en algunos dispositivos compatibles, no como mínimo universal. | Es un candidato real a comparar, pero necesita formato `.litertlm`/runtime diferente al GGUF/llama.cpp. La app de referencia Android de Google declara minSdk 31; falta determinar si el AAR LiteRT-LM fijado permite el API 28 previsto. No prometer compatibilidad en API 28 hasta verificar el AAR y hacer build/device test. |
| Licencia | Las fichas oficiales de Qwen3.5-0.8B y Qwen3.5-2B muestran Apache License 2.0; las fichas GGUF fijadas de Unsloth declaran `apache-2.0` y enlazan la licencia base correspondiente. | Licencia declarada corroborada documentalmente para base y conversión; antes de distribuir, conservar las copias de LICENSE/NOTICE aplicables, confirmar los textos en las revisiones exactas y añadir atribuciones de Qwen y Unsloth. |

Fuentes consultadas: [Qwen official repository and model list](https://github.com/QwenLM/Qwen3.8), [Qwen model license file](https://github.com/QwenLM/Qwen3.8/blob/main/LICENSE), [llama.cpp Qwen3.5 implementation](https://github.com/ggml-org/llama.cpp/blob/master/src/models/qwen35.cpp), [llama.cpp Android guide](https://github.com/ggml-org/llama.cpp/blob/master/docs/android.md), [llama.cpp Android example Gradle config](https://github.com/ggml-org/llama.cpp/blob/master/examples/llama.android/lib/build.gradle.kts), [llama.cpp Android example](https://github.com/ggml-org/llama.cpp/tree/master/examples/llama.android), [Google Gemma 4 on-device announcement](https://developers.googleblog.com/bring-state-of-the-art-agentic-skills-to-the-edge-with-gemma-4/), [Google LiteRT-LM performance and E2B artifact](https://developers.googleblog.com/blazing-fast-on-device-genai-with-litert-lm/), [LiteRT-LM Android/Kotlin API](https://github.com/google-ai-edge/LiteRT-LM/blob/main/docs/api/kotlin/getting_started.md), [Google AI Edge Gallery Android minSdk](https://github.com/google-ai-edge/gallery/blob/main/Android/src/app/build.gradle.kts), [Gemma E2B LiteRT-LM artifact](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/blob/main/gemma-4-E2B-it.litertlm), [tarjeta GGUF 0.8B](https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF), [archivo 0.8B Q4_K_M fijado](https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/blob/6ab461498e2023f6e3c1baea90a8f0fe38ab64d0/Qwen3.5-0.8B-Q4_K_M.gguf), [tarjeta GGUF 2B](https://huggingface.co/unsloth/Qwen3.5-2B-GGUF), [archivo 2B Q4_K_M fijado](https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/blob/f6d5376be1edb4d416d56da11e5397a961aca8ae/Qwen3.5-2B-Q4_K_M.gguf), [tarjeta Qwen 4B GGUF](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF), [archivo 4B Q4_K_M fijado](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/blob/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf). Las páginas de archivos reportan tamaños y SHA-256 recogidos en las tablas; falta comprobar esos bytes desde una descarga real controlada.

### Estado del gate

**EN PROGRESO: la verificación documental avanzó, pero la Fase 1 aún no está desbloqueada.** Se inspeccionaron las páginas de archivos en sus revisiones fijadas: confirman los tamaños redondeados y los SHA-256 reportados para ambos GGUF. El GGUF 2B expone metadatos `general.architecture=qwen35`, `general.file_type=Q4_K_M`, licencia `apache-2.0`, plantilla de chat y metadatos del tokenizer; las tarjetas fijadas de Unsloth para 0.8B y 2B declaran igualmente `apache-2.0`, con enlace a la licencia oficial Qwen, cuyas páginas se revisaron. Esta lectura documental no equivale a descargar y hashear independientemente los bytes ni a capturar las licencias en el producto. Pendiente: validar ambos hashes con archivos descargados, inspeccionar metadatos/tokenizer/chat template completos del 0.8B y revisar los metadatos de ambos modelos con herramienta GGUF, conservar licencias/atribuciones aplicables y validar carga/generación en hardware Android ARM64. En este entorno no hay `adb`, Flutter/Java ni dispositivo Android conectado, así que no se puede completar el build/test de dispositivo aquí. API 28 queda como baseline provisional para Qwen; si LiteRT-LM exige API 31, Gemma será un benchmark separado o requerirá revisar el mínimo Android mediante decisión explícita.

1. Descargar cada candidato a almacenamiento temporal controlado, verificar longitud y SHA-256, y no guardar los pesos grandes en Git.
2. Inspeccionar GGUF metadata/tokenizer/chat template/contexto y LICENSE de las revisiones fijadas; guardar los metadatos esenciales y atribuciones, no los pesos.
3. Compilar `llama.cpp` en CI para las ABI nativas del producto y probar carga/generación en Android ARM64 API 28; medir RAM además del tamaño del archivo.
4. Comprobar si LiteRT-LM se puede integrar de forma soportada con API 28; la app oficial AI Edge Gallery usa API 31. Si no, decidir si se excluye Gemma de la app/API 28 o si se eleva minSdk a 31 para incluirlo.
5. Acordar dispositivos objetivo y umbrales de latencia/RAM/almacenamiento antes de aprobar el gate.

Las etiquetas de Ollama son solo alias de UX; el plan fija IDs de repositorio/archivo/revisión de GGUF y no depende de Ollama ni de un servidor.

### Candidatos fijados para la prueba (no redistribuir hasta verificar)

Se propone empezar con las cuantizaciones `Q4_K_M` del repositorio GGUF de Unsloth, cuyo modelo base es el modelo oficial Qwen y que están destinadas a `llama.cpp`:

| Alias solicitado | ID oficial del modelo base | Archivo GGUF candidato | Tamaño reportado | SHA-256 reportado | Revisión fijada |
|---|---|---|---:|---|---|
| `qwen3.5:0.8b` | `Qwen/Qwen3.5-0.8B` | `Qwen3.5-0.8B-Q4_K_M.gguf` | 532,517,120 bytes (≈533 MB) | `bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517` | `6ab461498e2023f6e3c1baea90a8f0fe38ab64d0` |
| `qwen3.5:2b` | `Qwen/Qwen3.5-2B` | `Qwen3.5-2B-Q4_K_M.gguf` | 1,280,835,840 bytes (≈1.28 GB) | `aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223` | `f6d5376be1edb4d416d56da11e5397a961aca8ae` |

Comparadores adicionales (no son reemplazos decididos):

| Modelo | Artefacto | Tamaño y hash reportados | Backend | Estado |
|---|---|---|---|---|
| Qwen3.5-4B | `Qwen3.5-4B-Q4_K_M.gguf` | 2,740,937,888 bytes; SHA-256 `00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4` | llama.cpp, GGUF | Fuera del objetivo de 8 GB de RAM para gama media; solo experimento opt-in en hardware de más memoria, no bloquea ni amplía la ruta principal. Revisión fijada `e87f176479d0855a907a41277aca2f8ee7a09523`; sin verificar por descarga/dispositivo. |
| Gemma 4 E2B IT (~2.3B efectivos) | `gemma-4-E2B-it.litertlm` | 2,588,147,712 bytes; SHA-256 `181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c` | LiteRT-LM, Kotlin Android | Alternativa experimental aprobada para estudio comparativo, fuera de la ruta principal de 8 GB; pin de revisión/model license y minSdk exacto aún por verificar. No es intercambiable con GGUF. |

Qwen3.5-9B y las generaciones posteriores Qwen3.6/3.8 quedan fuera del objetivo actual de gama media con 8 GB de RAM por su escala y sus requisitos de memoria. No son parte de la evaluación principal. Qwen3.5-4B también queda fuera del perfil recomendado; su mención se conserva solo como experimento opcional en hardware con más memoria. La ruta principal sigue siendo validar primero 0.8B y luego 2B.

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

1. Definir el directorio privado de modelos y manifiesto versionado con ID, alias visible, archivo, formato (`GGUF`/`.litertlm`), runtime requerido, tamaño, checksum, cuantización, licencia y metadatos de contexto.
2. Permitir descargar el archivo desde una fuente explícita o importarlo con el selector de almacenamiento de Android; soportar reintento, cancelación, progreso y falta de espacio.
3. Descargar a temporal, validar longitud/checksum y publicar con rename atómico; no cargar pesos parciales ni sobrescribir un modelo válido antes de validar el nuevo.
4. Añadir eliminar modelo, espacio requerido/libre y protección contra rutas externas al directorio autorizado.
5. No persistir claves de proveedor ni introducir telemetría. Tras completar la descarga, el modo local debe ser usable sin red.

**Gate:** pruebas de checksum incorrecto, interrupción, reanudación/limpieza, duplicados, almacenamiento insuficiente, importación, borrado y offline; integridad validada al reabrir la app.

## Fase 3 — `LocalLlmProvider` y ciclo de vida de inferencia

1. Implementar `LlmProvider` local manteniendo la firma de streaming usada por `AgentLoop`; resolver el backend desde el manifiesto del modelo (llama.cpp para GGUF; LiteRT-LM solo si Gemma supera su gate).
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

## Fase 6 — Comparación de candidatos ~2B y elección

1. Solo si el spike Qwen 0.8B está verde, probar Qwen3.5-2B en el conjunto de tareas idéntico y en el perfil objetivo de 8 GB.
2. Qwen3.5-4B y Gemma 4 E2B no forman parte de esta comparación de producto; estudiarlos únicamente como experimentos separados y opt-in si se dispone de hardware adecuado y se aprueba expresamente ese alcance.
3. Usar Q4_K_M para los GGUF Qwen; registrar que cualquier comparación experimental con Gemma usa formato y runtime distintos.
4. Medir calidad en español, selección/argumentos de herramientas, tasa de corrección, latencia, tokens/s, pico de RAM, temperatura, batería, almacenamiento y requisito de API.
5. No comparar benchmarks de proveedores como sustituto de pruebas ChronoxAI; declarar los casos en que cada modelo falla.
6. Elegir un modelo principal y opcionalmente conservar otro como descarga opt-in. Nunca cambiar de modelo ni enviar prompts a la nube sin decisión del usuario.

**Gate:** resultados reproducibles en el mismo Android, en modo avión; Gemma solo se considera si LiteRT-LM es compatible con el minSdk objetivo. Si requiere elevarlo, la decisión se confirma antes de tocar `minSdk`. El seleccionado debe superar el corpus de agente y límites de recursos acordados.

## Fase 7 — Release, seguridad y aceptación final

1. Confirmar que APK contiene solo bibliotecas nativas necesarias, no pesos grandes; revisar ABI, stripping y tamaño.
2. Revisar licencias/atribuciones del runtime y de ambos modelos, suma de verificación, seguridad de descarga e importación y exclusión de archivos privados del export.
3. Probar instalación limpia, actualización, modelo ya descargado, modo avión, cancelación durante generación, cierre forzado y poco almacenamiento en un Android real.
4. Actualizar documentación, diagnósticos, notas de release y CI; mantener tests unitarios automatizados y un smoke test real de hardware registrado.

**Gate:** CI Format/Analyze/Tests/APK en verde y checklist del dispositivo firmado por resultado; solo entonces marcar el soporte offline como completado.

## Criterio global

ChronoxAI puede instalarse y seleccionar cada modelo sin Ollama. Una vez que el artefacto se encuentre en almacenamiento local, conversaciones, generación y uso de herramientas se completan en modo avión; la app no inicia un servidor ni contacta servicios remotos para inferencia. Las capacidades y limitaciones del modelo se declaran y no se ocultan con un fallback cloud.
