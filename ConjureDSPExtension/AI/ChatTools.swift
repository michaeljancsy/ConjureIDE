import Foundation

/// Anthropic tool definitions for ConjureDSP's chat sidebar.
/// Each tool maps to a local Swift function on the AU.
enum ChatTools {
    /// All tool definitions in Anthropic API format.
    static let definitions: [[String: Any]] = [
        [
            "name": "compile_and_run",
            "description": "Compile and load a DSP script into the audio engine. For Python scripts, this loads instantly. For Rust scripts, this compiles to WASM first (takes a few seconds). Returns whether it succeeded, any error message, and benchmark timing.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "source": [
                        "type": "string",
                        "description": "The complete script source code (Python or Rust). Language is auto-detected.",
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["source"],
            ] as [String: Any],
        ] as [String: Any],
        [
            "name": "get_script",
            "description": "Get the currently loaded script source code.",
            "input_schema": [
                "type": "object",
                "properties": [:] as [String: Any],
            ] as [String: Any],
        ] as [String: Any],
        [
            "name": "get_error",
            "description": "Get the last error message from script loading or compilation.",
            "input_schema": [
                "type": "object",
                "properties": [:] as [String: Any],
            ] as [String: Any],
        ] as [String: Any],
        [
            "name": "set_parameter",
            "description": "Set a DAW-automatable parameter value. Up to 16 parameters (indices 0-15). Pass the actual value in the parameter's declared range (e.g., 1000.0 for a cutoff in Hz). The AU parameter tree clamps to min/max automatically. Use get_parameters first to see available parameters and their ranges.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "index": [
                        "type": "integer",
                        "description": "Parameter index (0-15).",
                        "minimum": 0,
                        "maximum": 15,
                    ] as [String: Any],
                    "value": [
                        "type": "number",
                        "description": "Parameter value in the declared range (e.g., 1000.0 for Hz, -12.0 for dB).",
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["index", "value"],
            ] as [String: Any],
        ] as [String: Any],
        [
            "name": "get_parameters",
            "description": "Read all active parameter values with names, ranges, and units.",
            "input_schema": [
                "type": "object",
                "properties": [:] as [String: Any],
            ] as [String: Any],
        ] as [String: Any],
        [
            "name": "get_audio_state",
            "description": "Get the current audio engine state: sample rate, channel count, max frames per buffer, and bypass state.",
            "input_schema": [
                "type": "object",
                "properties": [:] as [String: Any],
            ] as [String: Any],
        ] as [String: Any],
        [
            "name": "list_presets",
            "description": "List all available presets (factory and user). Returns preset names, whether they're factory or user presets, and their language (Python or Rust).",
            "input_schema": [
                "type": "object",
                "properties": [:] as [String: Any],
            ] as [String: Any],
        ] as [String: Any],
        [
            "name": "save_preset",
            "description": "Save the currently loaded script as a user preset.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "name": [
                        "type": "string",
                        "description": "Name for the preset.",
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["name"],
            ] as [String: Any],
        ] as [String: Any],
        [
            "name": "toggle_bypass",
            "description": "Toggle bypass mode. When bypassed, audio passes through unprocessed (useful for A/B comparison).",
            "input_schema": [
                "type": "object",
                "properties": [:] as [String: Any],
            ] as [String: Any],
        ] as [String: Any],
    ]
}
