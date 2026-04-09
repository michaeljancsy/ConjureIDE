---
name: build-release
description: Build and release ConjureDSP — bump version, build, sign, notarize, package DMG, and upload to R2.
user_invocable: true
---

# Build & Release ConjureDSP

You are running the ConjureDSP build and release pipeline. Follow these steps in order.

## Step 1: Read current version

Read the current version from the Xcode project:
```bash
grep -m1 'MARKETING_VERSION' ConjureDSP.xcodeproj/project.pbxproj
grep -m1 'CURRENT_PROJECT_VERSION' ConjureDSP.xcodeproj/project.pbxproj
```

Report the current version and build number to the user.

## Step 2: Ask about version bumping

Use AskUserQuestion to ask the user how they want to bump the version. Present these options:

- **Patch bump** (e.g., 1.0.5 -> 1.0.6) — for bug fixes and minor improvements
- **Minor bump** (e.g., 1.0.5 -> 1.1.0) — for new features
- **Major bump** (e.g., 1.0.5 -> 2.0.0) — for breaking changes
- **Build number only** (e.g., build 1 -> build 2, version stays the same) — for re-releasing the same version

## Step 3: Ask about the pipeline

Use AskUserQuestion to ask what the user wants to do. Present these options:

- **Build, notarize, and release** (Recommended) — full pipeline: build, sign, notarize, generate appcast, upload to R2
- **Build and notarize only** — build a distributable DMG but don't upload
- **Build only** — build without notarizing (for local testing, not distributable)

## Step 4: Confirm and run

Summarize the plan to the user (version, build number, what will happen), then run the appropriate script. Pass version/build flags directly to the script — it handles updating the pbxproj.

- **Build, notarize, and release**: `./scripts/build-and-release.sh --version X.Y.Z --build N`
- **Build and notarize only**: `./scripts/build.sh --notarize --version X.Y.Z --build N`
- **Build only**: `./scripts/build.sh --version X.Y.Z --build N`

For version bumps, pass the new version and reset build to 1. For build-only bumps, pass just the new build number.

Use a long timeout (600000ms / 10 minutes) since builds and notarization take a while.

## Step 5: Report results

After the script completes, report:
- Whether it succeeded or failed
- The version and build number
- The DMG path and size
- What steps completed (built, notarized, released)

If it failed, show the relevant error output and suggest fixes.

## Notes

- If the user has already built and just wants to release, run `./scripts/release.sh` for them. It picks up the existing DMG from `build/release/` and uploads to R2.
