# Contributing to ConjureDSP

## Development setup

Follow the [README build steps](README.md#building) first: run the one-time
setup scripts, then create `Config/Local.xcconfig` from the template and set
`DEVELOPMENT_TEAM` to your Apple team id. A free Apple Developer account is
enough for local development — Debug builds use automatic signing.

Set your team **only** in `Config/Local.xcconfig`, never through Xcode's
Signing & Capabilities pane — the pane writes `DEVELOPMENT_TEAM` into the
shared `project.pbxproj`, which would leak your team id into your PR and
override everyone else's local config.

Things to know about signing:

- **Debug + automatic signing is the supported contributor path.** The
  Release configurations use manual "Developer ID Application" signing with
  the maintainer's provisioning profiles (`ExportOptions.plist`,
  `PROVISIONING_PROFILE_SPECIFIER` entries, `scripts/notarize.sh`,
  `scripts/release.sh`) — that release plumbing is maintainer-only and not
  expected to work elsewhere.
- **App Group**: the targets share the App Group
  `group.com.MichaelJancsy.ConjureDSP` (see the entitlements files and the
  per-target `AppGroupContainer.swift`). Development-signed builds can use
  this group id with your own team; macOS may show a one-time consent prompt.
  If your setup refuses it, replace the group id in the `.entitlements` files
  and the `AppGroupContainer.id` constants with your own.
- Debug and Release builds intentionally use different AU identities and
  bundle ids so they can coexist — see "Plugin Identity" in `AGENTS.md`.

The plugin registers with macOS when the ConjureDSP host app runs. If the AU
stops appearing in hosts, see "AU Registration Troubleshooting" in
`AGENTS.md` (never use `pluginkit -r`).

## Tests

Three test targets, fastest first — use the fastest one that can express your
test:

```bash
# Pure logic/FFI tests, no app launch (~6 s) — the default
xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP test -only-testing:ConjureDSPLogicTests

# Integration tests that launch the host app (~2 min)
xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP test -only-testing:ConjureDSPTests
```

For standalone Rust kernel tests (`cargo test`), use the exact invocation in
`AGENTS.md` → "Rust build" — it needs environment variables that track the
Python embedding, and that file is the canonical copy.

UI tests (`ConjureDSPUITests`) are slow; run only the specific class or
method relevant to your change.

This project practices TDD where the behavior is objectively testable: write
the failing test first, then the smallest change that makes it pass.

## Pull requests

- Branch from `main`, keep PRs focused, and make sure
  `ConjureDSPLogicTests` passes (plus `ConjureDSPTests` when you touch AU,
  preset, or export behavior).
- `AGENTS.md` is the in-repo architecture reference (also consumed by coding
  agents). If your change alters architecture, build phases, or conventions
  documented there, update it in the same PR.

## Reporting issues

Use GitHub Issues. For security vulnerabilities, follow
[SECURITY.md](SECURITY.md) instead of filing a public issue.
