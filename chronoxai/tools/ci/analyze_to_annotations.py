#!/usr/bin/env python3
"""Convierte la salida de `flutter analyze` en anotaciones de GitHub Actions.

Por qué existe: el log completo de un job no siempre es accesible por API
(la descarga puede fallar), pero las *annotations* sí. Publicar cada problema
con fichero, línea y columna permite verlo señalado en el diff del PR y leerlo
programáticamente.

Uso:
    flutter analyze --fatal-infos > /tmp/analyze.txt 2>&1
    python3 tools/ci/analyze_to_annotations.py /tmp/analyze.txt
"""

import re
import sys

# "  error • mensaje • lib/x.dart:12:3 • regla"
LINE = re.compile(
    r"^\s*(error|warning|info)\s+•\s+(.*?)\s+•\s+(\S+?):(\d+):(\d+)\s+•\s+(.*)$"
)


def escape(text: str) -> str:
    """Escapa los caracteres que rompen el protocolo de workflow commands."""
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def main() -> int:
    if len(sys.argv) < 2:
        print("uso: analyze_to_annotations.py <fichero>", file=sys.stderr)
        return 2

    try:
        with open(sys.argv[1], encoding="utf-8", errors="replace") as handle:
            lines = handle.read().splitlines()
    except FileNotFoundError:
        print(f"No existe {sys.argv[1]}", file=sys.stderr)
        return 2

    found = 0
    counts = {"error": 0, "warning": 0, "info": 0}

    for line in lines:
        match = LINE.match(line)
        if not match:
            continue
        level, message, path, line_no, col, rule = match.groups()
        counts[level] += 1
        # `info` se emite como warning: GitHub no tiene un nivel "info".
        kind = "error" if level == "error" else "warning"
        print(
            f"::{kind} file={path},line={line_no},col={col},"
            f"title={escape(rule)}::{escape(message)}"
        )
        found += 1

    print(
        f"Anotaciones: {found} "
        f"({counts['error']} errores, {counts['warning']} avisos, "
        f"{counts['info']} infos) en {len(lines)} líneas de salida"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
