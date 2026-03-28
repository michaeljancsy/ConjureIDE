# ConjureDSP Marketing & Promotional Plan

## Context

ConjureDSP is an AUv3 audio effect plugin for macOS where users write DSP code (Python or Rust) that runs in real-time inside their DAW. The upcoming headline feature is **Claude Code embedded directly in the plugin** — a full AI coding agent terminal inside an audio plugin, a first for the industry. Users bring their own Claude Code subscription.

**Pricing:** $10/month or $50/year
**Budget:** ~$500–2k for launch marketing
**Audience:** Audio developers, musicians/producers, and creative coders

---

## Positioning & Core Message

**One-liner:** "Write audio effects with code and AI — inside your DAW."

**Elevator pitch:** ConjureDSP is a programmable audio plugin with Claude Code built in. Describe the sound you want, and the AI writes, compiles, and tests the DSP code in real time. Or write it yourself in Python or Rust. Either way, you hear the result instantly.

**Key differentiators to emphasize:**
1. **Claude Code inside an audio plugin** — not a chatbot, a full coding agent that can write, compile, run, debug, adjust parameters, and iterate autonomously
2. **Instant feedback loop** — write code, hear it immediately in your DAW signal chain
3. **Two languages** — Python (instant load, numpy/scipy) for prototyping, Rust/WASM for performance
4. **Export as standalone plugin** — turn your script into a distributable AUv3
5. **Community presets via GitHub** — browse, share, and remix other people's effects

---

## Launch Campaign Strategy

### Phase 1: Pre-Launch Tease (1–2 weeks before launch)

**Hero demo video (most important asset):**
- 60–90 second screen recording showing the magic moment: user opens ConjureDSP in a DAW, types a natural language prompt into Claude Code like "make a resonant lowpass filter with an LFO on the cutoff", and the AI writes the Python, compiles it, and you hear the effect on the audio — all in one take
- No narration needed, just screen capture with DAW audio playing. The visual is self-explanatory and shareable.
- End card: product name, price, URL
- This is the single most important marketing asset. Budget ~$0 (you can record this yourself)

**Shorter clips for social (15–30 sec each):**
- "Prompt to effect in 30 seconds" — just the Claude Code interaction, compressed
- "Fix my distortion" — show Claude Code diagnosing and fixing a broken script
- "From Python to standalone plugin" — show the export flow
- "Spectrogram before/after" — visually satisfying A/B comparison

**Where to post tease content:**
- Twitter/X (audio dev and music production communities are active here)
- YouTube Shorts / TikTok (the "prompt → hear it" loop is perfect for short-form)
- Mastodon (audio dev community has presence)
- Personal accounts + tag @AnthropicAI

### Phase 2: Launch Day

**Channels (organic, free):**

1. **Hacker News** — "Show HN: I built an audio plugin with Claude Code embedded inside it"
   - HN loves: novel AI applications, creative coding, Rust, Python, technical depth
   - Write a concise post focusing on the technical architecture (embedded Python 3.14 free-threaded, Rust→WASM, Claude Code agent with 9 tools)
   - Be available to answer comments for the first few hours
   - This is probably the highest-leverage single action for launch

2. **Reddit** (multiple subreddits, stagger posts over a few days):
   - r/AudioPlugins — direct target audience
   - r/synthesizers — overlaps with people who enjoy sound design from scratch
   - r/DSP — technical audience, focus on the Python/Rust DSP angle
   - r/musicproduction — broader, lead with "AI writes your effects"
   - r/programming — "Claude Code embedded in a real-time audio plugin" angle
   - r/rust — Rust→WASM DSP pipeline angle
   - r/ClaudeAI — Claude Code showcase
   - r/MacApps — macOS native app spotlight

3. **Audio developer forums:**
   - KVR Audio forum (largest plugin community)
   - JUCE forum (devs who build plugins, would appreciate the architecture)
   - The Audio Programmer Discord

4. **YouTube** — longer-form demo video (5–10 min):
   - Full walkthrough: install, open in DAW, write a script, use Claude Code, export
   - Show both beginner flow (Claude Code does everything) and power-user flow (hand-written Rust)
   - Good for SEO ("programmable audio plugin", "AI audio effect", "write DSP in Python")

5. **Anthropic ecosystem:**
   - Submit to Anthropic's showcase / customer stories (they actively feature Claude Code integrations)
   - Post in Claude Code community channels
   - This is a genuinely novel integration — Anthropic has incentive to amplify it

**Channels (paid, from budget):**

6. **Targeted YouTube/podcast sponsorship** (~$500–1000):
   - The Audio Programmer YouTube channel (perfect audience overlap)
   - ADC (Audio Developer Conference) community channels
   - A music production YouTuber who's also code-curious

7. **KVR Audio listing** (free basic, ~$50–100 for featured):
   - Product database entry (standard for any plugin)
   - Optional promoted listing during launch week

### Phase 3: Post-Launch (ongoing)

**Content flywheel:**
- Weekly "Preset of the Week" showcasing a community preset from GitHub — builds the community store and gives people reasons to share
- Short tutorial clips: "How to build a chorus in 20 lines of Python", "Sidechain compressor with Claude Code"
- User-generated content: retweet/share anyone who posts about ConjureDSP

**Community building:**
- Discord server for ConjureDSP users (preset sharing, help, feature requests)
- GitHub Discussions on the community preset repo
- Encourage users to publish their presets to GitHub (the sharing flow is already built)

**SEO / evergreen content:**
- Landing page optimized for "programmable audio plugin", "AI audio effect plugin", "write DSP code in DAW"
- Blog posts / tutorials that rank for DSP learning queries ("how to write a reverb in Python", "real-time audio processing with numpy")

---

## Messaging by Audience

### For audio developers / DSP engineers:
- Lead with: rapid prototyping, Python + Rust, instant compilation, export to standalone AU
- "Prototype effects in Python, ship them in Rust — all inside your DAW"
- Technical details matter: free-threaded Python 3.14, numpy/scipy, wasmtime, fuel metering
- The Claude Code angle: "AI pair-programmer for DSP"

### For musicians / producers:
- Lead with: describe what you want, AI builds it
- "Your own personal DSP engineer, inside your DAW"
- Show the before/after spectrogram — make it visual
- Emphasize: no coding experience needed, Claude Code handles it
- Community presets as entry point (browse and tweak before writing from scratch)

### For creative coders:
- Lead with: live coding audio, Python in real-time, the joy of hearing your code
- "Like Processing or p5.js, but for sound — running live in your DAW"
- The export feature: turn your experiments into real plugins
- GitHub integration as a sharing/remix culture enabler

---

## Launch Checklist

- [ ] Landing page live with buy + download flow (Paddle + GitHub Releases)
- [ ] Hero demo video recorded and edited (60–90 sec)
- [ ] 3–4 short social clips cut from longer footage
- [ ] Longer YouTube walkthrough (5–10 min)
- [ ] HN "Show HN" post drafted
- [ ] Reddit posts drafted for 3–4 subreddits
- [ ] KVR product listing created
- [ ] Discord server set up (or GitHub Discussions enabled)
- [ ] Outreach email to 2–3 YouTube creators / podcasters
- [ ] Submit to Anthropic showcase / press contact
- [ ] Community preset repo seeded with 10+ interesting presets with good READMEs

---

## Budget Allocation

| Item | Est. Cost |
|------|-----------|
| YouTube/podcast sponsorship (1–2 creators) | $500–1000 |
| KVR featured listing | $50–100 |
| Domain + hosting (if not already owned) | $50–100 |
| Miscellaneous (graphics, assets) | $100–200 |
| **Total** | **$700–1400** |

Everything else is organic: your own demo videos, forum posts, social media, Anthropic ecosystem.

---

## What Will Make or Break This

**The demo video is everything.** The "prompt → compile → hear it" loop is inherently viral and visually compelling. If the hero video is good, people will share it. If it's mediocre, nothing else matters. Spend the most time here.

**HN + Reddit are the launch multipliers.** For a technical product at this budget, these communities are where early adopters live. A well-written HN post that hits the front page is worth more than $10k in ads.

**The Anthropic angle is free leverage.** This is one of the most creative Claude Code integrations possible. Anthropic's developer relations team would likely want to feature this. Reach out proactively.

**Community presets are the long-term moat.** The GitHub integration means every shared preset is a piece of marketing content and a reason for new users to try the product. Seed the community store aggressively at launch.
