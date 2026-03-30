# ConjureDSP Teaser Video — Production Guide

A step-by-step guide for producing the 60–90 second hero demo video. This is the single most important marketing asset for launch.

**Goal:** Show the "prompt to audio effect" magic moment — user types a natural language request, Claude Code writes the DSP code, and you hear the effect transform the audio live. No narration, no fluff. The visual is self-explanatory.

**Target length:** 60–90 seconds (teaser), with 15–30 second clips cut from the same footage for social.

**Tone:** Clean, confident, slightly futuristic. Dark UI on a dark background. Let the product speak.

**Audience:** Audio developers, music producers, creative coders.

---

## 1. Pre-Production Setup

### Screen Recording Software

Pick one:

| Tool | Cost | Pros | Cons |
|------|------|------|------|
| **OBS Studio** | Free | Best quality, flexible scenes, can composite multiple sources | Steeper learning curve |
| **ScreenFlow** | $169 | Built-in editing, good macOS integration | Paid |
| **macOS Screenshot** (Cmd+Shift+5) | Free | Zero setup, records system audio natively on macOS 15+ | No scene composition, limited editing |

**Recommendation:** OBS for the best result, macOS Screenshot for quick iteration while rehearsing.

### Display Settings

- **Resolution:** Record at Retina resolution (2560x1600 on 14" MBP, 3024x1964 on 16"). Export will downscale to 1080p/4K.
- **Scaling:** Use "Default" or "More Space" in System Settings > Displays — you want the plugin UI and DAW to both be readable.
- **Dark mode:** ON. ConjureDSP and Monaco editor look best in dark mode.
- **Clean desktop:** Hide all desktop icons. Set a plain dark wallpaper (solid dark gray or black).
- **Dock:** Auto-hide (System Settings > Desktop & Dock > Automatically hide and show the Dock).
- **Menu bar:** Hide the clock and Spotlight icon if possible. Turn on Do Not Disturb to suppress notifications.
- **Cursor:** Default macOS cursor. Don't use a custom cursor — it looks unprofessional.

### DAW Setup (Logic Pro)

1. Open Logic Pro with a single-track project.
2. Load an audio loop that sounds good dry but will clearly benefit from an effect. Good choices:
   - A clean electric guitar loop (effects like distortion, chorus, or filter are dramatically audible)
   - A drum loop (compression, saturation, bit crush are obvious)
   - A synth pad (reverb, phaser, tremolo are clearly visible on the spectrogram)
3. Insert ConjureDSP on the channel strip (Audio FX slot).
4. Set the loop to repeat so audio plays continuously during recording.
5. Resize the Logic window to fill roughly the left 40% of the screen (or use a single-window layout where the plugin floats over the arrangement).

### ConjureDSP App State

- Start with the **Passthrough** preset (empty editor, no effect applied). The audio should be passing through unprocessed.
- Make sure the **spectrogram** is visible (it provides dramatic visual feedback when the effect kicks in).
- Expand the **parameter sliders panel** — you'll want sliders visible for the moment after the script loads.
- Clear any error messages from previous sessions.
- Have the **Claude Code terminal** tab ready (or visible in a split if the UI supports it).

### Audio Routing

You need to capture the DAW audio output in the screen recording:

- **OBS:** Add an "Audio Output Capture" source pointed at your audio interface or BlackHole virtual audio device. Route Logic's output through BlackHole.
- **ScreenFlow:** Captures system audio natively — just enable "Record Computer Audio."
- **macOS Screenshot (Cmd+Shift+5):** On macOS 15+, captures system audio by default.
- **Verify levels:** Do a 10-second test recording, play it back, confirm audio is clean and loud enough (peak around -6 dB).

---

## 2. Storyboard

Seven scenes. Total runtime target: 70 seconds. Times below are approximate — adjust in editing.

### Scene 1: The Setup (0:00–0:08)

**What's on screen:** Logic Pro with a track playing a clean guitar loop. ConjureDSP is inserted and visible — the editor is empty (Passthrough preset), audio passes through unaffected. Spectrogram shows the raw input signal.

**Purpose:** Establish context. Viewer sees a DAW, hears dry audio, sees an empty plugin.

**Text overlay:** None yet. Let the viewer take in the scene.

### Scene 2: The Prompt (0:08–0:18)

**What's on screen:** User clicks into the Claude Code terminal and types a natural language prompt.

**Prompt to type:** "make a warm tape saturator with drive, tone, and mix controls"

**Purpose:** This is the hook. The viewer sees someone typing English into an audio plugin. Unexpected and intriguing.

**Text overlay (optional):** "Write audio effects with code and AI" — appears as the user starts typing.

**Tips:**
- Type at a natural pace, not too fast. The viewer needs to read the prompt.
- Rehearse this 5+ times. You want a clean take where the AI responds well on the first try.
- If the AI's first response isn't ideal, start over. Don't show iteration in the teaser — save that for the longer demo.

### Scene 3: Claude Code Writes the Code (0:18–0:35)

**What's on screen:** Claude Code streams its response. Code appears in the Monaco editor in real-time. The terminal shows tool calls (compile_and_run, set_parameter, etc.).

**Purpose:** The "wow" moment. An AI is writing real DSP code live.

**Editing note:** **Speed this up 2–4x in post.** Claude Code takes 15–30 seconds to write a full script. In the teaser, compress this to ~10 seconds. The viewer doesn't need to read every line — they need to see code flowing rapidly and feel the speed.

**Text overlay (optional):** None. Let the code speak.

### Scene 4: The Audio Transforms (0:35–0:45)

**What's on screen:** The script finishes compiling. The "Run" indicator shows success. Parameter sliders appear with real labels (Drive, Tone, Mix). **The audio changes audibly** — the dry guitar now has warm saturation.

**Purpose:** The payoff. Prompt → code → sound. This is the moment people will remember.

**Editing note:** Keep this at **real speed**. The transition from dry to processed audio is the most important moment in the video. Don't rush it. Let the viewer hear the before/after.

**Spectrogram:** Should visibly change — harmonics appear, the frequency content shifts. This adds a visual exclamation mark to the audio change.

### Scene 5: Parameter Tweaking (0:45–0:55)

**What's on screen:** User moves the Drive slider up — sound gets grittier. Moves the Tone knob — brightness changes. Adjusts Mix — blend between dry and wet.

**Purpose:** Show that this isn't a one-shot trick. The generated effect has real, tweakable parameters that respond in real-time.

**Spectrogram:** Reacts to each parameter change. Visually satisfying.

**Tips:**
- Move sliders slowly and deliberately. Each adjustment should be audible.
- Pause briefly between slider movements so the viewer can hear each change.

### Scene 6: Quick Versatility Cut (0:55–1:05)

**What's on screen:** Quick cut to a different scene — either:
- **Option A:** A Rust script compiling to WASM, showing the "Compiling..." → "Ready" transition. Different sound (e.g., a ping-pong delay or phaser on a drum loop).
- **Option B:** The community preset browser, scrolling through presets, clicking to load one. Instant audio change.
- **Option C:** The spectrogram in difference mode, showing a colorful before/after visualization.

**Purpose:** Show breadth. The product isn't just "AI writes Python" — it's a whole ecosystem of scriptable audio.

**Editing note:** This is a fast cut, 5–10 seconds max. Don't linger. It's a taste, not a demo.

### Scene 7: End Card (1:05–1:15)

**What's on screen:** Fade or cut to a clean end card.

**Contents:**
- Product name: **ConjureDSP**
- Tagline: "Write audio effects with code and AI"
- URL: conjuredsp.com
- Price: "$10/mo or $50/yr"
- App icon

**Background:** Solid dark (#1a1a1a or similar). Keep it minimal.

**Duration:** 5–8 seconds. Long enough to read, short enough to not overstay.

---

## 3. Recording Tips

### Rehearse Before Recording

- Run through the full flow 3–5 times before hitting record.
- Test your Claude Code prompt until you get a consistently good response. The AI is non-deterministic — some prompts produce cleaner results than others.
- Good prompts for the teaser (pick one):
  - "make a warm tape saturator with drive, tone, and mix controls"
  - "make a resonant lowpass filter with an LFO on the cutoff frequency"
  - "build a stereo ping-pong delay with tempo sync, feedback, and mix"
  - "create a 3-band parametric EQ with frequency, gain, and Q for each band"
- The best prompt is one where the effect is **audibly dramatic** and the parameters are **visually interesting** (multiple sliders with meaningful names).

### During Recording

- **Mouse movements:** Slow, deliberate, no jittery movements. Move in straight lines. Pause briefly before clicking.
- **Multiple takes:** Record 5+ complete takes. Pick the best one in editing. Storage is cheap.
- **Don't stop on mistakes:** If Claude Code produces a slightly imperfect result, keep going — you can cut around it. If it completely fails, start the take over.
- **Let audio breathe:** After the effect activates (Scene 4), let the audio play for at least 3–4 seconds before touching anything. The viewer needs to hear the change.

### Common Pitfalls

- Notification pops up mid-recording → Use Do Not Disturb
- DAW audio crackles/glitches → Increase buffer size to 512 or 1024 before recording
- Claude Code response is slow → Rehearse at a time with good API latency (avoid peak hours)
- Spectrogram doesn't look dramatic → Choose an effect with strong harmonic content (saturation, distortion, ring mod)
- Mouse cursor lingers in an awkward spot → Move it to the edge of the screen when not clicking

---

## 4. Audio Guidance

### DAW Audio (Primary)

The DAW audio is the star. Pick source material where the before/after is unmistakable:

- **For saturation/distortion effects:** Clean electric guitar, clean synth lead, or acoustic drums
- **For filter effects:** Full-spectrum synth pad or rich chord progression
- **For delay/modulation effects:** Sparse guitar riff or plucked synth with space between notes
- **For compression/dynamics:** Drum loop with dynamic variation

**Avoid:** Heavily processed source material, full mixes (too complex to hear the effect), very quiet or very short clips.

### Background Music Bed (Optional)

A subtle ambient music bed underneath the screen recording can make the video feel more polished. It should:
- Be very quiet — barely perceptible under the DAW audio
- Be ambient/textural (pads, drones) — no prominent melodies or beats that compete with the DAW audio
- Fade in at the start, fade out before the end card
- Be royalty-free or licensed for commercial use

Sources for royalty-free ambient music:
- Artlist.io ($17/mo)
- Epidemic Sound ($15/mo)
- Free Music Archive (free, CC-licensed)
- Create your own ambient pad in a synth — fitting for an audio plugin product

**If in doubt, skip the music bed.** The DAW audio alone is compelling enough.

### No Voiceover

The teaser has no narration. Text overlays handle any messaging. This keeps the video:
- Language-independent (shareable globally)
- Faster-paced (no waiting for someone to finish a sentence)
- Focused on the visual/audio magic

Save voiceover for the longer 5–10 minute YouTube walkthrough.

---

## 5. Editing Workflow

### Recommended Editors

| Editor | Cost | Best for |
|--------|------|----------|
| **DaVinci Resolve** | Free | Best free option, professional color/audio, speed ramping |
| **Final Cut Pro** | $300 | Fast on Apple Silicon, great for macOS screen recordings |
| **iMovie** | Free | Simplest option, fine for a straight cut with text overlays |

**Recommendation:** DaVinci Resolve if you want the best result for free. Final Cut Pro if you already own it.

### Edit Structure

1. **Import** your best take(s) into the timeline.
2. **Trim** to start right as the DAW audio begins playing (Scene 1). Cut any dead time at the beginning.
3. **Speed ramp Scene 3** (Claude Code writing code): Select the section, apply 2–4x speed. In DaVinci Resolve: right-click clip > Change Clip Speed. In Final Cut Pro: Cmd+R, set to 200–400%.
   - Keep the speed change smooth — use a brief ramp (0.5s) into and out of the fast section rather than a hard cut to fast-forward.
4. **Keep Scene 4 at 1x speed.** The audio transformation must feel real-time.
5. **Add text overlays:**
   - Scene 2 (as user types): "Write audio effects with code and AI"
   - Scene 6 (versatility cut): "Python or Rust. Hear it instantly."
   - Use a clean sans-serif font (SF Pro, Inter, or Helvetica Neue). White text, slight drop shadow or dark background pill for readability over the UI.
   - Animate in with a simple fade (0.3s). No spinning or bouncing text.
6. **Scene 7 end card:** Create in Figma, Keynote, or directly in the editor. Dark background, centered text, app icon.
7. **Color grading:** Minimal. The dark-mode UI already looks good. At most:
   - Slight contrast boost
   - Very subtle vignette to draw focus to the center
   - Don't warm/cool the image — the editor syntax highlighting colors should remain accurate.
8. **Audio mixing:**
   - DAW audio: -6 dB to -3 dB (prominent but not clipping)
   - Background music bed (if used): -18 dB to -24 dB (barely audible)
   - Apply a gentle limiter on the master to prevent clipping

### Pacing

The most common mistake in demo videos is **lingering too long** on any one moment. Every second should show something new or build anticipation. Target:

- Scene 1 (setup): 8 seconds max
- Scene 2 (typing prompt): 10 seconds
- Scene 3 (code generation, sped up): 10–15 seconds
- Scene 4 (audio transforms): 8–10 seconds
- Scene 5 (parameter tweaking): 10 seconds
- Scene 6 (versatility): 5–10 seconds
- Scene 7 (end card): 5–8 seconds

Total: ~60–75 seconds. If it's running long, cut Scene 6 shorter first.

---

## 6. Export Settings

### YouTube / Website (Primary)

- **Resolution:** 3840x2160 (4K) if you recorded at Retina resolution, otherwise 1920x1080 (1080p)
- **Codec:** H.264 (widest compatibility) or H.265/HEVC (better quality at lower bitrate, YouTube re-encodes anyway)
- **Bitrate:** 35–45 Mbps for 4K, 15–20 Mbps for 1080p
- **Frame rate:** 60 fps (screen recordings look noticeably smoother at 60 fps)
- **Audio:** AAC, 320 kbps, stereo
- **Container:** .mp4

### YouTube Shorts / TikTok / Instagram Reels (Vertical)

- **Aspect ratio:** 9:16 (1080x1920)
- **Crop strategy:** Center the crop on the ConjureDSP plugin window. The DAW arrangement view can be cropped out — it's not essential for the short clip.
- **Same codec/bitrate settings** as above, but at 1080x1920.

### Twitter/X

- **Aspect ratio:** 16:9 (1920x1080) or 1:1 (1080x1080)
- **Max file size:** 512 MB (not usually an issue for 60–90 sec)
- **Twitter compresses aggressively** — upload the highest quality file you have. 1080p H.264, 15+ Mbps.

### Thumbnail

Pick a frame where:
- The Monaco editor shows code (syntax highlighting visible)
- The spectrogram is active and colorful
- Parameter sliders are visible with labels
- The overall image reads well at small sizes (thumbnail on YouTube)

Export this frame as a PNG. Add the product name and a short hook in bold text ("AI writes audio effects") using Figma or Canva.

---

## 7. Social Clip Cut-Down Guide

From the hero footage, extract 3–4 short clips (15–30 sec each) for social platforms:

### Clip 1: "Prompt to Effect in 30 Seconds"
- **Scenes:** 2 → 3 (sped up) → 4
- **Duration:** 20–30 seconds
- **The hook:** Typing a natural language prompt, code appears, audio transforms.
- **Best for:** Twitter/X, YouTube Shorts, TikTok
- **Text overlay:** "prompt to audio effect in 30 seconds"

### Clip 2: "Spectrogram Before/After"
- **Content:** Side-by-side or toggle between input and output spectrogram
- **Duration:** 10–15 seconds
- **The hook:** Visually striking — colors and patterns change dramatically
- **Best for:** Twitter/X (visual content performs well), Instagram
- **Text overlay:** "before / after"

### Clip 3: "Fix My Distortion"
- **Record a separate take:** Start with a broken script (intentional error), ask Claude Code "this sounds too harsh, make the saturation warmer", watch it fix and improve the code.
- **Duration:** 20–30 seconds
- **The hook:** AI debugging and iterating on audio code
- **Best for:** Reddit, HN comments (technical audience)

### Clip 4: "Python to Standalone Plugin"
- **Content:** Show the export flow — click Export, name the plugin, see the standalone AUv3 created
- **Duration:** 15–20 seconds
- **The hook:** Turn your script into a distributable audio plugin
- **Best for:** Audio developer forums, r/AudioPlugins

---

## 8. Quick Reference Checklist

### Before recording
- [ ] Dark mode on, clean desktop, Do Not Disturb on
- [ ] Dock hidden, notification badges off
- [ ] DAW project open with audio loop playing and repeating
- [ ] ConjureDSP inserted, Passthrough preset loaded
- [ ] Spectrogram visible, parameter panel expanded
- [ ] Claude Code terminal ready
- [ ] Screen recording tool configured and tested (10-sec test recording verified)
- [ ] Audio routing confirmed (DAW output captured in recording)
- [ ] Buffer size increased (512+) to prevent audio glitches
- [ ] Claude Code prompt rehearsed 3–5 times

### After recording
- [ ] Best take selected
- [ ] Scene 3 speed-ramped (2–4x)
- [ ] Text overlays added
- [ ] End card created and appended
- [ ] Audio levels balanced
- [ ] Exported at 4K/1080p H.264 60fps
- [ ] Thumbnail exported as PNG
- [ ] 3–4 social clips cut from hero footage
- [ ] Vertical (9:16) versions created for Shorts/TikTok/Reels
