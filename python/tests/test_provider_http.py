"""Provider-upstream HTTP tests: fake loopback servers feed vllm-mlx and
llamacpp providers canned/malformed responses; process lifecycle is
exercised with scripted fake children. No real binaries or models."""
import json
import os
import socket
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from ondevice_agent_platform.chat import (ChatMessage, ChatRequest, ChatRole,
                                          FinishReason)
from ondevice_agent_platform.cancellation import CancellationToken
from ondevice_agent_platform.errors import ErrorCode, PlatformError
from ondevice_agent_platform.profiles import (ModelKind, ModelProfile,
                                              ModelSource)
from ondevice_agent_platform.providers import _openai
from ondevice_agent_platform.providers.llamacpp import (LlamaCppProvider,
                                                        _Server as LlamaServer)
from ondevice_agent_platform.providers.vllmmlx import (VllmMlxProvider,
                                                       _Server as VllmServer)

TOOL_SPEC = {"name": "read_file",
             "parameters": {"type": "object",
                            "properties": {"path": {"type": "string"}},
                            "required": ["path"]}}


def raises(code, fn, *a, **k):
    try:
        fn(*a, **k)
    except PlatformError as e:
        assert e.code == code, f"expected {code}, got {e.code}: {e}"
        return e
    raise AssertionError(f"expected PlatformError {code}")


class _FakeUpstream:
    """One canned response per connection on a private loopback port.
    `responder(conn)` overrides the canned bytes for stall/cancel tests."""

    def __init__(self, status=200, body=b"", extra_headers=None,
                 responder=None):
        self.status = status
        self.body = body
        self.extra_headers = extra_headers or {}
        self.responder = responder
        self.requests = []
        self._sock = socket.socket()
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind(("127.0.0.1", 0))
        self._sock.listen(8)
        self.port = self._sock.getsockname()[1]
        self._closed = threading.Event()
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _read_head(self, conn):
        buf = b""
        while b"\r\n\r\n" not in buf and len(buf) < 65536:
            chunk = conn.recv(4096)
            if not chunk:
                return None, buf
            buf += chunk
        head, _, rest = buf.partition(b"\r\n\r\n")
        length = 0
        for line in head.split(b"\r\n"):
            if line.lower().startswith(b"content-length:"):
                length = int(line.split(b":", 1)[1].strip())
        while len(rest) < length:
            chunk = conn.recv(4096)
            if not chunk:
                break
            rest += chunk
        return head, rest[:length]

    def _serve(self):
        while not self._closed.is_set():
            try:
                conn, _ = self._sock.accept()
            except OSError:
                return
            try:
                conn.settimeout(10)
                parsed = self._read_head(conn)
                if parsed[0] is None:
                    conn.close()
                    continue
                self.requests.append(parsed)
                if self.responder is not None:
                    self.responder(conn)
                    continue
                reason = {200: "OK", 400: "Bad Request",
                          500: "Internal Server Error"}.get(
                    self.status, "X")
                head = (f"HTTP/1.1 {self.status} {reason}\r\n"
                        "Content-Type: application/json\r\n")
                for k, v in self.extra_headers.items():
                    head += f"{k}: {v}\r\n"
                head += f"Content-Length: {len(self.body)}\r\n\r\n"
                conn.sendall(head.encode() + self.body)
            except OSError:
                pass
            finally:
                try:
                    conn.close()
                except OSError:
                    pass

    def close(self):
        self._closed.set()
        try:
            self._sock.close()
        except OSError:
            pass


def _tool_frame(arguments_part, cid=None, name=None, finish=None):
    """One SSE chunk carrying a tool-call delta fragment."""
    fn = {}
    if name is not None:
        fn["name"] = name
    if arguments_part is not None:
        fn["arguments"] = arguments_part
    tc = {"index": 0}
    if cid is not None:
        tc["id"] = cid
    if fn:
        tc["function"] = fn
    delta = {"tool_calls": [tc]}
    return {"choices": [{"delta": delta, "finish_reason": finish}]}


def _sse(frames, usage=None):
    out = []
    for f in frames:
        out.append(b"data: " + json.dumps(f).encode() + b"\n\n")
    if usage is not None:
        out.append(b"data: " + json.dumps({"choices": [],
                                           "usage": usage}).encode()
                   + b"\n\n")
    out.append(b"data: [DONE]\n\n")
    return b"".join(out)


def _stream_done(content="hi", finish="stop",
                 usage=None):
    frames = [{"choices": [{"delta": {"content": content},
                            "finish_reason": None}]},
              {"choices": [{"delta": {}, "finish_reason": finish}]}]
    return _sse(frames, usage)


def _fake_server(cls, port, alias="m"):
    srv = cls.__new__(cls)
    srv.alias = alias
    srv.port = port
    srv.proc = _FakeProc()
    srv.last_used = time.time()
    return srv


class _FakeProc:
    """Scriptable child process: poll() returns `exit_code` until
    terminated; records terminate/kill/wait order."""

    def __init__(self, exit_code=None, terminate_times_out=False):
        self.exit_code = exit_code
        self.terminate_times_out = terminate_times_out
        self.calls = []

    def poll(self):
        return self.exit_code

    def terminate(self):
        self.calls.append("terminate")
        self.exit_code = -15

    def wait(self, timeout=None):
        self.calls.append("wait")
        if self.terminate_times_out and "kill" not in self.calls:
            import subprocess as _sp
            raise _sp.TimeoutExpired("cmd", timeout)
        if self.exit_code is None:
            self.exit_code = -9
        return self.exit_code

    def kill(self):
        self.calls.append("kill")
        self.exit_code = -9


class _FakeStore:
    def __init__(self, ready=True):
        self._ready = ready

    def is_ready(self, source, artifact_file=None):
        return self._ready

    def directory(self, source, artifact_file=None):
        return tempfile.gettempdir()

    def manifest_of(self, source, artifact_file=None):
        return {"files": [{"path": "m.gguf"}]}


def _profile(alias="m", provider_id="vllm-mlx"):
    return ModelProfile(
        alias=alias, provider_id=provider_id, kind=ModelKind.LLM,
        task="chat", capabilities=("text",), max_output_tokens=64,
        source=ModelSource(repo="o/r", revision="abc123"))


def _request(alias="m", text="hi", **kw):
    defaults = dict(model=alias,
                    messages=[ChatMessage(role=ChatRole.USER,
                                          parts=[text])],
                    max_output_tokens=32, has_explicit_output_limit=True)
    defaults.update(kw)
    return ChatRequest(**defaults)


def _vllm_with_server(upstream, profile=None):
    provider = VllmMlxProvider(_FakeStore())
    profile = profile or _profile()
    provider._servers[profile.alias] = _fake_server(
        VllmServer, upstream.port, profile.alias)
    return provider, profile


def _llama_with_server(upstream, profile=None):
    provider = LlamaCppProvider(_FakeStore())
    profile = profile or _profile(provider_id="llamacpp")
    provider._servers[profile.alias] = _fake_server(
        LlamaServer, upstream.port, profile.alias)
    return provider, profile


class TestVllmStream(unittest.TestCase):
    def setUp(self):
        self.upstreams = []
        self.addCleanup(self._close_all)

    def _close_all(self):
        for u in self.upstreams:
            u.close()

    def upstream(self, **kw):
        u = _FakeUpstream(**kw)
        self.upstreams.append(u)
        return u

    def test_valid_text_stream(self):
        up = self.upstream(body=_stream_done(
            "hi", "stop", {"prompt_tokens": 3,
                           "completion_tokens": 1,
                           "total_tokens": 4}))
        provider, profile = _vllm_with_server(up)
        result = provider.complete(_request(), profile)
        self.assertEqual(result.content, "hi")
        self.assertEqual(result.finish_reason, FinishReason.STOP)
        self.assertEqual(result.usage.prompt_tokens, 3)

    def test_tool_stream_split_arguments(self):
        frames = [
            _tool_frame("{\"path\": \"fix", cid="call_1",
                        name="read_file"),
            _tool_frame("ture.txt\"}"),
            {"choices": [{"delta": {}, "finish_reason": "tool_calls"}]},
        ]
        up = self.upstream(body=_sse(frames))
        provider, profile = _vllm_with_server(up)
        result = provider.complete(_request(), profile)
        self.assertEqual(result.finish_reason, FinishReason.TOOL_CALLS)
        self.assertEqual(len(result.tool_calls), 1)
        call = result.tool_calls[0]
        self.assertEqual(call.name, "read_file")
        self.assertEqual(call.arguments, {"path": "fixture.txt"})
        self.assertEqual(call.id, "call_1")

    def test_length_finish_preserved(self):
        up = self.upstream(body=_stream_done("hi", "length"))
        provider, profile = _vllm_with_server(up)
        result = provider.complete(_request(), profile)
        self.assertEqual(result.finish_reason, FinishReason.LENGTH)

    def test_upstream_400(self):
        up = self.upstream(status=400, body=b'{"error": "nope"}')
        provider, profile = _vllm_with_server(up)
        e = raises(ErrorCode.PROVIDER_UNAVAILABLE,
                   provider.complete, _request(), profile)
        self.assertIn("400", e.detail or "")
        self.assertNotIn("nope", e.detail or "")

    def test_upstream_500(self):
        up = self.upstream(status=500, body=b"boom details")
        provider, profile = _vllm_with_server(up)
        e = raises(ErrorCode.PROVIDER_UNAVAILABLE,
                   provider.complete, _request(), profile)
        self.assertNotIn("boom", e.detail or "")

    def test_malformed_stream_json(self):
        up = self.upstream(body=b"data: {not json\n\n")
        provider, profile = _vllm_with_server(up)
        raises(ErrorCode.PROVIDER_UNAVAILABLE,
               provider.complete, _request(), profile)

    def test_error_frame(self):
        up = self.upstream(body=_sse(
            [{"error": {"message": "upstream unhappy"}}]))
        provider, profile = _vllm_with_server(up)
        raises(ErrorCode.PROVIDER_UNAVAILABLE,
               provider.complete, _request(), profile)

    def test_eof_before_done(self):
        body = b"data: " + json.dumps({"choices": [
            {"delta": {"content": "hi"}, "finish_reason": "stop"}]}
        ).encode() + b"\n\n"   # no [DONE]
        up = self.upstream(body=body)
        provider, profile = _vllm_with_server(up)
        raises(ErrorCode.PROVIDER_UNAVAILABLE,
               provider.complete, _request(), profile)

    def test_done_without_finish_reason(self):
        body = _sse([{"choices": [{"delta": {"content": "hi"},
                                  "finish_reason": None}]}])
        up = self.upstream(body=body)
        provider, profile = _vllm_with_server(up)
        raises(ErrorCode.PROVIDER_UNAVAILABLE,
               provider.complete, _request(), profile)

    def test_non_data_frame_refused(self):
        up = self.upstream(body=b"event: weird\n\n")
        provider, profile = _vllm_with_server(up)
        raises(ErrorCode.PROVIDER_UNAVAILABLE,
               provider.complete, _request(), profile)

    def test_comment_and_blank_lines_skipped(self):
        body = (b": heartbeat\n\n\n" + _stream_done("hi", "stop"))
        up = self.upstream(body=body)
        provider, profile = _vllm_with_server(up)
        self.assertEqual(
            provider.complete(_request(), profile).content, "hi")

    def test_bad_tool_arguments_json(self):
        frames = [
            _tool_frame("{oops", cid="c1", name="read_file"),
            {"choices": [{"delta": {}, "finish_reason": "tool_calls"}]},
        ]
        up = self.upstream(body=_sse(frames))
        provider, profile = _vllm_with_server(up)
        raises(ErrorCode.PROVIDER_UNAVAILABLE,
               provider.complete, _request(), profile)

    def test_non_object_tool_arguments(self):
        frames = [
            _tool_frame("[1,2]", cid="c1", name="read_file"),
            {"choices": [{"delta": {}, "finish_reason": "tool_calls"}]},
        ]
        up = self.upstream(body=_sse(frames))
        provider, profile = _vllm_with_server(up)
        raises(ErrorCode.PROVIDER_UNAVAILABLE,
               provider.complete, _request(), profile)

    def test_tool_call_missing_id_or_name(self):
        frames = [
            _tool_frame("{\"path\": \"fixture.txt\"}"),
            {"choices": [{"delta": {}, "finish_reason": "tool_calls"}]},
        ]
        up = self.upstream(body=_sse(frames))
        provider, profile = _vllm_with_server(up)
        raises(ErrorCode.PROVIDER_UNAVAILABLE,
               provider.complete, _request(), profile)

    def test_cancel_while_waiting_for_headers(self):
        # Upstream accepts, reads the request, and never responds; the
        # token observer must abort through conn.sock.
        gate = threading.Event()

        def stall(conn):
            gate.wait(5)

        up = self.upstream(responder=stall)
        provider, profile = _vllm_with_server(up)
        token = CancellationToken()
        box = {}
        t = threading.Thread(target=lambda: box.setdefault(
            "r", self._complete(provider, profile, token)), daemon=True)
        t.start()
        time.sleep(0.3)
        token.cancel()
        t.join(5)
        self.assertFalse(t.is_alive())
        self.assertIsInstance(box.get("r"), PlatformError)
        self.assertEqual(box["r"].code, ErrorCode.CANCELLED)
        gate.set()

    def test_cancel_while_body_stalled(self):
        # Headers + one SSE frame arrive, then the upstream stalls; the
        # observer closes the in-flight response socket.
        gate = threading.Event()

        def responder(conn):
            try:
                conn.sendall(
                    b"HTTP/1.1 200 OK\r\n"
                    b"Content-Type: text/event-stream\r\n\r\n"
                    b"data: {\"choices\":[]}\n\n")
            except OSError:
                pass
            gate.wait(5)
            try:
                conn.close()
            except OSError:
                pass

        up = self.upstream(responder=responder)
        provider, profile = _vllm_with_server(up)
        token = CancellationToken()
        box = {}
        t = threading.Thread(target=lambda: box.setdefault(
            "r", self._complete(provider, profile, token)), daemon=True)
        t.start()
        time.sleep(0.4)
        token.cancel()
        t.join(5)
        self.assertFalse(t.is_alive())
        self.assertIsInstance(box.get("r"), PlatformError)
        self.assertEqual(box["r"].code, ErrorCode.CANCELLED)
        gate.set()

    def _complete(self, provider, profile, token):
        try:
            return provider.complete(_request(), profile, token=token)
        except PlatformError as e:
            return e

    def test_pre_cancelled_token_never_sends(self):
        up = self.upstream(body=_stream_done("hi", "stop"))
        provider, profile = _vllm_with_server(up)
        token = CancellationToken()
        token.cancel()
        raises(ErrorCode.CANCELLED, provider.complete, _request(),
               profile, token)
        self.assertEqual(len(up.requests), 0)

    def test_wire_response_format_strict_forwarded(self):
        from ondevice_agent_platform.chat import ResponseFormat
        provider = VllmMlxProvider(_FakeStore())
        req = _request()
        req.response_format = ResponseFormat(
            kind="json_schema", name="r",
            schema={"type": "object"}, strict=True)
        body = provider._wire_request(req)
        self.assertTrue(
            body["response_format"]["json_schema"]["strict"])
        self.assertEqual(
            body["response_format"]["json_schema"]["schema"],
            {"type": "object"})

    def test_requires_load_dead_process_reaped(self):
        provider = VllmMlxProvider(_FakeStore())
        profile = _profile()
        dead = _fake_server(VllmServer, 1, profile.alias)
        dead.proc = _FakeProc(exit_code=0)
        provider._servers[profile.alias] = dead
        provider._epochs[profile.alias] = 0
        self.assertTrue(provider.requires_load(profile))
        self.assertNotIn(profile.alias, provider._servers)
        self.assertEqual(provider._epochs[profile.alias], 1)

    def test_healthy_cached_process_not_a_load(self):
        provider = VllmMlxProvider(_FakeStore())
        profile = _profile()
        provider._servers[profile.alias] = _fake_server(
            VllmServer, 1, profile.alias)
        self.assertFalse(provider.requires_load(profile))

    def test_server_stop_escalates_and_reaps(self):
        proc = _FakeProc(exit_code=None, terminate_times_out=True)
        srv = _fake_server(VllmServer, 1)
        srv.proc = proc
        srv.stop()
        self.assertIn("terminate", proc.calls)
        self.assertIn("kill", proc.calls)
        self.assertGreaterEqual(proc.calls.count("wait"), 2)
        self.assertIsNotNone(proc.exit_code)

    def test_evict_bumps_epoch_and_stops(self):
        provider = VllmMlxProvider(_FakeStore())
        profile = _profile()
        srv = _fake_server(VllmServer, 1, profile.alias)
        proc = srv.proc
        provider._servers[profile.alias] = srv
        provider._epochs[profile.alias] = 0
        provider.evict_resident()
        self.assertEqual(provider._epochs[profile.alias], 1)
        self.assertIn("terminate", proc.calls)

    def test_multi_choice_stream_refused(self):
        frames = [{"choices": [{"delta": {"content": "hi"}},
                               {"delta": {"content": "other"}}]},
                  {"choices": [{"delta": {}, "finish_reason": "stop"}]}]
        up = self.upstream(body=_sse(frames))
        provider, profile = _vllm_with_server(up)
        raises(ErrorCode.PROVIDER_UNAVAILABLE,
               provider.complete, _request(), profile)

    def test_non_dict_choice_refused(self):
        frames = [{"choices": ["not-a-dict"]},
                  {"choices": [{"delta": {}, "finish_reason": "stop"}]}]
        up = self.upstream(body=_sse(frames))
        provider, profile = _vllm_with_server(up)
        raises(ErrorCode.PROVIDER_UNAVAILABLE,
               provider.complete, _request(), profile)

    def test_non_dict_delta_refused(self):
        frames = [{"choices": [{"delta": "nope",
                                "finish_reason": None}]},
                  {"choices": [{"delta": {}, "finish_reason": "stop"}]}]
        up = self.upstream(body=_sse(frames))
        provider, profile = _vllm_with_server(up)
        raises(ErrorCode.PROVIDER_UNAVAILABLE,
               provider.complete, _request(), profile)

    def test_oversized_single_line_refused(self):
        # One absurdly long data line must not allocate past the cap.
        from unittest import mock
        from ondevice_agent_platform.limits import PlatformLimits
        body = b"data: " + b"x" * 4096 + b"\n\n"
        up = self.upstream(body=body)
        provider, profile = _vllm_with_server(up)
        with mock.patch.object(PlatformLimits, "REQUEST_BODY_BYTES", 128):
            raises(ErrorCode.PROVIDER_UNAVAILABLE,
                   provider.complete, _request(), profile)


class TestLlamaCppUpstream(unittest.TestCase):
    def setUp(self):
        self.upstreams = []
        self.addCleanup(self._close_all)

    def _close_all(self):
        for u in self.upstreams:
            u.close()

    def upstream(self, **kw):
        u = _FakeUpstream(**kw)
        self.upstreams.append(u)
        return u

    def _ok(self, content="pong", finish="stop", **kw):
        message = {"role": "assistant", "content": content}
        message.update(kw.pop("message_extra", {}))
        payload = {"choices": [{"message": message,
                                "finish_reason": finish}],
                   "usage": {"prompt_tokens": 2, "completion_tokens": 1,
                             "total_tokens": 3}}
        return json.dumps(payload).encode()

    def test_valid_text(self):
        up = self.upstream(body=self._ok("pong"))
        provider, profile = _llama_with_server(up)
        result = provider.complete(_request(), profile)
        self.assertEqual(result.content, "pong")
        self.assertEqual(result.finish_reason, FinishReason.STOP)
        self.assertEqual(result.usage.total_tokens, 3)

    def test_valid_tool_call(self):
        body = self._ok(
            "", finish="tool_calls",
            message_extra={"content": None, "tool_calls": [
                {"id": "call_9", "type": "function",
                 "function": {"name": "read_file",
                              "arguments": "{\"path\": \"fixture.txt\"}"}}]})
        up = self.upstream(body=body)
        provider, profile = _llama_with_server(up)
        result = provider.complete(_request(), profile)
        self.assertEqual(result.finish_reason, FinishReason.TOOL_CALLS)
        self.assertEqual(result.tool_calls[0].arguments,
                         {"path": "fixture.txt"})

    def test_upstream_500(self):
        up = self.upstream(status=500, body=b"internal detail")
        provider, profile = _llama_with_server(up)
        e = raises(ErrorCode.PROVIDER_UNAVAILABLE,
                   provider.complete, _request(), profile)
        self.assertIn("500", e.detail or "")
        self.assertNotIn("internal detail", e.detail or "")

    def test_malformed_body_json(self):
        up = self.upstream(body=b"{nope")
        provider, profile = _llama_with_server(up)
        raises(ErrorCode.PROVIDER_UNAVAILABLE,
               provider.complete, _request(), profile)

    def test_empty_choices(self):
        up = self.upstream(body=json.dumps({"choices": []}).encode())
        provider, profile = _llama_with_server(up)
        raises(ErrorCode.PROVIDER_UNAVAILABLE,
               provider.complete, _request(), profile)

    def test_non_object_tool_args_refused(self):
        body = self._ok("", finish="tool_calls",
                        message_extra={"content": None, "tool_calls": [
                            {"id": "c1", "type": "function",
                             "function": {"name": "read_file",
                                          "arguments": "\"x\""}}]})
        up = self.upstream(body=body)
        provider, profile = _llama_with_server(up)
        raises(ErrorCode.PROVIDER_UNAVAILABLE,
               provider.complete, _request(), profile)

    def test_empty_message_refused(self):
        body = json.dumps({"choices": [{"message": {"role": "assistant"},
                                        "finish_reason": "stop"}],
                           }).encode()
        up = self.upstream(body=body)
        provider, profile = _llama_with_server(up)
        raises(ErrorCode.PROVIDER_UNAVAILABLE,
               provider.complete, _request(), profile)

    def test_length_finish_preserved(self):
        up = self.upstream(body=self._ok("pong", "length"))
        provider, profile = _llama_with_server(up)
        result = provider.complete(_request(), profile)
        self.assertEqual(result.finish_reason, FinishReason.LENGTH)

    def test_validate_strict_refused(self):
        from ondevice_agent_platform.chat import ResponseFormat
        provider = LlamaCppProvider(_FakeStore())
        req = _request()
        req.response_format = ResponseFormat(
            kind="json_schema", schema={"type": "object"}, strict=True)
        raises(ErrorCode.INVALID_REQUEST,
               provider.validate, req, _profile(provider_id="llamacpp"))
        req.response_format = ResponseFormat(
            kind="json_schema", schema={"type": "object"}, strict=False)
        provider.validate(req, _profile(provider_id="llamacpp"))

    def test_validate_forced_tool_choice_refused(self):
        from ondevice_agent_platform.chat import (ChatToolSpec,
                                                  NamedToolChoice,
                                                  ToolChoice)
        provider = LlamaCppProvider(_FakeStore())
        req = _request()
        req.tools = [ChatToolSpec(**TOOL_SPEC)]
        req.tool_choice = NamedToolChoice("read_file")
        raises(ErrorCode.INVALID_REQUEST,
               provider.validate, req, _profile(provider_id="llamacpp"))
        req.tool_choice = ToolChoice.REQUIRED
        raises(ErrorCode.INVALID_REQUEST,
               provider.validate, req, _profile(provider_id="llamacpp"))
        req.tool_choice = ToolChoice.NONE
        provider.validate(req, _profile(provider_id="llamacpp"))

    def test_cancel_waiting_for_headers(self):
        gate = threading.Event()

        def stall(conn):
            gate.wait(5)

        up = self.upstream(responder=stall)
        provider, profile = _llama_with_server(up)
        token = CancellationToken()
        box = {}
        t = threading.Thread(target=lambda: box.setdefault(
            "r", self._complete(provider, profile, token)), daemon=True)
        t.start()
        time.sleep(0.3)
        token.cancel()
        t.join(5)
        self.assertFalse(t.is_alive())
        self.assertEqual(box["r"].code, ErrorCode.CANCELLED)
        gate.set()

    def _complete(self, provider, profile, token):
        try:
            return provider.complete(_request(), profile, token=token)
        except PlatformError as e:
            return e


class TestWireResult(unittest.TestCase):
    """Shared parser: strict shape rules independent of transport."""

    def test_tool_call_object_arguments_passthrough(self):
        result = _openai.wire_result(
            {"choices": [{"message": {
                "role": "assistant", "content": None,
                "tool_calls": [{"id": "c", "type": "function",
                                "function": {"name": "read_file",
                                             "arguments": {
                                                 "path": "fixture.txt"}}}]},
                          "finish_reason": "tool_calls"}]}, "m")
        self.assertEqual(result.tool_calls[0].arguments,
                         {"path": "fixture.txt"})

    def test_error_payload(self):
        raises(ErrorCode.PROVIDER_UNAVAILABLE, _openai.wire_result,
               {"error": {"message": "x"}}, "m")

    def test_missing_finish_reason(self):
        raises(ErrorCode.PROVIDER_UNAVAILABLE, _openai.wire_result,
               {"choices": [{"message": {"content": "hi"}}]}, "m")

    def test_content_filter_is_legitimate(self):
        result = _openai.wire_result(
            {"choices": [{"message": {"content": "read fixture"},
                          "finish_reason": "content_filter"}]}, "m")
        self.assertEqual(result.finish_reason, FinishReason.CONTENT_FILTER)
        self.assertEqual(result.content, "read fixture")

    def test_null_content_content_filter_allowed(self):
        # A filtered refusal with no content is a real terminal answer.
        result = _openai.wire_result(
            {"choices": [{"message": {"role": "assistant",
                                      "content": None},
                          "finish_reason": "content_filter"}]}, "m")
        self.assertEqual(result.finish_reason, FinishReason.CONTENT_FILTER)
        self.assertEqual(result.content, "")

    def test_empty_string_stop_refused(self):
        raises(ErrorCode.PROVIDER_UNAVAILABLE, _openai.wire_result,
               {"choices": [{"message": {"content": ""},
                             "finish_reason": "stop"}]}, "m")

    def test_null_content_stop_refused(self):
        raises(ErrorCode.PROVIDER_UNAVAILABLE, _openai.wire_result,
               {"choices": [{"message": {"content": None},
                             "finish_reason": "stop"}]}, "m")

    def test_tool_calls_finish_without_calls_refused(self):
        raises(ErrorCode.PROVIDER_UNAVAILABLE, _openai.wire_result,
               {"choices": [{"message": {"content": "hi"},
                             "finish_reason": "tool_calls"}]}, "m")

    def test_duplicate_tool_call_ids_refused(self):
        tc = {"id": "dup", "type": "function",
              "function": {"name": "read_file",
                           "arguments": {"path": "fixture.txt"}}}
        raises(ErrorCode.PROVIDER_UNAVAILABLE, _openai.wire_result,
               {"choices": [{"message": {"content": None,
                                         "tool_calls": [tc, dict(tc)]},
                             "finish_reason": "tool_calls"}]}, "m")

    def test_tool_calls_beyond_bound_refused(self):
        from unittest import mock
        from ondevice_agent_platform.limits import PlatformLimits
        tc = {"id": "c", "type": "function",
              "function": {"name": "read_file",
                           "arguments": {"path": "fixture.txt"}}}
        two = [dict(tc, id="a"), dict(tc, id="b")]
        with mock.patch.object(PlatformLimits,
                               "CHAT_TOOL_CALLS_PER_MESSAGE", 1):
            raises(ErrorCode.PROVIDER_UNAVAILABLE, _openai.wire_result,
                   {"choices": [{"message": {"content": None,
                                             "tool_calls": two},
                                 "finish_reason": "tool_calls"}]}, "m")

    def test_invalid_usage_refused(self):
        base = {"choices": [{"message": {"content": "hi"},
                             "finish_reason": "stop"}]}
        for bad in ({"prompt_tokens": True},
                    {"completion_tokens": -1},
                    {"total_tokens": "many"}):
            raises(ErrorCode.PROVIDER_UNAVAILABLE, _openai.wire_result,
                   dict(base, usage=bad), "m")

    def test_unknown_usage_fields_omitted(self):
        result = _openai.wire_result(
            {"choices": [{"message": {"content": "hi"},
                          "finish_reason": "stop"}],
             "usage": {"prompt_tokens": 3, "mystery": 9}}, "m")
        self.assertEqual(result.usage.prompt_tokens, 3)
        self.assertIsNone(result.usage.total_tokens)


if __name__ == "__main__":
    unittest.main()
