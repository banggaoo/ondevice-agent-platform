"""Direct provider truthfulness tests: stubbed mlx-lm/mlx-vlm modules
(never imported or loaded), strict response-format handling on every
route, readiness via find_spec only, and option rejection in validate."""
import io
import os
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from ondevice_agent_platform.cancellation import CancellationToken
from ondevice_agent_platform.chat import (ChatImage, ChatMessage,
                                          ChatRequest, ChatResult,
                                          ChatRole, ChatToolCall,
                                          ChatToolSpec, FinishReason,
                                          NamedToolChoice, ResponseFormat,
                                          ToolChoice)
from ondevice_agent_platform.errors import ErrorCode, PlatformError
from ondevice_agent_platform.profiles import (ModelKind, ModelProfile,
                                              ModelSource)
from ondevice_agent_platform.providers import mlx_provider
from ondevice_agent_platform.providers.apple import AppleFoundationProvider
from ondevice_agent_platform.providers.mlx_provider import MLXProvider


def raises(code, fn, *a, **k):
    try:
        fn(*a, **k)
    except PlatformError as e:
        assert e.code == code, f"expected {code}, got {e.code}: {e}"
        return e
    raise AssertionError(f"expected PlatformError {code}")


TOOL = ChatToolSpec(
    name="read_file",
    parameters={"type": "object",
                "properties": {"path": {"type": "string"}},
                "required": ["path"]})


def _request(**kw):
    defaults = dict(
        model="m",
        messages=[ChatMessage(role=ChatRole.USER, parts=["hi"])],
        max_output_tokens=32, has_explicit_output_limit=True)
    defaults.update(kw)
    return ChatRequest(**defaults)


def _profile(alias="m", capabilities=("text",), provider_id="mlx"):
    return ModelProfile(
        alias=alias, provider_id=provider_id, kind=ModelKind.LLM,
        task="chat", capabilities=capabilities, max_output_tokens=64,
        source=ModelSource(repo="o/r", revision="abc123"))


class _Chunk:
    def __init__(self, text="", prompt_tokens=0, generation_tokens=0,
                 finish_reason=None):
        self.text = text
        self.prompt_tokens = prompt_tokens
        self.generation_tokens = generation_tokens
        self.finish_reason = finish_reason


class _FakeStore:
    def __init__(self, ready=True):
        self._ready = ready

    def is_ready(self, source, artifact_file=None):
        return self._ready

    def directory(self, source, artifact_file=None):
        return tempfile.gettempdir()

    def manifest_of(self, source, artifact_file=None):
        return {"files": []}


def _installed_provider(vlm=True):
    """MLXProvider with a resident fake container - no real load."""
    provider = MLXProvider(_FakeStore())
    model = types.SimpleNamespace(config=types.SimpleNamespace())
    processor = types.SimpleNamespace()
    provider._containers["m"] = mlx_provider._Container(
        model, processor, vlm)
    return provider


class TestMLXValidate(unittest.TestCase):
    def setUp(self):
        self.provider = MLXProvider(_FakeStore())
        self.profile = _profile()

    def test_nonzero_penalties_refused(self):
        req = _request(presence_penalty=0.5)
        raises(ErrorCode.INVALID_REQUEST,
               self.provider.validate, req, self.profile)
        req = _request(frequency_penalty=-0.1)
        raises(ErrorCode.INVALID_REQUEST,
               self.provider.validate, req, self.profile)

    def test_zero_penalty_is_noop(self):
        req = _request(presence_penalty=0.0, frequency_penalty=0.0)
        self.provider.validate(req, self.profile)

    def test_forced_tool_choice_best_effort(self):
        req = _request(tools=[TOOL], tool_choice=ToolChoice.REQUIRED)
        self.provider.validate(req, self.profile)
        req = _request(tools=[TOOL],
                       tool_choice=NamedToolChoice("read_file"))
        self.provider.validate(req, self.profile)

    def test_auto_and_none_tool_choice_allowed(self):
        for choice in (ToolChoice.AUTO, ToolChoice.NONE, None):
            req = _request(tools=[TOOL], tool_choice=choice)
            self.provider.validate(req, self.profile)

    def test_strict_response_format_refused(self):
        req = _request(response_format=ResponseFormat(
            kind="json_schema", schema={"type": "object"}, strict=True))
        raises(ErrorCode.INVALID_REQUEST,
               self.provider.validate, req, self.profile)

    def test_nonstrict_formats_allowed(self):
        for strict in (None, False):
            req = _request(response_format=ResponseFormat(
                kind="json_schema", schema={"type": "object"},
                strict=strict))
            self.provider.validate(req, self.profile)
        req = _request(response_format=ResponseFormat(kind="json_object"))
        self.provider.validate(req, self.profile)


class TestMLXReadiness(unittest.TestCase):
    def test_has_ready_artifact_never_imports(self):
        provider = MLXProvider(_FakeStore(ready=True))
        provider.track_profiles([_profile()])
        with mock.patch.object(
                mlx_provider, "_module_present", return_value=True), \
                mock.patch.object(
                    mlx_provider, "_import_mlx_lm",
                    side_effect=AssertionError("import on health path")), \
                mock.patch.object(
                    mlx_provider, "_import_mlx_vlm",
                    side_effect=AssertionError("import on health path")):
            self.assertTrue(provider.has_ready_artifact)

    def test_not_ready_when_store_empty(self):
        provider = MLXProvider(_FakeStore(ready=False))
        provider.track_profiles([_profile()])
        with mock.patch.object(mlx_provider, "_module_present",
                               side_effect=AssertionError(
                                   "probe with no artifact")):
            self.assertFalse(provider.has_ready_artifact)

    def test_module_absent_is_not_ready(self):
        provider = MLXProvider(_FakeStore(ready=True))
        provider.track_profiles([_profile()])
        with mock.patch.object(
                mlx_provider, "_module_present", return_value=False):
            self.assertFalse(provider.has_ready_artifact)


class _DecodedImage:
    """Stand-in for the PIL image utils.load_image returns; carries the
    source bytes it decoded so tests can verify BytesIO -> decoded object."""
    def __init__(self, source_bytes):
        self.raw = source_bytes


def _vlm_module(chunks, captured):
    """A fake mlx_vlm: apply_chat_template records its arguments;
    stream_generate yields the scripted chunks and records kwargs;
    utils.load_image decodes a BytesIO into a _DecodedImage like the real
    seam (which returns a PIL image), so the ABI mismatch where raw buffers
    reached stream_generate cannot hide in the stub."""
    vlm = types.ModuleType("mlx_vlm")

    def apply_chat_template(processor, config, messages, **kw):
        captured["template_messages"] = messages
        captured["template_kwargs"] = kw
        return "rendered-prompt"

    def stream_generate(model, processor, prompt, image=None, **kw):
        captured["prompt"] = prompt
        captured["image"] = image
        captured["gen_kwargs"] = kw
        for c in chunks:
            yield c

    def load_image(source):
        data = source.getvalue()
        captured.setdefault("load_image_inputs", []).append(data)
        return _DecodedImage(data)

    vlm.stream_generate = stream_generate
    vlm.prompt_utils = types.SimpleNamespace(
        apply_chat_template=apply_chat_template)
    vlm.utils = types.SimpleNamespace(load_image=load_image)
    vlm.load = lambda path: (object(), object())
    return vlm


def _lm_module(chunks, captured):
    lm = types.ModuleType("mlx_lm")

    def stream_generate(model, tokenizer, prompt=None, **kw):
        captured["prompt"] = prompt
        captured["gen_kwargs"] = kw
        for c in chunks:
            yield c

    lm.stream_generate = stream_generate
    lm.load = lambda path: (object(), object())
    sample_utils = types.ModuleType("mlx_lm.sample_utils")

    def make_sampler(**kw):
        captured["sampler"] = kw
        return ("sampler", kw)

    sample_utils.make_sampler = make_sampler
    lm.sample_utils = sample_utils
    return lm, {"mlx_lm": lm, "mlx_lm.sample_utils": sample_utils}


_PNG = (b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR"
        b"\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00"
        b"\x1f\x15\xc4\x89")


class TestMlxVlmPath(unittest.TestCase):
    def _complete(self, provider, req, token=None, chunks=None):
        captured = {}
        chunks = chunks if chunks is not None else [
            _Chunk("hi", prompt_tokens=5, generation_tokens=2,
                   finish_reason="stop")]
        fake = _vlm_module(chunks, captured)
        with mock.patch.object(mlx_provider, "_import_mlx_vlm",
                               return_value=fake), \
                mock.patch.object(mlx_provider, "_import_mlx_lm",
                                  return_value=object()):
            result = provider.complete(req, _profile(
                capabilities=("text", "vision")), token=token)
        return result, captured

    def test_full_history_and_decoded_images(self):
        provider = _installed_provider(vlm=True)
        messages = [
            ChatMessage(role=ChatRole.SYSTEM, parts=["sys"]),
            ChatMessage(role=ChatRole.USER, parts=["first"],
                        images=[ChatImage(data=_PNG,
                                          media_type="image/png")]),
            ChatMessage(role=ChatRole.ASSISTANT, parts=["earlier"]),
            ChatMessage(role=ChatRole.USER, parts=["hi"]),
        ]
        req = _request(messages=messages)
        result, captured = self._complete(provider, req)
        sent = captured["template_messages"]
        # Every turn survives, in order; image turn carries markers.
        self.assertEqual([m["role"] for m in sent],
                         ["system", "user", "assistant", "user"])
        content = sent[1]["content"]
        # Image markers lead the turn's content: Gemma 4's grounding
        # degrades when instructions precede the image.
        self.assertEqual(content[0], {"type": "image"})
        self.assertEqual(content[1], {"type": "text", "text": "first"})
        self.assertEqual(captured["template_kwargs"]["num_images"], 1)
        self.assertTrue(
            captured["template_kwargs"]["add_generation_prompt"])
        # load_image received a BytesIO wrapping the original bytes...
        self.assertEqual(captured["load_image_inputs"], [_PNG])
        # ...and stream_generate received the DECODED object, not a buffer.
        images = captured["image"]
        self.assertEqual(len(images), 1)
        self.assertIsInstance(images[0], _DecodedImage)
        self.assertNotIsInstance(images[0], io.BytesIO)
        self.assertEqual(images[0].raw, _PNG)
        self.assertEqual(result.content, "hi")
        self.assertEqual(result.usage.prompt_tokens, 5)
        self.assertEqual(result.usage.completion_tokens, 2)

    def test_image_order_preserved_across_turns(self):
        provider = _installed_provider(vlm=True)
        other = b"\x89PNG-second-turn-image"
        messages = [
            ChatMessage(role=ChatRole.USER, parts=["one"],
                        images=[ChatImage(data=_PNG,
                                          media_type="image/png")]),
            ChatMessage(role=ChatRole.ASSISTANT, parts=["between"]),
            ChatMessage(role=ChatRole.USER, parts=["two"],
                        images=[ChatImage(data=other,
                                          media_type="image/png")]),
        ]
        _, captured = self._complete(provider, _request(messages=messages))
        images = captured["image"]
        self.assertEqual([i.raw for i in images], [_PNG, other])
        self.assertEqual(captured["load_image_inputs"], [_PNG, other])
        contents = [m["content"] for m in captured["template_messages"]]
        self.assertEqual(contents[0][0], {"type": "image"})
        self.assertEqual(contents[2][0], {"type": "image"})
        self.assertEqual(captured["template_kwargs"]["num_images"], 2)

    def test_sampling_and_seed_forwarded(self):
        provider = _installed_provider(vlm=True)
        req = _request(temperature=0.4, top_p=0.9, seed=7)
        _, captured = self._complete(provider, req)
        gen = captured["gen_kwargs"]
        self.assertEqual(gen["temperature"], 0.4)
        self.assertEqual(gen["top_p"], 0.9)
        self.assertEqual(gen["seed"], 7)
        self.assertNotIn("temp", gen)

    def test_length_finish_preserved(self):
        provider = _installed_provider(vlm=True)
        result, _ = self._complete(provider, _request(), chunks=[
            _Chunk("hi", prompt_tokens=1, generation_tokens=3,
                   finish_reason="length")])
        self.assertEqual(result.finish_reason, FinishReason.LENGTH)

    def test_cancellation_between_chunks(self):
        provider = _installed_provider(vlm=True)
        token = CancellationToken()
        gate = threading.Event()
        chunks_iter = []

        def gen():
            yield _Chunk("h", prompt_tokens=1, generation_tokens=1)
            gate.wait(5)          # stall; token must abort
            yield _Chunk("i")

        chunks_iter = gen()
        captured = {}
        fake = _vlm_module(chunks_iter, captured)
        box = {}

        def run():
            try:
                with mock.patch.object(
                        mlx_provider, "_import_mlx_vlm",
                        return_value=fake), \
                        mock.patch.object(mlx_provider, "_import_mlx_lm",
                                          return_value=object()):
                    box["r"] = provider.complete(
                        _request(), _profile(
                            capabilities=("text", "vision")),
                        token=token)
            except PlatformError as e:
                box["r"] = e

        t = threading.Thread(target=run, daemon=True)
        t.start()
        time.sleep(0.3)
        token.cancel()
        gate.set()
        t.join(5)
        self.assertFalse(t.is_alive())
        self.assertIsInstance(box["r"], PlatformError)
        self.assertEqual(box["r"].code, ErrorCode.CANCELLED)

    def test_tool_choice_none_suppresses_schemas_and_calls(self):
        provider = _installed_provider(vlm=True)
        req = _request(tools=[TOOL], tool_choice=ToolChoice.NONE)
        chunks = [_Chunk('{"name":"read_file","arguments":'
                         '{"path":"fixture.txt"}}',
                         prompt_tokens=2, generation_tokens=4,
                         finish_reason="stop")]
        result, captured = self._complete(provider, req, chunks=chunks)
        self.assertNotIn("tools", captured["template_kwargs"])
        self.assertEqual(result.tool_calls, [])
        self.assertEqual(result.finish_reason, FinishReason.STOP)

    def test_tool_schemas_forwarded_when_allowed(self):
        provider = _installed_provider(vlm=True)
        req = _request(tools=[TOOL], tool_choice=ToolChoice.AUTO)
        _, captured = self._complete(provider, req)
        tools = captured["template_kwargs"].get("tools")
        self.assertIsNotNone(tools)
        self.assertEqual(tools[0]["function"]["name"], "read_file")

    def test_named_tool_choice_narrows_schemas(self):
        provider = _installed_provider(vlm=True)
        other = ChatToolSpec(name="write_file",
                             parameters={"type": "object", "properties": {}})
        req = _request(tools=[TOOL, other],
                       tool_choice=NamedToolChoice("read_file"))
        _, captured = self._complete(provider, req)
        tools = captured["template_kwargs"].get("tools")
        self.assertEqual([t["function"]["name"] for t in tools],
                         ["read_file"])

    def test_tool_result_turn_preserved(self):
        provider = _installed_provider(vlm=True)
        messages = [
            ChatMessage(role=ChatRole.USER, parts=["hi"]),
            ChatMessage(role=ChatRole.ASSISTANT,
                        tool_calls=[ChatToolCall(
                            id="c1", name="read_file",
                            arguments={"path": "fixture.txt"})]),
            ChatMessage(role=ChatRole.TOOL, parts=["read fixture"],
                        tool_call_id="c1"),
        ]
        req = _request(messages=messages)
        _, captured = self._complete(provider, req)
        sent = captured["template_messages"]
        self.assertEqual([m["role"] for m in sent],
                         ["user", "assistant", "tool"])
        self.assertEqual(sent[1]["tool_calls"][0]["function"]["name"],
                         "read_file")
        self.assertEqual(sent[2]["tool_call_id"], "c1")

    def test_gemma_tool_call_markup_parsed(self):
        # gemma4 emits its own markup (tool_call tags + quote tokens)
        # rather than the JSON envelope; the envelope parser must lift
        # it into ChatToolCall or consumers see undispatchable text.
        lt, gt, bar, q = chr(60), chr(62), chr(124), chr(34)
        text = (lt + bar + "tool_call" + gt + "call:read_file{path:"
                + lt + bar + q + bar + gt + "fixture.txt"
                + lt + bar + q + bar + gt + "}"
                + lt + "tool_call" + bar + gt)
        req = _request(tools=[TOOL])
        provider = MLXProvider.__new__(MLXProvider)
        result = provider._result(text, req, 10, 5)
        self.assertEqual(result.finish_reason, FinishReason.TOOL_CALLS)
        self.assertEqual(len(result.tool_calls), 1)
        self.assertEqual(result.tool_calls[0].name, "read_file")
        self.assertEqual(result.tool_calls[0].arguments,
                         {"path": "fixture.txt"})
        self.assertEqual(result.content, "")

    def test_hermes_tool_call_markup_parsed(self):
        # qwen chat templates emit Hermes markup: <tool_call> wrapping
        # <function=name><parameter=k>v</parameter></function>; the
        # parser must lift it or consumers see undispatchable XML.
        text = ("<tool_call>\n<function=get_weather>\n"
                "<parameter=city>\nSeoul\n</parameter>\n"
                "<parameter=units>\"celsius\"</parameter>\n"
                "</function>\n</tool_call>")
        req = _request(tools=[TOOL])
        provider = MLXProvider.__new__(MLXProvider)
        result = provider._result(text, req, 10, 5)
        self.assertEqual(result.finish_reason, FinishReason.TOOL_CALLS)
        self.assertEqual(len(result.tool_calls), 1)
        self.assertEqual(result.tool_calls[0].name, "get_weather")
        self.assertEqual(result.tool_calls[0].arguments,
                         {"city": "Seoul", "units": "celsius"})
        self.assertEqual(result.content, "")


class TestMlxTextPath(unittest.TestCase):
    def test_sampler_params_and_result(self):
        provider = _installed_provider(vlm=False)
        tokenizer = types.SimpleNamespace()
        provider._containers["m"].processor = tokenizer
        captured = {}

        def apply_chat_template(messages, **kw):
            captured["messages"] = messages
            captured["template_kwargs"] = kw
            return "rendered"

        tokenizer.apply_chat_template = apply_chat_template
        lm, modules = _lm_module(
            [_Chunk("hi", prompt_tokens=4, generation_tokens=1,
                    finish_reason="stop")], captured)
        with mock.patch.dict(sys.modules, modules), \
                mock.patch.object(mlx_provider, "_import_mlx_lm",
                                  return_value=lm):
            result = provider.complete(
                _request(temperature=0.2, top_p=0.5),
                _profile())
        self.assertEqual(result.content, "hi")
        self.assertEqual(captured["sampler"]["temp"], 0.2)
        self.assertEqual(captured["sampler"]["top_p"], 0.5)
        self.assertEqual(captured["gen_kwargs"]["max_tokens"], 32)
        self.assertEqual([m["role"] for m in captured["messages"]],
                         ["user"])

    def test_text_length_finish(self):
        provider = _installed_provider(vlm=False)
        tokenizer = types.SimpleNamespace(
            apply_chat_template=lambda m, **kw: "p")
        provider._containers["m"].processor = tokenizer
        lm, modules = _lm_module(
            [_Chunk("hi", prompt_tokens=4, generation_tokens=1,
                    finish_reason="length")], {})
        with mock.patch.dict(sys.modules, modules), \
                mock.patch.object(mlx_provider, "_import_mlx_lm",
                                  return_value=lm):
            result = provider.complete(_request(), _profile())
        self.assertEqual(result.finish_reason, FinishReason.LENGTH)

    def test_tool_choice_none_blocks_parsed_calls(self):
        provider = _installed_provider(vlm=False)
        tokenizer = types.SimpleNamespace(
            apply_chat_template=lambda m, **kw: "p")
        provider._containers["m"].processor = tokenizer
        lm, modules = _lm_module([_Chunk(
            '{"name":"read_file","arguments":{"path":"fixture.txt"}}',
            prompt_tokens=1, generation_tokens=2,
            finish_reason="stop")], {})
        req = _request(tools=[TOOL], tool_choice=ToolChoice.NONE)
        with mock.patch.dict(sys.modules, modules), \
                mock.patch.object(mlx_provider, "_import_mlx_lm",
                                  return_value=lm):
            result = provider.complete(req, _profile())
        self.assertEqual(result.tool_calls, [])
        self.assertEqual(result.finish_reason, FinishReason.STOP)


class TestEnsureContainer(unittest.TestCase):
    """Provider-owned deduplicated load: waiters share one in-flight load;
    a cancelled waiter unwinds while the load still caches the result."""

    def setUp(self):
        self.provider = MLXProvider(_FakeStore())
        self.profile = _profile()

    def _fake_load(self, delay, calls):
        container = mlx_provider._Container(
            types.SimpleNamespace(), types.SimpleNamespace(), False)

        def fake(profile):
            calls.append(1)
            time.sleep(delay)
            self.provider._containers[profile.alias] = container
            return container
        self.provider._container_for = fake
        return container

    def test_waiters_share_one_load(self):
        calls = []
        container = self._fake_load(0.1, calls)
        results = []
        threads = [threading.Thread(
            target=lambda: results.append(
                self.provider._ensure_container(self.profile, None)))
            for _ in range(2)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(5)
        self.assertEqual(len(results), 2)
        self.assertEqual(len(calls), 1)
        self.assertIs(results[0], container)
        self.assertIs(results[1], container)

    def test_cancelled_waiter_unwinds_load_still_caches(self):
        calls = []
        container = self._fake_load(0.15, calls)
        token = CancellationToken()
        caught = []

        def wait():
            try:
                self.provider._ensure_container(self.profile, token)
            except PlatformError as e:
                caught.append(e)

        t = threading.Thread(target=wait)
        t.start()
        time.sleep(0.03)
        token.cancel()
        t.join(5)
        self.assertEqual(len(caught), 1)
        self.assertEqual(caught[0].code, ErrorCode.CANCELLED)
        deadline = time.time() + 2
        while ("m" not in self.provider._containers
               and time.time() < deadline):
            time.sleep(0.01)
        self.assertIs(self.provider._containers["m"], container)
        self.assertEqual(len(calls), 1)

    def test_load_error_reaches_waiters(self):
        def boom(profile):
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                "model artifact not pulled")
        self.provider._container_for = boom
        raises(ErrorCode.PROVIDER_UNAVAILABLE,
               self.provider._ensure_container, self.profile, None)

    def test_cancelled_after_load_completes_still_refuses(self):
        calls = []
        self._fake_load(0.0, calls)
        token = CancellationToken()
        token.cancel()
        raises(ErrorCode.CANCELLED,
               self.provider._ensure_container, self.profile, token)

    def test_evict_alias_drops_container_and_blocks_reuse(self):
        calls = []
        self._fake_load(0.0, calls)
        self.provider._ensure_container(self.profile, None)
        self.assertIn("m", self.provider._containers)
        self.assertTrue(self.provider.evict_alias("m"))
        self.assertNotIn("m", self.provider._containers)
        self.assertFalse(self.provider.evict_alias("m"))
        self.assertTrue(self.provider.requires_load(self.profile))


class TestAppleValidate(unittest.TestCase):
    def setUp(self):
        self.provider = AppleFoundationProvider()
        self.profile = _profile(provider_id="apple-foundation-models")

    def test_strict_refused(self):
        req = _request(response_format=ResponseFormat(
            kind="json_schema", schema={"type": "object"}, strict=True))
        raises(ErrorCode.INVALID_REQUEST,
               self.provider.validate, req, self.profile)

    def test_unsupported_sampling_refused(self):
        raises(ErrorCode.INVALID_REQUEST, self.provider.validate,
               _request(top_p=0.5), self.profile)
        raises(ErrorCode.INVALID_REQUEST, self.provider.validate,
               _request(seed=1), self.profile)

    def test_tools_refused(self):
        raises(ErrorCode.INVALID_REQUEST, self.provider.validate,
               _request(tools=[TOOL]), self.profile)


class TestAppleBridgeLifecycle(unittest.TestCase):
    """Owned children: close() terminates/reaps and closes pipes, and a
    blocked complete() unwinds as CANCELLED - real subprocess where the
    lock/IO race only shows with a live child."""

    def _real_child(self, marker):
        import subprocess
        script = ("import sys,time\n"
                  "sys.stdin.readline()\n"
                  "open(sys.argv[1],'w').write('x')\n"
                  "time.sleep(20)\n")
        return subprocess.Popen(
            [sys.executable, "-u", "-c", script, marker],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            text=True, bufsize=1)

    def test_cancel_blocked_complete_ends_cancelled(self):
        with tempfile.TemporaryDirectory() as d:
            marker = os.path.join(d, "got-request")
            provider = AppleFoundationProvider()
            proc = self._real_child(marker)
            provider._proc = proc
            token = CancellationToken()
            box = {}

            def run():
                try:
                    provider.complete(_request(), self._profile(), token)
                except PlatformError as e:
                    box["r"] = e

            t = threading.Thread(target=run, daemon=True)
            t.start()
            # Wait until the fake child has consumed the request line:
            # the provider is now blocked in stdout.readline.
            deadline = time.time() + 10
            while not os.path.exists(marker) and time.time() < deadline:
                time.sleep(0.02)
            self.assertTrue(os.path.exists(marker))
            token.cancel()
            t.join(5)
            self.assertFalse(t.is_alive())
            self.assertIsInstance(box.get("r"), PlatformError)
            self.assertEqual(box["r"].code, ErrorCode.CANCELLED)
            self.assertIsNotNone(proc.poll())        # reaped
            self.assertTrue(proc.stdin.closed)
            self.assertTrue(proc.stdout.closed)
            provider.close()

    def test_close_closes_all_pipes(self):
        with tempfile.TemporaryDirectory() as d:
            provider = AppleFoundationProvider()
            proc = self._real_child(os.path.join(d, "m"))
            provider._proc = proc
            provider.close()
            self.assertIsNotNone(proc.poll())
            self.assertTrue(proc.stdin.closed)
            self.assertTrue(proc.stdout.closed)
            self.assertIsNone(provider._proc)

    def _profile(self):
        return _profile(provider_id="apple-foundation-models")

    def test_close_terminates_and_reaps(self):
        provider = AppleFoundationProvider()
        proc = mock.Mock()
        proc.poll.return_value = None
        provider._proc = proc
        provider.close()
        proc.terminate.assert_called_once()
        proc.wait.assert_called()
        self.assertIsNone(provider._proc)

    def test_close_when_no_child(self):
        provider = AppleFoundationProvider()
        provider.close()
        provider.close()
        self.assertIsNone(provider._proc)

    def test_close_tolerates_dead_child(self):
        provider = AppleFoundationProvider()
        proc = mock.Mock()
        proc.poll.return_value = 0
        proc.terminate.side_effect = ProcessLookupError()
        provider._proc = proc
        provider.close()
        self.assertIsNone(provider._proc)


class TestResponseUsage(unittest.TestCase):
    """Usage is emitted only when all three counts are known - partial
    results are never zero-filled into fabricated counts."""

    def _result(self, usage):
        from ondevice_agent_platform.chat import ChatResult, ChatUsage
        return ChatResult(model_identity="m", content="pong",
                          finish_reason=FinishReason.STOP,
                          usage=usage)

    def _stream_usage(self, frames):
        import json as _json
        for raw in frames:
            if raw == b"data: [DONE]\n\n":
                continue
            payload = _json.loads(
                raw[len(b"data: "):].strip())
            if payload.get("choices") == []:
                return payload["usage"]
        return None

    def test_partial_usage_omitted_not_fabricated(self):
        from ondevice_agent_platform.chat import ChatUsage
        from ondevice_agent_platform import openai_adapter
        result = self._result(ChatUsage(
            prompt_tokens=3, completion_tokens=None,
            total_tokens=None))
        body = openai_adapter.chat_response(result, "m")
        self.assertNotIn("usage", body)
        frames = openai_adapter.stream_frames(result, "m",
                                              include_usage=True)
        self.assertIsNone(self._stream_usage(frames))

    def test_genuine_zero_counts_emitted(self):
        from ondevice_agent_platform.chat import ChatUsage
        from ondevice_agent_platform import openai_adapter
        result = self._result(ChatUsage(
            prompt_tokens=0, completion_tokens=0, total_tokens=0))
        body = openai_adapter.chat_response(result, "m")
        self.assertEqual(body["usage"],
                         {"prompt_tokens": 0, "completion_tokens": 0,
                          "total_tokens": 0})
        frames = openai_adapter.stream_frames(result, "m",
                                              include_usage=True)
        self.assertEqual(self._stream_usage(frames), body["usage"])

    def test_full_usage_unchanged(self):
        from ondevice_agent_platform.chat import ChatUsage
        from ondevice_agent_platform import openai_adapter
        result = self._result(ChatUsage(
            prompt_tokens=3, completion_tokens=1, total_tokens=4))
        body = openai_adapter.chat_response(result, "m")
        self.assertEqual(body["usage"],
                         {"prompt_tokens": 3, "completion_tokens": 1,
                          "total_tokens": 4})


class _FakeDelegate:
    """Records escalations; answers with a canned result."""
    provider_id = "fake-delegate"

    def __init__(self, ready=True, requires_load=False):
        self.calls: list[ChatRequest] = []
        self._ready = ready
        self._requires_load = requires_load

    def artifact_ready(self, profile):
        return self._ready

    def requires_load(self, profile):
        return self._requires_load

    def complete(self, request, profile, token=None):
        self.calls.append(request)
        return ChatResult(model_identity=profile.alias, content="VLM",
                          finish_reason=FinishReason.STOP, usage=None)


class TestVisionHybrid(unittest.TestCase):
    """The deterministic OCR-first / VLM-fallback policy."""

    def _hybrid(self, ocr=None, delegate=None):
        from ondevice_agent_platform.providers.vision_hybrid import (
            VisionHybridProvider)
        dep = delegate or _FakeDelegate()
        hybrid = VisionHybridProvider(ocr=ocr)
        profile = _profile("vision-hybrid", capabilities=("text", "vision"),
                           provider_id="vision-hybrid")
        dprofile = _profile("qwen-vl", capabilities=("text", "vision"))
        hybrid.bind(profile.alias, dep, dprofile)
        return hybrid, dep, profile

    def _image_request(self, text="read the text"):
        return _request(messages=[ChatMessage(
            role=ChatRole.USER, parts=[text],
            images=[ChatImage(data=b"pngbytes", media_type="image/png")])])

    def test_ocr_direct_when_extraction_and_confident(self):
        hybrid, dep, profile = self._hybrid(
            ocr=lambda _b: [("Total $12.34", 0.97)])
        result = hybrid.complete(self._image_request(), profile)
        self.assertEqual(result.content, "Total $12.34")
        self.assertEqual(result.finish_reason, FinishReason.STOP)
        self.assertIsNone(result.usage)   # no tokens consumed
        self.assertEqual(dep.calls, [])   # VLM never invoked

    def test_ocr_direct_carries_structured_observations(self):
        # The additive oap_ocr field feeds callers that need positions
        # (ARTEMIS's OCR tool contract: text + pixel vertices).
        pos = [{"x": 0, "y": 8}, {"x": 286, "y": 8},
               {"x": 286, "y": 68}, {"x": 0, "y": 68}]
        hybrid, dep, profile = self._hybrid(
            ocr=lambda _b: [("TOTAL", 1.0, pos)])
        result = hybrid.complete(self._image_request(), profile)
        self.assertEqual(result.extra["oap_ocr"],
                         [{"text": "TOTAL", "confidence": 1.0,
                           "position": pos}])
        # Injected two-tuples (no position) normalize to position None.
        hybrid2, _d, profile2 = self._hybrid(
            ocr=lambda _b: [("X", 0.9)])
        res2 = hybrid2.complete(self._image_request(), profile2)
        self.assertIsNone(res2.extra["oap_ocr"][0]["position"])

    def test_escalated_answers_carry_no_ocr_field(self):
        # A VLM semantic answer has no positional OCR data - callers must
        # not mistake generated text for grounded boxes.
        hybrid, dep, profile = self._hybrid(ocr=lambda _b: [])
        result = hybrid.complete(self._image_request(), profile)
        self.assertIsNone(result.extra)

    def test_low_confidence_escalates_plain(self):
        hybrid, dep, profile = self._hybrid(
            ocr=lambda _b: [("garbled", 0.20)])
        result = hybrid.complete(self._image_request(), profile)
        self.assertEqual(result.content, "VLM")
        # Untrustworthy OCR must not reach the VLM as context.
        self.assertEqual(dep.calls[0].messages[0].role, ChatRole.USER)

    def test_empty_ocr_escalates_plain(self):
        hybrid, dep, profile = self._hybrid(ocr=lambda _b: [])
        hybrid.complete(self._image_request(), profile)
        self.assertEqual(len(dep.calls), 1)
        self.assertEqual(dep.calls[0].messages[0].role, ChatRole.USER)

    def test_semantic_prompt_escalates_with_ocr_context(self):
        hybrid, dep, profile = self._hybrid(
            ocr=lambda _b: [("SALE 50%", 0.99)])
        request = self._image_request("what color are the walls")
        hybrid.complete(request, profile)
        self.assertEqual(len(dep.calls), 1)
        escalated = dep.calls[0]
        self.assertEqual(escalated.messages[0].role, ChatRole.SYSTEM)
        self.assertIn("SALE 50%", escalated.messages[0].combined_text)
        # The original user turn (image intact) follows the context.
        self.assertTrue(escalated.messages[1].images)

    def test_no_images_passthrough(self):
        hybrid, dep, profile = self._hybrid()
        hybrid.complete(_request(), profile)
        self.assertEqual(len(dep.calls), 1)

    def test_bridge_absent_escalates(self):
        # ocr=None -> real bridge lookup; patch it missing.
        from ondevice_agent_platform.providers import vision_hybrid
        hybrid, dep, profile = self._hybrid(ocr=None)
        with mock.patch.object(vision_hybrid, "_vision_bridge",
                               return_value=None):
            result = hybrid.complete(self._image_request(), profile)
        self.assertEqual(result.content, "VLM")
        self.assertEqual(len(dep.calls), 1)

    def test_unbound_alias_unavailable(self):
        from ondevice_agent_platform.providers.vision_hybrid import (
            VisionHybridProvider)
        hybrid = VisionHybridProvider()
        raises(ErrorCode.PROVIDER_UNAVAILABLE, hybrid.complete,
               self._image_request(),
               _profile("ghost", provider_id="vision-hybrid"))

    def test_validate_refuses_strict(self):
        hybrid, _dep, profile = self._hybrid()
        rf = ResponseFormat(kind="json_schema",
                            schema={"type": "object"}, strict=True)
        raises(ErrorCode.INVALID_REQUEST, hybrid.validate,
               _request(response_format=rf), profile)

    def test_validate_refuses_forced_tool(self):
        hybrid, _dep, profile = self._hybrid()
        raises(ErrorCode.INVALID_REQUEST, hybrid.validate,
               _request(tool_choice=NamedToolChoice(name="x")), profile)

    def test_requires_load_delegates(self):
        hybrid, _dep, profile = self._hybrid(
            delegate=_FakeDelegate(requires_load=True))
        self.assertTrue(hybrid.requires_load(profile))

    def test_readiness_reports_delegate(self):
        hybrid, _dep, profile = self._hybrid(
            delegate=_FakeDelegate(ready=False))
        self.assertFalse(hybrid.has_ready_artifact)
        self.assertIs(hybrid.artifact_ready(profile), False)


if __name__ == "__main__":
    unittest.main()
