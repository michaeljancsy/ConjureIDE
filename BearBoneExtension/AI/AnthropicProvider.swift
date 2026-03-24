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
        - Add "curve": "log" for frequency and time params (exponential slider distribution):
          "cutoff": {"min": 20.0, "max": 20000.0, "unit": "Hz", "default": 1000.0, "curve": "log"},
          Default curve is "linear". Use "log" when the range spans orders of magnitude.
        - Common units: "dB", "Hz", "ms", "%", ":1", "" (dimensionless).
        - Up to 16 parameters can be declared.
        - ALWAYS use PARAMS when your effect has controllable parameters.
        - Dict key order determines AU parameter address (first = 0, second = 1, etc.).
        """

    private static let realTimeRules = """
        Real-time safety rules — process() runs in the audio callback, so every allocation, \
        deallocation, or hidden Python overhead causes glitches:

        VECTORIZE EVERYTHING — never use per-sample Python loops:
        - NEVER use `for i in range(frame_count)` — this is catastrophically slow
        - ALWAYS use numpy vectorized operations on entire arrays/slices at once
        - Example: instead of looping to apply gain, do `np.multiply(inputs[ch][:frame_count], gain, out=outputs[ch][:frame_count])`
        - For LFOs/oscillators: pre-allocate a phase array global, compute all samples with \
          np.sin(phase_array, out=lfo_buf) in one call, then multiply with audio
        - For sample-by-sample state (e.g. filters with feedback): use a pre-allocated buffer and \
          vectorize as much as possible, only falling back to a Python loop for the minimal \
          feedback path if absolutely necessary
        - The channel loop `for ch in range(channels)` is fine (only 1-2 iterations)

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

    // MARK: - Chat (Multi-turn with Tool Use)

    /// Events streamed from a chat request. The caller assembles these into ContentBlocks.
    enum ChatEvent {
        /// A chunk of text from the assistant.
        case textDelta(String)
        /// A tool use block has started (provides the tool name and call ID).
        case toolUseStart(id: String, name: String)
        /// A chunk of the tool input JSON string.
        case toolInputDelta(String)
        /// The current content block has ended.
        case contentBlockEnd
        /// The message is complete. Contains the stop reason.
        case messageStop(stopReason: String?)
    }

    /// The system prompt for the chat sidebar, which has access to tools.
    static let chatSystemPrompt = """
        You are a DSP assistant for BearBone, a real-time audio plugin. You help users create, \
        modify, and debug audio effect scripts. You can compile and run scripts, read errors, \
        set parameters, and manage presets.

        When the user asks you to create or modify an effect, use the compile_and_run tool \
        to load it into the audio engine. If compilation fails, read the error and fix the script \
        automatically. Always compile and run scripts rather than just showing code.

        When modifying an existing script, use get_script first to read the current source, \
        then make targeted changes rather than rewriting from scratch.

        \(apiContract)

        \(realTimeRules)

        \(rustApiContract)

        \(rustRealTimeRules)

        Keep responses concise. Focus on what you did and any relevant details (timing, \
        parameter mappings). Don't repeat the full script back unless asked.
        """

    /// Stream a chat request with tool definitions. Returns ChatEvents.
    func streamChat(
        messages: [[String: Any]],
        tools: [[String: Any]],
        systemPrompt: String,
        apiKey: String
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached { [self] in
                do {
                    var request = URLRequest(url: apiURL)
                    request.httpMethod = "POST"
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.setValue("application/json", forHTTPHeaderField: "content-type")

                    var body: [String: Any] = [
                        "model": model,
                        "max_tokens": 4096,
                        "stream": true,
                        "system": systemPrompt,
                        "messages": messages,
                    ]
                    if !tools.isEmpty {
                        body["tools"] = tools
                    }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await self.session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw AIProviderError.invalidResponse("Not an HTTP response")
                    }

                    self.log.info("Chat HTTP status: \(httpResponse.statusCode)")

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

                    var stopReason: String?

                    for try await event in SSEParser.events(from: bytes) {
                        if Task.isCancelled { break }
                        guard let eventType = event.type else { continue }

                        switch eventType {
                        case "content_block_start":
                            // Parse tool_use block starts
                            if let parsed = self.parseJSON(event.data),
                               let contentBlock = parsed["content_block"] as? [String: Any],
                               let blockType = contentBlock["type"] as? String,
                               blockType == "tool_use",
                               let id = contentBlock["id"] as? String,
                               let name = contentBlock["name"] as? String
                            {
                                continuation.yield(.toolUseStart(id: id, name: name))
                            }

                        case "content_block_delta":
                            if let parsed = self.parseJSON(event.data),
                               let delta = parsed["delta"] as? [String: Any],
                               let deltaType = delta["type"] as? String
                            {
                                switch deltaType {
                                case "text_delta":
                                    if let text = delta["text"] as? String {
                                        continuation.yield(.textDelta(text))
                                    }
                                case "input_json_delta":
                                    if let json = delta["partial_json"] as? String {
                                        continuation.yield(.toolInputDelta(json))
                                    }
                                default:
                                    break
                                }
                            }

                        case "content_block_stop":
                            continuation.yield(.contentBlockEnd)

                        case "message_delta":
                            if let parsed = self.parseJSON(event.data),
                               let delta = parsed["delta"] as? [String: Any]
                            {
                                stopReason = delta["stop_reason"] as? String
                            }

                        case "message_stop":
                            continuation.yield(.messageStop(stopReason: stopReason))
                            continuation.finish()
                            return

                        case "error":
                            let message = parseErrorEvent(event.data)
                            throw AIProviderError.invalidResponse(message)

                        default:
                            break
                        }
                    }

                    continuation.yield(.messageStop(stopReason: stopReason))
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

    // MARK: - Parsing Helpers

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

    /// Parse a JSON string into a dictionary.
    private func parseJSON(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }
}
