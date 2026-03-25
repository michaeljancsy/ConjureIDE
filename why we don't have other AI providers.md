# Why We Don't Have Other AI Providers

ConjureDSP currently supports only Anthropic Claude as its AI provider. This is a deliberate choice, not an oversight.

## The core issue: tool use

ConjureDSP's AI chat isn't a simple text-in/text-out interface. It runs an agentic loop with 9 tools — compile_and_run, get_script, set_parameter, toggle_bypass, save_preset, and more. The AI autonomously compiles DSP scripts, reads errors, fixes them, adjusts parameters, and iterates — all without the user copying and pasting anything.

This requires reliable structured tool calling with multi-step reasoning. The AI needs to:

1. Decide which tool to call based on context
2. Produce valid JSON arguments
3. Interpret the result
4. Decide what to do next (fix an error? adjust a parameter? call another tool?)
5. Repeat for up to 10 rounds

## Why not Ollama / local models?

We evaluated Ollama as a local, free, offline-capable provider. The appeal is real — no API costs, no internet required, full privacy. But:

- **Tool use quality**: Most local models that fit in consumer hardware (8-32GB RAM) have weak or unreliable tool calling. A failed tool call mid-loop produces confusing behavior — partial scripts, phantom errors, loops that go nowhere.
- **Code quality for real-time audio**: Generated code runs directly in the audio callback. Bad code means glitches, silence, or crashes. Our system prompts encode detailed real-time safety rules (no allocations in `process()`, vectorize everything, use numpy `out=` parameters). Smaller models are much less likely to follow these constraints.
- **Model management UX**: Ollama requires the user to install a separate app, pull models, keep it running. This adds friction and support surface area for a degraded experience.

### What about a lightweight "generate-only" mode?

We considered a standalone "Generate from Prompt" feature that bypasses the agentic loop — just send a prompt, get a script back, insert it into the editor. This would avoid the tool use problem entirely and could work with ~150 lines of new code.

This remains the most viable entry point if we revisit local model support. It would also serve as the foundation for a "Fix with AI" button.

## Why not OpenAI?

OpenAI would actually be a reasonable second provider — their tool use is reliable and the models are strong at code generation. If we add a second provider, OpenAI is the likely candidate. The main blocker is engineering effort: `ChatService` currently hardcodes `AnthropicProvider` as a concrete type, so adding any provider requires generalizing the chat infrastructure first.

## When we'd revisit this

- If local models improve at tool use (especially at 7-14B parameter sizes that run well on Apple Silicon)
- If user demand justifies the engineering cost of a second cloud provider
- If we add non-agentic AI features (autocomplete, generate popover) where tool use isn't required
