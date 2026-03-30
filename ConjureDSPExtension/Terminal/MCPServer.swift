//
//  MCPServer.swift
//  ConjureDSP
//
//  HTTP+SSE server implementing the Model Context Protocol (MCP).
//  Exposes the AU's 9 tools to Claude Code and other MCP clients.
//
//  Transport: Streamable HTTP (2025-03-26 MCP spec)
//  - POST /mcp  — client sends JSON-RPC requests, server responds with JSON-RPC or SSE
//  - GET  /mcp  — SSE stream for server-initiated notifications
//

import Foundation
import Network
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "MCPServer")

/// MCP server that exposes ConjureDSP's tools via HTTP+SSE on localhost.
@MainActor
final class MCPServer {

    /// The tool provider (AU extension) that executes tool calls.
    weak var toolProvider: MCPToolProvider?

    /// The port the server is listening on (nil if not started).
    private(set) var port: UInt16?

    private let appGroupContainerURL: URL?
    private var listener: NWListener?
    private var connections: [NWConnection] = []

    /// Active SSE connections waiting for server-initiated events.
    private var sseConnections: [ObjectIdentifier: NWConnection] = [:]

    /// Buffered data per connection for handling fragmented TCP packets.
    private var connectionBuffers: [ObjectIdentifier: Data] = [:]

    init(appGroupContainerURL: URL?) {
        self.appGroupContainerURL = appGroupContainerURL
    }

    // MARK: - Lifecycle

    /// Start the MCP server on a random available port.
    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: .any)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handleListenerState(state)
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleNewConnection(connection)
                }
            }

            listener.start(queue: .main)
        } catch {
            log.error("Failed to create MCP listener: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stop the server and close all connections.
    func stop() {
        listener?.cancel()
        listener = nil
        for conn in connections {
            conn.cancel()
        }
        connections.removeAll()
        sseConnections.removeAll()
        port = nil
        log.info("MCP server stopped")
    }

    // MARK: - Listener State

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let listenerPort = listener?.port?.rawValue {
                port = listenerPort
                log.info("MCP server listening on port \(listenerPort)")
                writePortToAppGroup()
            }
        case .failed(let error):
            log.error("MCP listener failed: \(error.localizedDescription, privacy: .public)")
            listener?.cancel()
            // Retry after a delay
            Task {
                try? await Task.sleep(for: .seconds(2))
                start()
            }
        case .cancelled:
            port = nil
        default:
            break
        }
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        connections.append(connection)

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            Task { @MainActor in
                if case .failed = state {
                    self?.removeConnection(connection)
                } else if case .cancelled = state {
                    self?.removeConnection(connection)
                }
            }
        }

        connection.start(queue: .main)
        receiveHTTPRequest(on: connection)
    }

    private func removeConnection(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
        sseConnections.removeValue(forKey: ObjectIdentifier(connection))
        connectionBuffers.removeValue(forKey: ObjectIdentifier(connection))
    }

    // MARK: - HTTP Request Parsing

    private func receiveHTTPRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            Task { @MainActor in
                if let data {
                    self.appendAndTryParse(data, on: connection)
                }
                if let error {
                    log.debug("Connection receive error: \(error.localizedDescription, privacy: .public)")
                    self.removeConnection(connection)
                } else if isComplete {
                    self.removeConnection(connection)
                } else {
                    self.receiveHTTPRequest(on: connection)
                }
            }
        }
    }

    /// Buffer incoming data and attempt to parse a complete HTTP request.
    private func appendAndTryParse(_ data: Data, on connection: NWConnection) {
        let connId = ObjectIdentifier(connection)
        var buffer = connectionBuffers[connId] ?? Data()
        buffer.append(data)
        connectionBuffers[connId] = buffer

        guard let requestString = String(data: buffer, encoding: .utf8) else {
            sendHTTPResponse(connection: connection, status: 400, body: "Bad Request")
            connectionBuffers.removeValue(forKey: connId)
            return
        }

        // Need at least the headers (terminated by \r\n\r\n)
        guard let headerEndRange = requestString.range(of: "\r\n\r\n") else {
            // Headers incomplete — wait for more data
            return
        }

        let headerSection = String(requestString[..<headerEndRange.lowerBound])
        let bodyStart = requestString[headerEndRange.upperBound...]

        // Parse Content-Length to know how much body to expect
        var contentLength = 0
        for line in headerSection.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(value) ?? 0
                break
            }
        }

        // Check if we have the complete body
        let bodyReceivedCount = bodyStart.utf8.count
        if bodyReceivedCount < contentLength {
            // Body incomplete — wait for more data
            return
        }

        // Complete request — consume buffer and parse
        connectionBuffers.removeValue(forKey: connId)

        // Parse request line
        let lines = headerSection.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendHTTPResponse(connection: connection, status: 400, body: "Bad Request")
            return
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            sendHTTPResponse(connection: connection, status: 400, body: "Bad Request")
            return
        }

        let method = String(parts[0])
        let path = String(parts[1])
        // Content-Length is in bytes, so slice on UTF-8 view (not String.prefix which counts characters)
        let body: String? = contentLength > 0 ? String(decoding: Array(bodyStart.utf8.prefix(contentLength)), as: UTF8.self) : nil

        // Route
        switch (method, path) {
        case ("POST", "/mcp"):
            handleMCPPost(body: body, on: connection)
        case ("GET", "/mcp"):
            handleMCPGet(on: connection)
        case ("OPTIONS", _):
            handleCORS(on: connection)
        case ("GET", "/health"):
            sendHTTPResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}", contentType: "application/json")
        default:
            sendHTTPResponse(connection: connection, status: 404, body: "Not Found")
        }
    }

    // MARK: - MCP POST Handler (JSON-RPC requests)

    private func handleMCPPost(body: String?, on connection: NWConnection) {
        guard let body, let bodyData = body.data(using: .utf8) else {
            sendJSONRPCError(connection: connection, id: .int(0), code: -32700, message: "Parse error: empty body")
            return
        }

        let request: MCPProtocol.JSONRPCRequest
        do {
            request = try JSONDecoder().decode(MCPProtocol.JSONRPCRequest.self, from: bodyData)
        } catch {
            sendJSONRPCError(connection: connection, id: .int(0), code: -32700, message: "Parse error: \(error.localizedDescription)")
            return
        }

        switch request.method {
        case "initialize":
            handleInitialize(request: request, on: connection)
        case "notifications/initialized":
            // Client acknowledgment — no response needed
            sendHTTPResponse(connection: connection, status: 202, body: "")
        case "tools/list":
            handleToolsList(request: request, on: connection)
        case "tools/call":
            handleToolsCall(request: request, on: connection)
        case "ping":
            sendJSONRPCResult(connection: connection, id: request.id, result: AnyCodable([:] as [String: String]))
        default:
            sendJSONRPCError(connection: connection, id: request.id, code: -32601, message: "Method not found: \(request.method)")
        }
    }

    // MARK: - MCP GET Handler (SSE stream)

    private func handleMCPGet(on connection: NWConnection) {
        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/event-stream",
            "Cache-Control: no-cache",
            "Connection: keep-alive",
            "Access-Control-Allow-Origin: *",
            "",
            "",
        ].joined(separator: "\r\n")

        let headerData = Data(headers.utf8)
        connection.send(content: headerData, completion: .contentProcessed { _ in })
        sseConnections[ObjectIdentifier(connection)] = connection

        // Send initial endpoint event
        let endpointEvent = "event: endpoint\ndata: /mcp\n\n"
        connection.send(content: Data(endpointEvent.utf8), completion: .contentProcessed { _ in })
    }

    // MARK: - MCP Method Handlers

    private func handleInitialize(request: MCPProtocol.JSONRPCRequest, on connection: NWConnection) {
        let instructions = toolProvider?.mcpStateSummary?()

        let result = MCPProtocol.InitializeResult(
            capabilities: MCPProtocol.ServerCapabilities(
                tools: MCPProtocol.ToolsCapability(listChanged: false)
            ),
            serverInfo: MCPProtocol.ServerInfo(name: "conjuredsp", version: "1.0.0"),
            instructions: instructions
        )

        if let encoded = try? JSONEncoder().encode(result) {
            sendJSONRPCResult(connection: connection, id: request.id, result: AnyCodable(
                try! JSONSerialization.jsonObject(with: encoded)
            ))
        }
    }

    private func handleToolsList(request: MCPProtocol.JSONRPCRequest, on connection: NWConnection) {
        let result = MCPProtocol.ToolsListResult(tools: MCPProtocol.tools)

        if let encoded = try? JSONEncoder().encode(result) {
            sendJSONRPCResult(connection: connection, id: request.id, result: AnyCodable(
                try! JSONSerialization.jsonObject(with: encoded)
            ))
        }
    }

    private func handleToolsCall(request: MCPProtocol.JSONRPCRequest, on connection: NWConnection) {
        guard let params = request.params,
              let toolName = params["name"]?.value as? String else {
            sendJSONRPCError(connection: connection, id: request.id, code: -32602, message: "Missing tool name")
            return
        }

        guard let provider = toolProvider else {
            sendJSONRPCError(connection: connection, id: request.id, code: -32603, message: "Audio unit not available")
            return
        }

        // Convert arguments to JSON string
        let inputJSON: String
        if let args = params["arguments"]?.value as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: args),
           let str = String(data: data, encoding: .utf8) {
            inputJSON = str
        } else {
            inputJSON = "{}"
        }

        let requestId = request.id
        provider.executeMCPTool(toolName, inputJSON: inputJSON) { [weak self] resultJSON, isError in
            Task { @MainActor in
                let toolResult = MCPProtocol.ToolCallResult(
                    content: [MCPProtocol.ContentBlock(type: "text", text: resultJSON)],
                    isError: isError ? true : nil
                )

                if let encoded = try? JSONEncoder().encode(toolResult) {
                    self?.sendJSONRPCResult(
                        connection: connection,
                        id: requestId,
                        result: AnyCodable(try! JSONSerialization.jsonObject(with: encoded))
                    )
                }
            }
        }
    }

    // MARK: - CORS

    private func handleCORS(on connection: NWConnection) {
        let headers = [
            "HTTP/1.1 204 No Content",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, POST, OPTIONS",
            "Access-Control-Allow-Headers: Content-Type",
            "",
            "",
        ].joined(separator: "\r\n")
        connection.send(content: Data(headers.utf8), completion: .contentProcessed { [weak connection] _ in
            connection?.cancel()
        })
    }

    // MARK: - HTTP Response Helpers

    private func sendHTTPResponse(connection: NWConnection, status: Int, body: String, contentType: String = "text/plain") {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 202: statusText = "Accepted"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }

        let response = [
            "HTTP/1.1 \(status) \(statusText)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.utf8.count)",
            "Access-Control-Allow-Origin: *",
            "Connection: close",
            "",
            body,
        ].joined(separator: "\r\n")

        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak connection] _ in
            connection?.cancel()
        })
    }

    private func sendJSONRPCResult(connection: NWConnection, id: JSONRPCId, result: AnyCodable) {
        let response = MCPProtocol.JSONRPCResponse(id: id, result: result, error: nil)
        guard let data = try? JSONEncoder().encode(response),
              let jsonString = String(data: data, encoding: .utf8) else { return }
        sendHTTPResponse(connection: connection, status: 200, body: jsonString, contentType: "application/json")
    }

    private func sendJSONRPCError(connection: NWConnection, id: JSONRPCId, code: Int, message: String) {
        let response = MCPProtocol.JSONRPCResponse(id: id, result: nil, error: MCPProtocol.JSONRPCError(code: code, message: message))
        guard let data = try? JSONEncoder().encode(response),
              let jsonString = String(data: data, encoding: .utf8) else { return }
        sendHTTPResponse(connection: connection, status: 200, body: jsonString, contentType: "application/json")
    }

    // MARK: - App Group Port Discovery

    private func writePortToAppGroup() {
        guard let port else { return }
        guard let containerURL = appGroupContainerURL else {
            log.warning("Failed to get App Group container URL")
            return
        }
        let portFileURL = containerURL.appendingPathComponent("mcp-server-port")
        do {
            try "\(port)".write(to: portFileURL, atomically: true, encoding: .utf8)
            log.info("Wrote MCP port \(port) to App Group container")
        } catch {
            log.warning("Failed to write MCP port to App Group: \(error.localizedDescription, privacy: .public)")
        }
    }
}
