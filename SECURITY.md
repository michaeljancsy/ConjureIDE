# Security Policy

## Reporting a vulnerability

Please report vulnerabilities privately: open this repository's **Security**
tab on GitHub and choose **Report a vulnerability** (GitHub private advisory)
rather than filing a public issue. You should receive a response within a
week.

## Scope notes

ConjureDSP intentionally executes user-supplied code: DSP scripts (Python and
Rust/WASM), custom preset UIs (HTML/JS in a WKWebView), and an embedded
terminal running the Claude Code CLI. Reports that "a preset can run code"
are by-design behavior, not vulnerabilities.

In scope, for example:

- Escaping the WASM sandbox or its fuel metering from a Rust preset
- A custom preset UI bypassing the scheme handler's CSP / sandboxing to read
  files outside its bundle or exfiltrate data over the network
- The plugin's local MCP/WebSocket servers being reachable from other
  machines or other local users
- Preset bundles or `.nam`/tone downloads triggering memory-unsafe parsing in
  the Rust kernel
- Privilege or sandbox escapes involving the ConjureDSPTerminal companion app
  or exported standalone AUs
