# Notas de la versión

Este fichero lo usa el job `build` del CI como cuerpo de la release. Debe existir
siempre: si falta, `softprops/action-gh-release` falla con
`Unable to find body_path`, y el fallo aparece después de haber compilado el APK,
que es la peor forma de perder veinte minutos.

Mantén aquí lo que cambia para quien usa la app, no el detalle de implementación.

---

## Versión 0.1.0 — primera compilación

Aún no hay release pública: el APK se genera en el CI para verificar que la
cadena de compilación funciona de principio a fin (firma incluida).

Lo que ya funciona:

- **Runtime Linux propio** dentro del APK: `proot` + Debian arm64, sin depender de
  Termux ni de ninguna otra app. Se inicializa en el primer arranque y después
  funciona sin conexión.
- **Terminal real** (PTY) sobre el contenedor, con `apt`, `git`, `python3` y
  `node` disponibles.
- **Kernel de plugins**: un plugin declara las capacidades que usa, puede aportar
  herramientas, skills, modos de trabajo y su propia pantalla, y se monta y
  desmonta sin reiniciar la app.
- **Motor del agente**: bucle de *tool-calling* con streaming, aprobaciones por
  herramienta, cancelación real, reintentos con espera y compactación de
  contexto.
- **Log de sesión** en JSONL, reconstruible, base de la UI y de la telemetría.

Pendiente para la primera versión instalable:

- Pantallas de sesión, ajustes de proveedor y panel de trayectoria.
- Descarga e inicialización del rootfs desde la app.
- Resto de herramientas del catálogo de DeepSeek Harness.

### Notas de instalación

- Requiere Android 7.0 o superior y ARM64.
- El contenedor se instala en el almacenamiento interno de la app: reserva unos
  600 MB para el rootfs y deja espacio para lo que instales encima.
- La app no pide root y no lo necesita.
