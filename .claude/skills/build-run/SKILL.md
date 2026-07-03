---
name: build-run
description: Command-line substitute for Xcode's Build+Run — builds ConjureDSP with a chosen configuration (Debug/Release), then launches the app.
user_invocable: true
---

# Build & Run ConjureDSP

Command-line replacement for Xcode's Build+Run button. Builds the host app from the current worktree with the user's chosen configuration, then launches the resulting `.app` directly from DerivedData. Does not sign for distribution, notarize, or touch the release pipeline — this is purely for local testing.

Follow these steps in order. Ask the question below with AskUserQuestion and wait for the user's answer before moving on. Do not make recommendations or pre-select options.

## Step 1: Ask Debug vs Release

Use AskUserQuestion:

- **Debug** — fast incremental build, whole-module optimizations off, DEBUG flag set
- **Release** — whole-module optimized, slower to rebuild, matches the distribution binary's behavior

Wait for the answer.

## Step 2: Confirm and run the build

Briefly summarize (e.g. "Building Debug") and kick off the build. Compose the xcodebuild invocation as follows:

**Debug:**
```bash
xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP -configuration Debug build
```

**Release:**
```bash
xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP -configuration Release build
```

Use a long timeout (600000ms / 10 minutes) since the Rust build phase can be slow on a clean build. Pipe through `tail -60` so the output stays readable but errors are still visible. If the build fails, extract the error with `grep -E "error:"` and surface it to the user instead of launching.

## Step 3: Locate and launch the built app

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

## Step 4: Report

Report the configuration (Debug/Release), the full `$APP_PATH`, and confirmation that the app launched. If the build failed, show the error output and skip the launch step.

## Notes

- **AU cache:** The `ConjureDSP` host app target has a `Bust AU Cache` build phase that kills `AudioComponentRegistrar` after every build, so AU re-discovery happens automatically. No manual cache busting is needed.
- **Release bundle ID conflicts:** Release builds use the production bundle ID (`com.MichaelJancsy.ConjureDSP`). If a real installed version exists at `/Applications/ConjureDSP.app`, the `pre-build-clean.sh` build phase moves it aside automatically.
- **Worktrees:** This skill works from any git worktree — the Monaco, Python, and Rust toolchain symlinks are set up by session-start hooks.
- **Not for distribution:** This skill does not notarize, sign with Developer ID, or upload anything. Use `/build-release` for the distribution pipeline.
