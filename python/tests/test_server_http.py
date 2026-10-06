"""Raw-socket transport tests for the platform HTTP server: Host
authority, request framing refusal, bounded reads, pipelining refusal,
peer-disconnect cancellation, and bounded-connection saturation."""
import json
import os
import socket
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))
sys.path.insert(0, os.path.dirname(__file__))

from ondevice_agent_platform.errors import ErrorCode, PlatformError
from ondevice_agent_platform.limits import PlatformLimits
from ondevice_agent_platform.server import PlatformHTTPServer

from test_supervisor import FakeLLM, FakeSource, make_supervisor
from ondevice_agent_platform.profiles import ModelKind, ModelProfile
from ondevice_agent_platform.state import JobState


def _parse_head(raw: bytes):
    head, _, body = raw.partition(b"\r\n\r\n")
    lines = head.split(b"\r\n")
    status = int(lines[0].split(b" ", 2)[1])
    headers = {}
    for line in lines[1:]:
        if b":" in line:
            k, v = line.split(b":", 1)
            headers[k.strip().lower().decode("latin-1")] = \
                v.strip().decode("latin-1")
    return status, headers, body


def _read_all(sock, timeout=5.0):
    sock.settimeout(timeout)
    out = b""
    try:
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            out += chunk
    except (socket.timeout, OSError):
        pass
    return out


def _read_response(sock, timeout=5.0):
    """Read exactly one response: head then Content-Length body. Streams
    and close-delimited responses read until timeout/close."""
    sock.settimeout(timeout)
    raw = b""
    while b"\r\n\r\n" not in raw:
        chunk = sock.recv(65536)
        if not chunk:
            return None
        raw += chunk
        if len(raw) > 65536:
            return None
    status, headers, body = _parse_head(raw)
    if "content-length" in headers:
        need = int(headers["content-length"]) - len(body)
        while need > 0:
            chunk = sock.recv(min(65536, need))
            if not chunk:
                break
            body += chunk
            need -= len(chunk)
    else:
        body += _read_all(sock, timeout)
    return status, headers, body


def _request(port, head: bytes, body: bytes = b"", timeout=5.0):
    s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    try:
        s.sendall(head + body)
        return _read_response(s, timeout)
    finally:
        s.close()


def _head(port, method="GET", path="/api/status", headers=None,
          host=None):
    h = [f"{method} {path} HTTP/1.1",
         f"Host: {host or f'127.0.0.1:{port}'}"]
    for k, v in (headers or {}).items():
        h.append(f"{k}: {v}")
    return ("\r\n".join(h) + "\r\n\r\n").encode()


class _BlockingLLM(FakeLLM):
    """Honors only the job token - provider.cancel() stays a no-op."""
    provider_id = "blocking-llm"

    def __init__(self):
        super().__init__()
        self.started = threading.Event()
        self.saw_cancel = threading.Event()

    def complete(self, request, profile, token=None):
        self.started.set()
        end = time.time() + 10
        while time.time() < end:
            if token is not None and token.is_cancelled:
                self.saw_cancel.set()
                raise PlatformError(ErrorCode.CANCELLED)
            time.sleep(0.02)
        raise PlatformError(ErrorCode.INTERNAL, "timeout in fake")


class TestTransport(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.sup = make_supervisor(self.tmp.name)
        self.addCleanup(self.sup.shutdown)
        self.provider = FakeLLM()
        self.sup.register_model(
            ModelProfile(alias="m", provider_id="fake-llm",
                         kind=ModelKind.LLM, task="chat",
                         max_output_tokens=64),
            provider=self.provider)
        self.server = PlatformHTTPServer(self.sup, port=0)
        self.server.start()
        self.addCleanup(self.server.stop)
        self.port = self.server.port

    def test_foreign_bind_refused(self):
        raises = None
        try:
            PlatformHTTPServer(self.sup, host="0.0.0.0", port=0)
        except PlatformError as e:
            raises = e
        self.assertIsNotNone(raises)
        self.assertEqual(raises.code, ErrorCode.ROOT_UNSAFE)

    def test_valid_status_request(self):
        status, headers, body = _request(
            self.port, _head(self.port))
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("x-content-type-options"),
                         "nosniff")
        self.assertIn(b"resource", body)

    def test_wrong_host_port_refused(self):
        status, _, _ = _request(
            self.port, _head(self.port,
                             host=f"127.0.0.1:{self.port + 1}"))
        self.assertEqual(status, 400)

    def test_foreign_host_refused(self):
        status, _, _ = _request(
            self.port, _head(self.port, host="evil.example"))
        self.assertEqual(status, 400)

    def test_missing_host_refused(self):
        raw = b"GET /api/status HTTP/1.1\r\nAccept: */*\r\n\r\n"
        status, _, _ = _request(self.port, raw)
        self.assertEqual(status, 400)

    def test_duplicate_host_refused(self):
        raw = (f"GET /api/status HTTP/1.1\r\n"
               f"Host: 127.0.0.1:{self.port}\r\n"
               f"Host: 127.0.0.1:{self.port}\r\n\r\n").encode()
        status, _, _ = _request(self.port, raw)
        self.assertEqual(status, 400)

    def test_transfer_encoding_refused(self):
        raw = _head(self.port, "POST", "/v1/chat/completions",
                    {"Transfer-Encoding": "chunked"})
        status, _, _ = _request(self.port, raw)
        self.assertEqual(status, 400)

    def test_conflicting_content_length_refused(self):
        body = b"{}"
        raw = _head(self.port, "POST", "/v1/chat/completions",
                    {"Content-Type": "application/json"}) \
            .replace(b"\r\n\r\n",
                     f"\r\nContent-Length: {len(body)}\r\n"
                     f"Content-Length: {len(body) + 1}\r\n\r\n".encode())
        status, _, _ = _request(self.port, raw, body)
        self.assertEqual(status, 400)

    def test_invalid_content_length_refused(self):
        raw = _head(self.port, "POST", "/v1/chat/completions",
                    {"Content-Length": "abc"})
        status, _, _ = _request(self.port, raw)
        self.assertEqual(status, 400)

    def test_oversized_content_length_refused(self):
        raw = _head(self.port, "POST", "/v1/chat/completions",
                    {"Content-Length":
                     str(PlatformLimits.REQUEST_BODY_BYTES + 1)})
        status, _, _ = _request(self.port, raw)
        self.assertEqual(status, 413)

    def test_expect_header_refused(self):
        raw = _head(self.port, "POST", "/v1/chat/completions",
                    {"Expect": "100-continue", "Content-Length": "2"})
        status, _, _ = _request(self.port, raw, b"{}")
        self.assertEqual(status, 417)

    def test_oversized_headers_refused(self):
        pad = "x" * (PlatformLimits.REQUEST_HEADER_BYTES + 64)
        raw = _head(self.port, headers={"X-Pad": pad})
        status, _, _ = _request(self.port, raw)
        self.assertEqual(status, 431)

    def test_full_size_header_plus_body_succeeds(self):
        # Regression: head bytes through the terminator may use the whole
        # header budget; lookahead body bytes arriving in the same recv
        # must not count against it (previously a false 431).
        body = json.dumps({"model": "m", "messages": [
            {"role": "user", "content": "hi"}]}).encode()
        base = _head(self.port, "POST", "/v1/chat/completions",
                     {"Content-Type": "application/json",
                      "Content-Length": str(len(body)),
                      "X-Pad": ""})
        pad_len = PlatformLimits.REQUEST_HEADER_BYTES - len(base)
        raw = _head(self.port, "POST", "/v1/chat/completions",
                    {"Content-Type": "application/json",
                     "Content-Length": str(len(body)),
                     "X-Pad": "x" * pad_len})
        self.assertLessEqual(
            len(raw), PlatformLimits.REQUEST_HEADER_BYTES)
        status, _, resp = _request(self.port, raw, body)
        self.assertEqual(status, 200)

    def test_colonless_header_line_refused(self):
        raw = (f"GET /api/status HTTP/1.1\r\n"
               f"Host: 127.0.0.1:{self.port}\r\n"
               f"garbage-no-colon\r\n\r\n").encode()
        status, _, _ = _request(self.port, raw)
        self.assertEqual(status, 400)

    def test_obs_fold_header_line_refused(self):
        raw = (f"GET /api/status HTTP/1.1\r\n"
               f"Host: 127.0.0.1:{self.port}\r\n"
               f" folded-continuation\r\n\r\n").encode()
        status, _, _ = _request(self.port, raw)
        self.assertEqual(status, 400)

    def test_connection_watcher_threads_do_not_leak(self):
        for _ in range(5):
            status, _, _ = _request(self.port, _head(self.port))
            self.assertEqual(status, 200)
        deadline = time.time() + 5
        while time.time() < deadline:
            watchers = [t for t in threading.enumerate()
                        if t.name == "oap-conn-watch" and t.is_alive()]
            if not watchers:
                break
            time.sleep(0.05)
        self.assertEqual(watchers, [])

    def test_get_with_body_refused(self):
        raw = _head(self.port, "GET", "/api/status",
                    {"Content-Length": "3"})
        status, _, _ = _request(self.port, raw, b"abc")
        self.assertEqual(status, 400)

    def test_pipelined_request_never_dispatches(self):
        first = _head(self.port, "GET", "/api/status")
        second = _head(self.port, "POST", "/v1/chat/completions",
                       {"Content-Type": "application/json",
                        "Content-Length": "60"})
        status, _, _ = _request(self.port, first + second)
        self.assertEqual(status, 400)
        self.assertEqual(self.provider.calls, 0)

    def test_truncated_body_times_out(self):
        with mock.patch.object(PlatformLimits, "CONNECTION_READ_SECONDS",
                               0.5):
            s = socket.create_connection(("127.0.0.1", self.port),
                                         timeout=5)
            try:
                s.sendall(_head(self.port, "POST",
                                "/v1/chat/completions",
                                {"Content-Length": "128",
                                 "Content-Type": "application/json"})
                          + b"{}")
                # The server must not answer or dispatch; the read
                # deadline closes the connection.
                out = _read_all(s, timeout=5)
                self.assertEqual(out, b"")
                self.assertEqual(self.provider.calls, 0)
            finally:
                s.close()

    def test_foreign_origin_403(self):
        status, _, _ = _request(
            self.port, _head(self.port,
                             headers={"Origin": "http://evil.example"}))
        self.assertEqual(status, 403)

    def test_cross_site_fetch_403(self):
        status, _, _ = _request(
            self.port, _head(self.port,
                             headers={"Sec-Fetch-Site": "cross-site"}))
        self.assertEqual(status, 403)

    def test_peer_disconnect_cancels_inference(self):
        provider = _BlockingLLM()
        self.sup.register_model(
            ModelProfile(alias="slow", provider_id="blocking-llm",
                         kind=ModelKind.LLM, task="chat",
                         max_output_tokens=64),
            provider=provider)
        body = json.dumps({"model": "slow", "messages": [
            {"role": "user", "content": "hi"}]}).encode()
        s = socket.create_connection(("127.0.0.1", self.port),
                                     timeout=5)
        s.sendall(_head(self.port, "POST", "/v1/chat/completions",
                        {"Content-Type": "application/json",
                         "Content-Length": str(len(body))}) + body)
        self.assertTrue(provider.started.wait(5))
        deadline = time.time() + 5
        job = None
        while time.time() < deadline and job is None:
            active = [j for j in self.sup.list_jobs()
                      if j.state == JobState.ACTIVE]
            job = active[0] if active else None
            time.sleep(0.02)
        self.assertIsNotNone(job)
        # The client vanishes mid-inference: the disconnect monitor must
        # cancel the request token the provider was handed.
        s.close()
        self.assertTrue(provider.saw_cancel.wait(5))
        # The ledger must reach a confirmed terminal CANCELLED with the
        # provider actually returned - not just the token signal observed.
        deadline = time.time() + 5
        record = None
        while time.time() < deadline:
            record = self.sup.job_record(job.id)
            if (record is not None
                    and record.state == JobState.CANCELLED
                    and record.provider_finished):
                break
            time.sleep(0.05)
        self.assertIsNotNone(record)
        self.assertEqual(record.state, JobState.CANCELLED)
        self.assertTrue(record.provider_finished)
        # And the server still serves afterwards.
        status, _, resp = _request(self.port, _head(self.port))
        self.assertEqual(status, 200)
        self.assertIn(b"resource", resp)

    def test_connection_saturation_recovers(self):
        with mock.patch.object(PlatformLimits, "CONNECTION_READ_SECONDS",
                               5.0):
            server = None
            with mock.patch.object(PlatformLimits, "CONNECTIONS", 4):
                server = PlatformHTTPServer(self.sup, port=0)
                server.start()
                port = server.port
                idles = []
                try:
                    for _ in range(4):
                        idles.append(socket.create_connection(
                            ("127.0.0.1", port), timeout=5))
                    # Slots full: an arriving request is refused, not
                    # queued forever.
                    result = _request(port, _head(port), timeout=5)
                    self.assertIsNotNone(result)
                    self.assertEqual(result[0], 429)
                    for s in idles:
                        s.close()
                    idles.clear()
                    time.sleep(0.3)
                    status, _, body = _request(port, _head(port))
                    self.assertEqual(status, 200)
                    self.assertIn(b"resource", body)
                finally:
                    for s in idles:
                        try:
                            s.close()
                        except OSError:
                            pass
                    server.stop()


if __name__ == "__main__":
    unittest.main()
