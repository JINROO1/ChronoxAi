# Avisos de terceros — inferencia offline

## Qwen3.5 (0.8B y 2B)

Los modelos base Qwen3.5-0.8B y Qwen3.5-2B se ofrecen bajo Apache License 2.0. ChronoxAI no empaqueta sus pesos en el APK; el usuario descarga o importa por separado el GGUF Q4_K_M.

## Conversión GGUF de Unsloth

Los archivos `Qwen3.5-0.8B-Q4_K_M.gguf` y `Qwen3.5-2B-Q4_K_M.gguf` se obtienen de las tarjetas Unsloth fijadas a revisiones inmutables del catálogo:

- 0.8B: `6ab461498e2023f6e3c1baea90a8f0fe38ab64d0`, SHA-256 `bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517`.
- 2B: `f6d5376be1edb4d416d56da11e5397a961aca8ae`, SHA-256 `aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223`.

Las tarjetas de ambos repositorios declaran `apache-2.0`. El importador exige el tamaño y SHA-256 fijados antes de instalar o cargar un archivo.

## llama.cpp

El runtime nativo se compila desde `ggml-org/llama.cpp`, commit `3ba1ce0e28d991800e1585b7d3533f77213939d6`, bajo la licencia MIT que acompaña a su código fuente.

Las copias de Apache License 2.0 y MIT incluidas en este directorio acompañan al APK. No constituyen asesoría legal; revisar de nuevo las revisiones upstream antes de una distribución pública.
