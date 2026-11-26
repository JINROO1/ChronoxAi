# Protocolo de aceptación física — Qwen offline

Este protocolo se ejecuta **una sola vez, cuando la versión instalable final esté lista**, en un teléfono físico. No sustituirlo por un emulador. El REDMAGIC 8S Pro de 16 GB valida ese dispositivo; por sí solo no certifica el perfil general de 8 GB.

## Evidencia de la build

- Commit probado:
- GitHub Actions run / artefacto:
- SHA-256 del APK (validar con `SHA256SUMS`):
- ¿APK firmado con clave release real?:
- Versión instalada / ¿instalación limpia o actualización?:
- Resultado de instalación y apertura:

## Dispositivo y estado inicial

- Fabricante/modelo:
- Android/API / parche:
- ABI (la pantalla de Modelos sin conexión muestra API/ABI):
- RAM total / almacenamiento libre:
- Temperatura aproximada del dispositivo:
- Estado batería y ahorro de energía:

## Casos requeridos — hacer por separado para 0.8B y 2B

1. Instalar/abrir ChronoxAI y descargar o importar el modelo. Confirmar tamaño, checksum abreviado y origen fijado en la ficha. En importación SAF, verificar aceptación del GGUF fijado y rechazo/limpieza para un archivo que no coincida.
2. Seleccionar el proveedor **Modelo local integrado (sin red)** y el ID correcto; cerrar y volver a abrir la app, comprobar que proveedor y modelo persisten.
3. Activar modo avión (Wi-Fi y datos móviles apagados) después de tener el modelo. Enviar al menos tres prompts en español y una conversación de dos turnos. Deben llegar respuestas; no debe aparecer un fallback ni un error de proveedor remoto.
4. Durante una generación larga, cancelar desde la UI; comprobar que el stream se detiene, la app sigue respondiendo y una generación posterior funciona.
5. Abrir **Mediciones del dispositivo** después de una generación. Registrar RSS actual/pico, PSS, RAM disponible, tiempo de carga y tokens/s. Repetir luego de varios turnos; anotar cierres, calentamiento o ralentización.
6. Mantener una prueba intermitente por 10 minutos; anotar estabilidad, throttling percibido y batería. No forzar la ejecución si el teléfono muestra temperatura crítica.
7. Con los plugins de archivo/shell habilitados, ejecutar las tareas siguientes; el shell debe pedir aprobación, la aceptación ejecuta solo el comando indicado y el rechazo no ejecuta nada:
   - “Lee el archivo `offline-qa/readme.txt` y dime su primera línea.” (preparar el archivo con el texto `CHRONOX_OFFLINE_OK`).
   - “Crea `offline-qa/result.txt` con el texto `local-only` y léelo de vuelta.” Verificar que el archivo realmente cambió.
   - “Ejecuta `printf CHRONOX_APPROVED` en el shell.” Aceptar y confirmar la salida.
   - Repetir la orden de shell y rechazarla; confirmar que no se ejecutó.
8. Cambiar a otro proveedor/modelo, descargar el segundo Qwen y volver a seleccionar el modelo local. Confirmar que el modelo en uso no se puede borrar hasta cambiar de proveedor/modelo.

## Resultados por modelo

| Medida | 0.8B | 2B |
|---|---:|---:|
| Primera carga (s) | | |
| RSS pico (MiB) | | |
| PSS (MiB) | | |
| Tokens/s después del calentamiento | | |
| Generaciones completadas / intentadas | | |
| Cancelación y recuperación correctas | | |
| Tareas de archivo correctas | | |
| Shell: aprobación ejecuta / rechazo no ejecuta | | |
| Modo avión sin fallbacks remotos | | |
| Estabilidad/temperatura/batería (notas) | | |

## Dictamen

- [ ] La instalación y descarga/importación fueron correctas.
- [ ] Ambos GGUF se cargaron desde almacenamiento privado.
- [ ] Los casos de conversación funcionaron con modo avión.
- [ ] Cancelar no dejó la inferencia bloqueada y liberar/cambiar modelo no cerró la app.
- [ ] Las llamadas respetaron validación de argumentos, permisos y decisión del usuario; el rechazo de shell no produjo efecto.
- [ ] Se conservaron APK, SHA-256 y estas mediciones.
- [ ] El perfil 8 GB se validó en un dispositivo físico de 8 GB (si no, **no** marcar soporte general de 8 GB).

Resultado final: **pendiente de ejecutar en el teléfono físico**. No marcar los gates de Fase 1, 4, 5, 6 o 7 como aceptados hasta registrar la evidencia correspondiente. Los umbrales de RAM/latencia descritos en `PLAN_OFFLINE_QWEN.md` siguen siendo propuestas hasta decisión y medición.
