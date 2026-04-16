# ConjureDSP — Competitive Landscape

_Last updated: 2026-04-16_

ConjureDSP is an AUv3 audio effect plugin for macOS that lets users write DSP scripts in Python or Rust. This document summarizes the current competitive landscape and tracks specific competitors of interest.

## Direct Competitors (Scriptable Plugin Hosts)

No new direct competitors have launched in the AUv3 / Python / Rust scriptable-plugin space as of this check. The established players:

- **Blue Cat's Plug'n Script** — Commercial scripting plugin using AngelScript. Supports VST, VST3, AU, AAX. On-the-fly compilation, custom UI. Most feature-complete commercial analog to ConjureDSP, but uses AngelScript rather than mainstream languages.
- **Protoplug** (Open Source Audio Research) — Free/open-source Lua/LuaJIT scripting plugin for VST/AU on Windows, Linux, macOS. Mature but development activity is minimal.

**ConjureDSP's positioning remains distinctive**: no competitor exposes Python or Rust as the end-user scripting surface inside an AUv3 plugin.

## Adjacent / Framework Players (not direct competitors)

- **NIH-plug** — Rust framework for *developers* building VST3/CLAP plugins. Not a runtime scripting host for end users.
- **iPlug3** — C++ plugin framework with optional Python/Node bindings for testing and server-side rendering, not in-DAW scripting.
- **PyPhonic** — Experimental Python VST. Hobbyist-scale, not a commercial product.
- **JUCE** — Dominant C++ plugin framework. Not scriptable.

## Emerging Adjacent Category — AI Text-to-DSP

A new category has emerged in 2026 that overlaps ConjureDSP's "roll your own plugin in your DAW" value proposition but via natural-language prompting rather than code. Amorph is the flagship; multiple smaller AI FX/instrument generators are also appearing. Worth monitoring as a separate vector that may shape user expectations.

## Amorph (Artists in DSP) — Detailed Tracking

### Product summary
- Free / pay-what-you-like "Text-to-DSP" plugin powered by the **Cmajor** language.
- Formats: VST3, AU, CLAP. Platforms: macOS 10.15+ and Windows 10/11.
- **No AUv3 or iOS support** as of this check — desktop-only. This is a meaningful differentiator in ConjureDSP's favor if mobile/iOS AUv3 matters to your roadmap.
- Workflow: three stages — **Ask** (user prompts an external LLM like ChatGPT or Gemini to generate Cmajor code), **Compile** (paste code into Amorph), **Play** (auto-generates knob UI for all parameters). Users can also edit/write Cmajor directly.

### Timeline
- **Feb 2026** — Open beta announced; wide press coverage (MusicTech, Bedroom Producers Blog, Synthtopia, Gearspace, Sonic State, We Rave You, Rekkerd, Audio Plugin Guy, The Beat Community, Musixon).
- **Apr 3, 2026** — Major visual overhaul shipped: **custom user interfaces** — users can design and tweak per-patch plugin appearance (e.g., modern FX vs. vintage synth looks).

### Reception
- **Positive** among Discord beta testers. Representative quotes: "Hard to describe how awesome this thing is"; "I just built a 13-plugin modular MATAMP, and it sounds pretty much like a DOOM amp."
- **Skeptical** voices on forums raise the AI-hallucination / debugging cost concern: "there's like 10 different ai fx/instrument generation tools out there. Who the hell has time to debug hallucinated outputs?"
- Press tone is broadly enthusiastic; no significant negative reviews.

### Pricing & business model
- Still free / pay-what-you-like. No pricing change since launch. Still in open beta — no 1.0 / paid tier announced.

### Likely next moves to watch
- AUv3 / iOS support (would directly contest ConjureDSP's turf).
- In-plugin LLM integration (currently requires pasting from external LLMs — a friction point likely to be closed).
- Preset / patch sharing marketplace.

## Strategic Takeaways for ConjureDSP

1. **Core positioning is intact.** Python + Rust + AUv3 remains unique. No direct competitor has launched in this niche.
2. **Primary pressure is indirect** and comes from AI text-to-DSP (Amorph). Different workflow (prompt vs. code), but competing for the same "build your own plugin in your DAW" mindshare.
3. **Differentiators to lean on**:
   - AUv3 / iOS reach (Amorph is desktop-only).
   - Mainstream languages (Python / Rust) vs. Cmajor or AngelScript.
   - Deterministic, debuggable code written by the user vs. LLM-generated Cmajor requiring debugging of hallucinations.
4. **Watch list**: Amorph AUv3/iOS support, Amorph in-plugin LLM, any new Rust-based scripting plugin leveraging `nih-plug`, and further entrants in the AI text-to-DSP category.

## Sources

- [Amorph GUI update – Bedroom Producers Blog, Apr 3 2026](https://bedroomproducersblog.com/2026/04/03/amorph-gui-update/)
- [Amorph initial release – Bedroom Producers Blog, Feb 11 2026](https://bedroomproducersblog.com/2026/02/11/artists-in-dsp-amorph/)
- [Amorph Review – We Rave You](https://weraveyou.com/2026/03/amorph-review-build-your-own-plugins-with-ai/)
- [Amorph announcement – Gearspace](https://gearspace.com/board/new-product-alert/1460848-artists-dsp-announces-amorph-prompt-driven-audio-plugin-early-access.html)
- [Amorph – Synthtopia](https://www.synthtopia.com/content/2026/02/18/new-ai-based-plugin-amorph-lets-you-create-new-effects-instruments-right-in-your-daw/)
- [Amorph – MusicTech](https://musictech.com/news/music/artists-in-dsp-amorph/)
- [Amorph – Audio Plugin Guy](https://www.audiopluginguy.com/news-artists-in-dsp-has-released-amorph-a-free-plugin-that-turns-plain-english-text-into-working-audio-effects-and-instruments/)
- [Amorph Gumroad page](https://artistsindsp.gumroad.com/l/amorph)
- [Blue Cat's Plug'n Script](https://www.bluecataudio.com/Products/Product_PlugNScript/)
- [Protoplug – OSAR](https://www.osar.fr/protoplug/)
- [ConjureDSP beta thread – KVR](https://www.kvraudio.com/forum/viewtopic.php?p=9228860)
- [NIH-plug (Rust framework)](https://github.com/robbert-vdh/nih-plug)
- [Cmajor](https://cmajor.dev/)
