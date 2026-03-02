import Foundation

/// Parses Server-Sent Events from an async byte stream.
///
/// Note: We iterate raw bytes and split lines manually instead of using
/// `bytes.lines` because `URLSession.AsyncBytes.lines` drops empty lines,
/// which SSE relies on as event boundaries.
enum SSEParser {
    struct Event {
        let type: String?
        let data: String
    }

    /// Parse SSE events from URLSession async bytes.
    static func events(from bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                var currentType: String?
                var dataLines: [String] = []
                var lineBuffer = Data()

                do {
                    for try await byte in bytes {
                        if Task.isCancelled { break }

                        if byte == UInt8(ascii: "\n") {
                            // Strip trailing \r if present (\r\n line ending)
                            if lineBuffer.last == UInt8(ascii: "\r") {
                                lineBuffer.removeLast()
                            }
                            let line = String(data: lineBuffer, encoding: .utf8) ?? ""
                            lineBuffer.removeAll(keepingCapacity: true)

                            processLine(
                                line,
                                currentType: &currentType,
                                dataLines: &dataLines,
                                continuation: continuation
                            )
                        } else {
                            lineBuffer.append(byte)
                        }
                    }

                    // Handle last line if no trailing newline
                    if !lineBuffer.isEmpty {
                        let line = String(data: lineBuffer, encoding: .utf8) ?? ""
                        processLine(
                            line,
                            currentType: &currentType,
                            dataLines: &dataLines,
                            continuation: continuation
                        )
                    }

                    // Flush any remaining event
                    if !dataLines.isEmpty {
                        continuation.yield(Event(type: currentType, data: dataLines.joined(separator: "\n")))
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

    /// Process a single SSE line, dispatching events on empty lines.
    private static func processLine(
        _ line: String,
        currentType: inout String?,
        dataLines: inout [String],
        continuation: AsyncThrowingStream<Event, Error>.Continuation
    ) {
        if line.isEmpty {
            // Empty line = dispatch event
            if !dataLines.isEmpty {
                let event = Event(
                    type: currentType,
                    data: dataLines.joined(separator: "\n")
                )
                continuation.yield(event)
            }
            currentType = nil
            dataLines = []
        } else if line.hasPrefix("event:") {
            currentType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            let value = String(line.dropFirst(5))
            // SSE spec: strip single leading space if present
            if value.hasPrefix(" ") {
                dataLines.append(String(value.dropFirst()))
            } else {
                dataLines.append(value)
            }
        }
        // Ignore "id:", "retry:", and comments (":")
    }
}
