---
name: build-release
description: Build and release ConjureDSP — bump version, build, sign, notarize, package DMG, and upload to R2.
user_invocable: true
---

# Build & Release ConjureDSP

Follow these steps in order. Ask each question separately — wait for the user's answer before moving to the next question. Do not make recommendations or pre-select options.

## Step 1: Show current version and determine next build number

Read the current version from the Xcode project:
```bash
grep -m1 'MARKETING_VERSION' ConjureDSP.xcodeproj/project.pbxproj
grep -m1 'CURRENT_PROJECT_VERSION' ConjureDSP.xcodeproj/project.pbxproj
```

Also check the highest build number in the existing appcast (Sparkle requires monotonically increasing build numbers across ALL versions):
```bash
grep 'sparkle:version' build/release/appcast/appcast.xml 2>/dev/null | sed 's/[^0-9]//g' | sort -n | tail -1
```
If no appcast exists locally, sync from R2 first:
```bash
mkdir -p build/release/appcast && /opt/homebrew/bin/rclone copy r2:conjuredsp-updates build/release/appcast --include "appcast.xml" 2>/dev/null
```

Report the current version, build number, and the highest appcast build number to the user.

## Step 2: Ask about version bump

Use AskUserQuestion with these options:

- **Patch bump** (e.g., 1.0.5 -> 1.0.6)
- **Minor bump** (e.g., 1.0.5 -> 1.1.0)
- **Major bump** (e.g., 1.0.5 -> 2.0.0)
- **Build number only** (e.g., build 1 -> build 2, version stays the same)

Wait for the answer before continuing.

## Step 3: Ask about notarization

Use AskUserQuestion with these options:

- **Notarize**
- **Skip notarization**

Wait for the answer before continuing.

## Step 4: Ask about R2 upload

Use AskUserQuestion with these options:

- **Upload to R2**
- **Skip upload**

Wait for the answer before continuing.

## Step 5: Confirm and run

Summarize the plan (version, build number, notarize yes/no, upload yes/no) and ask the user to confirm before running.

Then run the appropriate script. Pass version/build flags directly — the scripts handle updating the pbxproj.

- **Build + notarize + upload**: `./scripts/build-and-release.sh --version X.Y.Z --build N`
- **Build + notarize, no upload**: `./scripts/build.sh --notarize --version X.Y.Z --build N`
- **Build + upload, no notarize**: `./scripts/build.sh --version X.Y.Z --build N` then `./scripts/release.sh`
- **Build only**: `./scripts/build.sh --version X.Y.Z --build N`

**CRITICAL: Build number must be strictly greater than the highest build number in the appcast.** Sparkle uses the build number (not the marketing version) to determine update ordering. If the build number is lower than or equal to an existing appcast entry, Sparkle will silently ignore the new version. For version bumps, do NOT reset build to 1 — use (highest appcast build + 1). For build-only bumps, also use (highest appcast build + 1).

Use a long timeout (600000ms / 10 minutes) since builds and notarization take a while.

## Step 6: Report results

After the script completes, report whether it succeeded or failed, the version and build number, the DMG path and size, and what steps completed.

If it failed, show the relevant error output and suggest fixes.
