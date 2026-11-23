#!/usr/bin/env python3
"""Convierte la salida de `flutter test` en anotaciones de GitHub Actions.

Extrae, por cada test fallido, su nombre y el primer mensaje de error, y lo
publica como anotación. Así el fallo es visible sin descargar el log.

Uso:
    flutter test --reporter expanded > /tmp/test.txt 2>&1
    python3 tools/ci/test_to_annotations.py /tmp/test.txt
"""

import re
import sys

# "12:34 +5 -2: grupo nombre del test [E]"
# El contador de fallos va pegado o separado según la versión:
#   "00:01 +0: nombre [E]"      (sin fallos previos)
#   "00:02 +0 -1: nombre [E]"   (con fallos previos)
FAILED = re.compile(r"^\d{2}:\d{2}\s+\+\d+(?:\s+-\d+)?:\s*(.*?)\s*\[E\]$")
# "  lib/domain/x.dart 12:5  main.<fn>"  -> ubicación del fallo
LOCATION = re.compile(r"^\s*((?:test|lib)/\S+\.dart)\s+(\d+):(\d+)\s")
# Líneas que no aportan al resumen
NOISE = re.compile(
    r"^(package:|dart:|═|─|Expected:|Actual:|Which:|  Actual:|  Expected:|"
    r"\s*$|\d{2}:\d{2}\s+\+\d+)"
)


def escape(text: str) -> str:
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def main() -> int:
    if len(sys.argv) < 2:
        print("uso: test_to_annotations.py <fichero>", file=sys.stderr)
        return 2

    try:
        with open(sys.argv[1], encoding="utf-8", errors="replace") as handle:
            lines = handle.readlines()
    except FileNotFoundError:
        return 2

    failures = []  # [(nombre, ubicacion|None, [detalles])]
    current = None

    for line in lines:
        stripped = line.rstrip("\n")
        match = FAILED.match(stripped)
        if match:
            if current:
                failures.append(current)
            current = [match.group(1), None, []]
            continue

        if current is None:
            continue

        loc = LOCATION.match(stripped)
        if loc and current[1] is None:
            current[1] = loc.groups()
            continue

        if not NOISE.match(stripped.strip()) and len(current[2]) < 12:
            current[2].append(stripped.strip())

    if current:
        failures.append(current)

    for name, location, details in failures:
        message = " | ".join(details[:6]) or "test fallido sin detalle"
        if location:
            path, line_no, col = location
            print(
                f"::error file={path},line={line_no},col={col},"
                f"title={escape(name)}::{escape(message)}"
            )
        else:
            print(f"::error title={escape(name)}::{escape(message)}")

    print(f"Anotaciones: {len(failures)} test(s) fallido(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
