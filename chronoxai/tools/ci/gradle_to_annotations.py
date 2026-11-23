#!/usr/bin/env python3
"""Convierte los errores de Gradle/Kotlin/Android en anotaciones de GitHub.

El job de build es el único que valida la parte Android (compileSdk, manifiesto,
tipos de servicio en primer plano). Como los logs de Actions no siempre se pueden
descargar, cualquier fallo ahí se publica como anotación con fichero y línea; si
no, solo se sabe que "el build falló".

Uso:
    flutter build apk --release > /tmp/build.txt 2>&1
    python3 tools/ci/gradle_to_annotations.py /tmp/build.txt
"""

import re
import sys

# "e: file:///path/app/src/main/kotlin/app/chronoxai/MainActivity.kt:45:9 ..."
KOTLIN = re.compile(r"^e:\s+file://(?P<path>[^:]+):(?P<line>\d+):(?P<col>\d+)\s+(?P<msg>.+)$")
# "> Task :app:compileDebugKotlin FAILED" y similares, sin ubicación.
TASK = re.compile(r"^(?:> )?(?:Execution failed for )?Task (?P<task>:[^\s]+)(?: FAILED)?\.?$")
# "FAILURE: Build failed with an exception." -> marcador de bloque
FAILURE = re.compile(r"^FAILURE: Build failed")
# Línea genérica de error de Gradle, sin fichero.
GENERIC = re.compile(r"^(?:What went wrong:|\* What went wrong:)\s*$")
# "app/src/main/AndroidManifest.xml:12:5-30 Error: ..."
MANIFEST = re.compile(
    r"^(?P<path>[\w./-]*AndroidManifest\.xml):(?P<line>\d+):(?P<col>\d+)[^E]*Error:\s*(?P<msg>.+)$"
)
# "error: resource ... not found" y mensajes de AAPT2.
AAPT = re.compile(r"^(?P<path>[\w./-]+\.xml):(?P<line>\d+):\s*error:\s*(?P<msg>.+)$")


def escape(text: str) -> str:
    return text.replace("%", "%25").replace("\r", "").replace("\n", "%0A")


def main() -> int:
    if len(sys.argv) < 2:
        print("uso: gradle_to_annotations.py <fichero>", file=sys.stderr)
        return 2

    try:
        with open(sys.argv[1], encoding="utf-8", errors="replace") as handle:
            lines = handle.readlines()
    except FileNotFoundError:
        return 2

    found = []
    seen = set()

    def add(path, line, message, title="Error de compilación"):
        key = (path, line, message)
        if key in seen:
            return
        seen.add(key)
        found.append((path, line, message, title))

    for index, raw in enumerate(lines):
        line = raw.rstrip("\n")

        for pattern in (KOTLIN, MANIFEST, AAPT):
            match = pattern.match(line.strip())
            if match:
                data = match.groupdict()
                add(
                    data["path"],
                    int(data["line"]),
                    data["msg"].strip(),
                    "Error de compilación",
                )
                break
        else:
            match = TASK.match(line.strip())
            if match:
                # La causa suele estar en las líneas siguientes; se recogen.
                detail = []
                for follow in lines[index + 1 : index + 12]:
                    text = follow.strip()
                    if not text:
                        if detail:
                            break
                        continue
                    if text.startswith(("> Task", "BUILD FAILED", "* Try")):
                        break
                    detail.append(text)
                add(
                    ".github",
                    index + 1,
                    " ".join(detail)[:900] or match.group("task"),
                    f"Fallo en {match.group('task')}",
                )
                continue

            if FAILURE.match(line.strip()) or GENERIC.match(line.strip()):
                detail = []
                for follow in lines[index + 1 : index + 8]:
                    text = follow.strip()
                    if not text or text.startswith("* Try"):
                        if detail:
                            break
                        continue
                    detail.append(text)
                if detail:
                    add(".github", index + 1, " ".join(detail)[:900], "Build fallido")

    for path, line, message, title in found:
        print(
            f"::error file={path},line={line},title={escape(title)}::{escape(message)}"
        )

    print(f"Anotaciones: {len(found)} error(es) de compilación")
    return 0


if __name__ == "__main__":
    sys.exit(main())
