#!/usr/bin/env python3
"""Ejemplo de plugin externo JSON-RPC por stdin/stdout (una línea por mensaje)."""
import json
import sys


def send(message):
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def handle(request):
    method = request.get("method")
    params = request.get("params") or {}
    request_id = request.get("id")

    if method == "initialize":
        result = {"protocolVersion": "1.0", "serverInfo": {"name": "echo", "version": "1.0.0"}}
    elif method == "tools/list":
        result = {"tools": [{
            "name": "echo",
            "description": "Devuelve el texto recibido.",
            "inputSchema": {
                "type": "object",
                "properties": {"text": {"type": "string", "description": "Texto a repetir."}},
                "required": ["text"],
            },
        }]}
    elif method == "tools/call":
        if params.get("name") != "echo":
            result = {"isError": True, "content": [{"type": "text", "text": "Herramienta desconocida."}]}
        else:
            text = str((params.get("arguments") or {}).get("text", ""))
            result = {"content": [{"type": "text", "text": text}]}
    elif method == "shutdown":
        return False
    else:
        if request_id is None:
            return True
        send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "Method not found"}})
        return True

    if request_id is not None:
        send({"jsonrpc": "2.0", "id": request_id, "result": result})
    return True


for line in sys.stdin:
    try:
        request = json.loads(line)
        if not handle(request):
            break
    except Exception as error:  # el mensaje de error va a stderr, nunca al framing stdout
        print(str(error), file=sys.stderr, flush=True)
