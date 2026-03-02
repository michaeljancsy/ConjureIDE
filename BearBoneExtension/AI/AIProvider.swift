import Foundation

/// Errors from AI provider API calls.
enum AIProviderError: LocalizedError {
    case noAPIKey
    case networkError(Error)
    case httpError(statusCode: Int, message: String)
    case rateLimited(retryAfterSeconds: Int?)
    case invalidResponse(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key configured. Open Settings to add your API key."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .httpError(let code, let message):
            return "API error (\(code)): \(message)"
        case .rateLimited(let seconds):
            if let seconds {
                return "Rate limited. Try again in \(seconds) seconds."
            }
            return "Rate limited. Please wait and try again."
        case .invalidResponse(let detail):
            return "Invalid response: \(detail)"
        case .cancelled:
            return "Generation cancelled."
        }
    }
}

/// Protocol for LLM providers that generate Python DSP scripts.
protocol AIProvider {
    var name: String { get }

    /// Generate a complete Python DSP script from a user's natural language description.
    /// Yields text chunks as they arrive from the streaming API.
    func generateScript(
        prompt: String,
        existingScript: String?,
        apiKey: String
    ) -> AsyncThrowingStream<String, Error>

    /// Fix a broken script given its source and the error message.
    /// Yields text chunks as they arrive from the streaming API.
    func fixScript(
        script: String,
        error: String,
        apiKey: String
    ) -> AsyncThrowingStream<String, Error>
}
