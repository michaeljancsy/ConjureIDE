# Competitive Landscape

ConjureDSP sits at the intersection of programmable audio and traditional plugin UX — a code editor embedded in an AUv3 effect that lets users write DSP in Python or Rust, with AI assistance, and export presets as standalone plugins.

## Direct Competitors

### FAUST

Functional DSP programming language that compiles to AU, VST, and other targets. Mature project with academic roots and a dedicated community. Free and open-source. The language is purpose-built for DSP, which makes it expressive but comes with a steep learning curve. No built-in editor-as-plugin experience — the workflow is offline compilation followed by loading the result into a DAW.

### Cabbage + Csound

Text-based DSP authoring with plugin export. Long history in academic and experimental audio. Csound's syntax is powerful but niche, making it less approachable than Python for newcomers. The tooling is functional but dated compared to modern developer environments.

### plugdata (Pure Data in a plugin)

Open-source project that packages Pure Data's visual patching environment inside a VST/AU plugin. Growing community, active development. Different paradigm from ConjureDSP — visual dataflow patching rather than text-based coding. Lower barrier to entry for non-programmers but less precise control than code.

## Adjacent Products

### Max/MSP / Max for Live

Industry standard for prototyping and performing with custom audio. Visual patching environment. The Max for Live integration is Ableton-exclusive, which limits reach. Expensive standalone license. Powerful but complex — projects can become unwieldy. Not a traditional "plugin you load in any DAW" experience.

### Reaktor (Native Instruments)

Visual and low-level DSP building environment. Ships as a plugin with a large library of user-created instruments and effects. Powerful, with a dedicated builder community, but complex to author in. More consumer-oriented than FAUST/Csound — many users load presets rather than build from scratch.

### VCV Rack

Modular synthesizer simulator available as a standalone app and plugin. Focus is on emulating hardware Eurorack modules. Large ecosystem of free and paid modules. Different target audience — hardware modular enthusiasts rather than DSP programmers.

### RNBO (Cycling '74)

Export Max patches as compiled VST/AU plugins. Bridges visual patching to distributable plugin output. Requires Max license and familiarity with the Max environment. More of a plugin development tool than a live-coding environment.

## Lower-Level Frameworks

### JUCE

C++ framework and the industry standard for commercial plugin development. Requires full C++ expertise. Not an end-user product — it's the tool that plugin companies use to build their products. Relevant as context for where ConjureDSP fits: it offers a dramatically simpler path to a working audio effect than writing C++ against JUCE.

## ConjureDSP's Differentiators

**Python as a DSP language.** The barrier to entry is dramatically lower than FAUST, Csound, or C++. Python is the most widely known programming language, and numpy/scipy provide production-grade DSP primitives. No competitor offers Python as a first-class DSP authoring language inside a plugin.

**AI-assisted coding.** The integrated Claude Code terminal is unique in this space. No competing product offers AI assistance for writing DSP code. This has the potential to expand the addressable audience beyond programmers to producers and sound designers who can describe what they want in natural language.

**Dual-language support.** Python for rapid prototyping, Rust compiled to WASM for production performance. No competitor offers this kind of gradient — users can start in Python and graduate to Rust when performance matters, without changing tools.

**Export presets as standalone AUv3 plugins.** Users can ship their own audio plugins without maintaining a build toolchain, signing certificates, or understanding plugin architecture. This turns ConjureDSP from a tool into a platform.

**Runs inside the DAW.** The edit-compile-listen loop happens in the plugin window. FAUST, Cabbage, and Csound all require an offline compile step followed by reloading the plugin. ConjureDSP's workflow is closer to a REPL.

**Community preset sharing.** GitHub-based preset browsing and personal repo sync. Effects are shareable as single files rather than compiled binaries.

## Key Risks

**Niche audience.** The intersection of "DAW users" and "people who write code" is small. AI coding assistance expands this, but the product still requires comfort with a code editor. Market sizing is uncertain.

**macOS and AUv3 only.** No Windows support and no VST3 format limits the total addressable market significantly. Most commercial plugins ship cross-platform. Windows DAW users (a large segment) are entirely unreachable.

**Python performance ceiling.** Real-time audio processing in Python has inherent throughput and latency constraints compared to compiled code. The Rust/WASM path mitigates this, but the Python experience is the primary onramp and its limitations will surface for complex effects or low-latency requirements.

**Free and open-source competition.** FAUST, plugdata, and Cabbage are all free. Competing on price with open-source is difficult for the expert segment who already know these tools. The value proposition needs to be strong enough to justify a subscription.

**Single-developer risk.** As a solo project, development velocity, support capacity, and bus factor are all constrained.

## Strategic Opportunities

**AI as the primary interface.** If the value proposition shifts from "write your own DSP code" to "describe the effect you want and AI builds it," the addressable market expands well beyond programmers. Producers and sound designers who would never write Python could still use ConjureDSP through natural language. The Claude Code terminal integration is early but points in this direction.

**Export as a platform play.** The ability to export standalone AUv3 plugins creates a potential marketplace dynamic. Users who build effects could distribute or sell them. ConjureDSP becomes the authoring tool for a new class of plugin creators.

**Education market.** Python + real-time audio feedback is a compelling teaching tool for DSP courses. Academic adoption could drive awareness and create a pipeline of users who graduate to professional use.

**Cross-platform expansion.** Adding Windows/VST3 support would dramatically increase the addressable market, though the engineering investment is substantial given the deep macOS/AUv3 integration.
