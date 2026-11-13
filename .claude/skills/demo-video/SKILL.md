---
name: demo-video
description: Record an automated ConjureDSP demo video in Logic Pro — screen+audio capture of inserting the plugin, prompting the embedded Claude terminal on camera, and hearing the generated effect. Produces a raw .mov and a shareable .mp4.
user_invocable: true
---

# Demo Video

Records a full demo take autonomously: ffmpeg captures the screen + BlackHole audio while computer-use drives Logic Pro — insert ConjureDSP on a looping track, type the prompt into the embedded Claude terminal, wait for generation, interact with the generated custom UI, bypass A/B, done. First proven end-to-end 2026-08-17 (take 4 of 4; see Known failure modes for what killed takes 1–3).

## Step 0: Get the prompt

If `args` is non-empty, that's the demo prompt verbatim. Otherwise ask with AskUserQuestion. Good demo prompts name an audible effect plus a custom-UI ask, e.g. "Build a warm vintage tape echo with wow, flutter, and saturation. Give it a custom UI with an XY pad controlling delay time vs feedback."

**Preset-name collisions:** the agent will likely name the preset after the effect ("Vintage Tape Echo"). If a bundle with that name already exists in `~/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/Presets/`, delete it first (`rm -r`, NOT `rm -rf` — the auto-mode classifier blocks `-rf` here) so the run reads as fresh.

## Step 1: Preflight (some items need the user)

1. **The Claude window records too.** Your computer-use screenshots FILTER apps you weren't granted — ffmpeg does not. The floating Claude desktop window (and anything else over Logic) will be in the video even though you can't see it. Ask the user to hide/minimize it, then verify with an UNFILTERED ground-truth frame before rolling:
   ```bash
   ffmpeg -y -f avfoundation -i "Capture screen 0" -frames:v 1 /tmp/precheck.png
   ```
   Read the png. If anything but Logic + desktop is visible, fix before recording. Re-check this any time you're about to roll.
2. `request_access` for **Logic Pro**, **Finder** and **ConjureIDE** (full tier), and **ConjureDSPTerminal** (click tier — it needs a same-turn retry confirmation because the name matches "terminal"; you only need to see it and click its close button). Ask for full-screen control in the same minute. Two gotchas, both found 2026-11-12:
   - **An app is only found while it is running.** ConjureDSPTerminal lives inside `ConjureDSP.app/Contents/Library/` and is not indexed; start it first (`open -g .../ConjureDSPTerminal.app`) and then ask.
   - **Typing into the plug-in's terminal needs the extension process itself.** While Logic hosts the plug-in, keyboard focus belongs to the extension process (shown as "ConjureIDE (Logic Pro)", bundle `com.MichaelJancsy.ConjureDSP.ConjureDSPExtension`), not to Logic. Clicks in the plug-in window work under Logic's grant; `type`/`key` are refused, and background `app_type` can't reach the xterm view (it isn't in the accessibility tree). `request_access` can't find that process by name or bundle ID (it isn't in the app index), and Logic's generic helper `com.apple.audio.AUHostingService.arm64e` isn't the one that matters and can't be resolved either. **What works:** with the owner at the Mac, open Logic with the plug-in inserted, then have the owner type `@` and the app's name ("ConjureIDE (Logic Pro)") in this session's prompt so it is targeted directly, and approve the box. Do this in the owner's first visit, before they leave. Never get around the refusal another way (no pasting through a context menu, no writing to the terminal's WebSocket, no System Events keystrokes).
3. **Audio loopback: test with a tone, not just a capture.** On 2026-11-12 BlackHole 2ch passed nothing at all (flat −91 dB, even for a tone played straight into it), while Avid's "Pro Tools Audio Bridge 2-A" loopback worked. Test each candidate before choosing:
   ```bash
   ffmpeg -hide_banner -f lavfi -i "sine=f=440:d=0.1" -f audiotoolbox -list_devices true - 2>&1 | grep '\['   # output indices
   ffmpeg -v error -re -f lavfi -i "sine=f=440:d=5" -af volume=0.1 -f audiotoolbox -audio_device_index <N> - &
   sleep 1; ffmpeg -v error -y -f avfoundation -i ":<device name>" -t 2 /tmp/cap.wav
   ffmpeg -i /tmp/cap.wav -af volumedetect -f null - 2>&1 | grep max_volume   # about -38 dB = works; -91.0 = dead
   ```
   A flat −91.0 dB is digital silence. The built-in mic recording room noise (about −75 dB) proves the recorder has audio permission, so a dead loopback is the device, not permissions.
4. Screen Recording permission: run a 1 s test capture with audio (`-pixel_format bgr0 -i "Capture screen 0:<loopback>"`); verify the file has video+audio streams and the frame isn't black. If it fails, tell the user which app to enable in System Settings → Privacy & Security → Screen Recording; never change settings yourself.
5. Resolve avfoundation device indices at runtime (`ffmpeg -f avfoundation -list_devices true -i ""`); device names are stable, indices are not.
6. **Check the display before rolling** (`system_profiler SPDisplaysDataType`). On 2026-11-12 a docked Dell 4K woke mid-session and mirrored the laptop at "looks like 1920×1080": the screenshot coordinate frame changed, Logic no longer filled the screen, and captures became 3840×2160. That 16:9 shape is ideal for a 1080p video; just re-fill Logic (Window → Fill) and re-take coordinates. To tell a dock waking from the owner sitting down, read `ioreg -c IOHIDSystem | grep HIDIdleTime` twice: if idle keeps growing since your own last click, nobody is there.
7. Template project: `~/Music/ConjureDSP-Demo/Demo.logicx` — one audio track, a dry Apple loop at bar 1, Cycle enabled. **As of 2026-11-12 it has ConjureIDE already inserted (Passthrough)**, so in the Take copy remove it before rolling: hover the slot, click its right-hand arrow → No Plug-in, Cmd+S. If the project is missing, create it via computer-use (Empty Project → Audio track → drag a loop from the Loop Browser (`O`) → `;` to move to playhead → `u` to set cycle → Cmd+S, Package, save into ConjureDSP-Demo). Keep `captures/` next to it. Never use the owner's own projects.

## Step 2: Build + register the Release AU

Same as `/try-it` but Release — the Debug identity would show "ConjureDSP(Debug)" in Logic:

```bash
xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP -configuration Release build
```

Then resolve `BUILT_PRODUCTS_DIR` via `-showBuildSettings`, launch `ConjureDSP.app` once (registers `aufx 0001 CONJ`, starts the ConjureDSPTerminal companion), verify `auval -v aufx 0001 CONJ` passes, quit the host app (`osascript -e 'quit app id "com.MichaelJancsy.ConjureDSP"'` — companion keeps running).

Skip the build if the Release AU already validates and the build is current.

Before building a test build for a video:
- **Blank the telemetry keys** so the take doesn't send Mixpanel/Sentry events. In a worktree, `Config/Local.xcconfig` is a *symlink to the main checkout's file*: `unlink` it and copy the real file in first, then blank `CONJURE_MIXPANEL_TOKEN` and `CONJURE_SENTRY_DSN` in the copy, or you will edit the main checkout's file.
- The Release build runs `scripts/pre-build-clean.sh`, which moves `/Applications/ConjureDSP.app` to `/Applications/ConjureDSP.app.dev-backup`. Put it back afterwards (Step 6).
- Run `scripts/check-app-groups.sh <built ConjureDSP.app>`; it must pass, or the "would like to access data from other apps" prompt (issue #370) will appear on camera.
- Do an off-camera test insert in a throwaway copy of the project first, and open the plug-in's Terminal there too: that catches the macOS prompt and any Claude Code sign-in or setup screen before you roll.

## Step 3: Stage Logic

1. `rsync -a --delete Demo.logicx/ Take.logicx/` then `open Take.logicx`.
2. **Never fullscreen Logic.** The companion's focus-steal bounces you off the fullscreen Space and the plugin window lands over the raw desktop (killed take 1). Keep Logic a maximized normal window — it hides the desktop just as well.
3. Set Logic output to the loopback device that passed the tone test (BlackHole 2ch, or Pro Tools Audio Bridge 2-A) via Logic Pro → Settings… → Audio → Devices → Output Device → Apply. Logic switches the input to the same device; that's harmless while no track is armed. Do this off-camera. It's a global Logic pref, so **back up first** — the saved device may be an interface that isn't plugged in (2026-11-12: Clarett+ 8Pre), which you can't re-pick in Logic's menu afterwards:
   ```bash
   defaults export com.apple.logic10 ~/Music/ConjureDSP-Demo/captures/logic-prefs-before-<date>.plist
   ```
   Step 6 restores it.

## Step 4: The take

Roll ffmpeg in the background first:

```bash
ffmpeg -y -f avfoundation -framerate 30 -capture_cursor 1 -pixel_format bgr0 \
  -i "Capture screen 0:<loopback device>" \
  -c:v libx264 -preset ultrafast -crf 23 -pix_fmt yuv420p -c:a aac -b:a 192k \
  ~/Music/ConjureDSP-Demo/captures/raw-takeN.mov
```

(At 3840×2160 this runs at about 0.92× real time; fine. The file size on disk stays flat for the first seconds because the muxer buffers; check the `frame=` counter in ffmpeg's log instead.)

Then, verifying every click against a fresh screenshot (never replay blind coordinates):

1. Press Space (loop starts; recorded audio begins).
2. Click the channel strip's empty **Audio FX** slot → `mouse_move` (NOT click — clicking collapses the menu) over "Audio Units" → hover "ConjureDSP" (manufacturer) → hover "ConjureIDE" → click "Stereo". Move horizontally into each submenu before moving up or down, or the diagonal crosses another item and switches submenus. (If ConjureIDE was the last plug-in in that slot, it also appears as a shortcut at the top of the slot menu.)
3. **Companion popup:** ConjureDSPTerminal comes to front and shows its "Ready (MCP…)" status window ~2 s after insert, every time. Immediately screenshot, click its close button, then click the plugin window title bar to refocus Logic. Total on-screen time ~4 s; the user can trim.
4. If the plugin window didn't open, single-click the ConjureDSP slot (a double-click opens-then-closes it).
5. Click the **Terminal** toolbar button; wait for the Claude prompt (~10 s). If a login-method picker appears instead, STOP the recording — auth is the user's; see Known failure modes. When the pane starts it briefly prints the shell command it runs (`cd '/Users/<name>/Library/…/agent-workspace' && claude …`), which shows the owner's home folder: cut those frames in the edit.
6. Click the terminal input, type the prompt, press Return. This needs the extension-process grant from Step 1 item 2; without it `type` is refused and the take has to stop here.
7. Poll with `wait 90–100 s` + screenshot until the final digest appears (typically 5–10 min; the compiled effect becomes audible mid-take, which is the point). Ground truth: a fresh `.cdp` appears in the App Group `Presets/` dir.
8. Finale: click the **UI** tab, verify the custom UI rendered (flip the "Custom UI" toggle on if off), drag the XY pad through 2–3 slow moves (4–5 s pauses so the change is audible), then click **Bypass** on, wait 5 s, off, wait 7 s.
9. Click the Tracks area, press Space to stop, then `pkill -INT -f raw-takeN.mov` (SIGINT = clean file; the background task reports "failed exit 1", which is normal).

## Re-recording a take for free (transcript replay)

A generation run costs real time and tokens, so **never pay twice for the same prompt**. Every embedded-agent run persists a full transcript (the pane runs plain `claude` with the real `HOME`):

```
~/.claude/projects/-Users-michaeljancsy-Library-Application-Support-ConjureDSP-agent-workspace/*.jsonl
```

One file per run, identifiable by its opening prompt. `~/.conjuredsp-demo/replay.py` re-renders one as a Claude Code-style session — streaming text, grouped tool lines ("Called conjuredsp 4 times"), a spinner with a virtual clock, and the real final digest. Zero tokens.

**Getting it on screen:** the pane launches the agent in a *subshell* (`wrapInWorkspace(..., isExec: false)`), so typing `/exit` in the CLI drops to a live zsh prompt in the same PTY. From there:

```
clear; REPLAY_HOLD=20 REPLAY_TOTAL=170 python3 ~/.conjuredsp-demo/replay.py
```

`REPLAY_HOLD` clears the screen and holds it blank for N seconds so ffmpeg can start before anything draws; `REPLAY_TOTAL` is the target length in seconds; `REPLAY_SESSION` selects a different transcript. The script holds the final frame indefinitely so the pane never shows a dead shell.

**Take order:** load the finished preset first (so the UI tab and audio are real), then terminal → `/exit` → replay command → start playback → roll ffmpeg → let it play → finale on the real preset.

Honesty note: this is a **re-enactment** — a real session's content, re-rendered, with the preset already built. The audio and custom UI in the finale are genuinely real. Fine for marketing, but say so if asked whether it is a live capture.

## Step 5: Verify + post-process

1. `ffprobe` duration/streams; `volumedetect` mean/max (silence ≈ mean < -60 dB means the routing was wrong).
2. Extract 3–4 spot frames (`-ss N -frames:v 1`) and READ them — check for the Claude window, popups, and desktop leakage. This catches what filtered screenshots hid.
3. Transcode: `ffmpeg -i raw.mov -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p -c:a aac -b:a 192k demo-<slug>-<date>.mp4`. **Finished mp4s (and 960px phone previews) go in `~/Projects/ConjureDSP/conjuredsp-marketing/Videos/`.** Keep the raw .mov in `~/Music/ConjureDSP-Demo/captures/` for manual editing (deliverable is raw pacing — no speedups unless asked).
4. SendUserFile the mp4 if ≤30 MiB, otherwise make and send a 960px crf-30 preview (the 30 MiB limit applies to phone/Remote Control viewers).

### Fixed-length cut with captions (e.g. the 60-second website loop)

This Mac's ffmpeg has **no `drawtext` filter**, so text is drawn with Pillow and laid over with `overlay`. Two helpers live next to this file:

- `make_overlays.py` renders transparent 1920×1080 PNGs in the brand palette: `caption "text"` (bottom pill), `prompt "text"` (the typed request as a quote, for when terminal text is too small to read), `badge "Sped up 12x"` (top-right), and `endcard --icon assets/app-icon.png` (ConjureIDE · free and open source · conjuredsp.com/ide).
- `edit_demo.py cutlist.json` cuts the raw take from a JSON list of segments: raw start/end, a 16:9 `crop` in raw pixels, a `speed` factor, overlays with from/to times, and the raw time ranges whose audio plays under the segment. Picture can be sped up while the sound stays real-time (crossfaded clips: dry before the effect loads, wet after), which sounds far better than sped-up audio. Still cards use `{"image": ..., "duration": ...}`. It prints the planned total; make it come to exactly the target length.

Speed-up labels must state the factor (the waiting part of a 5–10 minute generation squeezed into ~15 s is roughly 20–40×). Verify the output: `ffprobe` duration, `volumedetect` not silent, and read 8+ frames spread across the video for personal windows, the Claude window, prompts and notifications.

## Step 6: Restore

- Quit Logic if you launched it (`osascript -e 'tell application "Logic Pro" to quit saving no'`; Take.logicx is disposable). Logic writes its prefs on quit, so restore the audio device *after* it has quit, key by key (rewriting the whole domain with `defaults import` fails on control characters in Logic's plist):
  ```bash
  python3 -c "import plistlib,sys; b=plistlib.load(open(sys.argv[1],'rb')); plistlib.dump(b['AudioHardwarePreferences'], open('/tmp/ahp.plist','wb'))" <backup.plist>
  defaults write com.apple.logic10 AudioHardwarePreferences "$(cat /tmp/ahp.plist)"
  # then each of FullOutputDriverName, FullInputDriverName, OutputDriverName, InputDriverName with -string <value from the backup>
  ```
  and compare against the backup to confirm.
- Quit the test build's companion, `lsregister -u` the DerivedData Release app, move `/Applications/ConjureDSP.app.dev-backup` back to `/Applications/ConjureDSP.app`, `lsregister -f -R -trusted` it, then `killall -9 AudioComponentRegistrar pkd` (as `bust-au-cache.sh` does). `pluginkit -mv -i com.MichaelJancsy.ConjureDSP.ConjureDSPExtension` should show the /Applications path.
- Show the Claude window again (`set visible of application process "Claude" to true`), `screen-turn release`, kill caffeinate, `release_full_control`.
- The generated preset stays in the user's library; don't delete it.

## Known failure modes (each killed a take on 2026-08-17)

- **Take 1 — fullscreen + focus steal:** companion activation bounced off Logic's fullscreen Space; desktop (personal files) recorded. Fix: maximized window, never fullscreen.
- **Take 2 — CLI login picker:** `claude` auto-updated between AU instances and asked for a login method. Selecting the highlighted option is fine to try (it's a menu, not credentials), but if a browser OAuth opens, stop and hand it to the user. Never enter credentials or complete OAuth yourself.
- **Take 3 — invisible overlay:** the floating Claude window was in the entire recording; screenshots couldn't see it (allowlist filtering). Fix: preflight item 1, always.
- **Companion popup on every AU instantiation** (filed as a bug): close it fast, budget ~4 s of blemish.
- **Bypass click flips the "Custom UI" toggle display off** (filed as a bug): harmless to the render; flip it back if you need the toggle shown on.
- **Auto-mode / onboarding dialogs in the embedded terminal:** new CLI versions pop setup flows (auto-mode "Set it up?" etc.). Esc cancels; never confirm a settings write. Removing the plugin kills the session and discards any pending proposal.
- A stray Esc/Enter while the terminal has focus can trigger those flows — click into the terminal only when you intend to type.
- **"(BlackHole 2ch)" in parentheses in Logic's device settings = device offline** (e.g. after a reboot); Logic silently falls back to another output and the capture records silence. Always open the Output Device dropdown and re-select the unparenthesized entry, then run a 2 s meter test before rolling.
- **The Claude desktop window is always-on-top** — fronting or enlarging Logic never buries it. Hide it with `osascript -e 'tell application "System Events" to set visible of application process "Claude" to false'` (works headless; Automation grant persists). It re-shows itself when the app activates (e.g. after SendUserFile) — re-hide and re-verify with an unfiltered frame before and during takes.
- **SendUserFile has a 30 MiB limit to phone viewers** — ship a 960px crf-30 preview for the phone and keep the full-quality file local.
- **Run `caffeinate -dis` for the whole session** — a take died to display sleep/lock once.
- **Crash dialogs mid-take may be unrelated apps** (an "Instruments quit unexpectedly" alert was Apple's profiler, not the AU). Read the dialog via unfiltered frame grab before assuming the plugin crashed; System Events can click its buttons if needed.
- The Logic plugin-slot double-click can select a Recent menu entry (inserted a stock Gain and a Compressor on separate occasions) — always screenshot between opening a slot menu and clicking in it.
- **Verify the recording file is growing ~3 s after starting ffmpeg** (`ls -la` the path). avfoundation screen capture is effectively single-consumer: a zombie ffmpeg holding the device makes the new one block silently at init — a full 17-minute take was once "recorded" to nothing. Corollary: **never trust `pkill` blindly** — follow every kill with `pgrep` and escalate to `-9`; a "killed" frame-grab survived twice.
- **macOS TCC prompt "ConjureDSP would like to access data from other apps"** fires at AU instantiation for every new build of the extension (UserNotificationCenter dialog, invisible to filtered screenshots — read it via System Events or an unfiltered grab). It is a security consent: NEVER click it yourself; push-notify the user and watch for dismissal (`count windows` of UserNotificationCenter). If "Don't Allow" is chosen the AU loads with a blank UI and no mcp-instances file — a fresh insert after the user clicks Allow recovers.
- The loop browser's synthetic drag-and-drop can fail persistently (undownloaded cloud loops fail silently; even local loops sometimes refuse). Deterministic fallback: File → Import → Audio File… with Cmd+Shift+G and the absolute path (find local loops under `/Library/Audio/Apple Loops`), then `;` to move the region to the playhead.
- The Claude window re-shows itself when the app activates (e.g. after SendUserFile mid-take) — re-run the System Events hide before every roll and avoid file delivery while recording.
- macOS screensaver/lock shows a slow-panning wallpaper that looks like an empty desktop in captures; Logic keeps running but windowless-looking, and Space switches don't render. If consecutive unfiltered frames show slightly different crops of the same wallpaper, it's the lock screen — only the user can unlock.

## Known failure modes (2026-11-12, 60-second website take)

- **Take stopped at the typing step:** the extension process holds keyboard focus and the approval tool can't find it (Step 1 item 2). The insert and terminal-opening part was recorded fine; the take was stopped, the Mac restored and the screen turn released rather than holding it while waiting for the owner. Get that grant during the owner's first visit.
- **BlackHole 2ch dead:** flat −91 dB even for a direct tone; Pro Tools Audio Bridge 2-A worked (Step 1 item 3).
- **Display changed mid-session:** a docked 4K monitor woke and mirrored at 1920×1080 (Step 1 item 6).
- **After `app_menu` or `app_screenshot`, full-screen `computer_batch` is refused** ("currently controlling … in the background"): call `app_release` first.
- **Claude Code auto-updates between plug-in instances** (v2.1.309 → v2.1.323 within 10 minutes) and prints an "Updated to latest…" banner; harmless, no setup screen appeared.
