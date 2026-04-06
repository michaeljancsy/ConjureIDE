# ConjureDSP Release Plan

## Context

ConjureDSP is an AUv3 audio plugin with Python/Rust DSP scripting, AI-assisted coding, NAM tone support, and a subscription system. The goal is to ship an initial **free beta** DMG (ASAP, 1-2 weeks), then transition to a **paid release** (Paddle subscription), and continue iterating post-launch. This plan triages all in-flight work (11 open PRs, 2 in-progress features) into what's blocking release vs. what can wait.

**Key decisions:**
- Beta = fully unlocked (hard-code `licensed=true`, no demo timer, no subscription UI)
- Claude Code terminal included in beta (companion app ships)
- Timeline: ASAP (1-2 weeks)

---

## Phase 1: Free Beta DMG (Target: ~April 20, 2026)

**Goal:** Ship a publicly downloadable DMG. All features fully unlocked — no license check, no demo timer.

### Must merge before beta

| PR | What | Why it blocks beta |
|----|------|--------------------|
| **#125** — Unique Python module names | Isolates Python modules per AU instance | Multi-track in a DAW causes cross-contamination without this |
| **#126** — Fix exported Python AUs in DAWs | Fixes `from conjuredsp import ...` in exports | Exported Python presets silently fail in DAWs |
| **#132** — Consolidate App Group container URLs | Reduces TCC permission prompts | Multiple permission dialogs on first launch |
| **#156** — Build numpy/scipy against Accelerate | Replaces OpenBLAS with Apple Accelerate | Performance + correctness; also fixes partial install bug |

### Should merge if time allows

| PR | What | Why |
|----|------|-----|
| **#129** — Cmd+Shift+A Save As shortcut | Keyboard shortcut | Small QoL, low risk |
| **#88** — Monaco inline error markers + themes | Squiggly underlines + color themes | Major UX improvement for code editing |
| **#90** — GitHub ETag caching + retry | HTTP caching for community browser | Prevents API hammering, better offline behavior |
| **#164** — NAM redistribution certification | Gate on exporting NAM tones | Legal/ethical protection |

### Infrastructure tasks

1. **Hard-code `licensed=true` for beta** — bypass subscription check. The `AtomicBool` licensed flag in `kernel.rs` and `SubscriptionStatus` in Swift both default to active. No demo timer, no subscription UI.
   - Files: `rust/conjure_dsp/src/kernel.rs` (AtomicBool init), `ConjureDSPExtension/Model/SubscriptionManager.swift`
2. **Run `release.sh` end-to-end** — archive → notarize → DMG. Store notarization creds in Keychain.
3. **Verify DMG on a clean Mac** — no Xcode, no Rust. App launches, loads in DAW, runs preset, companion app connects.
4. **Provision Sparkle R2 bucket** — `wrangler r2 bucket create conjuredsp-updates`, attach `updates.conjuredsp.com`. Enables pushing fixes via auto-update.
5. **Minimal landing page** — product name, pitch, screenshot, download button → GitHub Releases. No buy button yet.

### Can skip for beta

| Item | Why |
|------|-----|
| PR #115 — Python package management | Needs end-to-end manual testing |
| Rust crate package management | Same |
| PR #163 — NAM tone browser polish | Not broken, just polish |
| PR #154, #152 — Plans only | No code |
| NAM export authorization gates | Before paid launch |
| Teaser video | Nice-to-have, not blocking DMG |

---

## Phase 2: Paid Launch (End of Beta)

**Goal:** Enable subscription system. New users must pay. Beta users get grace period or early-adopter pricing.

### Must do before turning on payments

1. **Paddle account setup** — product created, pricing set, checkout tested. Backend (`api.conjuredsp.com`) already deployed.
2. **Remove beta licensing override** — revert the hard-coded `licensed=true`, re-enable subscription checks and demo timer.
3. **Landing page with Buy button** — Paddle.js checkout overlay. Add pricing, features, audio demos.
4. **End-to-end subscription test** — buy → activate → verify token → licensed → features unlocked. Test expiration + grace period.
5. **Demo mode polish** — verify 60s timer is clear. "Buy" buttons in SubscriptionSettingsView and demo-expired overlay link correctly.
6. **NAM export authorization gates** — flag/gate exporting NAM tones without creator authorization.
7. **NAM exports work** — end-to-end test of exporting NAM preset as standalone AU.
8. **TCC permissions loop check** — verify no loop when host app + AU-in-DAW run simultaneously.
9. **Privacy policy / Terms of Service** — required when charging money.

### Should do before paid launch

- **Onboarding walkthrough** — guided first-run experience introducing the editor, presets, parameters, terminal, and export features. Paying users need to understand what they're getting.
- **Non-Claude-Code agent options** — alternative AI agent backends beyond Claude Code CLI (e.g., direct API integration, other LLM providers). Not all users will have Claude Code set up; the AI-assisted coding feature shouldn't be locked to one CLI tool.
- **Python package management (PR #115)** — significant value-add; companion app architecture built, needs manual testing.
- **Rust crate management** — end-to-end testing remaining.
- **100 community presets (jovial-mendeleev)** — rich community browser makes product feel alive at launch.

---

## Phase 3: Post-Launch

Ship as updates after paid launch:

- **Sparkle auto-updates** — infrastructure built (SPM dep, R2 plan, EdDSA key). Ship with first update.
- **Python package follow-ups** — vendored exports, dependency badges, auto-launch companion app
- **Self-contained Python exports** — bundle Python runtime in exported AUs (~100MB each)
- **Export AU instantiation tests** — integration tests via AVAudioUnitComponentManager
- **AI script quality** — verify AI-generated scripts use vectorized numpy ops
- **Automated license webhook** — replace pre-generated key batch when it runs low
- **Cross-platform** — if demand warrants

---

## Worktree Cleanup

| Worktree | Status | Action |
|----------|--------|--------|
| affectionate-nash | Stale (fix already merged) | Clean up |
| enchanted-prancing-harbor | Export AU debug logging | Review for merge |
| hardcore-shirley | PRs #132 + #129 | Merge PRs, clean up |
| inspiring-curran | NAM export test fixes | Review for merge |
| jovial-mendeleev | 100 community presets | Merge before paid launch |
| package-management | PR #115 | Manual test, merge before paid launch |
| pr-115-review | Review branch for #115 | Clean up after merge |
| priceless-newton | PR #156 Accelerate numpy | Merge before beta |
| reverent-shtern | Manual testing checklist | Merge |
| sharp-chaplygin | Older checklist | Clean up (superseded) |
| unique-python-module-names | PR #125 | Merge before beta |
| busy-hellman | External, unknown state | Investigate or clean up |

---

## Verification Checklist

### Before beta ship
- [ ] All 4 "must merge" PRs on main
- [ ] `xcodebuild test -only-testing:ConjureDSPTests` passes
- [ ] `release.sh` produces signed, notarized DMG
- [ ] DMG installs and runs on clean Mac (no dev tools)
- [ ] Plugin loads in Logic Pro and Ableton Live
- [ ] Python + Rust presets both process audio
- [ ] Multi-track (2 instances) produces independent output
- [ ] No TCC permission prompts beyond initial file access
- [ ] Export preset as standalone AU, load in DAW — works
- [ ] Claude Code terminal connects via companion app
- [ ] Sparkle "Check for Updates" doesn't crash (no appcast yet is OK)

### Before paid launch
- [ ] All of the above, plus:
- [ ] Paddle checkout → subscription active → app licensed
- [ ] Demo mode works (60s → silence, buy button visible)
- [ ] NAM export gate enforced
- [ ] Landing page buy button works end-to-end
- [ ] Privacy policy / ToS published
