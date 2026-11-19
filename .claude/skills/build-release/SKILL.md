---
name: build-release
description: Build and release ConjureIDE — bump the version, build, sign, notarize, make the DMG, upload to R2, then commit, tag and open a PR.
user_invocable: true
---

# Build and release ConjureIDE

A release (and any R2 upload) needs Michael's own typed yes in this session. If you are a worker or PM and he isn't here, send the request to "MAIN Conjure Director of Product" with a link to this session, and wait.

Before each release, tell "MAIN ConjureDSP.com PM" whether it changes anything on the /ide pages, docs or privacy policy.

Ask each question separately with AskUserQuestion and wait for the answer. Don't recommend or pre-select an option.

## Step 1: Current version and next build number

Read the version from the main checkout, not a worktree (a worktree may be on an old commit):
```bash
MAIN=$(git worktree list --porcelain | awk '/^worktree/{path=$2} /^branch refs\/heads\/main$/{print path; exit}')
grep -m1 'MARKETING_VERSION' "$MAIN/ConjureDSP.xcodeproj/project.pbxproj"
grep -m1 'CURRENT_PROJECT_VERSION' "$MAIN/ConjureDSP.xcodeproj/project.pbxproj"
mkdir -p "$MAIN/build/release/appcast" && /opt/homebrew/bin/rclone copy r2:conjuredsp-updates "$MAIN/build/release/appcast" --include "appcast.xml"
grep 'sparkle:version' "$MAIN/build/release/appcast/appcast.xml" | sed 's/[^0-9]//g' | sort -n | tail -1
```
Report the version, the build number, and the highest build number in the appcast. The new build number must be higher than every appcast entry (Sparkle ignores lower or equal ones). Never reset it to 1. If main's version is behind the newest appcast entry, say so.

Also check free disk (`df -h /`). A release needs about 25 GB; stop and say so if there is less.

## Step 2–4: Ask

1. Version bump: patch, minor, major, or build number only.
2. Notarize, or skip.
3. Upload to R2, or skip.

## Step 5: Confirm and run

Summarize (version, build, notarize, upload) and get the yes. Then run in the background (it takes 10+ minutes):

- Build + notarize + upload: `./scripts/build-and-release.sh --version X.Y.Z --build N`
- Build + notarize: `./scripts/build.sh --notarize --version X.Y.Z --build N`
- Build + upload: `./scripts/build.sh --version X.Y.Z --build N`, then `./scripts/release.sh`
- Build only: `./scripts/build.sh --version X.Y.Z --build N`

`build.sh` checks the Sentry token first and uploads and verifies the dSYMs after archiving. If that fails, fix the token (`SENTRY_AUTH_TOKEN`, or `token=` under `[auth]` in `~/.sentryclirc`) and re-run. Never work around it with a bare `sentry-cli debug-files upload`.

## Step 6: Report

Say whether it worked, the version and build, the DMG path and size, which steps ran, and the dSYM result (the `All N debug files are on Sentry` line and the `Kept:` path). On failure, show the error and suggest a fix.

## Step 7: Commit, tag and PR (only after success)

From the main checkout, and only if it has no uncommitted changes besides the pbxproj (otherwise do this in a new worktree):
```bash
cd "$MAIN"
git checkout -b release/vX.Y.Z-bN
git add ConjureDSP.xcodeproj/project.pbxproj
git commit -m "Release X.Y.Z (build N)"
git tag vX.Y.Z-bN
git push origin release/vX.Y.Z-bN vX.Y.Z-bN
gh pr create --title "Release X.Y.Z (build N)" --body "Bump version to X.Y.Z, build N."
```
Report the PR link and tag. If nothing was staged (version already right), say so and skip.
