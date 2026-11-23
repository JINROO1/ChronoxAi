# Avisos de terceros — Chronox AI

Chronox AI **no depende de la aplicación Termux**. Empaqueta los siguientes binarios
precompilados dentro del APK, en `android/app/src/main/jniLibs/arm64-v8a/`, obtenidos con
`tools/fetch_runtime.sh`. Se ejecutan como **procesos independientes** (`Process.start`),
nunca se enlazan contra el código de la app.

## proot (fork de Termux) — GPLv2

* Proyecto: <https://github.com/termux/proot>
* Versión empaquetada: `5.1.107.102`
* Licencia: GNU General Public License v2.0
* Texto completo: <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>
* Código fuente de la versión exacta: <https://github.com/termux/proot/archive/v5.1.107.102.zip>
* Build usado: `termux/termux-packages/packages/proot/build.sh`

> Distribuimos el binario sin modificarlo y ofrecemos el enlace al fuente exacto arriba.
> Si en el futuro se aplican parches, deben publicarse en este mismo repositorio bajo
> `third_party/proot/patches/`.

## libtalloc — LGPLv3

* Proyecto: <https://talloc.samba.org/>
* Licencia: GNU Lesser General Public License v3.0
* Enlazado dinámicamente (`.so` separado en `jniLibs`), lo que la LGPL permite.

## libandroid-shmem — Apache-2.0

* Proyecto: <https://github.com/termux/libandroid-shmem>
* Licencia: Apache License 2.0

## Distribuciones Linux (descargadas por el usuario, no redistribuidas)

El *rootfs* de Debian se descarga **en el dispositivo** desde el registro público de Docker
Hub. Chronox AI no redistribuye esa imagen; el usuario acepta las licencias de Debian al
instalarla. Contiene software bajo GPL, LGPL, BSD y otras licencias, cuyos textos están en
`/usr/share/doc/<paquete>/copyright` dentro del propio contenedor.

## Componentes de Flutter

Ver `pubspec.lock` y los avisos de cada paquete (`xterm`, `flutter_pty`, `archive`, etc.).
