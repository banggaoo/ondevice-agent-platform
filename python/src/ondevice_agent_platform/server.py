"""Loopback HTTP/1.1 server + router, mirroring HTTPServer.swift and
Router.swift. Built on the stdlib threaded HTTP server; the route table,
guards, session/CSRF checks, SSE framing, and the private ACP bridge carry
over unchanged in semantics."""
from __future__ import annotations

import json
import posixpath
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import openai_adapter
from .acp_service import _rpc_error  # NDJSON error frames for the bridge
from .cancellation import CancellationToken
from .console_sessions import ConsoleSessions
from .errors import ErrorCode, PlatformError
from .limits import PlatformLimits
from .profiles import Grant, LocalConsumers, ModelKind

_CONSOLE_DIR = posixpath.join(posixpath.dirname(__file__), "console")

_CSP = ("default-src 'none'; style-src 'self'; script-src 'self'; "
        "connect-src 'self'; font-src 'self'")

_STATUS = {
    ErrorCode.INVALID_REQUEST: 400, ErrorCode.MALFORMED_JSON: 400,
    ErrorCode.VERSION_UNSUPPORTED: 400, ErrorCode.UNAUTHORIZED: 401,
    ErrorCode.FORBIDDEN: 403, ErrorCode.NOT_FOUND: 404,
    ErrorCode.CONFLICT: 409, ErrorCode.PAYLOAD_TOO_LARGE: 413,
    ErrorCode.RATE_LIMITED: 429, ErrorCode.CAPACITY_LIMITED: 429,
    ErrorCode.PROVIDER_UNAVAILABLE: 503, ErrorCode.RESOURCE_DENIED: 503,
    ErrorCode.CANCELLED: 503, ErrorCode.CANCELLATION_UNCONFIRMED: 503,
    ErrorCode.STORAGE_FAILURE: 503, ErrorCode.STORAGE_EXHAUSTED: 503,
    ErrorCode.DEADLINE_EXCEEDED: 504, ErrorCode.SESSION_CLOSED: 410,
    ErrorCode.INTERNAL: 500, ErrorCode.ROOT_UNSAFE: 500,
}


def _status_code(error: PlatformError) -> int:
    return _STATUS.get(error.code, 500)


def _valid_host(host: str | None) -> bool:
    """Loopback-only: the listener binds loopback, and the Host header must
    name the same authority so a browser cannot be driven at a foreign
    loopback service."""
    if not host:
        return False
    name = host.split(":", 1)[0].lower()
    return name in ("127.0.0.1", "localhost", "::1", "[::1]")


class _Request:
    def __init__(self, handler: "BaseHTTPRequestHandler",
                 body: bytes, token: CancellationToken) -> None:
        self.method = handler.command
        self.path = urllib.parse.urlsplit(handler.path).path
        self.headers = handler.headers
        self.body = body
        self.cancellation = token

    def header(self, name: str) -> str | None:
        return self.headers.get(name)


class _Response:
    def __init__(self, status: int = 200, headers: list | None = None,
                 body: bytes = b"", stream=None) -> None:
        self.status = status
        self.headers = headers or []
        self.body = body
        self.stream = stream   # callable(wfile) -> None for SSE/NDJSON

    @staticmethod
    def json(obj, status: int = 200) -> "_Response":
        return _Response(status, [("Content-Type", "application/json")],
                         json.dumps(obj).encode())


class Router:
    def __init__(self, supervisor, acp, sessions, bridge,
                 static_dir: str = _CONSOLE_DIR) -> None:
        self._s = supervisor
        self._acp = acp
        self._sessions = sessions
        self._bridge = bridge
        self._static_dir = static_dir
        self._consumer_windows: dict[str, list[float]] = {}
        self._window_lock = threading.Lock()
        self._event_subscribers = 0
        self._sub_lock = threading.Lock()

    # -- guards ---------------------------------------------------------------

    def _expected_origin(self, req: _Request) -> str:
        return f"http://{req.header('Host') or ''}"

    def _require_origin(self, req: _Request) -> None:
        origin = req.header("Origin")
        if origin is not None and origin != self._expected_origin(req):
            raise PlatformError(ErrorCode.FORBIDDEN)

    def _require_exact_origin(self, req: _Request) -> None:
        if req.header("Origin") != self._expected_origin(req):
            raise PlatformError(ErrorCode.FORBIDDEN)

    def _require_same_site_fetch(self, req: _Request) -> None:
        if req.header("Sec-Fetch-Site") == "cross-site":
            raise PlatformError(ErrorCode.FORBIDDEN)

    def _local_route(self, req: _Request, principal):
        """Fixed local-trust identity for one route family. Authorization
        headers are ignored: no header or body value can select a different
        principal."""
        self._require_origin(req)
        self._require_same_site_fetch(req)
        self._consumer_rate_limit(principal.id)
        return principal

    def _consumer_rate_limit(self, consumer_id: str) -> None:
        cutoff = time.time() - 60
        with self._window_lock:
            window = [t for t in self._consumer_windows.get(consumer_id, [])
                      if t >= cutoff]
            if len(window) >= PlatformLimits.REQUESTS_PER_CONSUMER_PER_MINUTE:
                raise PlatformError(ErrorCode.RATE_LIMITED)
            window.append(time.time())
            self._consumer_windows[consumer_id] = window

    def _cookie_session(self, req: _Request):
        cookie = req.header("Cookie")
        if not cookie:
            return None
        for part in cookie.split(";"):
            kv = part.strip().split("=", 1)
            if len(kv) == 2 and kv[0] == "platform_session":
                return self._sessions.lookup(kv[1])
        return None

    def _require_console_session(self, req: _Request, mutation: bool):
        if mutation:
            self._require_exact_origin(req)
        else:
            self._require_origin(req)
        self._require_same_site_fetch(req)
        session = self._cookie_session(req)
        if session is None:
            raise PlatformError(ErrorCode.UNAUTHORIZED)
        if mutation and req.header("X-CSRF-Token") != session.csrf:
            raise PlatformError(ErrorCode.FORBIDDEN)
        return session

    # -- routing ----------------------------------------------------------------

    def handle(self, req: _Request, wfile) -> None:
        if not _valid_host(req.header("Host")):
            self._send(wfile, _Response.json(
                openai_adapter.error_body(
                    PlatformError(ErrorCode.INVALID_REQUEST)), 400))
            return
        try:
            response = self._route(req)
        except PlatformError as e:
            response = _Response.json(
                openai_adapter.error_body(e), _status_code(e))
        except Exception:
            response = _Response.json(
                openai_adapter.error_body(
                    PlatformError(ErrorCode.INTERNAL)), 500)
        self._send(wfile, response)

    def _route(self, req: _Request) -> _Response:
        method, path = req.method, req.path
        if method == "GET" and path == "/":
            return self._static("index.html", "text/html; charset=utf-8")
        if method == "GET" and path == "/styles.css":
            return self._static("styles.css", "text/css")
        if method == "GET" and path == "/app.js":
            return self._static("app.js", "text/javascript; charset=utf-8")
        if method == "POST" and path == "/api/session":
            return self._bootstrap(req)
        if method == "GET" and path == "/api/session":
            return self._session_info(req)
        if method == "POST" and path == "/api/logout":
            return self._logout(req)
        if method == "GET" and path == "/api/status":
            return self._admin_json(req, self._s.status_snapshot)
        if method == "GET" and path == "/api/registry":
            return self._admin_json(req, self._s.registry_snapshot)
        if method == "GET" and path == "/api/jobs":
            return self._admin_jobs(req)
        if method == "POST" and path == "/api/console/operator/prompt":
            return self._operator_prompt(req)
        if method == "POST" and path == "/v1/chat/completions":
            return self._chat_completions(req)
        if method == "GET" and path == "/v1/models":
            return self._list_models(req)
        if method == "POST" and path == "/api/ml/predictions":
            return self._ml_predict(req)
        if method == "POST" and path == "/_bridge/acp":
            return self._bridge_acp(req)
        if method == "POST" and path.startswith("/api/jobs/") \
                and path.endswith("/cancel"):
            return self._cancel_job(req)
        if method == "GET" and path == "/api/events":
            return self._events(req)
        raise PlatformError(ErrorCode.NOT_FOUND)

    # -- static assets ----------------------------------------------------------

    def _static(self, name: str, content_type: str) -> _Response:
        import os
        path = os.path.join(self._static_dir, name)
        real = os.path.realpath(path)
        if not real.startswith(os.path.realpath(self._static_dir)
                               + os.sep) or not os.path.isfile(real):
            raise PlatformError(ErrorCode.NOT_FOUND)
        with open(real, "rb") as fh:
            body = fh.read()
        return _Response(200, [
            ("Content-Type", content_type),
            ("Content-Security-Policy", _CSP),
            ("X-Content-Type-Options", "nosniff"),
            ("X-Frame-Options", "DENY"),
            ("Cache-Control", "no-store"),
        ], body)

    # -- console sessions ----------------------------------------------------------

    def _session_response(self, session) -> _Response:
        response = _Response.json({
            "session": session.id, "csrf": session.csrf,
            "expiresAt": session.expires_at})
        response.headers.append(
            ("Set-Cookie",
             f"platform_session={session.id}; Path=/; HttpOnly; "
             "SameSite=Strict"))
        return response

    def _bootstrap(self, req: _Request) -> _Response:
        self._require_exact_origin(req)
        site = req.header("Sec-Fetch-Site")
        if site is not None and site != "same-origin":
            raise PlatformError(ErrorCode.FORBIDDEN)
        session = self._cookie_session(req)
        if session is not None:
            return self._session_response(session)
        if not self._sessions.login_allowed():
            raise PlatformError(ErrorCode.RATE_LIMITED)
        return self._session_response(self._sessions.create())

    def _session_info(self, req: _Request) -> _Response:
        session = self._require_console_session(req, mutation=False)
        return _Response.json({
            "session": session.id, "csrf": session.csrf,
            "expiresAt": session.expires_at})

    def _logout(self, req: _Request) -> _Response:
        session = self._require_console_session(req, mutation=True)
        self._sessions.logout(session.id)
        if self._bridge is not None:
            self._bridge.connection_closed(session.id)
        return _Response.json({"ok": True})

    def _operator_prompt(self, req: _Request) -> _Response:
        session = self._require_console_session(req, mutation=True)
        self._consumer_rate_limit("console-operator")
        if self._bridge is None:
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                "operator is not enabled")
        reply = self._bridge.prompt(session, req.body, req.cancellation)
        return _Response.json(reply)

    # -- admin reads ----------------------------------------------------------------

    def _admin_json(self, req: _Request, produce) -> _Response:
        principal = self._local_route(req, LocalConsumers.ADMINISTRATION)
        self._s.require(Grant.ADMIN_READ, principal)
        return _Response.json(produce())

    def _admin_jobs(self, req: _Request) -> _Response:
        def produce():
            jobs = self._s.list_jobs()
            return {"jobs": [{
                "id": j.id, "kind": j.kind.value, "consumer": j.consumer_id,
                "state": j.state.value, "parentId": j.parent_id,
                "createdAt": j.created_at, "updatedAt": j.updated_at,
            } for j in jobs]}
        return self._admin_json(req, produce)

    # -- job cancel ----------------------------------------------------------------

    def _cancel_job(self, req: _Request) -> _Response:
        job_id = req.path[len("/api/jobs/"):-len("/cancel")]
        if not job_id or not all(
                c.isalnum() or c == "-" for c in job_id):
            raise PlatformError(ErrorCode.INVALID_REQUEST)
        has_browser_marker = (
            (req.header("Cookie") or "").find("platform_session=") >= 0
            or req.header("Origin") is not None
            or req.header("Sec-Fetch-Site") is not None)
        if has_browser_marker:
            self._require_console_session(req, mutation=True)
        else:
            self._local_route(req, LocalConsumers.ADMINISTRATION)
        self._s.cancel_job(LocalConsumers.ADMINISTRATION, job_id)
        return _Response.json({"ok": True})

    # -- events (SSE) ----------------------------------------------------------------

    def _events(self, req: _Request) -> _Response:
        session = self._require_console_session(req, mutation=False)
        with self._sub_lock:
            if self._event_subscribers >= PlatformLimits.EVENT_SUBSCRIBERS:
                raise PlatformError(ErrorCode.RATE_LIMITED)
            self._event_subscribers += 1

        def stream(wfile) -> None:
            try:
                while not req.cancellation.is_cancelled:
                    if self._sessions.lookup(session.id) is None:
                        break
                    data = json.dumps(self._s.status_snapshot()).encode()
                    wfile.write(b"data: " + data + b"\n\n")
                    wfile.flush()
                    time.sleep(2)
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            finally:
                with self._sub_lock:
                    self._event_subscribers -= 1

        return _Response(200, [
            ("Content-Type", "text/event-stream"),
            ("Cache-Control", "no-store"),
            ("X-Content-Type-Options", "nosniff")], stream=stream)

    # -- OpenAI + ML ----------------------------------------------------------------

    def _chat_completions(self, req: _Request) -> _Response:
        principal = self._local_route(req, LocalConsumers.MODEL)
        chat_req, stream, include_usage = openai_adapter.parse_chat_request(
            req.body)
        try:
            result = self._s.submit_llm(principal, chat_req,
                                        cancellation=req.cancellation)
            if not stream:
                return _Response.json(openai_adapter.chat_response(
                    result, chat_req.model))
            frames = openai_adapter.stream_frames(
                result, chat_req.model, include_usage)

            def write_frames(wfile) -> None:
                try:
                    for f in frames:
                        wfile.write(f)
                    wfile.flush()
                except (BrokenPipeError, ConnectionResetError, OSError):
                    req.cancellation.cancel()

            return _Response(200, [
                ("Content-Type", "text/event-stream"),
                ("Cache-Control", "no-store"),
                ("X-Content-Type-Options", "nosniff")],
                stream=write_frames)
        except PlatformError as e:
            return _Response.json(openai_adapter.error_body(e),
                                  _status_code(e))

    def _list_models(self, req: _Request) -> _Response:
        principal = self._local_route(req, LocalConsumers.MODEL)
        self._s.require(Grant.LLM_INFER, principal)
        models = self._s.registered_models(ModelKind.LLM)
        return _Response.json(openai_adapter.models_response(models))

    def _ml_predict(self, req: _Request) -> _Response:
        principal = self._local_route(req, LocalConsumers.MODEL)
        self._s.require(Grant.ML_PREDICT, principal)
        prediction = openai_adapter.parse_prediction_request(req.body)
        result = self._s.submit_ml(principal, prediction,
                                   cancellation=req.cancellation)
        return _Response.json(
            openai_adapter.prediction_response(result))

    # -- private ACP bridge -----------------------------------------------------------

    def _bridge_acp(self, req: _Request) -> _Response:
        principal = self._local_route(req, LocalConsumers.AGENT)
        self._s.require(Grant.AGENT_RUN, principal)
        try:
            wrapper = json.loads(req.body)
        except (json.JSONDecodeError, UnicodeDecodeError):
            raise PlatformError(ErrorCode.MALFORMED_JSON)
        if not isinstance(wrapper, dict):
            raise PlatformError(ErrorCode.INVALID_REQUEST)
        conn_id = wrapper.get("connectionId")
        if not isinstance(conn_id, str) or not conn_id:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "connectionId required")
        if wrapper.get("close") is True:
            self._acp.connection_closed(conn_id)
            return _Response.json({"ok": True})
        agent_id = wrapper.get("agentId")
        if isinstance(agent_id, str):
            self._acp.bind(conn_id, agent_id, principal)
        message = wrapper.get("message")
        if message is None:
            return _Response.json({"ok": True})

        def stream(wfile) -> None:
            def emit(value) -> None:
                try:
                    wfile.write(json.dumps(
                        value, separators=(",", ":")).encode() + b"\n")
                    wfile.flush()
                except (BrokenPipeError, ConnectionResetError, OSError):
                    req.cancellation.cancel()
            self._acp.handle(conn_id, message, req.cancellation, emit)

        return _Response(200, [
            ("Content-Type", "application/x-ndjson"),
            ("Cache-Control", "no-store"),
            ("X-Content-Type-Options", "nosniff")], stream=stream)

    # -- transport ----------------------------------------------------------------

    @staticmethod
    def _send(wfile, response: _Response) -> None:
        reason = {
            200: "OK", 400: "Bad Request", 401: "Unauthorized",
            403: "Forbidden", 404: "Not Found", 409: "Conflict",
            410: "Gone", 413: "Payload Too Large",
            429: "Too Many Requests", 500: "Internal Server Error",
            503: "Service Unavailable", 504: "Gateway Timeout",
        }.get(response.status, "OK")
        head = f"HTTP/1.1 {response.status} {reason}\r\n"
        headers = list(response.headers)
        names = {k.lower() for k, _ in headers}
        if "x-content-type-options" not in names:
            headers.append(("X-Content-Type-Options", "nosniff"))
        if response.stream is None:
            headers.append(("Content-Length", str(len(response.body))))
        headers.append(("Connection", "close"))
        for k, v in headers:
            head += f"{k}: {v}\r\n"
        head += "\r\n"
        wfile.write(head.encode())
        if response.stream is not None:
            response.stream(wfile)
        else:
            wfile.write(response.body)


class PlatformHTTPServer:
    """Threaded loopback HTTP server owning the router."""

    def __init__(self, supervisor, acp=None, sessions=None, bridge=None,
                 host: str = "127.0.0.1", port: int = 8080) -> None:
        self.router = Router(supervisor, acp,
                             sessions or ConsoleSessions(), bridge)
        router = self.router
        limits_body = PlatformLimits.REQUEST_BODY_BYTES

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"
            server_version = "OnDeviceAgentPlatform/0.2"

            def log_message(self, fmt, *args):   # content-free: no request log
                pass

            def _dispatch(self) -> None:
                token = CancellationToken()
                body = b""
                if self.command == "POST":
                    try:
                        length = int(self.headers.get("Content-Length", "0"))
                    except ValueError:
                        length = -1
                    if length < 0 or length > limits_body:
                        Router._send(self.wfile, _Response.json(
                            openai_adapter.error_body(PlatformError(
                                ErrorCode.PAYLOAD_TOO_LARGE)), 413))
                        return
                    body = self.rfile.read(length)
                req = _Request(self, body, token)
                try:
                    router.handle(req, self.wfile)
                finally:
                    token.cancel()

            do_GET = _dispatch
            do_POST = _dispatch

        self._httpd = ThreadingHTTPServer((host, port), Handler)
        self._httpd.daemon_threads = True
        self._thread: threading.Thread | None = None

    @property
    def port(self) -> int:
        return self._httpd.server_address[1]

    def start(self) -> None:
        self._thread = threading.Thread(
            target=self._httpd.serve_forever, daemon=True,
            name="oap-http")
        self._thread.start()

    def stop(self) -> None:
        self._httpd.shutdown()
        self._httpd.server_close()
