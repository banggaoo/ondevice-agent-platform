"""Client side of the private ACP bridge: forwards newline-delimited
JSON-RPC between stdin/stdout and a running daemon's /_bridge/acp endpoint,
mirroring ACPFacade.swift. stdout carries only protocol lines; diagnostics
go to stderr."""
from __future__ import annotations

import json
import sys
import threading
import urllib.request
import uuid

from .limits import PlatformLimits


def _post(url: str, payload: dict, timeout: float):
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    return urllib.request.urlopen(req, timeout=timeout)


def run_stdio_facade(agent_id: str, bridge_url: str,
                     stdin=None, stdout=None) -> int:
    """Runs until stdin reaches EOF, then closes the bridge connection."""
    stdin = stdin if stdin is not None else sys.stdin.buffer
    stdout = stdout if stdout is not None else sys.stdout.buffer
    connection_id = f"facade-{uuid.uuid4()}"
    timeout = PlatformLimits.AGENT_DEADLINE_SECONDS + 30
    write_lock = threading.Lock()

    def out(line: bytes) -> None:
        with write_lock:
            stdout.write(line)
            stdout.flush()

    def emit_error(msg_id, code: int, message: str) -> None:
        out(json.dumps({"jsonrpc": "2.0", "id": msg_id,
                        "error": {"code": code, "message": message}},
                       separators=(",", ":")).encode() + b"\n")

    def forward(line: bytes) -> None:
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            emit_error(None, -32700, "parse error")
            return
        try:
            with _post(bridge_url, {
                    "connectionId": connection_id, "agentId": agent_id,
                    "message": message}, timeout) as resp:
                if resp.status != 200:
                    emit_error(message.get("id"), -32603, "bridge error")
                    return
                for chunk in resp:
                    if chunk.strip():
                        out(chunk if chunk.endswith(b"\n")
                            else chunk + b"\n")
        except Exception:
            emit_error(message.get("id"), -32603, "bridge unreachable")

    threads = []
    for raw in stdin:
        line = raw.rstrip(b"\n")
        if not line or len(line) > PlatformLimits.REQUEST_BODY_BYTES:
            continue
        t = threading.Thread(target=forward, args=(line,), daemon=True)
        t.start()
        threads.append(t)
    for t in threads:
        t.join()
    try:
        with _post(bridge_url, {"connectionId": connection_id,
                                "close": True}, 10):
            pass
    except Exception:
        pass
    return 0
