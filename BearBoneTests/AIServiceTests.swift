import Foundation
import Testing

// =============================================================================
// These tests verify the streaming patterns used in the AI pipeline.
// They are self-contained (no extension imports) to avoid duplicate symbol
// issues when the AU extension is loaded in-process during testing.
// =============================================================================

// MARK: - Mock URLProtocol for HTTP testing

/// URLProtocol subclass that returns pre-configured SSE response data.
final class MockSSEProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseData: Data = Data()
    nonisolated(unsafe) static var statusCode: Int = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockSSEProtocol.self]
    return URLSession(configuration: config)
}

// MARK: - Copied parsing logic (from AnthropicProvider) for standalone testing

/// Extracts text from an Anthropic content_block_delta JSON event.
/// This mirrors `AnthropicProvider.parseContentBlockDelta(_:)`.
private func parseContentBlockDelta(_ json: String) -> String? {
    guard let data = json.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let delta = obj["delta"] as? [String: Any],
        let text = delta["text"] as? String
    else { return nil }
    return text
}

// MARK: - SSE Parsing Logic (mirrors SSEParser) for standalone testing

private struct TestSSEEvent {
    let type: String?
    let data: String
}

/// Core SSE parsing logic that processes an array of lines.
/// This avoids URLSession.AsyncBytes dependencies entirely,
/// making the parsing logic testable in isolation.
private func processSSELines(_ lines: [String]) -> [TestSSEEvent] {
    var events: [TestSSEEvent] = []
    var currentType: String?
    var dataLines: [String] = []

    for line in lines {
        if line.isEmpty {
            if !dataLines.isEmpty {
                events.append(TestSSEEvent(
                    type: currentType,
                    data: dataLines.joined(separator: "\n")
                ))
            }
            currentType = nil
            dataLines = []
        } else if line.hasPrefix("event:") {
            currentType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            let value = String(line.dropFirst(5))
            if value.hasPrefix(" ") {
                dataLines.append(String(value.dropFirst()))
            } else {
                dataLines.append(value)
            }
        }
    }

    // Flush remaining
    if !dataLines.isEmpty {
        events.append(TestSSEEvent(type: currentType, data: dataLines.joined(separator: "\n")))
    }

    return events
}

/// Async version that wraps parsing in an AsyncThrowingStream (mirrors production pattern).
private func parseSSEEventsAsync(_ lines: [String]) -> AsyncThrowingStream<TestSSEEvent, Error> {
    AsyncThrowingStream { continuation in
        Task.detached {
            var currentType: String?
            var dataLines: [String] = []

            for line in lines {
                if Task.isCancelled { break }

                if line.isEmpty {
                    if !dataLines.isEmpty {
                        continuation.yield(TestSSEEvent(
                            type: currentType,
                            data: dataLines.joined(separator: "\n")
                        ))
                    }
                    currentType = nil
                    dataLines = []
                } else if line.hasPrefix("event:") {
                    currentType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    let value = String(line.dropFirst(5))
                    if value.hasPrefix(" ") {
                        dataLines.append(String(value.dropFirst()))
                    } else {
                        dataLines.append(value)
                    }
                }
            }

            if !dataLines.isEmpty {
                continuation.yield(TestSSEEvent(type: currentType, data: dataLines.joined(separator: "\n")))
            }
            continuation.finish()
        }
    }
}

/// Parse SSE events from URLSession.AsyncBytes (for integration tests).
/// Iterates raw bytes to preserve empty lines (bytes.lines drops them).
private func parseSSEEventsFromBytes(_ bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<TestSSEEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task.detached {
            var currentType: String?
            var dataLines: [String] = []
            var lineBuffer = Data()

            do {
                for try await byte in bytes {
                    if Task.isCancelled { break }

                    if byte == UInt8(ascii: "\n") {
                        if lineBuffer.last == UInt8(ascii: "\r") {
                            lineBuffer.removeLast()
                        }
                        let line = String(data: lineBuffer, encoding: .utf8) ?? ""
                        lineBuffer.removeAll(keepingCapacity: true)

                        if line.isEmpty {
                            if !dataLines.isEmpty {
                                continuation.yield(TestSSEEvent(
                                    type: currentType,
                                    data: dataLines.joined(separator: "\n")
                                ))
                            }
                            currentType = nil
                            dataLines = []
                        } else if line.hasPrefix("event:") {
                            currentType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let value = String(line.dropFirst(5))
                            if value.hasPrefix(" ") {
                                dataLines.append(String(value.dropFirst()))
                            } else {
                                dataLines.append(value)
                            }
                        }
                    } else {
                        lineBuffer.append(byte)
                    }
                }

                if !dataLines.isEmpty {
                    continuation.yield(TestSSEEvent(type: currentType, data: dataLines.joined(separator: "\n")))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { _ in
            task.cancel()
        }
    }
}

// MARK: - AsyncThrowingStream Pattern Tests

@Suite("AsyncThrowingStream Patterns")
struct AsyncStreamPatternTests {

    @Test func taskDetachedYieldsChunks() async throws {
        // Test: Task.detached inside AsyncThrowingStream build closure
        // yields values that the consumer can receive.
        // This is the core pattern used by SSEParser and AnthropicProvider.
        let stream = AsyncThrowingStream<String, Error> { continuation in
            Task.detached {
                for chunk in ["hello", " ", "world"] {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }

        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }

        #expect(chunks == ["hello", " ", "world"], "Task.detached should yield all chunks")
    }

    @Test func taskDetachedWithDelayYieldsChunks() async throws {
        // Test with a small delay between chunks to simulate streaming
        let stream = AsyncThrowingStream<String, Error> { continuation in
            Task.detached {
                for chunk in ["A", "B", "C"] {
                    try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }

        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }

        #expect(chunks == ["A", "B", "C"])
    }

    @Test func nestedAsyncThrowingStreamsWork() async throws {
        // Test: Nested AsyncThrowingStream (producer stream consumed by another
        // producer that yields to a consumer). This mirrors the SSEParser → AnthropicProvider → AIService chain.
        let innerStream = AsyncThrowingStream<Int, Error> { continuation in
            Task.detached {
                for i in 1...3 {
                    continuation.yield(i)
                }
                continuation.finish()
            }
        }

        let outerStream = AsyncThrowingStream<String, Error> { continuation in
            Task.detached {
                for try await value in innerStream {
                    continuation.yield("item_\(value)")
                }
                continuation.finish()
            }
        }

        var results: [String] = []
        for try await item in outerStream {
            results.append(item)
        }

        #expect(results == ["item_1", "item_2", "item_3"], "Nested streams should pass values through")
    }

    @Test @MainActor func mainActorTaskConsumesDetachedProducer() async throws {
        // Test: A Task on @MainActor consuming from a stream produced by Task.detached.
        // This mirrors AIService (MainActor) consuming AnthropicProvider (detached).
        let stream = AsyncThrowingStream<String, Error> { continuation in
            Task.detached {
                for chunk in ["def ", "process()", ":\n  pass"] {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }

        var accumulated = ""
        var updates: [String] = []

        // Consume on MainActor, accumulate, and call update closure
        let task = Task { @MainActor in
            for try await chunk in stream {
                accumulated += chunk
                let current = accumulated
                updates.append(current)
            }
        }

        // Wait for task completion
        _ = await task.result

        #expect(updates == ["def ", "def process()", "def process():\n  pass"],
                "MainActor consumer should receive all chunks progressively, got: \(updates)")
        #expect(accumulated == "def process():\n  pass")
    }

    @Test @MainActor func mainActorRunInsideMainActorTask() async throws {
        // Test: await MainActor.run { } called from a Task that already runs on MainActor.
        // This is what AIService.generate() does: the Task inherits @MainActor,
        // and inside it calls await MainActor.run { onUpdate(accumulated) }.
        let stream = AsyncThrowingStream<String, Error> { continuation in
            Task.detached {
                for chunk in ["A", "B", "C"] {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }

        var updates: [String] = []
        var accumulated = ""

        // This simulates the exact pattern in AIService.generate():
        // - Task inherits MainActor
        // - for try await chunk in stream
        // - await MainActor.run { onUpdate(accumulated) }
        let onUpdate: @Sendable (String) -> Void = { text in
            updates.append(text)
        }

        let task = Task { @MainActor in
            for try await chunk in stream {
                accumulated += chunk
                await MainActor.run { onUpdate(accumulated) }
            }
        }

        _ = await task.result

        #expect(updates == ["A", "AB", "ABC"],
                "MainActor.run inside MainActor Task should deliver updates, got: \(updates)")
    }
}

// MARK: - Content Block Delta Parsing Tests

@Suite("Anthropic JSON Parsing")
struct AnthropicParsingTests {

    @Test func parsesContentBlockDelta() {
        let json = """
            {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello world"}}
            """
        let result = parseContentBlockDelta(json)
        #expect(result == "hello world")
    }

    @Test func parsesEscapedCharacters() {
        let json = """
            {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"line1\\nline2"}}
            """
        let result = parseContentBlockDelta(json)
        #expect(result == "line1\nline2")
    }

    @Test func returnsNilForMalformedJSON() {
        #expect(parseContentBlockDelta("not json") == nil)
    }

    @Test func returnsNilForMissingDelta() {
        let json = #"{"type":"content_block_delta","index":0}"#
        #expect(parseContentBlockDelta(json) == nil)
    }

    @Test func returnsNilForMissingText() {
        let json = #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta"}}"#
        #expect(parseContentBlockDelta(json) == nil)
    }

    @Test func parsesEmptyText() {
        let json = #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":""}}"#
        #expect(parseContentBlockDelta(json) == "")
    }
}

// MARK: - SSE Parser Tests (synchronous, no URLSession dependency)

@Suite("SSE Parser")
struct SSEParserTests {

    @Test func parsesSimpleEvents() {
        let lines = [
            "event: message_start",
            "data: {\"type\":\"message_start\"}",
            "",
            "event: content_block_delta",
            "data: {\"delta\":{\"text\":\"hello\"}}",
            "",
            "event: message_stop",
            "data: {\"type\":\"message_stop\"}",
            "",
        ]

        let events = processSSELines(lines)
        #expect(events.count == 3, "Should parse 3 events, got \(events.count)")
        if events.count >= 3 {
            #expect(events[0].type == "message_start")
            #expect(events[1].type == "content_block_delta")
            #expect(events[1].data == "{\"delta\":{\"text\":\"hello\"}}")
            #expect(events[2].type == "message_stop")
        }
    }

    @Test func handlesMultipleDataLines() {
        let lines = [
            "event: multi",
            "data: line1",
            "data: line2",
            "",
        ]
        let events = processSSELines(lines)
        #expect(events.count == 1)
        #expect(events.first?.data == "line1\nline2")
    }

    @Test func skipsEventsWithNoData() {
        let lines = [
            "event: empty",
            "",
            "event: hasdata",
            "data: value",
            "",
        ]
        let events = processSSELines(lines)
        #expect(events.count == 1, "Should only yield events with data, got \(events.count)")
        #expect(events.first?.type == "hasdata")
    }

    @Test func stripsLeadingSpaceFromDataValue() {
        let lines = [
            "event: test",
            "data: hello",
            "",
        ]
        let events = processSSELines(lines)
        #expect(events.first?.data == "hello", "Should strip single leading space per SSE spec")
    }

    @Test func flushesUnterminatedEvent() {
        // Event at end without trailing empty line
        let lines = [
            "event: test",
            "data: value",
        ]
        let events = processSSELines(lines)
        #expect(events.count == 1, "Should flush unterminated event at end of stream")
        #expect(events.first?.data == "value")
    }

    @Test func ignoresComments() {
        let lines = [
            ": this is a comment",
            "event: test",
            "data: value",
            "",
        ]
        let events = processSSELines(lines)
        #expect(events.count == 1)
        #expect(events.first?.data == "value")
    }
}

// MARK: - SSE Parser Async Tests (verifies AsyncThrowingStream wrapper)

@Suite("SSE Parser Async")
struct SSEParserAsyncTests {

    @Test func yieldsAllEventsViaAsyncStream() async throws {
        let lines = [
            "event: message_start",
            "data: {\"type\":\"message_start\"}",
            "",
            "event: content_block_delta",
            "data: {\"delta\":{\"text\":\"hello\"}}",
            "",
            "event: message_stop",
            "data: {\"type\":\"message_stop\"}",
            "",
        ]

        var events: [TestSSEEvent] = []
        for try await event in parseSSEEventsAsync(lines) {
            events.append(event)
        }

        #expect(events.count == 3, "Async stream should yield all 3 events, got \(events.count)")
        if events.count >= 3 {
            #expect(events[0].type == "message_start")
            #expect(events[1].type == "content_block_delta")
            #expect(events[2].type == "message_stop")
        }
    }
}

// MARK: - URLSession.AsyncBytes Integration Tests

@Suite("URLSession AsyncBytes Integration", .serialized)
struct URLSessionBytesTests {

    @Test func sseParsingThroughURLSessionCRLF() async throws {
        // Integration test: SSE parsing through MockSSEProtocol with \r\n endings
        let sseText = "event: message_start\r\ndata: {\"type\":\"message_start\"}\r\n\r\nevent: content_block_delta\r\ndata: {\"delta\":{\"text\":\"hello\"}}\r\n\r\nevent: message_stop\r\ndata: {\"type\":\"message_stop\"}\r\n\r\n"

        MockSSEProtocol.responseData = Data(sseText.utf8)
        MockSSEProtocol.statusCode = 200

        let session = makeMockSession()
        let (bytes, _) = try await session.bytes(for: URLRequest(url: URL(string: "https://mock.test/crlf")!))

        var events: [TestSSEEvent] = []
        for try await event in parseSSEEventsFromBytes(bytes) {
            events.append(event)
        }

        #expect(events.count == 3, "Should parse 3 events with \\r\\n endings, got \(events.count)")
        if events.count >= 3 {
            #expect(events[0].type == "message_start")
            #expect(events[1].type == "content_block_delta")
            #expect(events[2].type == "message_stop")
        }
    }

    @Test func sseParsingThroughURLSessionLF() async throws {
        // Integration test: SSE parsing through MockSSEProtocol with \n endings
        let sseText = "event: message_start\ndata: {\"type\":\"message_start\"}\n\nevent: content_block_delta\ndata: {\"delta\":{\"text\":\"hello\"}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"

        MockSSEProtocol.responseData = Data(sseText.utf8)
        MockSSEProtocol.statusCode = 200

        let session = makeMockSession()
        let (bytes, _) = try await session.bytes(for: URLRequest(url: URL(string: "https://mock.test/lf")!))

        var events: [TestSSEEvent] = []
        for try await event in parseSSEEventsFromBytes(bytes) {
            events.append(event)
        }

        #expect(events.count == 3, "Should parse 3 events with \\n endings, got \(events.count)")
        if events.count >= 3 {
            #expect(events[0].type == "message_start")
            #expect(events[1].type == "content_block_delta")
            #expect(events[2].type == "message_stop")
        }
    }

    @Test func fullPipelineThroughURLSession() async throws {
        // Full pipeline: URLSession → SSE parsing → text extraction → accumulation
        let sseText = [
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"def "}}"#,
            "",
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"process"}}"#,
            "",
            "event: message_stop",
            #"data: {"type":"message_stop"}"#,
            "",
        ].joined(separator: "\n")

        MockSSEProtocol.responseData = Data(sseText.utf8)
        MockSSEProtocol.statusCode = 200

        let session = makeMockSession()
        let (bytes, _) = try await session.bytes(for: URLRequest(url: URL(string: "https://mock.test/pipeline")!))

        var textChunks: [String] = []
        for try await event in parseSSEEventsFromBytes(bytes) {
            guard let eventType = event.type else { continue }
            if eventType == "content_block_delta" {
                if let text = parseContentBlockDelta(event.data) {
                    textChunks.append(text)
                }
            }
        }

        #expect(textChunks == ["def ", "process"], "Should extract text chunks, got: \(textChunks)")
        #expect(textChunks.joined() == "def process")
    }
}

// MARK: - Language-Aware System Prompt Tests

/// Copies of the AnthropicProvider system prompts for standalone testing.
/// These mirror the production prompts to verify language-specific content.
private enum TestSystemPrompts {
    static let pythonApiContract = """
        API contract:
        - Function signature: def process(inputs, outputs, frame_count, sample_rate, params)
        - inputs: list of numpy.float32 arrays (one per channel), pre-allocated to max_frames length
        - outputs: list of numpy.float32 arrays (one per channel), pre-allocated to max_frames length
        - frame_count: number of valid samples this callback (may be less than array length)
        - sample_rate: current sample rate (e.g. 44100.0)
        - params: dict of parameter values keyed by name (if PARAMS is declared), \
          or list of floats 0–1 (legacy). Use these to make your effect controllable from the DAW.
        - Write processed audio into outputs[ch][:frame_count]
        - Only numpy is available (imported as np)
        - Global variables persist across callbacks (useful for phase accumulators, delay buffers, etc.)
        - Must handle both mono (1 channel) and stereo (2 channels)

        Parameters — declare a PARAMS dict at module level to define named parameters with metadata:
        PARAMS = {
            "rate":  {"min": 0.5, "max": 20.0, "unit": "Hz", "default": 5.0},
            "depth": {"min": 0.0, "max": 1.0,  "unit": "",   "default": 0.5},
        }
        - Each entry maps a lowercase snake_case name to min, max, unit, and default.
        - params is a dict with these names as keys and actual (denormalized) values: \
          rate_hz = params["rate"]  # already 0.5–20.0 Hz, no manual mapping needed
        - The DAW/UI shows sliders with real ranges and formatted values (e.g. "5.2 Hz", "-21.5 dB").
        - Common units: "dB", "Hz", "ms", "%", ":1", "" (dimensionless).
        - Up to 16 parameters can be declared.
        - ALWAYS use PARAMS when your effect has controllable parameters.
        - Dict key order determines AU parameter address (first = 0, second = 1, etc.).
        """

    static let rustApiContract = """
        API contract (Rust compiled to WebAssembly):
        - The script is compiled to wasm32-wasip1 and runs in a WASM sandbox
        - Must define four #[no_mangle] pub extern "C" functions:
          1. get_input_ptr() -> i32  — returns pointer to the input buffer
          2. get_output_ptr() -> i32 — returns pointer to the output buffer
          3. get_params_ptr() -> i32 — returns pointer to the params buffer (up to 16 × f32)
          4. process(input: *const f32, output: *mut f32, channels: i32, frame_count: i32, sample_rate: f32)
        - Static buffers: define MAX_CH (2) and MAX_FR (4096) constants, then:
          static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
          static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
          static mut PARAMS_BUF: [f32; 16] = [0.0; 16];
        - Audio is interleaved: total samples = channels * frame_count
        - Use std::slice::from_raw_parts(input, n) and from_raw_parts_mut(output, n) inside unsafe blocks
        - Must handle both mono (1 channel) and stereo (2 channels)
        - For stereo, samples are interleaved: [L0, R0, L1, R1, ...]

        Rich parameters (recommended) — declare metadata so the host denormalizes values for you:
        - Export get_param_metadata_ptr() and get_param_metadata_len() pointing to a static JSON string:
          static METADATA: &str = r#"[
              {"name":"Rate","min":0.5,"max":20.0,"unit":"Hz","default":5.0},
              {"name":"Depth","min":0.0,"max":1.0,"unit":"","default":0.5}
          ]"#;
          #[no_mangle]
          pub extern "C" fn get_param_metadata_ptr() -> i32 {
              METADATA.as_ptr() as i32
          }
          #[no_mangle]
          pub extern "C" fn get_param_metadata_len() -> i32 {
              METADATA.len() as i32
          }
        - With metadata, PARAMS_BUF receives actual denormalized values (not 0–1):
          let rate_hz = unsafe { PARAMS_BUF[0] }; // already 0.5–20.0 Hz, no mapping needed
        - Add "curve":"log" for frequency and time params (exponential slider distribution):
          {"name":"Cutoff","min":20.0,"max":20000.0,"unit":"Hz","default":1000.0,"curve":"log"}
          Default curve is "linear". Use "log" when the range spans orders of magnitude.
        - The DAW/UI shows sliders with real ranges and formatted values (e.g. "5.2 Hz", "-21.5 dB").
        - Common units: "dB", "Hz", "ms", "%", ":1", "" (dimensionless).
        - Up to 16 parameters. JSON array order determines parameter index (first = 0, second = 1, etc.).
        - ALWAYS use rich parameters when your effect has controllable params.
        """

    static let pythonSystemPrompt = """
        You are a DSP script generator for a real-time audio plugin. Generate Python scripts \
        that define a `process()` function.
        """

    static let rustSystemPrompt = """
        You are a DSP script generator for a real-time audio plugin compiled to WebAssembly. \
        Generate Rust scripts that define a `process()` function and static buffers.
        """

    /// Selects the appropriate system prompt based on language.
    /// This mirrors the dispatch logic in AnthropicProvider.generateScript().
    static func systemPrompt(for language: ScriptLanguage) -> String {
        switch language {
        case .python: return pythonSystemPrompt + "\n" + pythonApiContract
        case .rust: return rustSystemPrompt + "\n" + rustApiContract
        }
    }
}

@Suite("Language-Aware System Prompts")
struct LanguagePromptTests {

    @Test func pythonPromptContainsPythonKeywords() {
        let prompt = TestSystemPrompts.systemPrompt(for: .python)
        #expect(prompt.contains("def process"))
        #expect(prompt.contains("numpy"))
        #expect(prompt.contains("Python"))
    }

    @Test func pythonPromptDoesNotContainRustKeywords() {
        let prompt = TestSystemPrompts.systemPrompt(for: .python)
        #expect(!prompt.contains("wasm32"))
        #expect(!prompt.contains("#[no_mangle]"))
        #expect(!prompt.contains("*const f32"))
    }

    @Test func rustPromptContainsRustKeywords() {
        let prompt = TestSystemPrompts.systemPrompt(for: .rust)
        #expect(prompt.contains("Rust"))
        #expect(prompt.contains("wasm32"))
        #expect(prompt.contains("#[no_mangle]"))
        #expect(prompt.contains("*const f32"))
        #expect(prompt.contains("get_input_ptr"))
        #expect(prompt.contains("get_output_ptr"))
        #expect(prompt.contains("WebAssembly"))
    }

    @Test func rustPromptDoesNotContainPythonKeywords() {
        let prompt = TestSystemPrompts.systemPrompt(for: .rust)
        #expect(!prompt.contains("numpy"))
        #expect(!prompt.contains("def process"))
    }

    @Test func languageDispatchSelectsCorrectPrompt() {
        let pythonPrompt = TestSystemPrompts.systemPrompt(for: .python)
        let rustPrompt = TestSystemPrompts.systemPrompt(for: .rust)
        #expect(pythonPrompt != rustPrompt, "Python and Rust prompts should be different")
        #expect(pythonPrompt.contains("Python"))
        #expect(rustPrompt.contains("Rust"))
    }

    @Test func rustApiContractDocumentsBufferLayout() {
        let contract = TestSystemPrompts.rustApiContract
        #expect(contract.contains("MAX_CH"))
        #expect(contract.contains("MAX_FR"))
        #expect(contract.contains("INPUT_BUF"))
        #expect(contract.contains("OUTPUT_BUF"))
        #expect(contract.contains("from_raw_parts"))
        #expect(contract.contains("interleaved"))
    }

    @Test func pythonApiContractDocumentsNumpyArrays() {
        let contract = TestSystemPrompts.pythonApiContract
        #expect(contract.contains("numpy.float32"))
        #expect(contract.contains("frame_count"))
        #expect(contract.contains("sample_rate"))
        #expect(contract.contains("outputs[ch][:frame_count]"))
    }

    @Test func pythonApiContractDocumentsParamNames() {
        let contract = TestSystemPrompts.pythonApiContract
        #expect(contract.contains("PARAMS"))
        #expect(contract.contains("\"rate\""))
    }

    @Test func rustApiContractDocumentsParamNames() {
        let contract = TestSystemPrompts.rustApiContract
        #expect(contract.contains("get_param_metadata_ptr"))
        #expect(contract.contains("PARAMS_BUF"))
    }
}

// MARK: - Source Param Name Parser Tests

/// Standalone copy of the unified parser logic for testing.
/// This mirrors BearBoneExtensionAudioUnit.parseParamNames(fromSource:).
private func parseParamNames(fromSource source: String) -> [Int: String]? {
    let paramCount = 8
    let lines = source.components(separatedBy: .newlines)

    guard let markerIndex = lines.firstIndex(where: { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.range(of: #"^(#|//)\s*Parameters:"#, options: .regularExpression) != nil
    }) else {
        return nil
    }

    let pythonPattern = try! NSRegularExpression(pattern: #"^\s*(\w+)\s*=\s*(\d+)\s*$"#)
    let rustPattern = try! NSRegularExpression(pattern: #"^\s*const\s+(\w+)\s*:\s*usize\s*=\s*(\d+)\s*;"#)
    var names: [Int: String] = [:]

    for i in (markerIndex + 1)..<lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }

        let range = NSRange(line.startIndex..., in: line)
        let match = pythonPattern.firstMatch(in: line, range: range)
            ?? rustPattern.firstMatch(in: line, range: range)

        guard let match,
              let nameRange = Range(match.range(at: 1), in: line),
              let addrRange = Range(match.range(at: 2), in: line),
              let addr = Int(line[addrRange]),
              addr >= 0, addr < paramCount else {
            break
        }

        let constName = String(line[nameRange])
        names[addr] = constName.replacingOccurrences(of: "_", with: " ")
    }

    return names.isEmpty ? nil : names
}

@Suite("Rust Param Name Parser")
// Also tests unified parseParamNames() with Rust syntax
struct RustParamNameParserTests {

    @Test func parsesValidParamBlock() {
        let source = """
        const MAX_CH: usize = 2;
        static mut PARAMS_BUF: [f32; 8] = [0.0; 8];

        // Parameters:
        const RATE: usize = 0;
        const DEPTH: usize = 1;

        #[no_mangle]
        pub extern "C" fn process() {}
        """
        let result = parseParamNames(fromSource: source)
        #expect(result == [0: "RATE", 1: "DEPTH"])
    }

    @Test func returnsNilWhenNoMarker() {
        let source = """
        const MAX_CH: usize = 2;
        const RATE: usize = 0;
        """
        let result = parseParamNames(fromSource: source)
        #expect(result == nil)
    }

    @Test func handlesExtraWhitespace() {
        let source = """
        //   Parameters:
          const  RATE : usize = 0 ;
        """
        let result = parseParamNames(fromSource: source)
        #expect(result == [0: "RATE"])
    }

    @Test func convertsScreamingSnakeToTitleCase() {
        let source = """
        // Parameters:
        const BIT_DEPTH: usize = 0;
        const RATE_HZ: usize = 1;
        const MIX: usize = 2;
        """
        let result = parseParamNames(fromSource: source)
        #expect(result == [0: "BIT DEPTH", 1: "RATE HZ", 2: "MIX"])
    }

    @Test func filtersKeysOutsideRange() {
        let source = """
        // Parameters:
        const RATE: usize = 0;
        const BAD: usize = 9;
        """
        let result = parseParamNames(fromSource: source)
        #expect(result == [0: "RATE"])
    }

    @Test func returnsNilForEmptyParamBlock() {
        let source = """
        // Parameters:

        #[no_mangle]
        """
        let result = parseParamNames(fromSource: source)
        #expect(result == nil)
    }

    @Test func skipsBlankLinesWithinBlock() {
        let source = """
        // Parameters:
        const RATE: usize = 0;

        const DEPTH: usize = 1;
        """
        let result = parseParamNames(fromSource: source)
        #expect(result == [0: "RATE", 1: "DEPTH"])
    }
}

@Suite("Python Param Name Parser")
struct PythonParamNameParserTests {

    @Test func parsesValidPythonParamBlock() {
        let source = """
        import numpy as np

        # Parameters:
        DRIVE = 0
        MIX = 1

        def process(inputs, outputs, frame_count, sample_rate, params):
            pass
        """
        let result = parseParamNames(fromSource: source)
        #expect(result == [0: "DRIVE", 1: "MIX"])
    }

    @Test func returnsNilWhenNoPythonMarker() {
        let source = """
        import numpy as np
        DRIVE = 0
        """
        let result = parseParamNames(fromSource: source)
        #expect(result == nil)
    }

    @Test func convertsPythonScreamingSnake() {
        let source = """
        # Parameters:
        BIT_DEPTH = 0
        RATE_HZ = 1
        """
        let result = parseParamNames(fromSource: source)
        #expect(result == [0: "BIT DEPTH", 1: "RATE HZ"])
    }

    @Test func stopsAtNonAssignmentLine() {
        let source = """
        # Parameters:
        RATE = 0

        def process():
            pass
        """
        let result = parseParamNames(fromSource: source)
        #expect(result == [0: "RATE"])
    }
}

// MARK: - Full Anthropic SSE → Text Extraction Pipeline Test

@Suite("Anthropic Streaming Pipeline")
struct AnthropicPipelineTests {

    /// Simulates the full AnthropicProvider pipeline:
    /// SSE lines → event parsing → content_block_delta extraction → text chunks
    @Test func extractsTextFromAnthropicSSEResponse() async throws {
        let lines = [
            "event: message_start",
            "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_test\"}}",
            "",
            "event: content_block_start",
            "data: {\"type\":\"content_block_start\",\"index\":0}",
            "",
            "event: ping",
            "data: {\"type\":\"ping\"}",
            "",
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"import numpy"}}"#,
            "",
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" as np"}}"#,
            "",
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\ndef process"}}"#,
            "",
            "event: content_block_stop",
            "data: {\"type\":\"content_block_stop\",\"index\":0}",
            "",
            "event: message_delta",
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}",
            "",
            "event: message_stop",
            "data: {\"type\":\"message_stop\"}",
            "",
        ]

        // Parse SSE events and extract text from content_block_delta events
        var textChunks: [String] = []
        for try await event in parseSSEEventsAsync(lines) {
            guard let eventType = event.type else { continue }

            switch eventType {
            case "content_block_delta":
                if let text = parseContentBlockDelta(event.data) {
                    textChunks.append(text)
                }
            case "message_stop":
                break
            default:
                break
            }
        }

        #expect(textChunks.count == 3, "Should extract 3 text chunks, got \(textChunks.count): \(textChunks)")

        let fullText = textChunks.joined()
        #expect(fullText == "import numpy as np\ndef process",
                "Full text should be 'import numpy as np\\ndef process', got: '\(fullText)'")
    }

    /// Tests the accumulation pattern used by AIService:
    /// each chunk is appended, and the full accumulated text is sent to onUpdate.
    @Test @MainActor func accumulatesTextLikeAIService() async throws {
        let lines = [
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"def "}}"#,
            "",
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"process"}}"#,
            "",
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"(): pass"}}"#,
            "",
            "event: message_stop",
            "data: {\"type\":\"message_stop\"}",
            "",
        ]

        // Outer stream: SSE → text chunks (like AnthropicProvider)
        let textStream = AsyncThrowingStream<String, Error> { continuation in
            Task.detached {
                do {
                    for try await event in parseSSEEventsAsync(lines) {
                        if Task.isCancelled { break }
                        guard let eventType = event.type else { continue }
                        switch eventType {
                        case "content_block_delta":
                            if let text = parseContentBlockDelta(event.data) {
                                continuation.yield(text)
                            }
                        case "message_stop":
                            continuation.finish()
                            return
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in }
        }

        // Consumer on MainActor (like AIService.generate)
        var updates: [String] = []
        let onUpdate: @Sendable (String) -> Void = { text in
            updates.append(text)
        }

        var accumulated = ""
        let task = Task { @MainActor in
            for try await chunk in textStream {
                accumulated += chunk
                await MainActor.run { onUpdate(accumulated) }
            }
        }

        _ = await task.result

        #expect(updates.count == 3, "Should get 3 progressive updates, got \(updates.count): \(updates)")
        #expect(updates == ["def ", "def process", "def process(): pass"],
                "Updates should show progressive accumulation, got: \(updates)")
        #expect(accumulated == "def process(): pass")
    }
}
