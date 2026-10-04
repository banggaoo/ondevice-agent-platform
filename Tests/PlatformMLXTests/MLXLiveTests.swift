import XCTest
import PlatformTestSupport
@testable import PlatformMLX
@testable import PlatformCore

/// Live qualification of the open-weight route: real pull, real load, real
/// completion through the shared admission path. Runs only when
/// OAP_LIVE_MLX=1 is set - the artifact is large and the network is real.
final class MLXLiveTests: XCTestCase {

    private let source = ModelSource(repo: "mlx-community/Qwen3-0.6B-4bit",
                                     revision: "main")

    private func live() throws -> Bool {
        ProcessInfo.processInfo.environment["OAP_LIVE_MLX"] == "1"
    }

    /// Pull -> validate -> load -> single completion through submitLLM.
    /// Proves the route end-to-end; latency/memory numbers are recorded in
    /// docs/development.md, not asserted here.
    func testLivePullAndComplete() async throws {
        try XCTSkipUnless(live(), "set OAP_LIVE_MLX=1 to run the live model test")
        let stack = try await makeStack()
        let store = ModelStore(root: stack.root)

        if !store.isReady(source: source) {
            _ = try await store.pull(source: source)
        }
        XCTAssertTrue(store.isReady(source: source))

        let provider = MLXProvider(store: store)
        XCTAssertTrue(provider.hasReadyArtifact)
        let profile = ModelProfile(alias: "qwen-small",
                                   providerID: MLXProviderContract.id,
                                   kind: .llm, task: "chat",
                                   source: source)
        await stack.supervisor.registerModel(profile, provider: provider)
        await registerStandardPrincipals(stack.supervisor)

        let result = try await stack.supervisor.submitLLM(
            principal: modelPrincipal,
            request: ChatRequest(model: "qwen-small",
                                 messages: [
                                    ChatMessage(role: .system, parts: ["Reply with one word."]),
                                    ChatMessage(role: .user, parts: ["What is 2+2?"]),
                                 ],
                                 maxOutputTokens: 32))
        XCTAssertEqual(result.modelIdentity, MLXProviderContract.id)
        XCTAssertFalse(result.content.trimmingCharacters(in: .whitespaces).isEmpty)
        XCTAssertNotNil(result.usage)
        XCTAssertGreaterThan(result.usage?.promptTokens ?? 0, 0)
        XCTAssertGreaterThan(result.usage?.completionTokens ?? 0, 0)
    }

    /// Cancellation through the real seam: submit -> locate the live job ->
    /// cancelJob -> the provider's in-flight task is cancelled and the
    /// awaiting caller sees a thrown cancellation. Asserts it completes
    /// faster than generating the full 512-token response would take.
    func testLiveCancelStopsGeneration() async throws {
        try XCTSkipUnless(live(), "set OAP_LIVE_MLX=1 to run the live model test")
        let stack = try await makeStack()
        let store = ModelStore(root: stack.root)
        if !store.isReady(source: source) {
            _ = try await store.pull(source: source)
        }
        let provider = MLXProvider(store: store)
        let profile = ModelProfile(alias: "qwen-small",
                                   providerID: MLXProviderContract.id,
                                   kind: .llm, task: "chat", source: source)
        await stack.supervisor.registerModel(profile, provider: provider)
        await registerStandardPrincipals(stack.supervisor)

        let request = ChatRequest(model: "qwen-small",
                                  messages: [ChatMessage(
                                     role: .user,
                                     parts: ["Count slowly from 1 to 500, one number per line."])],
                                  maxOutputTokens: 512)
        let started = Date()
        let task = Task {
            try await stack.supervisor.submitLLM(principal: modelPrincipal,
                                                 request: request)
        }
        // Wait for the job to exist, then cancel it through the supervisor.
        var jobID: String?
        for _ in 0..<200 {
            let jobs = (try? await stack.supervisor.listJobs()) ?? []
            if let running = jobs.first(where: { $0.kind == .llm && !$0.isTerminal }) {
                jobID = running.id
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let jobID else {
            XCTFail("job never registered")
            task.cancel()
            return
        }
        try await stack.supervisor.cancelJob(principal: modelPrincipal, jobID: jobID)
        let outcome = await task.result
        XCTAssertThrowsError(try outcome.get()) { error in
            guard let e = error as? PlatformError else {
                return XCTFail("expected PlatformError, got \(error)")
            }
            XCTAssertEqual(e.code, .cancelled)
        }
        // Generating all 512 tokens takes many seconds; a cancelled job must
        // finish fast.
        XCTAssertLessThan(Date().timeIntervalSince(started), 60)
    }

    /// Vision route: real image input through the OpenAI contract shape into
    /// a pulled VLM. Uses OAP_LIVE_MLX_STORE to reuse an existing artifact;
    /// otherwise pulls Qwen3-VL-2B-Instruct-4bit (~1.8 GB).
    func testLiveVisionCompletion() async throws {
        try XCTSkipUnless(live(), "set OAP_LIVE_MLX=1 to run the live model test")
        let stack = try await makeStack()
        let store: ModelStore
        if let dir = ProcessInfo.processInfo.environment["OAP_LIVE_MLX_STORE"] {
            store = ModelStore(modelsDir: URL(fileURLWithPath: dir))
        } else {
            store = ModelStore(root: stack.root)
        }
        let source = ModelSource(repo: "mlx-community/Qwen3-VL-2B-Instruct-4bit",
                                 revision: "main")
        if !store.isReady(source: source) {
            _ = try await store.pull(source: source)
        }
        let provider = MLXProvider(store: store)
        let profile = ModelProfile(alias: "qwen-vl",
                                   providerID: MLXProviderContract.id,
                                   kind: .llm, task: "chat",
                                   capabilities: ["vision"], source: source)
        await stack.supervisor.registerModel(profile, provider: provider)
        await registerStandardPrincipals(stack.supervisor)

        // 64x48 solid red PNG, generated at test time - no bundled artifact.
        let png = Self.solidRedPNG()
        let request = ChatRequest(
            model: "qwen-vl",
            messages: [ChatMessage(
                role: .user,
                parts: ["What single solid color fills this image? One word."],
                images: [ChatImage(data: png, mediaType: "image/png")])],
            maxOutputTokens: 16)
        let result = try await stack.supervisor.submitLLM(
            principal: modelPrincipal, request: request)
        XCTAssertFalse(result.content.trimmingCharacters(in: .whitespaces).isEmpty)
        XCTAssertNotNil(result.usage)
        // The image is a solid red field; a working VLM says "red".
        XCTAssertTrue(result.content.lowercased().contains("red"),
                      "unexpected vision answer: \(result.content)")
    }

    /// Minimal 64x48 solid-red PNG built inline (zlib stored blocks - no
    /// compression, so no external codec is needed in the test).
    static func solidRedPNG() -> Data {
        func chunk(_ type: String, _ data: Data) -> Data {
            var out = Data()
            out.append(contentsOf: UInt32(data.count).bigEndianBytes)
            out.append(type.data(using: .ascii)!)
            out.append(data)
            var crc: UInt32 = 0xFFFF_FFFF
            for b in type.data(using: .ascii)! + data {
                crc ^= UInt32(b)
                for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
            }
            out.append(contentsOf: (crc ^ 0xFFFF_FFFF).bigEndianBytes)
            return out
        }
        var raw = Data()
        for _ in 0..<48 {
            raw.append(0) // scanline filter: none
            for _ in 0..<64 { raw.append(contentsOf: [200, 30, 30]) }
        }
        // zlib stream: 0x78 0x01 header + one stored block + adler32.
        var z = Data([0x78, 0x01])
        z.append(0x01) // final stored block
        z.append(contentsOf: UInt16(raw.count).littleEndianBytes)
        z.append(contentsOf: (~UInt16(raw.count)).littleEndianBytes)
        z.append(raw)
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in raw { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        z.append(contentsOf: (b << 16 | a).bigEndianBytes)

        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data()
        ihdr.append(contentsOf: UInt32(64).bigEndianBytes)
        ihdr.append(contentsOf: UInt32(48).bigEndianBytes)
        ihdr.append(contentsOf: [8, 2, 0, 0, 0])
        png.append(chunk("IHDR", ihdr))
        png.append(chunk("IDAT", z))
        png.append(chunk("IEND", Data()))
        return png
    }

    /// Cached-artifact functional check for the model-verification
    /// request: frozen alias/source pairs, deterministic injected
    /// resources, shared supervisor admission, real provider. Requires
    /// OAP_LIVE_MLX=1 and OAP_LIVE_MLX_STORE pointing at an already-pulled
    /// models dir; it never downloads and skips truthfully on a missing
    /// artifact. Asserts real generation and usage accounting only - a
    /// capped thinking response is valid output, not a quality pass.
    /// Sequential requests respect the single inference slot.
    func testLiveCachedTextCompletions() async throws {
        try XCTSkipUnless(live(), "set OAP_LIVE_MLX=1 to run the live model test")
        guard let dir = ProcessInfo.processInfo.environment["OAP_LIVE_MLX_STORE"] else {
            throw XCTSkip("set OAP_LIVE_MLX_STORE to a pulled models dir")
        }
        let store = ModelStore(modelsDir: URL(fileURLWithPath: dir))
        let provider = MLXProvider(store: store)
        let routes: [(alias: String, source: ModelSource)] = [
            ("qwen3.8-9b", .init(repo: "nvythong/Qwen3.8-9B-Distill-mlx-4Bit",
                                 revision: "e827c31fbd588828f43180a87ab34415a6d8a4bf")),
        ]
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        await registerStandardPrincipals(stack.supervisor)
        for (alias, source) in routes {
            guard store.isReady(source: source) else {
                throw XCTSkip("artifact not pulled: \(source.repo)@\(source.revision)")
            }
            let profile = ModelProfile(alias: alias, providerID: MLXProviderContract.id,
                                       kind: .llm, task: "chat", source: source)
            await stack.supervisor.registerModel(profile, provider: provider)
            let result = try await stack.supervisor.submitLLM(
                principal: modelPrincipal,
                request: ChatRequest(
                    model: alias,
                    messages: [ChatMessage(role: .user,
                                           parts: ["Say hello in a short sentence."])],
                    maxOutputTokens: 64, temperature: 0))
            XCTAssertEqual(result.modelIdentity, MLXProviderContract.id)
            XCTAssertFalse(result.content.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertNotNil(result.usage)
            XCTAssertGreaterThan(result.usage?.promptTokens ?? 0, 0)
            XCTAssertGreaterThan(result.usage?.completionTokens ?? 0, 0)
        }
    }

    /// D41 first paired measurement: identical fixed prompts across the
    /// Apple provider and pulled MLX routes, direct provider calls (no
    /// admission - measures the model, not the gate). Prints one JSON line
    /// per (prompt, route) for recording in docs. Not a benchmark: three
    /// prompts, single run, one warm host at thermal fair.
    func testLivePairedMeasurement() async throws {
        try XCTSkipUnless(live(), "set OAP_LIVE_MLX=1 to run the live model test")
        guard let dir = ProcessInfo.processInfo.environment["OAP_LIVE_MLX_STORE"] else {
            throw XCTSkip("set OAP_LIVE_MLX_STORE to a pulled models dir")
        }
        let store = ModelStore(modelsDir: URL(fileURLWithPath: dir))
        let mlx = MLXProvider(store: store)

        let routes: [(alias: String, source: ModelSource)] = [
            ("qwen3.8-9b", .init(repo: "nvythong/Qwen3.8-9B-Distill-mlx-4Bit",
                                 revision: "e827c31fbd588828f43180a87ab34415a6d8a4bf")),
        ]
        let prompts: [(id: String, text: String)] = [
            ("math", "Compute 17*23+19. Show your reasoning, then give the final answer."),
            ("code", "Write a Swift function `isPalindrome(_ s: String) -> Bool` ignoring case and non-letters. Code only."),
            ("instruction", "List exactly three colors, one per line, no numbering or extra words."),
        ]
        let maxTokens = 256

        var lines: [String] = []
        // Apple route (skipped truthfully if unavailable).
        let apple = AppleFoundationProvider()
        let appleProfile = ModelProfile(alias: "apple-foundation-model",
                                        providerID: AppleFoundationProvider.id,
                                        kind: .llm, task: "chat", maxOutputTokens: maxTokens)
        for p in prompts {
            let req = ChatRequest(model: appleProfile.alias, messages: [
                ChatMessage(role: .user, parts: [p.text])], maxOutputTokens: maxTokens,
                                  temperature: 0)
            let t0 = Date()
            do {
                let r = try await apple.complete(req, profile: appleProfile)
                lines.append(Self.line(route: "apple-fm", prompt: p.id,
                                       seconds: Date().timeIntervalSince(t0),
                                       usage: r.usage, content: r.content))
            } catch {
                lines.append(Self.line(route: "apple-fm", prompt: p.id,
                                       seconds: Date().timeIntervalSince(t0),
                                       usage: nil, content: "ERROR: \(error)"))
            }
        }
        for (alias, source) in routes where store.isReady(source: source) {
            let profile = ModelProfile(alias: alias, providerID: MLXProviderContract.id,
                                       kind: .llm, task: "chat", source: source)
            for p in prompts {
                let req = ChatRequest(model: alias, messages: [
                    ChatMessage(role: .user, parts: [p.text])], maxOutputTokens: maxTokens,
                                      temperature: 0)
                let t0 = Date()
                do {
                    let r = try await mlx.complete(req, profile: profile)
                    lines.append(Self.line(route: alias, prompt: p.id,
                                           seconds: Date().timeIntervalSince(t0),
                                           usage: r.usage, content: r.content))
                } catch {
                    lines.append(Self.line(route: alias, prompt: p.id,
                                           seconds: Date().timeIntervalSince(t0),
                                           usage: nil, content: "ERROR: \(error)"))
                }
            }
        }
        for line in lines { print("MEASURE \(line)") }
        XCTAssertFalse(lines.isEmpty, "no route was measurable")
    }

    private static func line(route: String, prompt: String, seconds: Double,
                             usage: ChatUsage?, content: String) -> String {
        let escaped = content.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .prefix(400)
        return """
        {"route":"\(route)","prompt":"\(prompt)","seconds":\(String(format: "%.2f", seconds)),"promptTokens":\(usage?.promptTokens ?? -1),"completionTokens":\(usage?.completionTokens ?? -1),"content":"\(escaped)"}
        """
    }
}

private extension FixedWidthInteger {
    var bigEndianBytes: [UInt8] {
        withUnsafeBytes(of: bigEndian) { Array($0) }
    }
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian) { Array($0) }
    }
}
