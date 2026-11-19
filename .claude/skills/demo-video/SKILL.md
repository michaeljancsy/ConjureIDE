---
name: demo-video
description: Record a ConjureIDE demo video in Logic Pro — screen and audio capture of inserting the plug-in, prompting the embedded Claude terminal on camera, and hearing the generated effect. Produces a raw .mov and a shareable .mp4.
user_invocable: true
---

# Demo video

ffmpeg records the screen plus BlackHole audio while computer use drives Logic Pro: insert ConjureIDE on a looping track, type the prompt into the embedded terminal, wait for the effect, play with its custom UI, bypass A/B.

## Where to record

Record on the test laptop (`Michaels-MacBook-Pro.local`), where DAW work belongs: hand the job to the matching TEST session there. Use the main Mac only if Michael says so.

## Before anything: what needs Michael

Do this in one visit, while he is at the Mac with this session open (see the global CLAUDE.md, "Working while I'm away"):
- `request_access` for Logic Pro, Finder (full) and ConjureDSPTerminal (click tier), plus full-screen control if needed.
- Screen Recording permission for the app that runs ffmpeg. If a 1 s test capture fails, tell him which app to enable in System Settings; never change settings yourself.
- Ask him to hide the Claude desktop window. It floats on top and ffmpeg records it even though your screenshots hide it. Never hide or move it yourself with System Events or any other script.
- The macOS prompt "ConjureDSP would like to access data from other apps" appears on first insert of each new build. Only he may answer it.
- If the embedded `claude` asks for a login method or opens a browser sign-in, stop: sign-in is his.

Then: `screen-turn status`, `screen-turn claim --who "<your session title>" --minutes 60 --what "ConjureIDE demo take in Logic"`, and `caffeinate -d -t 7200` in the background.

## Step 0: The prompt

Use `args`, or ask. Good prompts name an audible effect and a custom UI, e.g. "a warm vintage tape echo with wow, flutter and saturation, with an XY pad for delay time vs feedback". If a preset with the likely name already exists in the App Group `Presets/`, ask before deleting it; it is the user's library.

## Step 1: Preflight

1. Ground-truth frame: `ffmpeg -y -f avfoundation -i "Capture screen 0" -frames:v 1 <scratchpad>/precheck.png`, then read it. Only Logic and the desktop may be visible. Repeat before every roll.
2. Find device indices with `ffmpeg -f avfoundation -list_devices true -i ""`. Use the names "Capture screen 0" and "BlackHole 2ch".
3. Template project `~/Music/ConjureDSP-Demo/Demo.logicx`: one audio track, a dry Apple loop at bar 1, 2-bar cycle on, no ConjureIDE inserted. Captures go in `~/Music/ConjureDSP-Demo/captures/`.

## Step 2: Release build

`xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP -configuration Release build` (in the background), launch the built `ConjureDSP.app` once, check `auval -v aufx 0001 CONJ`, then quit the host app (`osascript -e 'quit app "ConjureDSP"'`). Skip if the current Release build already validates.

## Step 3: Stage Logic

1. `rsync -a --delete Demo.logicx/ Take.logicx/`, then `open Take.logicx`.
2. Keep Logic a maximized normal window. Never full screen: the companion app steals focus and the plug-in window lands on the bare desktop.
3. Set Logic's output to BlackHole 2ch (Settings → Audio → Devices → Apply). Make sure the entry isn't in parentheses (that means offline), and run a 2 s meter test.

## Step 4: The take

Start ffmpeg in the background:
```bash
ffmpeg -y -f avfoundation -framerate 30 -capture_cursor 1 -i "Capture screen 0:BlackHole 2ch" \
  -c:v libx264 -preset ultrafast -crf 23 -pix_fmt yuv420p -c:a aac -b:a 192k \
  ~/Music/ConjureDSP-Demo/captures/raw-takeN.mov
```
Check the file is growing after 3 s. If not, a leftover ffmpeg holds the device: find it with `pgrep ffmpeg` and stop it.

Take a fresh screenshot before every click.
1. Space to start the loop.
2. Audio FX slot → hover (don't click) Audio Units → ConjureDSP → ConjureDSP → click Stereo.
3. ConjureDSPTerminal shows a "Ready (MCP…)" window about 2 s later: close it, click the plug-in title bar.
4. Click Terminal, wait for the prompt, click the input, type the prompt, press Return.
5. Every 90–100 s, screenshot until the final summary appears (5–10 min). A new `.cdp` in the App Group `Presets/` folder confirms it.
6. Finale: UI tab (turn on "Custom UI" if off), 2–3 slow XY moves with 4–5 s pauses, Bypass on 5 s, off 7 s.
7. Stop Logic with Space, then `pkill -INT -f raw-takeN.mov` and confirm with `pgrep`.

If a setup dialog appears in the embedded terminal, press Esc; never confirm a settings change. If a crash or other dialog appears that the screen-control tool can't click, stop the take and report it. Never click it with System Events or any other script.

## Re-recording without a new generation

Each embedded-agent run saves a transcript under `~/.claude/projects/-Users-michaeljancsy-Library-Application-Support-ConjureDSP-agent-workspace/`. `~/.conjuredsp-demo/replay.py` replays one in the terminal pane for free: `/exit` the CLI, then `clear; REPLAY_HOLD=20 REPLAY_TOTAL=170 python3 ~/.conjuredsp-demo/replay.py` (`REPLAY_SESSION` picks a transcript). Load the finished preset first so the finale is real. This is a re-enactment; say so if asked whether it was live.

## Step 5: Check and export

1. `ffprobe` the streams; `volumedetect` (mean below -60 dB means the audio routing was wrong).
2. Grab and read 3–4 frames to check for stray windows.
3. `ffmpeg -i raw.mov -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p -c:a aac -b:a 192k demo-<slug>-<date>.mp4` into `~/Projects/ConjureDSP/conjuredsp-marketing/Videos/`. Keep the raw .mov. No speed-ups unless asked.
4. Send the mp4 if it is 30 MiB or less; otherwise send a 960 px, crf 30 preview.

## Step 6: Put things back

Set Logic's output back to the MacBook Pro speakers, quit Logic (Take.logicx is disposable), stop caffeinate, and `screen-turn release --who "<same title>"`. Leave the generated preset in the library.
