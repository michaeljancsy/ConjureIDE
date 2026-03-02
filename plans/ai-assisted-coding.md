# Support AI Coding (AI-Assisted Script Generation/Editing)

## Problem
Writing Python DSP scripts from scratch requires knowledge of numpy, audio processing concepts, and the `process()` function API. AI assistance could lower the barrier — users describe the desired effect in natural language, and the AI generates a working script.

## Current State

### Script Editor (`TestPluginExtension/UI/HighlightedTextEditor.swift`)
- NSTextView wrapped in NSViewRepresentable
- Python syntax highlighting via `PythonSyntaxHighlighter`
- `@Binding var text: String` for editor content
- Accessibility identifier: "scriptEditor"

### Script Loading Flow (`TestPluginExtension/Common/Audio Unit/TestPluginExtensionAudioUnit.swift`)
1. User edits script in editor
2. User clicks "Run" → calls `reloadScript(source:)`
3. `reloadScript` writes source to temp file, calls `dsp_kernel_load_script()`, benchmarks
4. Returns `ScriptSaveResult` with success/error/timing info
5. UI displays result in status bar

### Error Display (`TestPluginExtension/UI/TestPluginExtensionMainView.swift`)
- Error text shown in red at bottom of editor
- Benchmark timing shown in green/orange/red
- Auto-hides after 3 seconds

### Sandboxing
- Host app entitlements: `inter-app-audio` only
- AU extension: no entitlements file currently
- AUv3 extensions CAN make network requests with `com.apple.security.network.client` entitlement
- This breaks "sandbox-safe" status, but most commercial plugins aren't sandbox-safe anyway

### Python DSP API Contract
```python
import numpy as np

def process(inputs, outputs, frame_count, sample_rate):
    # inputs: list[np.ndarray[float32]], one per channel
    # outputs: list[np.ndarray[float32]], one per channel
    # frame_count: int
    # sample_rate: float
```

## Research Findings

### LLM API Options

| Provider | Context Window | Code Quality | Cost | Privacy | Dependency |
|----------|---------------|-------------|------|---------|------------|
| **Anthropic Claude** | 200K tokens | Excellent | Per-token | Cloud | SwiftAnthropic SDK |
| **OpenAI GPT-4** | 128K tokens | Excellent | Per-token | Cloud | MacPaw/OpenAI SDK |
| **Apple Foundation Models** | 4K tokens | Poor for code | Free | On-device | Native (macOS 26+) |
| **Local via MLX** | 8K-32K+ | Good (code models) | Free | On-device | ~1-8GB model files |

### Apple Foundation Models Assessment
- ~3B parameter on-device model, optimized for summarization/extraction, not code generation
- 4,096 token context window (combined input + output) — too small for system prompt + script + generation
- May not work in AUv3 extensions due to sandbox restrictions (reported issues with app extensions)
- **Verdict: Not suitable for code generation.** Could handle simple tasks like "explain this error" but not script generation.

### Recommended: Cloud API (Anthropic or OpenAI)
- Large context windows handle system prompt + existing script + conversation history
- Strong code generation, especially for Python/numpy
- Streaming support for progressive display
- User provides their own API key

### Swift SDKs
- **SwiftAnthropic** (github.com/jamesrochabrun/SwiftAnthropic): Most complete Anthropic SDK. Streaming, prompt caching, tool use.
- **MacPaw/OpenAI** (github.com/MacPaw/OpenAI): Mature OpenAI SDK.
- Both are Swift packages, easy to add to Xcode project.

### UX Patterns (Ranked by Value/Complexity)

1. **"Generate from Prompt"** — Toolbar button → popover with text field. User describes effect, AI generates complete script. Highest value, simplest to implement.
2. **"Fix with AI"** — Shown alongside script errors. Sends error + script to AI. Leverages existing error display.
3. **Chat Sidebar** — Split view for iterative refinement ("make it stereo", "add vibrato"). Moderate complexity.
4. **Inline Completion** — Ghost text as user types. Most complex, latency-sensitive. Defer to later.

## Recommended Implementation Plan

### Phase 1: Generate + Fix (MVP)

#### 1a. Add Network Entitlement
Create `TestPluginExtension/TestPluginExtension.entitlements`:
```xml
<key>com.apple.security.network.client</key>
<true/>
```

#### 1b. Add Swift Package Dependency
Add SwiftAnthropic (or a provider-agnostic wrapper supporting both Claude and OpenAI) to the Xcode project.

#### 1c. API Key Management
New `AISettings` model:
```swift
class AISettings: ObservableObject {
    @Published var provider: AIProvider = .anthropic  // .anthropic | .openai
    @Published var apiKey: String = ""                // stored in Keychain
    var isConfigured: Bool { !apiKey.isEmpty }
}
```

Store API key in Keychain using `Security` framework. Provide a settings popover accessible from the toolbar (gear icon).

#### 1d. System Prompt
```
You are an audio DSP assistant. Generate Python scripts for real-time audio processing.

The script must define a `process` function:
    def process(inputs, outputs, frame_count, sample_rate):

Parameters:
- inputs: list of numpy float32 arrays (one per channel)
- outputs: list of numpy float32 arrays (one per channel)
- frame_count: number of valid samples (use slicing: array[:frame_count])
- sample_rate: float (e.g., 44100.0)

numpy is available as `np`. Global variables persist across callbacks (useful for LFOs, delays).

Only output the Python script. No explanations, no markdown fences.
```

#### 1e. "Generate" Button UI
Add to `PresetToolbar.swift`:
- Sparkle/wand icon button (or "AI" label)
- Opens popover with:
  - Text field: "Describe the effect you want..."
  - "Generate" button
  - Loading indicator during API call
- On success: replaces editor content with generated script (does NOT auto-run)
- On error: shows error in the popover

#### 1f. "Fix with AI" Button
When an error is displayed in the status bar, show an additional "Fix with AI" button.
- Sends: system prompt + current script + error message
- Prompt: "This script produced the following error: {error}. Fix the script."
- On success: replaces editor content (does NOT auto-run)

#### 1g. Streaming Response
Use the SDK's streaming API to progressively fill the editor as tokens arrive. This provides immediate feedback and feels responsive even on slow connections.

```swift
// Anthropic streaming
let stream = try await client.streamMessage(...)
for try await event in stream {
    if case .contentBlockDelta(let delta) = event {
        editorText += delta.text
    }
}
```

### Phase 2: Chat Sidebar

- Collapsible panel alongside the script editor
- Maintains conversation context (messages array)
- Code blocks in responses have an "Insert" button to replace editor content
- Contextual: automatically includes current script in each message
- "Explain this script" and "Optimize this script" quick actions

### Phase 3: On-Device Option (Future)

- MLX via LocalLLMClient for code-specialized models (e.g., Qwen2.5-Coder-7B)
- Falls back to on-device when no API key configured
- Larger download but fully private and offline
- Provider selector in settings: Cloud (Claude/OpenAI) vs. On-Device

## Key Files to Create
- `TestPluginExtension/TestPluginExtension.entitlements` — Network client entitlement
- `TestPluginExtension/AI/AIService.swift` — LLM API wrapper (provider-agnostic)
- `TestPluginExtension/AI/AISettings.swift` — API key management (Keychain)
- `TestPluginExtension/AI/DSPPrompts.swift` — System prompts and prompt templates
- `TestPluginExtension/UI/GeneratePopover.swift` — Generate-from-prompt UI
- `TestPluginExtension/UI/AISettingsPopover.swift` — API key settings UI

## Key Files to Modify
- `TestPlugin.xcodeproj` — Add SwiftAnthropic (or chosen SDK) Swift package
- `TestPluginExtension/UI/PresetToolbar.swift` — Add Generate button, AI settings gear icon
- `TestPluginExtension/UI/TestPluginExtensionMainView.swift` — Add "Fix with AI" button to error display, wire Generate popover
- `TestPluginExtension/Common/UI/AudioUnitViewController.swift` — Initialize AISettings, pass to views

## Important Design Decisions

### Generated code is NEVER auto-run
AI-generated scripts could contain errors or unexpected behavior. Always require the user to review and explicitly click "Run" to load the script into the kernel.

### API key is user-provided
The app does not bundle an API key. Users bring their own key. This avoids cost management and keeps the app free.

### Provider-agnostic design
Abstract the LLM call behind a protocol so switching between Anthropic/OpenAI/local is a configuration change, not a code rewrite:
```swift
protocol AIProvider {
    func generate(prompt: String, systemPrompt: String) async throws -> AsyncStream<String>
}
```

## Testing
- Unit tests: system prompt construction with various contexts
- Unit tests: API key Keychain storage roundtrip
- Unit tests: AIService mock (verify prompt structure, error handling)
- UI tests: Generate button visible, popover opens, settings gear accessible
- Manual: Enter API key, describe "tremolo effect at 5Hz," verify generated script is valid Python
- Manual: Introduce a syntax error, verify "Fix with AI" appears and produces corrected script
- Edge cases: no API key configured (show setup prompt), network error, rate limit, empty prompt

## Estimated Complexity
Medium task — 2-3 days for Phase 1. The LLM integration itself is straightforward (one API call + streaming). Most effort is in the UI (popovers, settings, streaming display) and polish (error handling, loading states).
