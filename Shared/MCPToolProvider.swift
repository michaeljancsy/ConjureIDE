//
//  MCPToolProvider.swift
//  ConjureDSP
//
//  Shared protocol for MCP tool execution.
//  Add this file to BOTH the ConjureDSP host app and ConjureDSPExtension targets.
//

import Foundation

/// Protocol that allows the host app's MCP server to execute tools on the AU extension.
///
/// The AU extension's `ConjureDSPExtensionAudioUnit` conforms to this protocol.
/// Since the AU is loaded in-process, the host app can cast `auAudioUnit as? MCPToolProvider`
/// to access tool execution without needing compile-time access to extension types.
@objc protocol MCPToolProvider {
    /// Execute an MCP tool by name with JSON-encoded input.
    ///
    /// - Parameters:
    ///   - name: Tool name (e.g., "compile_and_run", "get_parameters")
    ///   - inputJSON: JSON string of tool input parameters (e.g., `{"source": "..."}`)
    ///   - completion: Called with (resultJSON, isError) when the tool finishes
    func executeMCPTool(_ name: String, inputJSON: String, completion: @escaping (_ resultJSON: String, _ isError: Bool) -> Void)

    /// List all available preset names with metadata as JSON.
    /// Separate from executeMCPTool because PresetManager is wired up at the view controller level,
    /// not directly on the AUAudioUnit.
    @objc optional func mcpListPresets() -> String

    /// Save the current script as a user preset. Returns result JSON.
    @objc optional func mcpSavePreset(_ name: String) -> String
}
