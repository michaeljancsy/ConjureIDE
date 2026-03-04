import Foundation
import os

final class AnthropicProvider: AIProvider {
    let name = "Anthropic"

    private let model = "claude-sonnet-4-20250514"
    private let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private let session: URLSession
    private let log = Logger(subsystem: "com.MichaelJancsy.BearBone", category: "Anthropic")

    init(session: URLSession = .shared) {
        self.session = session
    }

    private static let apiContract = """
        API contract:
        - Function signature: def process(inputs, outputs, frame_count, sample_rate, params)
        - inputs: list of numpy.float32 arrays (one per channel), pre-allocated to max_frames length
        - outputs: list of numpy.float32 arrays (one per channel), pre-allocated to max_frames length
        - frame_count: number of valid samples this callback (may be less than array length)
        - sample_rate: current sample rate (e.g. 44100.0)
        - params: list of 8 floats (0.0–1.0), DAW-automatable parameter values (Param 1–8). \
          Use these to make your effect controllable in real time from the host DAW.
        - Write processed audio into outputs[ch][:frame_count]
        - Only numpy is available (imported as np)
        - Global variables persist across callbacks (useful for phase accumulators, delay buffers, etc.)
        - Must handle both mono (1 channel) and stereo (2 channels)
        """

    private static let realTimeRules = """
        Real-time safety rules — process() runs in the audio callback, so every allocation, \
        deallocation, or hidden Python overhead causes glitches:

        ALLOCATIONS — never allocate inside process():
        - No new lists, dicts, sets, tuples, or strings
        - No list comprehensions, generator expressions, or range() calls
        - No NumPy operations that return new arrays — use slice assignment and the out= parameter \
          (e.g. np.multiply(a, b, out=output) instead of output = a * b)
        - Pre-allocate ALL buffers as globals on first call using a guard like: \
          global _buf; if '_buf' not in dir(): _buf = np.zeros(max_len, dtype=np.float32)

        DEALLOCATIONS — never drop the last reference to an object:
        - Don't create temporary objects that go out of scope (this triggers deallocation)
        - Don't use del statements

        HIDDEN OVERHEAD — avoid Python features with non-obvious cost:
        - No try/except blocks (frame setup cost; exceptions allocate tracebacks)
        - No function calls that internally allocate (prefer numpy ufuncs with out=)
        - Cache attribute lookups as local variables outside process() or as globals
        - No import statements inside process()
        - No closures or lambdas created inside process()

        WARM START — the host calls process() several times before real audio arrives, so \
        one-time initialization using a first-call guard is safe:
        - Pattern: global _buf; if '_buf' not in dir(): _buf = np.zeros(...)
        - This runs during warm-up, NOT on the first real audio callback
        - All subsequent calls must be allocation-free
        """

    // MARK: - Rust Prompts

    private static let rustApiContract = """
        API contract (Rust compiled to WebAssembly):
        - The script is compiled to wasm32-wasip1 and runs in a WASM sandbox
        - Must define four #[no_mangle] pub extern "C" functions:
          1. get_input_ptr() -> i32  — returns pointer to the input buffer
          2. get_output_ptr() -> i32 — returns pointer to the output buffer
          3. get_params_ptr() -> i32 — returns pointer to the params buffer (8 × f32)
          4. process(input: *const f32, output: *mut f32, channels: i32, frame_count: i32, sample_rate: f32)
        - Static buffers: define MAX_CH (2) and MAX_FR (4096) constants, then:
          static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
          static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
          static mut PARAMS_BUF: [f32; 8] = [0.0; 8];
        - The host writes 8 DAW-automatable parameter values (0.0–1.0) into PARAMS_BUF before \
          each process() call. Read PARAMS_BUF[0]–PARAMS_BUF[7] to access Param 1–8 and make \
          your effect controllable in real time from the host DAW.
        - Audio is interleaved: total samples = channels * frame_count
        - Use std::slice::from_raw_parts(input, n) and from_raw_parts_mut(output, n) inside unsafe blocks
        - Must handle both mono (1 channel) and stereo (2 channels)
        - For stereo, samples are interleaved: [L0, R0, L1, R1, ...]
        """

    private static let rustRealTimeRules = """
        Real-time safety rules — process() runs in the audio callback inside a WASM sandbox:

        NO HEAP ALLOCATIONS:
        - No Box, Vec, String, format!, or any heap-allocating types
        - No std::collections (HashMap, BTreeMap, etc.)
        - No dynamic dispatch (Box<dyn Trait>)
        - All state must be in static mut globals (safe in single-threaded WASM)

        NO PANICS:
        - Use wrapping arithmetic or manual bounds checks instead of indexing that could panic
        - No unwrap() or expect() on Option/Result
        - No integer overflow in debug mode (use wrapping_add, wrapping_mul, etc.)

        NO I/O:
        - No println!, eprintln!, or any print macros
        - No file access or network access
        - No std::io operations

        SAFE PATTERNS:
        - State persistence via static mut globals (WASM is single-threaded, so this is safe)
        - Direct pointer arithmetic with std::slice::from_raw_parts / from_raw_parts_mut
        - Inline math (f32 operations: sin, cos, etc. via f32 methods)
        - Constants via const or static
        """

    private static let rustSystemPrompt = """
        You are a DSP script generator for a real-time audio plugin compiled to WebAssembly. \
        Generate Rust scripts that define a `process()` function and static buffers.

        \(rustApiContract)

        \(rustRealTimeRules)

        Output ONLY the Rust source code. No explanations, no markdown fences, no comments about \
        what the script does. The script must be complete and immediately compilable.
        """

    private static let rustFixSystemPrompt = """
        You are a DSP script debugger for a real-time audio plugin compiled to WebAssembly. \
        The user's Rust DSP script has a compilation or runtime error. Fix the script to resolve \
        the error while preserving the intended behavior.

        \(rustApiContract)

        \(rustRealTimeRules)

        Output ONLY the corrected Rust source code. No explanations, no markdown fences.
        """

    private static let systemPrompt = """
        You are a DSP script generator for a real-time audio plugin. Generate Python scripts \
        that define a `process()` function.

        \(apiContract)

        \(realTimeRules)

        Output ONLY the Python script. No explanations, no markdown fences, no comments about what \
        the script does. The script must be complete and immediately executable.
        """

    private static let fixSystemPrompt = """
        You are a DSP script debugger for a real-time audio plugin. The user's Python DSP script has \
        an error. Fix the script to resolve the error while preserving the intended behavior.

        \(apiContract)

        \(realTimeRules)

        Output ONLY the corrected Python script. No explanations, no markdown fences.
        """

    func generateScript(
        prompt: String,
        existingScript: String?,
        language: ScriptLanguage,
        apiKey: String
    ) -> AsyncThrowingStream<String, Error> {
        var userContent = prompt
        if let existingScript, !existingScript.isEmpty {
            userContent += "\n\nHere is the current script for reference:\n```\n\(existingScript)\n```"
        }

        let messages: [[String: String]] = [
            ["role": "user", "content": userContent],
        ]

        let prompt = language == .rust ? Self.rustSystemPrompt : Self.systemPrompt
        return streamRequest(messages: messages, systemPrompt: prompt, apiKey: apiKey)
    }

    func fixScript(
        script: String,
        error: String,
        language: ScriptLanguage,
        apiKey: String
    ) -> AsyncThrowingStream<String, Error> {
        let userContent = """
            This script produced the following error:
            \(error)

            Script:
            ```
            \(script)
            ```
            """

        let messages: [[String: String]] = [
            ["role": "user", "content": userContent],
        ]

        let prompt = language == .rust ? Self.rustFixSystemPrompt : Self.fixSystemPrompt
        return streamRequest(messages: messages, systemPrompt: prompt, apiKey: apiKey)
    }

    private func streamRequest(
        messages: [[String: String]],
        systemPrompt: String,
        apiKey: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached { [self] in
                do {
                    var request = URLRequest(url: apiURL)
                    request.httpMethod = "POST"
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.setValue("application/json", forHTTPHeaderField: "content-type")

                    let body: [String: Any] = [
                        "model": model,
                        "max_tokens": 4096,
                        "stream": true,
                        "system": systemPrompt,
                        "messages": messages,
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await self.session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw AIProviderError.invalidResponse("Not an HTTP response")
                    }

                    self.log.info("HTTP status: \(httpResponse.statusCode)")

                    switch httpResponse.statusCode {
                    case 200:
                        break
                    case 401:
                        throw AIProviderError.noAPIKey
                    case 429:
                        let retryAfter = httpResponse.value(forHTTPHeaderField: "retry-after")
                            .flatMap(Int.init)
                        throw AIProviderError.rateLimited(retryAfterSeconds: retryAfter)
                    default:
                        // Try to read error body
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                            if errorBody.count > 500 { break }
                        }
                        throw AIProviderError.httpError(
                            statusCode: httpResponse.statusCode,
                            message: errorBody.isEmpty
                                ? "HTTP \(httpResponse.statusCode)" : errorBody
                        )
                    }

                    var chunkCount = 0
                    for try await event in SSEParser.events(from: bytes) {
                        if Task.isCancelled { break }

                        guard let eventType = event.type else { continue }

                        switch eventType {
                        case "content_block_delta":
                            if let text = parseContentBlockDelta(event.data) {
                                chunkCount += 1
                                continuation.yield(text)
                            } else {
                                self.log.warning(
                                    "Failed to parse content_block_delta: \(event.data.prefix(200))"
                                )
                            }
                        case "message_stop":
                            self.log.info("Stream complete, yielded \(chunkCount) chunks")
                            continuation.finish()
                            return
                        case "error":
                            let message = parseErrorEvent(event.data)
                            throw AIProviderError.invalidResponse(message)
                        default:
                            break
                        }
                    }

                    self.log.info("Stream ended (no message_stop), yielded \(chunkCount) chunks")
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AIProviderError.cancelled)
                } catch let error as AIProviderError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: AIProviderError.networkError(error))
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Parse the text from a content_block_delta SSE event.
    func parseContentBlockDelta(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let delta = obj["delta"] as? [String: Any],
            let text = delta["text"] as? String
        else { return nil }
        return text
    }

    /// Parse an error message from an error SSE event.
    private func parseErrorEvent(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = obj["error"] as? [String: Any],
            let message = error["message"] as? String
        else { return json }
        return message
    }
}
