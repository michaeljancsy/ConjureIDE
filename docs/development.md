# How ConjureIDE is built, tested and released

Setup, build and test commands are in `README.md` and `CONTRIBUTING.md`; the full manual is
`docs/architecture-reference.md`. This page holds the facts that are in neither. (Moved from
AGENTS.md / CLAUDE.md, word for word.)

## What a build does to this Mac

- Every build (including `xcodebuild test`) runs `scripts/pre-build-clean.sh` and
  `scripts/bust-au-cache.sh`. They kill `AudioComponentRegistrar` and `pkd`, clear the AU cache,
  and register this build's app with macOS. A DAW open in another session will lose and re-scan
  its plug-ins.
- A local Release build moves an installed `/Applications/ConjureDSP.app` to
  `/Applications/ConjureDSP.app.dev-backup`. Debug builds leave it alone.
- Builds take minutes.

## Rules for the code

- `process(ctx)` (one argument) is the only Python entry point. No allocation, file or network
  work on the audio thread.
- The export template shares `cdp-ui.js`, `customui-bridge.js` and
  `BundleAssetSchemeHandler.swift` with the extension by symlink. Keep them symlinks. Run the
  `check-drift` skill after touching either side.
- The in-app agent's instructions
  (`~/Library/Application Support/ConjureDSP/agent-workspace/CLAUDE.md`) are rewritten from
  `PTYManager.contextContent` each time the terminal opens. Change that source, not the
  generated file.

## Worktrees

Gitignored assets are missing in a new worktree. The SessionStart hook and
`scripts/setup-worktree.sh` link Monaco, xterm.js, uv-dist and `Config/Local.xcconfig` from the
main checkout. Copy (don't link) `rust/python-dist` and `rustc-dist` with `ditto`, because
builds write into them. (This replaces the "auto-symlink" description in the Worktrees section
of `docs/architecture-reference.md`.)

## Releases

- Check free disk first: a release needs about 25 GB.
- For each release, capture example reports from that release for the privacy page at
  conjuredsp.com/privacy. Capture one crash report, App Open, and the usage event with the most
  fields, each exactly as the release sends it.
  - The capture program is `harness/run.sh` in the latest ConjureIDE folder of the
    conjure-test-results repository on GitHub. For 3.1.1 that is
    `conjureide/2026-11-22-v3.1.1-example-reports/`.
  - It builds the release tag's own reporting code (`Analytics.swift`, `SentrySetup.swift`,
    `SentryHelper.swift`) with the tag's Mixpanel and Sentry versions. It sends to a stand-in
    server on this computer, so nothing reaches Mixpanel or Sentry. No window opens.
  - Before running it, check its `main.swift` call sites against the new tag. If the release
    changes what is reported (events, fields, error reports, library versions or options), update
    `main.swift` and `notes.md` to match.
  - Save the run as a new folder, `conjureide/<date>-v<version>-example-reports/`. Get the
    website's privacy section updated from it before the release is published.

## Logic

- In a new Logic project, Logic doesn't run a stopped track's plug-ins until the track has played
  once. Anything that must happen right away, such as applying a control change, can't wait for
  the audio-processing call.
- Logic hosts Audio Units in a helper process and sends parameter changes on a background thread,
  even with no audio running. Host calls don't necessarily arrive on the main thread, and passing
  an automated host test doesn't prove a Logic behaviour: it still needs a check in Logic.
- Logic's Controls view replaces the value names of the second-to-last control with its own
  "MIDI Mono Mode" words, so an on/off control placed second to last shows the wrong labels.
