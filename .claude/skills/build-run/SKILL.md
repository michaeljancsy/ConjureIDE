---
name: build-run
description: Command-line substitute for Xcode's Build+Run — builds ConjureDSP with a chosen configuration (Debug/Release) and BETA_BUILD flag, then launches the app.
user_invocable: true
---

# Build & Run ConjureDSP

Command-line replacement for Xcode's Build+Run button. Builds the host app from the current worktree with the user's chosen configuration and Beta flag, then launches the resulting `.app` directly from DerivedData. Does not sign for distribution, notarize, or touch the release pipeline — this is purely for local testing.

Follow these steps in order. Ask each question separately with AskUserQuestion and wait for the user's answer before moving on. Do not make recommendations or pre-select options.

## Step 1: Ask Debug vs Release

Use AskUserQuestion:

- **Debug** — fast incremental build, whole-module optimizations off, DEBUG flag set
- **Release** — whole-module optimized, slower to rebuild, matches the distribution binary's behavior

Wait for the answer.

## Step 2: Ask Beta vs Regular

Use AskUserQuestion:

- **Regular build** — normal licensing behavior (demo timer, DEMO badge when unlicensed)
- **Beta build** — injects `BETA_BUILD` compilation condition so the plugin runs fully licensed for 7 days from the build date (cyan BETA badge, no demo timer), then reverts to Demo

Wait for the answer.

## Step 3: Confirm and run the build

Briefly summarize (e.g. "Building Debug + Beta") and kick off the build. Compose the xcodebuild invocation as follows:

**Debug, regular:**
```bash
xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP -configuration Debug build
```

**Debug, Beta** — preserve the existing `DEBUG` flag when overriding:
```bash
xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP -configuration Debug build \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG BETA_BUILD'
```

**Release, regular:**
```bash
xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP -configuration Release build
```

**Release, Beta:**
```bash
xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP -configuration Release build \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='BETA_BUILD'
```

Use a long timeout (600000ms / 10 minutes) since the Rust build phase can be slow on a clean build. Pipe through `tail -60` so the output stays readable but errors are still visible. If the build fails, extract the error with `grep -E "error:"` and surface it to the user instead of launching.

## Step 4: Locate and launch the built app

After a successful build, resolve the build-products directory from the same xcodebuild invocation — don't hardcode a DerivedData path, since it varies per user/worktree:

```bash
BUILT_PRODUCTS_DIR=$(xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP -configuration <CONFIG> -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR / {print $3; exit}')
APP_PATH="$BUILT_PRODUCTS_DIR/ConjureDSP.app"
```

Verify `$APP_PATH` exists, then launch:
```bash
open "$APP_PATH"
```

Do NOT copy to `/Applications/` — launching from DerivedData is the whole point (matches what Xcode's Run button does).

## Step 5: Report

Report the configuration (Debug/Release + Regular/Beta), the full `$APP_PATH`, and confirmation that the app launched. If the build failed, show the error output and skip the launch step.

## Notes

- **AU cache:** The `ConjureDSP` host app target has a `Bust AU Cache` build phase that kills `AudioComponentRegistrar` after every build, so AU re-discovery happens automatically. No manual cache busting is needed.
- **Release bundle ID conflicts:** Release builds use the production bundle ID (`com.MichaelJancsy.ConjureDSP`). If a real installed version exists at `/Applications/ConjureDSP.app`, the `pre-build-clean.sh` build phase moves it aside automatically.
- **Worktrees:** This skill works from any git worktree — the Monaco, Python, and Rust toolchain symlinks are set up by session-start hooks.
- **Not for distribution:** This skill does not notarize, sign with Developer ID, or upload anything. Use `/build-release` for the distribution pipeline.
