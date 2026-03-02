import Foundation
import os

final class AnthropicProvider: AIProvider {
    let name = "Anthropic"

    private let model = "claude-sonnet-4-20250514"
    private let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private let session: URLSession
    private let log = Logger(subsystem: "com.MichaelJancsy.TestPlugin", category: "Anthropic")

    init(session: URLSession = .shared) {
        self.session = session
    }

    private static let systemPrompt = """
        You are a DSP script generator for a real-time audio plugin. Generate Python scripts \
        that define a `process()` function.

        API contract:
        - Function signature: def process(inputs, outputs, frame_count, sample_rate)
        - inputs: list of numpy.float32 arrays (one per channel), pre-allocated to max_frames length
        - outputs: list of numpy.float32 arrays (one per channel), pre-allocated to max_frames length
        - frame_count: number of valid samples this callback (may be less than array length)
        - sample_rate: current sample rate (e.g. 44100.0)
        - Write processed audio into outputs[ch][:frame_count]
        - Only numpy is available (imported as np)
        - Global variables persist across callbacks (useful for phase accumulators, delay buffers, etc.)
        - Must be real-time safe: no file I/O, no network, no print(), no dynamic imports
        - Must handle both mono (1 channel) and stereo (2 channels)

        Output ONLY the Python script. No explanations, no markdown fences, no comments about what the \
        script does. The script must be complete and immediately executable.
        """

    private static let fixSystemPrompt = """
        You are a DSP script debugger for a real-time audio plugin. The user's Python DSP script has \
        an error. Fix the script to resolve the error while preserving the intended behavior.

        API contract:
        - Function signature: def process(inputs, outputs, frame_count, sample_rate)
        - inputs: list of numpy.float32 arrays (one per channel), pre-allocated to max_frames length
        - outputs: list of numpy.float32 arrays (one per channel), pre-allocated to max_frames length
        - frame_count: number of valid samples this callback (may be less than array length)
        - sample_rate: current sample rate (e.g. 44100.0)
        - Write processed audio into outputs[ch][:frame_count]
        - Only numpy is available (imported as np)
        - Global variables persist across callbacks

        Output ONLY the corrected Python script. No explanations, no markdown fences.
        """

    func generateScript(
        prompt: String,
        existingScript: String?,
        apiKey: String
    ) -> AsyncThrowingStream<String, Error> {
        var userContent = prompt
        if let existingScript, !existingScript.isEmpty {
            userContent += "\n\nHere is the current script for reference:\n```\n\(existingScript)\n```"
        }

        let messages: [[String: String]] = [
            ["role": "user", "content": userContent],
        ]

        return streamRequest(messages: messages, systemPrompt: Self.systemPrompt, apiKey: apiKey)
    }

    func fixScript(
        script: String,
        error: String,
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

        return streamRequest(messages: messages, systemPrompt: Self.fixSystemPrompt, apiKey: apiKey)
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
