# ConjureIDE

@~/.claude/audio-work.md

ConjureIDE is an AUv3 audio effect for macOS in which users write real-time DSP inside the
plug-in, with an embedded AI coding terminal. It is the one ConjureDSP product that does not
follow `~/Projects/ConjureDSP/architecture.md`. How it's built, tested and released: `README.md`,
`CONTRIBUTING.md` and `docs/development.md`. How it works inside: `docs/architecture-reference.md`;
read the section you need before changing that area. How the sessions work together:
`~/Projects/ConjureDSP/how-we-work.md`.

## Rules

- Write a failing test first, then the smallest fix, using the fastest test target that can show
  the bug. Skip this only for things you can't test automatically (layout, "does it sound
  right"), and say that you skipped it.
- Run builds in the background, not in the foreground piped through `tail`.
- A build here makes any open DAW lose and re-scan its plug-ins (`docs/development.md`). Check
  `screen-turn status` first, and don't build while someone else holds a DAW turn.
- Never run `pluginkit -r` or `pluginkit -e ignore`. They can break registration permanently.
- The LaunchServices reset steps in `docs/au-registration-troubleshooting.md` affect every app on
  the Mac; ask the director of product first.
- In a worktree, edit files under the worktree path, not the main checkout.
- GitHub Issues on this repository are the backlog. File or update an issue when you finish a
  feature or find a bug.
