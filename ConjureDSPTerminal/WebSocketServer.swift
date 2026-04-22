//
//  WebSocketServer.swift
//  ConjureDSP
//
//  WebSocket server that relays pty I/O to connected terminal UIs.
//  The AU extension's xterm.js connects here to display the Claude Code terminal.
//

import Foundation
import Network
import os.log

private let wsLog = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "WebSocketServer")

/// WebSocket server for relaying terminal I/O between a pty and remote xterm.js clients.
final class WebSocketServer {

    /// The port the server is listening on.
    private(set) var port: UInt16?

    /// Called when a client sends text or binary data (terminal input from xterm.js).
    var onClientInput: ((Data) -> Void)?

    /// Called when a client connects or disconnects.
    var onClientCountChange: ((Int) -> Void)?

    /// Called when the listener is ready and the port is available.
    var onReady: ((UInt16) -> Void)?

    /// Text to send to the first client that connects (e.g. welcome banner).
    var pendingBanner: String?

    /// JSON control message to send to the first client that connects (alongside pendingBanner).
    var pendingControlMessage: Data?

    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]

    // MARK: - Lifecycle

    /// Start the WebSocket server on a specific port.
    func start(port: UInt16) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        // Add WebSocket protocol
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    self?.handleListenerState(state)
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async {
                    self?.handleNewConnection(connection)
                }
            }

            listener.start(queue: .main)
        } catch {
            wsLog.error("Failed to create WebSocket listener: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stop the server.
    func stop() {
        listener?.cancel()
        listener = nil
        for (_, client) in clients {
            client.cancel()
        }
        clients.removeAll()
        port = nil
    }

    /// Send data to all connected clients (pty output → xterm.js).
    func broadcast(_ data: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "ws", metadata: [metadata])

        for (id, client) in clients {
            client.send(content: data, contentContext: context, completion: .contentProcessed { [weak self] error in
                if let error {
                    wsLog.debug("Failed to send to client: \(error.localizedDescription, privacy: .public)")
                    DispatchQueue.main.async {
                        self?.removeClient(id)
                    }
                }
            })
        }
    }

    /// Send a JSON control message to all connected clients.
    func broadcastJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "ws", metadata: [metadata])
        for (id, client) in clients {
            client.send(content: data, contentContext: context, completion: .contentProcessed { [weak self] error in
                if let error {
                    wsLog.debug("Failed to send JSON to client: \(error.localizedDescription, privacy: .public)")
                    DispatchQueue.main.async { self?.removeClient(id) }
                }
            })
        }
    }

    /// Send a text message to all connected clients.
    func broadcastText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "ws", metadata: [metadata])

        for (id, client) in clients {
            client.send(content: data, contentContext: context, completion: .contentProcessed { [weak self] error in
                if let error {
                    wsLog.debug("Failed to send text to client: \(error.localizedDescription, privacy: .public)")
                    DispatchQueue.main.async {
                        self?.removeClient(id)
                    }
                }
            })
        }
    }

    var clientCount: Int { clients.count }

    // MARK: - Private

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let listenerPort = listener?.port?.rawValue {
                self.port = listenerPort
                wsLog.info("WebSocket server listening on port \(listenerPort)")
                onReady?(listenerPort)
            }
        case .failed(let error):
            wsLog.error("WebSocket listener failed: \(error.localizedDescription, privacy: .public)")
        default:
            break
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        clients[id] = connection
        wsLog.info("WebSocket client connected (total: \(self.clients.count))")
        onClientCountChange?(clients.count)

        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .failed, .cancelled:
                    self?.removeClient(id)
                default:
                    break
                }
            }
        }

        connection.start(queue: .main)
        let textMeta = NWProtocolWebSocket.Metadata(opcode: .text)
        let textCtx = NWConnection.ContentContext(identifier: "ws", metadata: [textMeta])
        if let ctrl = pendingControlMessage {
            pendingControlMessage = nil
            connection.send(content: ctrl, contentContext: textCtx, completion: .idempotent)
        }
        if let banner = pendingBanner {
            pendingBanner = nil
            if let data = banner.data(using: .utf8) {
                connection.send(content: data, contentContext: textCtx, completion: .idempotent)
            }
        }
        receiveFromClient(connection, id: id)
    }

    private func removeClient(_ id: ObjectIdentifier) {
        if let client = clients.removeValue(forKey: id) {
            client.cancel()
            wsLog.info("WebSocket client disconnected (total: \(self.clients.count))")
            onClientCountChange?(clients.count)
        }
    }

    private func receiveFromClient(_ connection: NWConnection, id: ObjectIdentifier) {
        connection.receiveMessage { [weak self] data, context, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                    switch metadata.opcode {
                    case .text, .binary:
                        DispatchQueue.main.async {
                            self.onClientInput?(data)
                        }
                    case .close:
                        DispatchQueue.main.async {
                            self.removeClient(id)
                        }
                        return
                    case .ping:
                        // Auto-reply handled by NW framework
                        break
                    default:
                        break
                    }
                }
            }

            if let error {
                wsLog.debug("WebSocket receive error: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async {
                    self.removeClient(id)
                }
                return
            }

            // Continue receiving. For WebSocket, isComplete means the message
            // (frame) is complete, NOT that the connection is done. We must
            // always re-register to receive the next message.
            self.receiveFromClient(connection, id: id)
        }
    }
}
