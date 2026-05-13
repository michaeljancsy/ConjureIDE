//
//  DSPDocumentation.swift
//  ConjureDSPExtension
//
//  Authoritative API reference strings for the conjuredsp library.
//  Used by the MCP get_docs tool and the AI Prompt Helper view.
//

import Foundation

enum DSPDocumentation {

    static let params = """
    # Parameter Builders

    ## Python and Rust use DIFFERENT syntax. Don't mix them.

    Python: `freq(min=0.1, max=20.0, default=4.0)` — keyword args.
    Rust:   `freq().min(0.1).max(20.0).default(4.0)` — fluent chain.

    A common mistake: writing `freq(min=…)` style in a Rust preset, or
    `freq().min(…)` style in a Python preset. Either way the file won't
    compile. The detailed examples below match the language section
    they're under — copy from the right one.

    Available builders and their default ranges:

    freq — 20-20000 Hz, log curve, default 1000 (audio-rate — filters, oscillators)
    lfo_rate — 0.1-20 Hz, log curve, default 1 (sub-audio — tremolo / autopan / chorus rate)
    db — -60 to +12 dB, linear curve, default 0
    time_ms — 0.1-1000 ms, log curve, default 100
    mix — 0.0-1.0, linear, default 0.5
    pct — 0-100%, linear, default 50
    toggle — 0/1, rendered as switch in UI, default 0
    ratio — 1-20 :1, linear, default 4
    param — generic with explicit min/max, default=min, linear, no unit

    ## Python syntax

    Builders are functions that return dicts. Customize via keyword arguments:

      from conjuredsp import freq, db, time_ms, mix, pct, toggle, choice, ratio, param

      PARAMS = {
          "cutoff": freq(),                                # use defaults: 20-20000 Hz
          "attack": time_ms(0.5, 50, default=5),           # positional min/max, keyword default
          "damping": freq(min=500, max=16000, default=4000),  # all keyword args
          "drive": pct(default=70),
          "mix": mix(default=0.35),
          "bypass": toggle(),
          "mode": choice("Low", "Mid", "High", default="Mid"),  # dropdown
      }

    param() accepts: param(min, max, unit="", default=None, curve="linear")

    choice(*labels, default=None) (Python) / choice(&[labels]) (Rust) — Dropdown menu, \
    receives selected index as float (0.0, 1.0, ...). Requires at least 2 labels. Rust \
    spelling: `MODE = choice(&["Low", "Mid", "High"]).default(1.0),`.

    ## Rust syntax

    Builders are const functions. Customize via method chaining:

      params! {
          CUTOFF = freq(),                                  // use defaults: 20-20000 Hz
          ATTACK = time_ms().min(0.5).max(50.0).default(5.0),
          DAMPING = freq().min(500.0).max(16000.0).default(4000.0),
          DRIVE = pct().default(70.0),
          MIX = mix().default(0.35),
          BYPASS = toggle(),
          ROTATE = param(0.0, 360.0).unit("°").default(0.0),  // generic builder
      }

    Chaining methods: .min(val), .max(val), .default(val), .unit("str"), .curve("log" or "linear")
    All are const fn and can be used in static/const contexts. Every builder
    shares the same modifier surface; `freq`, `db`, `time_ms`, `mix`, `pct`,
    `ratio`, `toggle` just preset sensible ranges/units. Use `param(min, max)`
    when none of the typed presets fit (e.g. degrees, semitones, ratios with
    a custom range) — default is `min`, unit is empty, curve is linear; chain
    `.unit().default().curve()` to fill them in.

    ## How parameters are delivered to scripts

    With PARAMS metadata: scripts receive denormalized actual values (e.g., 1000.0 Hz).
    Without PARAMS: scripts receive raw 0-1 normalized floats (legacy mode).
    Python params arg is a dict keyed by name. Rust params are accessed via ctx.param(INDEX).

    ## Python process() signature — copy this verbatim

    The single accepted signature is `def process(ctx):`. Everything the
    DSP needs hangs off `ctx`: input/output buffers, params, transport,
    telemetry, sidechain, and the bundle-private state mapping. This is
    the only shape the kernel will load — older positional forms now
    fail at script load with a clear error.

      import numpy as np
      from conjuredsp import freq, mix

      PARAMS = {
          "drive": freq(min=20.0, max=2000.0, default=200.0),
          "mix": mix(default=0.5),
      }

      def process(ctx):
          drive = ctx.params["drive"]    # also: ctx.params.drive
          mix_v = ctx.params["mix"]
          # ctx.inputs / ctx.outputs are 2D numpy arrays, shape
          # (channels, frame_count), pre-sliced to this block's length.
          # Whole-array ops broadcast across channels — no per-channel
          # Python loop, no [:ctx.frame_count] slicing required.
          wet = np.tanh(ctx.inputs * drive)
          ctx.outputs[:] = (1.0 - mix_v) * ctx.inputs + mix_v * wet

    What hangs off `ctx`:

    - `ctx.inputs` / `ctx.outputs` — 2D `numpy.ndarray[float32]` of shape
      `(channel_count, frame_count)`, pre-sliced to the current block.
      `ctx.inputs.shape[0]` is the channel count. Whole-array ops
      (`np.tanh(ctx.inputs, out=ctx.outputs)`, `ctx.outputs[:] = ctx.inputs * gain`)
      broadcast across both axes; per-channel access via
      `ctx.inputs[ch]` returns a contiguous 1D row view. Writes go
      in-place via `ctx.outputs[:] = …`, `out=ctx.outputs`, or
      row-index assignment `ctx.outputs[ch] = …` — only rebinding
      the attribute itself (`ctx.outputs = …`) is silently
      discarded.
    - `ctx.frame_count` — int, samples in this block. Explicit
      `[:ctx.frame_count]` slicing is unnecessary; the 2D arrays
      already are that slice.
    - `ctx.sample_rate` — float, Hz.
    - `ctx.params` — read-only `ParamsView` when a `PARAMS` dict is
      declared (supports both `ctx.params["name"]` and
      `ctx.params.name` styles; writes raise). Legacy scripts with no
      `PARAMS` dict get a positional list of 0–1 floats.
    - `ctx.transport` — namespace from the host's transport state.
      **Canonical keys** (the kernel publishes them with these exact
      names; pre-rename keys are gone):

      ```python
      ctx.transport.bpm                 # tempo in BPM
      ctx.transport.beat                # current beat position (float)
      ctx.transport.is_playing          # bool
      ctx.transport.time_sig_numerator
      ctx.transport.time_sig_denominator
      ctx.transport.sample_position
      ```

      `ctx.transport` is always present — even when the DAW isn't
      running, fields default to safe values (bpm=120, is_playing=False).
    - `ctx.telemetry` — writable mapping pre-seeded with declared
      `TELEMETRY` slot keys at zero. Write per-block values
      (`ctx.telemetry["gr_db"] = -3.5`) to publish to the host UI's
      `audio.onFrame`. **Reading telemetry from JS also requires
      `manifest.ui.audioFrames: true`** — see the `ui` topic for the
      manifest snippet.
    - `ctx.sidechain` — 2D `numpy.ndarray[float32]` mirroring
      `ctx.inputs`'s shape. Always allocated; zero-filled when the
      host hasn't connected a sidechain bus, so it's safe to read
      unconditionally.
    - `ctx.state` — read-only mapping over the bundle-private STATE
      channel (UI / MCP-writable, audio-readable). Mutating it inside
      `process()` raises AttributeError — write only via
      `ConjureDSP.state.set(...)` (JS) or the MCP `set_state` tool. See
      the `state` topic.

    ## Rust process! macro — copy this verbatim

    Every Rust preset's entry point is the `process! { ctx => /* body */ }`
    macro. It subsumes `setup!()` (buffers, exports), constructs the
    `Context`, and emits the zero-arg `extern "C" fn process()` the host
    expects. Do NOT hand-roll an `extern "C" fn process(...)` — the host
    looks for a zero-arg `process` export and modules with the legacy
    5-arg signature fail to load.

      use conjuredsp::*;

      params! {
          DRIVE = db().min(0.0).max(24.0).default(6.0),
          MIX   = mix().default(0.5),
      }

      process! { ctx =>
          let drive_gain = db_to_gain(ctx.param(DRIVE) as f64) as f32;
          let mix_val    = ctx.param(MIX);

          for c in 0..ctx.channels() {
              for i in 0..ctx.frames() {
                  let dry = ctx.input(c, i);
                  let wet = (dry * drive_gain).tanh();
                  ctx.set_output(c, i, crossfade(dry, wet, mix_val));
              }
          }
      }

    The identifier on the left of `=>` is the name your body uses for
    the `Context`. `ctx` is the canonical name (every factory preset
    uses it), but any identifier works — `process! { c => for f in
    0..c.frames() { … } }` is valid. The `=>` form was chosen over a
    closure-style `|ctx|` so the body's stack frame stays `process`
    instead of `process::{{closure}}::<hash>` in panic / `os_log`
    traces.

    A common mistake — leaving out the `ctx =>` binding entirely —
    triggers a friendly compile error:

      process! { /* body */ }
      // error: process! requires a context binding.
      //        Use: process! { ctx => /* body */ }
      //        (or any identifier in place of `ctx`).

    Per-block state belongs in `persist!(NAME: T = init)` (scalar /
    `Copy` values, accessed via `.get()` / `.set()` / `.replace()`) or
    `persist_buf!(NAME: T = init)` (large arrays / non-Copy types,
    accessed via `.with_mut(|buf| …)`). Both replace raw `static mut`
    and the `unsafe { … }` boilerplate that used to surround it. See
    the `state` topic.

    ## Rust ctx accessors

    The `Context` returned by `ctx(...)` exposes the full per-block
    surface. All accessors are bounds-checked or branchless; nothing
    here allocates.

    - `ctx.channels()` — `usize`, channel count for this block.
    - `ctx.frames()` — `usize`, frame count for this block. Always use
      this (not the raw `frame_count` arg) as the inner-loop bound.
    - `ctx.sample_rate()` — `f32`, Hz. Cast to `f64` for filter coeffs.
    - `ctx.input(c, i)` — `f32`, read input sample at (channel, frame).
    - `ctx.set_output(c, i, value)` — write output sample.
    - `ctx.param(INDEX)` — `f32`, denormalized parameter value (where
      `INDEX` is the constant generated by `params! { … }`).
    - `ctx.sidechain(c, i)` — `f32`, read sidechain input sample at
      (channel, frame). Returns 0.0 when nothing is routed or when the
      preset was built against a pre-sidechain `setup!()`. Out-of-range
      channel/frame indices clamp to silence (won't read past the buf).
      Currently up to 2 channels; use `MAX_SIDECHAIN_CHANNELS` if you
      need the constant.
    - `ctx.sidechain_connected()` — `bool`. False when the host has no
      audio routed to the sidechain bus. Branch on this before reading
      `ctx.sidechain(...)` so a script without a wired sidechain can
      fall back to keying off the main input.
    - `ctx.sidechain_channels()` — `usize`, number of sidechain channels
      the host pulled this block. 0 when nothing is routed; up to 2.
    - `ctx.set_telemetry_scalar(slot_index, value)` — publish one f32
      per render block to the host UI's `audio.onFrame.telemetry`.
      Out-of-bounds indices are silently no-op'd. Pair with the
      `telemetry!()` macro to declare slot names + units.

    Example — read sidechain when connected, fall back to main input:

      let env = if ctx.sidechain_connected() {
          ctx.sidechain(0, i).abs()
      } else {
          ctx.input(0, i).abs()
      };

    ## Reporting algorithmic latency

    Scripts that introduce algorithmic latency (lookahead, FFT,
    oversampling) declare `LATENCY = <samples>` (Python) or
    `latency!(<samples>)` (Rust). The host reads this at load time and
    reports it to the DAW via `AUAudioUnit.latency` for delay
    compensation.

    Only declare *real* pre-process latency the DAW should compensate
    for — don't roll creative delay time (delay lines, chorus, reverb)
    into this number. A delay or chorus plugin whose wet path includes
    a lookahead limiter, for example, should still declare the
    lookahead latency, but must not include the delay/modulation time.

    Python:

      LATENCY = 256  # samples of lookahead

    Rust — emits the `get_latency_samples` WASM export:

      latency!(256);
    """

    static let filters = """
    # Filters — BiquadCoeffs + Biquad

    Biquad filters using Audio EQ Cookbook formulas (Robert Bristow-Johnson).
    All internal math uses f64 for precision. Create one Biquad per channel.

    ## BiquadCoeffs — coefficient calculation (stateless)

    3-argument filters (freq, q, sample_rate):
      .lowpass(freq, q, sr)    — passes frequencies below cutoff
      .highpass(freq, q, sr)   — passes frequencies above cutoff
      .bandpass(freq, q, sr)   — passes a frequency band (constant skirt gain)
      .notch(freq, q, sr)      — removes a frequency band
      .allpass(freq, q, sr)    — passes all frequencies, shifts phase

    4-argument filters (freq, q, gain_db, sample_rate):
      .peak(freq, q, gain_db, sr)      — boosts or cuts at center frequency
      .lowshelf(freq, q, gain_db, sr)   — boosts or cuts below cutoff
      .highshelf(freq, q, gain_db, sr)  — boosts or cuts above cutoff

    Parameters:
      freq — center/cutoff frequency in Hz
      q — quality factor (0.707 = Butterworth/no resonance, higher = narrower/more resonant)
      gain_db — boost/cut in dB (only for peak, lowshelf, highshelf)
      sr — sample rate in Hz

    Python: BiquadCoeffs.lowpass(freq, q, sr) — returns BiquadCoeffs instance
    Rust: BiquadCoeffs::lowpass(freq, q, sr) — returns BiquadCoeffs (Copy type)
      IMPORTANT (Rust): all three arguments must be f64. Cast with `as f64`:
        BiquadCoeffs::lowpass(cutoff as f64, q as f64, sample_rate as f64)

    Zero-value / passthrough:
      .identity() — passthrough coeffs (b0=1, rest=0). Use for stack-allocating
                    a fixed-size array of slots that will be filled at runtime
                    (e.g. a parametric EQ where each band picks a filter type):
                      Rust:   let mut bands: [BiquadCoeffs; 5] = [BiquadCoeffs::identity(); 5];
                      Python: bands = [BiquadCoeffs.identity() for _ in range(5)]
                    Rust also implements Default for runtime use
                    (`BiquadCoeffs::default()`, `#[derive(Default)]` on containing
                    structs). Array initializers must use `::identity()` —
                    trait methods aren't `const` on stable Rust, so
                    `[BiquadCoeffs::default(); N]` won't compile.

    ## Biquad — stateful filter (Direct Form II Transposed)

    Python: Biquad(coeffs=None) — passthrough if no coeffs
    Rust: Biquad::new() — const fn, passthrough by default. Copy type.

    Methods:
      .set_coeffs(coeffs)        — update coefficients without resetting state
      .process_sample(x) -> y    — filter one sample (f64 in Rust, float in Python)
      .reset()                   — zero internal state (z1, z2)

    ## Typical usage pattern

    Python:
      _filters = None
      def process(ctx):
          global _filters
          n_ch, frame_count = ctx.inputs.shape
          if _filters is None:
              _filters = [Biquad() for _ in range(n_ch)]
          coeffs = BiquadCoeffs.lowpass(ctx.params["cutoff"], 0.707, ctx.sample_rate)
          for ch in range(n_ch):
              _filters[ch].set_coeffs(coeffs)
              row_in = ctx.inputs[ch]
              row_out = ctx.outputs[ch]
              for i in range(frame_count):
                  row_out[i] = _filters[ch].process_sample(row_in[i])

    Rust:
      persist!(BIQUADS: [Biquad; 2] = [Biquad::new(); 2]);
      // Inside process! { ctx => ... }:
      let coeffs = BiquadCoeffs::lowpass(ctx.param(CUTOFF) as f64, 0.707, ctx.sample_rate() as f64);
      let mut biquads = BIQUADS.get();
      for c in 0..ctx.channels() {
          biquads[c].set_coeffs(coeffs);
          for i in 0..ctx.frames() {
              let y = biquads[c].process_sample(ctx.input(c, i) as f64) as f32;
              ctx.set_output(c, i, y);
          }
      }
      BIQUADS.set(biquads);
    """

    static let delays = """
    # DelayLine — Circular Buffer

    Pre-allocated circular buffer for delay effects with fractional-sample interpolation.

    ## Construction

    Python: DelayLine(max_samples: int) — numpy float32 backed
      Sizing: int(max_delay_seconds * sample_rate)
      Property: .max_samples → int

    Rust: DelayLine::<SIZE>::new() — const generic, compile-time size
      SIZE must be a const. Example: DelayLine::<48000>::new()
      Stored across blocks via persist_buf! (in-place mutation, avoids the multi-KB get/set round-trip):
        persist_buf!(DELAYS: [DelayLine<48000>; 2] = [DelayLine::new(); 2]);
        // Inside process! { ctx => ... }:
        DELAYS.with_mut(|d| { d[c].write(sample); let wet = d[c].read(delay_samples as f64); });

    ## Methods

    .write(sample)              — write one sample and advance write head
    .read(delay_samples)        — fractional delay with linear interpolation (f64 delay arg in Rust)
    .read_cubic(delay_samples)  — fractional delay with 4-point Hermite interpolation (better for
                                  pitch shifting and modulated delays)
    .tap(delay_samples)         — integer delay, no interpolation (int arg in Python, usize in Rust)
    .clear()                    — zero buffer and reset write position

    ## Delay time conversion

    delay_samples = delay_time_ms * 0.001 * sample_rate
    max_samples = int(max_delay_seconds * sample_rate)

    ## Notes

    - write() before read() each sample — write advances the head, read looks backward
    - read(0) and tap(0) return the sample at the current write position (just written)
    - read(1) / tap(1) returns the previous sample
    - Rust DelayLine uses f32 samples, f64 delay argument for read/read_cubic
    """

    static let oscillators = """
    # Oscillators — LFO + Waveform Functions

    ## LFO — Stateful Low-Frequency Oscillator

    Python: LFO(sample_rate, freq=1.0, waveform="sine")
    Rust: Lfo::new() → defaults to 1 Hz sine at 44100 Hz. Call .init(sr, freq) each callback.
      Both args are f64. Cast f32 values: .init(ctx.sample_rate() as f64, rate_hz as f64)

    Methods:
      .tick() -> float          — advance one sample, returns value in [-1, 1]
      .set_freq(hz)             — update frequency
      .set_waveform(wf)         — Python: string ("sine","triangle","saw","square")
                                  Rust: Waveform enum (Waveform::Sine, Triangle, Saw, Square)
      .reset()                  — reset phase to 0
      .value                    — last tick() value (attribute/field, not a method call)

    Python-only:
      .tick_n(n) -> np.ndarray  — advance n samples, returns float32 array of shape (n,)
                                  More efficient than calling tick() in a loop.

    Rust-only:
      .init(sr: f64, freq: f64)  — set sample rate and frequency. Call at start of each process()
                                  callback to handle sample rate changes.

    ## Waveform enum (Rust)

    Waveform::Sine, Waveform::Triangle, Waveform::Saw, Waveform::Square

    ## Stateless waveform functions

    All take phase in [0, 1) and return value in [-1, 1]:
      sine(phase)      — sin(2*pi*phase)
      triangle(phase)  — triangle wave
      saw(phase)       — sawtooth wave (rising)

    advance_phase(phase, freq, sample_rate) -> new_phase  — advance phase by one sample, wraps at 1.0

    ## Multi-channel LFO pattern

    Call tick() once per frame (every frame iteration) to advance the phase by one sample.
    Do NOT call tick() once per channel — that would advance the phase too fast.

    Frames-outer loop (most common — call tick() unconditionally every frame, no if-condition):
      Python:
        n_ch, frame_count = ctx.inputs.shape
        for i in range(frame_count):
            mod = lfo.tick()          # tick every iteration, no condition
            # ctx.outputs[:, i] is a length-n_ch column; broadcasting mod
            # across it covers all channels in one assignment. Placeholder
            # body — see "Common applications" below for the real shapes.
            ctx.outputs[:, i] = ctx.inputs[:, i] * mod
      Rust:
        for f in 0..ctx.frames() {
            let mod_val = unsafe { LFO.tick() };       // tick once per frame
            for c in 0..ctx.channels() {
                ctx.set_output(c, f, ctx.input(c, f) * mod_val);  // placeholder — see "Common applications"
            }
        }

    Channels-outer loop (tick on channel 0, use .value for others):
      Python: mod = lfo.tick() if ch == 0 else lfo.value
      Rust: let mod_val = if c == 0 { unsafe { LFO.tick() } } else { unsafe { LFO.value } };

    ## Common applications

    The pattern above shows where to call tick(), not what to do with the value.
    `tick()` returns a bipolar [-1, 1] sine — multiplying audio by it directly is
    ring modulation, not tremolo. Three common LFO applications:

    ### Tremolo (amplitude modulation with depth control)

    Map the bipolar LFO to a unipolar [0, 1] gain envelope, then blend toward
    unity by (1 - depth) so depth=0 is bypass and depth=1 is full modulation.
    Python: use `lfo.tick_n(frame_count)` to fill the whole buffer at once and
    apply with `np.multiply(in, gain, out=out)` — looping per-sample in Python
    is much slower.

      Python:
        lfo = _lfo.tick_n(ctx.frame_count)                       # bipolar [-1, 1] array
        gain = (1.0 - depth) + depth * (lfo * 0.5 + 0.5)         # unipolar [0, 1] envelope
        # gain is shape (frame_count,); numpy broadcasts it across the
        # channel axis of the 2D ctx.inputs in one vectorized call.
        np.multiply(ctx.inputs, gain, out=ctx.outputs)
      Rust:
        for f in 0..ctx.frames() {
            let mod_val = unsafe { LFO.tick() } as f32;
            let gain = (1.0 - depth) + depth * (mod_val * 0.5 + 0.5);
            for c in 0..ctx.channels() {
                ctx.set_output(c, f, ctx.input(c, f) * gain);
            }
        }

    Why not `output = input * lfo.tick()` directly? The bipolar sine flips polarity
    twice per cycle, so the perceived amplitude rate is 2× the LFO rate, depth is
    locked at 100%, and zero crossings produce phase flips. At audio rates it
    becomes pure ring modulation (sum/difference sidebands).

    ### Auto-pan (stereo gain split)

    Bipolar LFO is the right shape here — positive values pan right (attenuate
    left), negative pan left. `depth` (0–1) scales the swing. Stereo only.

      Python:
        lfo = _lfo.tick_n(ctx.frame_count)                       # bipolar [-1, 1] array
        pan = lfo * depth
        gain_l = 1.0 - np.maximum(pan, 0.0)
        gain_r = 1.0 + np.minimum(pan, 0.0)
        # ctx.inputs[ch] is a contiguous 1D row view of the 2D array.
        np.multiply(ctx.inputs[0], gain_l, out=ctx.outputs[0])
        np.multiply(ctx.inputs[1], gain_r, out=ctx.outputs[1])
      Rust:
        for f in 0..ctx.frames() {
            let mod_val = unsafe { LFO.tick() } as f32;
            let pan = mod_val * depth;
            let gain_l = 1.0 - pan.max(0.0);
            let gain_r = 1.0 + pan.min(0.0);
            ctx.set_output(0, f, ctx.input(0, f) * gain_l);
            ctx.set_output(1, f, ctx.input(1, f) * gain_r);
        }

    ### Chorus / vibrato (delay-time modulation)

    Use the bipolar LFO to wobble the read position of a DelayLine around a
    base delay (chorus: ~10–25 ms base; vibrato: ~3–8 ms base, mix=1.0).
    `depth_samples` controls how far the read head swings. Use `read_cubic` for
    smoother pitch behavior on a moving read position. See get_docs("delays")
    for the full DelayLine API.

    Note: delay-line reads/writes are inherently sequential (write head must
    advance one sample at a time), so this section keeps the per-sample loop
    in both languages. For the Python idiom (manual numpy ring buffer), see
    factory preset `chorus`.

      Rust (sketch — DelayLine declared at module scope):
        for f in 0..ctx.frames() {
            let mod_val = unsafe { LFO.tick() };                 // bipolar [-1, 1]
            let read_samples = base_delay_samples + mod_val * depth_samples;
            let dry = ctx.input(0, f);
            let wet = unsafe { DELAY.read_cubic(read_samples) };
            unsafe { DELAY.write(dry); }
            ctx.set_output(0, f, dry * (1.0 - mix) + wet * mix);
        }

    ## Multi-voice LFO phase spread

    For chorus/flanger with N voices, spread LFO phases evenly. Pre-seed each LFO at module scope
    by advancing it by phase_offset * samples_per_cycle at a reference frequency.
    The reference sample rate cancels in the ratio (ticks × phase-per-tick = v/N regardless),
    so any value works for seeding — but use the actual sample_rate for correct LFO speed.
    Re-seed when sample_rate changes:

      NUM_VOICES = 3
      _lfos = None
      _last_sr = None

      def _init_lfos(sample_rate, rate_hz):
          global _lfos, _last_sr
          _lfos = []
          for v in range(NUM_VOICES):
              lfo = LFO(sample_rate, freq=rate_hz)
              for _ in range(int((v / NUM_VOICES) * sample_rate / rate_hz)):
                  lfo.tick()
              _lfos.append(lfo)
          _last_sr = sample_rate

      def process(ctx):
          if _last_sr != ctx.sample_rate:
              _init_lfos(ctx.sample_rate, ctx.params["rate"])
          ...
    """

    static let utilities = """
    # Utility Functions

    Stateless helpers for unit conversion and common audio math. All use f64 in Rust, float in Python.

    ## Unit conversion

    db_to_gain(db) -> gain          — 0 dB = 1.0, -6 dB ≈ 0.5, -20 dB = 0.1
    gain_to_db(gain) -> db          — inverse of db_to_gain, clamps to avoid log(0)
    ms_to_samples(ms, sr) -> int    — milliseconds to sample count (rounded)
    samples_to_ms(samples, sr)      — sample count to milliseconds
    freq_to_period(freq, sr)        — frequency in Hz to period in samples

    ## VU calibration (house standard)

    ConjureDSP uses **0 VU = -18 dBFS** (EBU R68). All presets that expose
    VU-style meters or "0 VU"-relative thresholds should use this convention
    so the meaning of "0 VU" is consistent across the library.

    To convert sample / RMS levels to VU dB:

      vu_db = 20 * log10(rms / VU_REF)   where VU_REF = 10^(-18/20) ≈ 0.1259

    Or, equivalently, in dBFS:

      vu_db = dbfs - (-18.0) = dbfs + 18.0

    Use the helpers from conjuredsp / conjuredsp-rs::dsp:

      VU_REF_DBFS  — the constant -18.0
      dbfs_to_vu(dbfs) -> vu_db   — dbfs_to_vu(-18.0) == 0.0, dbfs_to_vu(0.0) == 18.0

    Why -18 and not -20: EBU R68 (-18 dBFS = 0 VU) is the most-cited modern
    broadcast / mastering reference. SMPTE RP155 (-20 dBFS) and various US
    broadcast conventions (-14 to -20 dBFS) also exist; without a single
    house standard, presets silently disagree about what "0 VU" means.

    ## Smoothing

    smooth_coeff(time_ms, sr) -> alpha
      One-pole smoothing coefficient. Use as: state = alpha * state + (1 - alpha) * target
      Larger time_ms = slower smoothing (alpha closer to 1.0).
      time_ms=0 or negative returns 0.0 (instant).

    ## Waveshaping

    soft_clip(x, drive=1.0)   — tanh saturation. drive > 1 increases distortion.
    lerp(a, b, t)             — linear interpolation. t=0 → a, t=1 → b.

    ## Crossfade

    Rust: crossfade(dry: f32, wet: f32, mix: f32) -> f32
      Per-sample linear crossfade. mix=0 → dry, mix=1 → wet.

    Python: crossfade(dry, wet, mix, out, n)
      Buffer-level linear crossfade. Writes to out[:n] in-place.
      dry, wet, out are numpy arrays. mix is a float.

    Python-only: equal_power_crossfade(dry, wet, mix, out, n)
      Constant-energy crossfade using sine/cosine curves.
      Preserves perceived loudness at 50% mix (no energy dip).
    """

    static let accel = """
    # Accelerated Math — conjuredsp.accel

    Hardware-accelerated vectorized math operations. On WASM, these call Apple's
    Accelerate framework (vDSP/vecLib) via host imports for AMX/NEON-optimized
    performance. Use these instead of writing your own loops for matrix math,
    element-wise operations, or activation functions.

    ## Rust API

      use conjuredsp::accel;

      // Matrix multiply: out[m×n] = a[m×k] @ b[k×n], row-major
      accel::matmul(a: &[f32], b: &[f32], out: &mut [f32], m: usize, k: usize, n: usize)

      // Element-wise operations (all slices must be same length)
      accel::vec_add(a: &[f32], b: &[f32], out: &mut [f32])    // out = a + b
      accel::vec_mul(a: &[f32], b: &[f32], out: &mut [f32])    // out = a * b
      accel::vec_tanh(input: &[f32], output: &mut [f32])        // out = tanh(in)
      accel::vec_sigmoid(input: &[f32], output: &mut [f32])     // out = sigmoid(in)
      accel::vec_add_scalar(input: &[f32], scalar: f32, output: &mut [f32])  // out = in + s

    ### Rust Example

      use conjuredsp::accel;

      // 2x2 matrix multiply
      let a = [1.0, 2.0, 3.0, 4.0];
      let b = [5.0, 6.0, 7.0, 8.0];
      let mut c = [0.0f32; 4];
      accel::matmul(&a, &b, &mut c, 2, 2, 2);
      // c = [19.0, 22.0, 43.0, 50.0]

    ## Python API

      from conjuredsp.accel import matmul, vec_add, vec_mul, vec_tanh, vec_sigmoid, vec_add_scalar

      matmul(a, b, out)               # numpy.matmul (Accelerate BLAS)
      vec_add(a, b, out)              # numpy.add
      vec_mul(a, b, out)              # numpy.multiply
      vec_tanh(x, out)                # numpy.tanh
      vec_sigmoid(x, out)             # 1 / (1 + exp(-clip(x)))
      vec_add_scalar(x, scalar, out)  # numpy.add(x, scalar)

    IMPORTANT: `out` is REQUIRED in all functions (not optional). Pre-allocate
    output buffers and reuse them across calls. This is critical for real-time
    audio — per-call allocation causes memory growth because the macOS allocator
    retains pages. Example:

      # Pre-allocate once (e.g., in module scope or __init__)
      _buf = np.empty((rows, cols), dtype=np.float32)

      # Reuse every callback
      matmul(a, b, _buf)

    Note: You can also use numpy directly (e.g., `a @ b`) but be aware that
    numpy operators allocate new arrays each call. Use conjuredsp.accel with
    pre-allocated buffers for zero-allocation real-time code.

    ## Performance

    These functions are 10-30x faster than equivalent scalar loops for
    matrix-heavy workloads (e.g., NAM inference, convolutions) because they
    use Apple's AMX coprocessor (dedicated matrix math hardware).

    Always prefer accel:: functions over hand-written loops for:
    - Matrix multiplication
    - Bulk activation functions (tanh, sigmoid on arrays)
    - Element-wise vector operations on large buffers
    """

    static let nam = """
    # NAM — Neural Amp Modeling

    Load and run NAM (.nam) tone models from tone3000.com for guitar amp/pedal emulation.

    ## Python API

      from conjuredsp.nam import load_model

      model = load_model("tone3000://TONE_ID/MODEL_ID")

      # In process():
      wet = model.process(audio_array, channel_index)

    ### load_model(path) -> NamModel

    Loads a .nam file. Path formats:
      "tone3000://toneId/modelId" — downloaded tone (use list_tones tool to see available)
      "~/path/to/model.nam" — local file with tilde expansion
      "/absolute/path/to/model.nam" — absolute path

    ### NamModel

    Properties:
      .architecture — "WaveNet" or "LSTM"
      .receptive_field — number of history samples needed (WaveNet only)
      .sample_rate — sample rate the model was trained at

    Methods:
      .process(audio: np.ndarray, channel: int) -> np.ndarray
        Process one channel of audio. Returns array of same length.
        Maintains per-channel history automatically across callbacks.
      .reset()
        Clear history buffers / LSTM hidden state.

    ## Python Usage Pattern

      from conjuredsp.nam import load_model
      from conjuredsp import db, mix

      PARAMS = {
          "input_gain": db(default=0),
          "mix": mix(default=1.0),
      }

      model = load_model("tone3000://12345/67890")

      def process(ctx):
          gain = 10 ** (ctx.params["input_gain"] / 20.0)
          mix_val = ctx.params["mix"]
          # NAM inference is per-channel (stateful), so the channel loop
          # stays. Rows are 1D views of the 2D ctx.inputs / ctx.outputs.
          for ch in range(ctx.inputs.shape[0]):
              row = ctx.inputs[ch]
              wet = model.process(row * gain, ch)
              ctx.outputs[ch] = row * (1 - mix_val) + wet * mix_val

    ## Rust API — single model

      use conjuredsp::*;
      nam!("tone3000://TONE_ID/MODEL_ID");

      process! { ctx =>
          unsafe {
              for c in 0..ctx.channels() {
                  let n = ctx.frames();
                  for i in 0..n { NAM_IN[i] = ctx.input(c, i); }
                  nam_process(&NAM_IN[..n], &mut NAM_OUT[..n], c);
                  for i in 0..n { ctx.set_output(c, i, NAM_OUT[i]); }
              }
          }
      }

    ### nam!("path") macro

    Declares a single NAM model. Expands to:
      - static mut NAM_IN / NAM_OUT: [f32; MAX_FR] — scratch buffers
      - nam_process(input, output, channel) -> bool — runs host-side inference
      - Manifest exports: get_nam_manifest_ptr, get_nam_manifest_len

    The host reads the path from the compiled WASM, loads the .nam file,
    and injects the native model before the first process() call. Inference
    runs natively on the host (not inside the WASM sandbox) for speed.

    ## Rust API — multiple models in one preset

    Use `nams!` to declare two or more models. Each NAME becomes a slot
    constant (`pub const NAME: u32`) you pass to `nam_process_slot`.

      use conjuredsp::*;

      nams! {
          DRIVE = "tone3000://19/56",
          CAB   = "tone3000://42/8",
      }

      process! { ctx =>
          // cascade DRIVE -> CAB
          let mut a = [0.0_f32; MAX_FR];
          let mut b = [0.0_f32; MAX_FR];
          unsafe {
              for c in 0..ctx.channels() {
                  let n = ctx.frames();
                  for i in 0..n { a[i] = ctx.input(c, i); }
                  nam_process_slot(DRIVE, &a[..n], &mut b[..n], c);
                  nam_process_slot(CAB,   &b[..n], &mut a[..n], c);
                  for i in 0..n { ctx.set_output(c, i, a[i]); }
              }
          }
      }

    Slots are independent — each maintains its own per-channel state.
    `nam_process_slot` returns `false` if the slot's model failed to inject
    (e.g. the user hasn't downloaded that tone yet); the output slice is
    untouched in that case so callers can fall back to dry signal.

    ## Notes

    - NAM models are mono — inference runs independently per channel with shared weights
    - WaveNet models maintain a sliding history window across callbacks (automatic)
    - If model sample rate != DAW sample rate, a warning is logged on first process() call
    - Use list_tones tool to see downloaded tones and their tone3000:// paths
    """

    static let state = """
    # STATE — bundle-private state channel

    A persistent JSON-shaped state mapping that is **UI-writable and
    audio-readable**, lives outside the AU parameter tree, and persists
    via the DAW project (not the bundle). Use it for things that aren't
    parameters: step sequencers, slot selections, NAM model paths,
    captured impulse responses, MIDI learn maps — anything you want the
    user's edits to survive a reopen but don't want eating an AU
    automation lane.

    ## Why not parameters?

    The 16-slot AU parameter tree is for things the DAW automates as
    floats. STATE is for everything else: arrays, strings, structured
    objects. Audio-thread reads are atomic-pointer-swap cheap, so a UI
    can write 32 sequencer steps as a single JSON array and the next
    render block sees them.

    ## Python author surface

    Declare defaults at module level — top-level `STATE = {…}`. The
    kernel installs the dict on script load; new instances start from
    these defaults; user edits are read back from the DAW project on
    reopen.

    ```python
    STATE = {
        "slots":     [0] * 32,         # 32-step sequence
        "selected":  0,                # current slot
        "ir_path":   None,             # nullable
    }

    def process(ctx):
        slots = ctx.state["slots"]     # read-only view
        i = int(ctx.state["selected"])
        gate = slots[i]
        # … apply gate to ctx.inputs / ctx.outputs …
    ```

    `ctx.state` is a **read-only mapping**. Mutating it inside
    `process()` raises `AttributeError`. Writes only happen through
    `ConjureDSP.state.set(...)` (JS) or the MCP `set_state` tool. This
    is the boundary that lets the kernel make audio-thread reads
    lock-free — the audio thread never has to coordinate with writers.

    ## Rust author surface

    Declare the state buffer with `state!()`. The macro emits the
    host-facing exports plus typed accessors on `cx` for the common
    fixed-shape cases plus a raw-bytes escape hatch:

    | Accessor | Returns |
    |---|---|
    | `cx.state_int(key)` / `cx.state_int_or(key, default)` | `Option<i32>` / `i32` |
    | `cx.state_bool(key)` / `cx.state_bool_or(key, default)` | `Option<bool>` / `bool` |
    | `cx.state_f32(key)` / `cx.state_f32_or(key, default)` | `Option<f32>` / `f32` |
    | `cx.state_array_u8::<N>(key)` / `cx.state_array_u8_or(key, default)` | `Option<[u8; N]>` / `[u8; N]` |
    | `cx.state_array_i32::<N>(key)` / `cx.state_array_i32_or(key, default)` | `Option<[i32; N]>` / `[i32; N]` |
    | `cx.state_array_f32::<N>(key)` / `cx.state_array_f32_or(key, default)` | `Option<[f32; N]>` / `[f32; N]` |
    | `cx.state_bytes()` | `&'static [u8]` (raw JSON content) |
    | `cx.state_generation()` | `u64` (bumps on every accepted write) |

    The typed readers parse the kernel's JSON STATE buffer in place and
    have no allocation cost on the audio thread. Fixed-size array
    readers return `None` if the JSON array is shorter than `N` (so the
    caller can fall back to defaults rather than getting partially
    initialised data) and silently take the prefix when it's longer.

    ```rust
    use conjuredsp::*;
    state!();
    // Optional: bump the cap (default 64 KiB). Clamped to 1 MiB.
    // state!(max_bytes = 131_072);

    persist!(CACHED_GEN: u64 = u64::MAX);
    persist!(PATTERN: [u8; 16] = [1; 16]);
    persist!(SELECTED: i32 = 0);
    persist!(FROZEN: bool = false);

    process! { cx =>
        let g = cx.state_generation();
        if g != CACHED_GEN.get() {
            PATTERN.set(cx.state_array_u8_or::<16>("pattern", [1; 16]));
            SELECTED.set(cx.state_int_or("selected", 0));
            FROZEN.set(cx.state_bool_or("frozen", false));
            CACHED_GEN.set(g);
        }
        // … apply PATTERN.get() / SELECTED.get() / FROZEN.get() to ctx.input / ctx.set_output …
    }
    ```

    For shapes the typed accessors don't cover (nested objects,
    variable-length strings, custom binary), fall back to
    `cx.state_bytes()` + your own parser. The kernel stores STATE as
    UTF-8 JSON, so `serde_json` works once you've added it through the
    crate package manager — the conjuredsp crate stays dependency-free
    so that's an opt-in, not a tax on every preset.

    Note: there's no `set_state_*` from Rust. STATE is UI/MCP-writable
    and audio-readable by design — the audio thread stays lock-free
    because writers can't race with it.

    ## JS surface — `ConjureDSP.state.*`

    UIs read and write state through the bridge. Mirrors
    `ConjureDSP.parameters.*` in shape:

    ```js
    ConjureDSP.state.get('slots')               // current value
    ConjureDSP.state.set('slots', [1, 0, 1, 0]) // returns false on
                                                 // size-cap reject
    ConjureDSP.state.onChange('slots', cb)      // fires on every set
                                                 // AND external _stateUpdate
    ConjureDSP.state.onAnyChange((k, v) => {})  // fires with (key, value)
    ConjureDSP.state.reset('slots')             // restore one key to default
    ConjureDSP.state.resetAll()                 // restore everything
    ```

    `set` returns boolean — `false` when the resulting buffer would
    exceed the per-script cap. Handle it: a UI that silently drops
    writes is the worst-of-both-worlds.

    ## MCP surface

    For agent / scripted access:

    - `set_state {key, value}` — writes a single key (validates against
      the script's declared keys when in strict mode).
    - `get_state` — returns the full state map; pass `[{key}]` to read
      one key.
    - `reset_state` — full reset to script defaults; pass `[{key}]` to
      reset a single key.

    ## Persistence

    State lives in the DAW project, not the bundle. Mechanism: the AU's
    `fullState` and `fullStateForDocument` accessors embed the JSON
    bytes under a `conjuredsp_state` key. Reopening the project hands
    those bytes to `PresetStateManager.restore(from:)` which validates
    + reinstalls them.

    New instances always boot from the script's defaults — `STATE = {…}`
    in Python; Rust scripts read raw bytes via `cx.state_bytes()` and
    are responsible for their own default-when-empty handling. The
    bundle ships behaviour, the DAW project ships per-instance edits.

    ## Size cap

    Default cap: **64 KiB**. Hard ceiling: **1 MiB**. Rust opt-in to
    raise the per-script cap via `state!(max_bytes = N)`. Python
    presets use the default. The cap protects the DAW project from
    presets that unbounded-grow their state buffer (each
    fullStateForDocument copy lands in the project file).

    ## When to use STATE vs PARAMS vs TELEMETRY

    | What | Mechanism | Audience |
    |---|---|---|
    | DAW-automatable float | `PARAMS` | host automation lanes, MIDI learn |
    | UI/MCP-writable structured value | `STATE` | UI, agent, persisted edits |
    | Per-block read-back from DSP | `TELEMETRY` | UI meters/visualizers |

    Never put params on the STATE channel — you lose automation. Never
    put state on the PARAMS channel — you lose anything that isn't a float.
    """

    static let ui = """
    # Custom HTML/JS UIs — cdp-ui component library

    ## Recommended call order for preset+UI authoring

    Before you write anything, call `get_bundle_info` — it tells you
    what preset is currently active, whether it's a factory bundle
    (read-only), and whether it already ships a UI. If a working
    factory bundle has a UI you can borrow patterns from, fetch it
    with `read_bundle_file('ui/index.html')` first. Most authoring
    sessions go:

      1. `get_bundle_info` — see the active bundle.
      2. `read_bundle_file('ui/index.html')` — optional, study a
         working example.
      3. `save_preset(name, source, language)` — fork to a new
         editable user bundle. This switches the active preset to
         the new bundle AND reloads the kernel with `source`, so the
         user can hit play immediately.
      4. `write_bundle_file('manifest.json', …)` — declare params
         and the `ui` block (schemaVersion 2).
      5. `write_bundle_file('ui/index.html', …)` — the HTML.
      6. `write_bundle_file('ui/assets/...', …)` — optional CSS, JS,
         images.
      7. `validate_bundle` — static checks (lint).
      8. `smoke_test_ui` — runtime check (load in offscreen
         WKWebView, confirm bridge ready, components bound, params
         covered, no JS errors).

    `write_bundle_file` for `ui/*` and `manifest.json` already inlines
    a validation report in its response — separate `validate_bundle`
    is mostly useful as a final pass.

    When a preset bundle's manifest declares a `ui` block and ships a
    `ui/index.html`, the plugin renders that HTML in a WKWebView instead
    of the auto-generated slider panel. The webview is pre-injected with:

    - `window.ConjureDSP` bridge (from `customui-bridge.js`) — parameters,
      theme, audio frames
    - `cdp-ui.js` component library — the widgets below

    You DO NOT include `<script src="...">` for either. Both are already
    loaded before your document-start scripts run. Just use the tags.

    ## Manifest ui block

    Add to manifest.json alongside `entry`:

    ```json
    {
        "schemaVersion": 2,
        "entry": "process.py",
        "language": "python",
        "params": [ ... ],
        "ui": {
            "entryHTML": "ui/index.html",
            "width": 520,
            "height": 380,
            "fps": 30,
            "audioFrames": false
        }
    }
    ```

    - `entryHTML` — path relative to the bundle root.
    - `width` / `height` — pt; the webview is pinned to this height, so
      authors control vertical space. Window is user-resizable horizontally.
      **The manifest is the single source of truth for size.** Do NOT also
      set `body { width: ... }` or `body { height: ... }` in CSS — the
      webview is already sized by `manifest.ui`, and a shrunken body just
      leaves whitespace around the rendered content while the webview
      stays at manifest dimensions. To change the plugin's size, edit
      `manifest.ui.width` / `height`; leave `body` to fill the viewport
      (default behavior, or `html, body { width: 100%; height: 100% }`).
      Both `validate_bundle` (static) and `smoke_test_ui` (runtime) flag
      body-vs-manifest size disagreement.
    - `fps` — tick rate hint for `window.ConjureDSP.audio.onFrame`.
    - `audioFrames` — **REQUIRED `true` if your UI calls
      `ConjureDSP.audio.onFrame(...)` or reads telemetry slots.** When
      false (the default), the audio capture consumer doesn't run,
      `onFrame` never fires, and your meters silently sit at zero with
      no error in the console. Toggle on for visualizers / meters /
      telemetry consumers; leave off for pure-control UIs.

    When `schemaVersion: 2` ships `params: [...]`, the AU parameter tree
    is populated from the manifest BEFORE the DSP script compiles —
    meaning the custom UI can render with correct defaults during a slow
    Rust compile. Always prefer v2 + `params` over relying on DSP-extracted
    metadata.

    ## Components

    All web components; use them as custom elements in HTML:

    ```html
    <cdp-slider param="cutoff"></cdp-slider>
    <cdp-toggle param="bypass_eq"></cdp-toggle>
    <cdp-choice param="mode"></cdp-choice>
    <cdp-xy param-x="cutoff" param-y="resonance" invert-y></cdp-xy>
    <cdp-knob param="threshold"></cdp-knob>
    <cdp-panel auto></cdp-panel>   <!-- renders one control per param -->
    ```

    - `<cdp-slider>` — honors `curve:"log"` metadata automatically;
      renders `label | track | value` in a row. Set `--cdp-label-width: 0`
      and `--cdp-value-width: 0` to collapse to a bare track.
    - `<cdp-toggle>` — for `style:"toggle"` params. Renders as a switch.
    - `<cdp-choice>` — for `style:"choice"` params. Segmented control
      (≤2 options) or dropdown (3+), driven by manifest `options`.
    - `<cdp-xy>` — 2D pad. `invert-y` flips so low Y = bottom (standard
      graph orientation — omit for "screen" orientation where top = 0).
      Auto-renders one `name + value` row per axis (X first, Y second)
      below the pad, sourced from each control's `metadata.name`. Add
      `no-labels` to suppress the readout when you're managing your own
      gutter or legend (see `preset_svf.cdp` for the pattern).
    - `<cdp-knob>` — circular knob. Vertical drag changes the value
      (200px = 0..1; Shift = fine control); also supports mouse-wheel,
      arrow keys (Shift = fine, Page = ±0.20), Home/End for min/max,
      and double-click-to-default. Stacked layout: face / label /
      value. Theme via `--cdp-knob-size`, `--cdp-knob-sweep`,
      `--cdp-knob-face-bg`, `--cdp-knob-rim-bg`,
      `--cdp-knob-indicator-color`, `--cdp-knob-indicator-width`. For
      a fully custom shape (vintage tube, hexagon, animated needle),
      slot in your own SVG and react to the published
      `--cdp-knob-norm` CSS variable (0..1, updated live during drag)
      entirely in CSS — the component still owns events and parameter
      writes, you own the geometry:

      ```html
      <cdp-knob param="drive">
        <svg slot="visual" viewBox="0 0 100 100">
          <use href="#tube-body"/>
          <line x1="50" y1="50" x2="50" y2="10" stroke="white"
                style="transform-origin: 50px 50px;
                       transform: rotate(calc(var(--cdp-knob-norm)
                                               * 270deg - 135deg))"/>
        </svg>
      </cdp-knob>
      ```
    - `<cdp-meter source="peak-out">` — read-only level meter with PPM
      ballistics, peak-hold marker (~2 s, click-to-reset), and three-zone
      coloring (green / yellow at `warn` / red at `clip`). Sources:
      `peak-in`, `peak-out`, `rms-in`, `rms-out`, or `telemetry:<key>`
      to read a per-block DSP value. `unit="db"` skips the linear→dB
      conversion (use it when the source already publishes dB, e.g.
      gain-reduction telemetry). `orientation="vertical"` (default) or
      `horizontal`. `min`/`max` set the dB range; `decay` (default
      `11.76` dB/s, IEC PPM) tunes fall rate; `hold="0"` disables hold,
      `"infinite"` latches until clicked. `gradient="smooth"` blends
      colors continuously instead of hard-stopping at warn/clip. Add
      `invert` for "more is worse" sources (gain-reduction, ducking):
      bar fills from the `max` end and red lives at the `min` end —
      with `invert`, set `warn` closer to `max` and `clip` closer to
      `min`. For total color control, override `--cdp-meter-gradient`
      with any `linear-gradient(...)`. **Meters need `"audioFrames":
      true` in the manifest** — without it `onFrame` never fires and
      the meter sits at zero (see "Audio frames" below). Meters do NOT
      take a `param=` attribute; pair them with at least one slider /
      knob / toggle so the bundle has actuators.

      ```html
      <cdp-meter source="peak-out" min="-60" max="0" warn="-18" clip="-6">
        <span slot="label">OUT</span>
      </cdp-meter>

      <!-- GR meter: 0 dB = no reduction (safe), -24 dB = max reduction -->
      <cdp-meter source="telemetry:gain_reduction"
                 min="-24" max="0" warn="-6" clip="-12" invert>
        <span slot="label">GR</span>
      </cdp-meter>

      <!-- Smooth blend instead of hard-edged zones -->
      <cdp-meter source="rms-out" gradient="smooth">
        <span slot="label">RMS</span>
      </cdp-meter>
      ```

      **When to roll your own `<canvas>` instead.** `<cdp-meter>` renders
      as a PPM-style bar fill (rectangular track + clip-path) — there is
      no built-in primitive for analog-style rotating-needle visualizers
      (VU meters, gauges, dial faces). For those, hand-roll a `<canvas>`
      and draw the needle yourself: subscribe to `ConjureDSP.audio.onFrame`
      (or a vector telemetry slot) for the source value, then map it to a
      rotation angle. **Resolve fill/stroke colors via
      `getComputedStyle(probe).color` on a hidden element styled with
      `color: CanvasText; background: Canvas;`** so the canvas tracks the
      host theme — Canvas 2D cannot parse system color literals like
      `'CanvasText'` and will silently paint black. Re-resolve on the
      `themechange` event. Minimal needle math:

      ```js
      // Pivot at bottom-center, sweep ±42° around vertical
      const ANG_MIN = -42 * Math.PI / 180;
      const ANG_MAX =  42 * Math.PI / 180;
      const t = (value - min) / (max - min);            // 0..1
      const ang = -Math.PI / 2 + ANG_MIN + t * (ANG_MAX - ANG_MIN);
      const nx = cx + Math.cos(ang) * radius;
      const ny = cy + Math.sin(ang) * radius;
      ctx.beginPath();
      ctx.moveTo(cx, cy);
      ctx.lineTo(nx, ny);
      ctx.stroke();
      ```

      A one-pole visual smoother (`disp += (target - disp) * 0.35`) on
      top of the DSP-side ballistics hides per-frame jitter without
      lying about the meter's response. See the VU Saturator factory
      preset for a worked example.

    - `<cdp-scope telemetry="env_curve">` — read-only oscilloscope that
      draws a vector telemetry slot (one float per audio frame, see
      "Vector telemetry" below) as a waveform. `draw="line"` (default),
      `"filled"`, or `"dots"`. `min`/`max` pin the y-range; omit either
      or both to engage auto-range with ~1 s decay (so a transient peak
      stays visible briefly before the tracker walks back in). `length`
      clips the slice to the first N samples; omit to draw the whole
      vector. Add `grid` for a 5×5 reference grid. Heavy decimation
      kicks in automatically when the vector is much longer than the
      canvas (one min+max pair per pixel column — same trick a DAW
      thumbnail uses). Theme via `--cdp-scope-line-color`,
      `--cdp-scope-fill-color`, `--cdp-scope-grid-color`. **Needs
      `"audioFrames": true` in the manifest** — same gate as the meter,
      same silent failure mode without it. Loose-name resolution: the
      `telemetry=` attribute matches slot names case/underscore/space-
      insensitively, so `telemetry="env_curve"` binds to a Rust slot
      declared `ENV_CURVE` and a Python slot declared `env_curve`.

      ```html
      <!-- Per-block envelope curve from the saturator preset -->
      <cdp-scope telemetry="env_curve" min="-1" max="1" grid></cdp-scope>

      <!-- GR trajectory: auto-range so a quiet section doesn't waste
           half the display, but the impulses stay tall -->
      <cdp-scope telemetry="gr_db" draw="filled"></cdp-scope>
      ```

    - `<cdp-panel auto>` — fallback layout that mirrors the stock slider
      panel. Useful as a one-liner when you just want themed sliders.

    ### Don't display the same value twice

    Every `<cdp-slider>` / `<cdp-knob>` / `<cdp-toggle>` / `<cdp-choice>`
    already renders its own label and formatted value (with units) inside
    its shadow DOM. Adding a sibling `<span>`/`<div>` that shows
    `formatValue(...)` for the same param produces a duplicate readout
    the user has to mentally reconcile, and the two will tear under
    fast updates because they redraw from different paths.

    If the default value position doesn't fit your layout, restyle the
    built-in instead of duplicating it:

    ```css
    /* Hide the default value entirely (and let your layout render its own). */
    cdp-knob::part(value) { display: none; }

    /* Or just resize the value column on cdp-slider rows. */
    cdp-slider { --cdp-value-width: 0; }
    ```

    The components expose `::part(label)`, `::part(value)`, `::part(track)`,
    `::part(face)`, `::part(rim)`, `::part(indicator)`, `::part(puck)`,
    `::part(option)`, `::part(thumb)`, `::part(readout)`,
    `::part(axis-x-name)`, `::part(axis-x-value)`, `::part(axis-y-name)`,
    `::part(axis-y-value)` for restyling without re-rendering.

    ### Hand-rolled bindings need a declarative twin

    The validator's UI-coverage check scans the HTML statically for
    `<cdp-*>` elements with `param=` (or `param-x=` / `param-y=`)
    attributes. **Imperative `parameters.set(idx, v)` calls in your
    own JS — drag handlers on a `<canvas>`, custom widgets, anything
    not built on cdp-ui — are invisible to that scan.** A preset that
    drives every param via hand-rolled JS will fail the coverage check
    even though the param is fully reachable at runtime.

    Three escape hatches, pick whichever fits your layout:

    1. **Visible cdp-* widget alongside your custom UI.** Cleanest —
       gives the user a fallback control too.
    2. **Hidden cdp-* widgets in a `<details>` block.** Useful when
       your canvas-driven control is the primary surface but you want
       the validator (and DAWs without canvas drag) to see a binding.
       Collapse it by default; the binding still counts.
    3. **`<cdp-panel auto>`** — renders one widget per declared param
       automatically. One line, full coverage. Good as a stock fallback
       you ship below your hand-rolled canvas.

    `smoke_test_ui` runs the same check at runtime, so the failure mode
    is symmetric: both static lint and the offscreen WKWebView smoke
    test will tell you which params are unbound.

    `smoke_test_ui` also measures the rendered scroll extent against
    `manifest.ui.{width,height}` after `ready` fires. If the content
    needs more space than declared (by more than ~8pt on either axis),
    the response includes a `content_overflow` block — `{declared,
    rendered, overflows: ["height"], by_pixels: {height: 75}}` — and
    the field is omitted entirely when everything fits. The live
    plugin pins the webview to the manifest dimensions, so anything
    that overflows there clips silently for the user. When you see
    overflow, **bump `manifest.ui.height` (or `width`) up to the
    rendered size** rather than trying to compress the layout into a
    too-small budget — vertical headroom is cheap, cramped sliders
    aren't.

    ## Author JS API (`window.ConjureDSP.ui`)

    For preset JS beyond the components:

    ```js
    const { control, formatValue, denormalize, normalize } = ConjureDSP.ui;

    const cutoff = control(idx);        // { value, setValue(v), metadata,
                                        //   onChange(cb), normalize, denormalize }
    cutoff.onChange(v => draw(v));
    cutoff.setValue(2500);              // writes actual value (curve-aware)

    formatValue(1000, cutoff.metadata)  // "1.00 kHz"
    denormalize(0.5, cutoff.metadata)   // 0..1 -> actual (log curve: ~632 Hz)
    normalize(1000, cutoff.metadata)    // actual -> 0..1
    ```

    `ConjureDSP.ui.requireVersion(n)` — throws if the library is older
    than `n`. Bump when adding features your UI depends on.

    ## Param-name resolution

    Components accept `param=` as an index OR a name. Name matching is
    loose — case-insensitive, underscores and spaces are ignored. That
    means a SINGLE ui/index.html works with both the Python variant
    (`"low_gain"`, lowercase dict keys) and the Rust variant (`"Low Gain"`,
    Title Case from `params!()`'s `push_title_case`). Don't duplicate
    UIs per language.

    ## Theming

    Everything reads system colors (`CanvasText`, `Canvas`) so the UI
    tracks the host's light/dark mode automatically. Override at host level:

    ```css
    cdp-slider {
        --cdp-accent: #00d8ff;
        --cdp-track-bg: #2a2a2a;
        --cdp-thumb-size: 14px;
        --cdp-label-width: 90px;
        --cdp-value-width: 72px;
        --cdp-radius: 6px;
        --cdp-font-size: 12px;
    }
    cdp-xy::part(pad)   { border-radius: 10px; height: 220px; }
    cdp-xy::part(puck)  { width: 18px; height: 18px; }
    ```

    Exposed `::part()` names: `label`, `value`, `track`, `thumb`, `pad`,
    `puck`, `option`, `readout`, `axis-x-name`, `axis-x-value`,
    `axis-y-name`, `axis-y-value`.

    ## Audio frames (opt-in, for visualizers)

    Two-step setup — **both steps required, or onFrame never fires**:

    1. Declare in manifest:

       ```json
       "ui": { "entryHTML": "ui/index.html", "width": 520, "height": 380,
               "fps": 30, "audioFrames": true }
       ```

    2. Subscribe in JS:

       ```js
       ConjureDSP.audio.onFrame(frame => {
           // frame = { peakIn, peakOut, rmsIn, rmsOut, fft?, telemetry? }
           drawMeter(frame.peakOut);
       });
       ```

    If you call `onFrame` without `audioFrames: true` in the manifest,
    your callback registers but the capture pipeline isn't consuming —
    so no frames are ever delivered. There's no warning; the meter
    just stays at zero. This is the most common cause of "my meter
    doesn't move" reports.

    Pass `{ fft: true }` as a second arg to opt in to FFT (heavier
    payload; default payload is ~80 bytes).

    ### `frame.fftIn` / `frame.fftOut` shape

    Bin-to-frequency conversion (use `frame.sampleRate`, not a hardcoded
    48000 — the host can run at 44.1k / 96k / etc.):

    ```js
    ConjureDSP.audio.onFrame(frame => {
        if (!frame.fftOut) return;             // FFT only present when opts.fft = true
        const N = frame.fftOut.length * 2;     // FFT size (halfN bins published)
        for (let bin = 1; bin < frame.fftOut.length; bin++) {
            const hz  = bin * frame.sampleRate / N;
            const dB  = frame.fftOut[bin];     // already in dB, range [-120, 0]
            // …plot or aggregate…
        }
    }, { fft: true });
    ```

    Spec (matches `AudioCaptureManager.computeFFT`):

    - **Format:** real-only `Float32` array of **power dB**, computed as
      `10 * log10(|X[k]|² / N²)`. Already in dB — do **not** take
      `20*log10` again.
    - **Range:** clamped to **[-120.0, 0.0]** dB. -120 is silence; 0 is
      a full-scale unit-amplitude sinusoid hitting one bin exactly.
    - **Length:** `fftSize / 2` floats (default fftSize = 2048 → **1024
      bins**). Recover `N` as `frame.fftOut.length * 2`.
    - **Window:** Hann, normalized via `vDSP_HANN_NORM` (Accelerate's
      energy-preserving normalization).
    - **Hop:** 50% (`fftSize / 2` samples). FFT bins only ride along on
      ticks that produced a new column, so `frame.fftIn` / `frame.fftOut`
      are `undefined` on most ticks (CADisplayLink fires faster than
      hops complete) — gate on `if (!frame.fftOut) return;`.
    - **Bin → Hz:** `freq_hz = bin * frame.sampleRate / N` for bins
      `1..N/2 - 1`. Bin spacing is `sampleRate / N` (≈ 23.4 Hz at 48 kHz,
      `N = 2048`).
    - **DC and Nyquist:** vDSP's real-FFT packing folds **both** DC (bin
      0) and Nyquist (bin N/2) into `bins[0]` as
      `DC² + Nyquist²` — the array does not contain a separate Nyquist
      bin, and `bins[0]` is not pure DC. Skip `bin = 0` for any
      bin → frequency mapping that needs to be precise.
    - **Channel mix:** mono — input/output ring buffers feed the FFT
      from channel 0 only (no L/R split).

    Both `fftIn` and `fftOut` use the identical pipeline — same window,
    scale, clamp, and dB conversion — so per-bin subtraction
    (`fftOut[i] - fftIn[i]`) yields a meaningful dB delta.

    ### Smoothing FFT bins to display rate

    The gating idiom above (`if (!frame.fftOut) return;`) is necessary
    but not sufficient on its own: it draws *only* on FFT-column ticks,
    so bars step at ~23 Hz instead of flowing at display rate. Hold the
    last column in a per-bin buffer, decay it toward a visible floor,
    and coalesce paints through `requestAnimationFrame`:

    ```js
    const SPEC_FLOOR = -90;   // dB shown at the bottom of the canvas
    const SPEC_DECAY = 0.85;  // per-FFT-column decay coefficient

    let spec = null;          // Float32Array, smoothed per-bin dB

    function ingestSpectrum(prev, fresh) {
        const n = fresh.length;
        // Pre-fill with SPEC_FLOOR so the first decay step doesn't pull
        // from a 0 dB seed (which would otherwise flash near the canvas
        // top for one frame on UI mount).
        if (!prev || prev.length !== n) prev = new Float32Array(n).fill(SPEC_FLOOR);
        // Peak-hold, then decay toward the floor:
        //   decayed = prev * SPEC_DECAY + SPEC_FLOOR * (1 - SPEC_DECAY)
        //   held    = max(decayed, fresh)
        for (let i = 0; i < n; i++) {
            const decayed = prev[i] * SPEC_DECAY + SPEC_FLOOR * (1 - SPEC_DECAY);
            prev[i] = fresh[i] > decayed ? fresh[i] : decayed;
        }
        return prev;
    }

    let raf = 0;
    function scheduleRedraw() {
        if (raf) return;
        raf = requestAnimationFrame(() => { raf = 0; drawSpectrum(spec); });
    }

    ConjureDSP.audio.onFrame(frame => {
        if (!frame.fftOut) return;          // gate: only update on FFT columns
        spec = ingestSpectrum(spec, frame.fftOut);
        scheduleRedraw();                   // one paint per display tick
    }, { fft: true });
    ```

    Why each piece matters:

    - **Peak-hold-then-decay-toward-floor**, not raw bin updates: a loud
      transient snaps to the new value immediately and then drifts down
      toward `SPEC_FLOOR` over many display ticks — easier to read than
      ~23 Hz steps. The recurrence decays toward the floor, not toward
      the fresh value; the difference matters if you adapt it.
    - **`SPEC_FLOOR` pre-fill** of the buffer: without it the buffer
      starts at 0 dB (`new Float32Array(n)`), and the first decay step
      lands at `SPEC_FLOOR * (1 - 0.85) ≈ -13.5 dB` — visible as a brief
      flash near the canvas top on UI mount.
    - **`requestAnimationFrame` coalescer**: the buffer is updated every
      FFT-column tick (~23 Hz at 48 kHz / N=2048, see the Hop bullet
      above and the cadence comment at AudioCaptureManager.swift:554),
      but the *paint* runs at display rate so motion stays smooth.
    - **No throttle in the canonical shape**: call `scheduleRedraw()`
      directly. Presets that overlay an FFT on a draggable curve (where
      parameter-drag triggers its own redraws) may add a `performance.now()`
      throttle to avoid competing — see
      `preset_eq3.cdp/ui/index.html:139` for that variant. Pure
      analyzers should leave it unthrottled.
    - **Use `frame.sampleRate`** for any bin → Hz mapping (already shown
      in the bin-conversion example above): never hardcode 48000.

    ## DSP→UI telemetry channel

    For meters / visualizers that need to show **internal DSP state**
    (gain reduction, envelope follower output, sidechain RMS, NAM
    model magnitude) — values that aren't reconstructible from
    rmsIn/rmsOut — declare named float slots the DSP writes per block.

    Rust:

    ```rust
    use conjuredsp::*;
    telemetry! {
        GR_DB  = scalar_telemetry().unit("dB"),
        ENV_DB = scalar_telemetry().unit("dB"),
    }
    process! { ctx =>
        // … DSP …
        ctx.set_telemetry_scalar(GR_DB, max_gr_db_this_block);
        ctx.set_telemetry_scalar(ENV_DB, env_db);
    }
    ```

    The macro must be invoked with at least one slot — either fill it in
    or omit it entirely. Empty `telemetry!{}` and `telemetry!()` forms
    are accepted as no-ops so the script still compiles while you're
    iterating, but they don't expose anything to the host.

    Python (`ctx.telemetry` is the single writable mapping):

    ```python
    TELEMETRY = {"gr_db": {"unit": "dB"}, "env_db": {"unit": "dB"}}
    def process(ctx):
        ctx.telemetry["gr_db"] = max_gr_db_this_block
        ctx.telemetry["env_db"] = env_db
    ```

    UI consumer — slot key is the script's source token verbatim
    (`GR_DB` for the Rust macro identifier, `"gr_db"` for the Python
    dict key). No canonicalization: telemetry has no DAW-facing
    surface, so title-casing would only mangle acronyms (DB / RMS /
    GR / FFT) without enabling any third consumer:

    ```js
    ConjureDSP.audio.onFrame(frame => {
        if (!frame.telemetry) return;        // legacy preset, no slots
        const gr = frame.telemetry["GR_DB"]; // Rust-side identifier
        meter.show(gr);
    });
    ```

    UIs that target both backends use a `??` chain:

    ```js
    const gr = frame.telemetry["GR_DB"] ?? frame.telemetry["gr_db"];
    ```

    **Telemetry rides on `audio.onFrame`** — so the manifest still
    needs `"audioFrames": true`. Without it, the DSP keeps writing to
    its slots but no frames are ever delivered to JS, and your meter
    sits at zero. See "Audio frames" above for the manifest snippet.

    Don't mirror DSP math in JS to compute these values — parameter
    changes leak between block boundaries, attack/release state is
    hard to track from outside, and the result drifts from the audio
    whenever you tweak the script. 16 slots max per script (scalar +
    vector combined). Zero overhead for presets that don't declare any.

    ## Vector telemetry (array visualizers)

    Scalar slots emit one value per block — fine for meters that show
    "how much" but useless when the UI needs an array per block (one
    value per comb-filter tap, per grain in a pool, per audio frame
    for a scope). Declare a `vector_telemetry` slot and the host
    publishes a JS Array on every `audio.onFrame` tick.

    **Length contract.** Each slot is a fixed buffer of capacity
    `MAX_FRAMES` (4096). The host reads exactly `frame_count` floats
    from the slot per block — that's also the JS Array length the UI
    receives. Indices past what your script wrote are stale (initially
    zero, then whatever the previous block left there). Plan for that
    on the read side: write your N values into the first N indices and
    have the UI consume only those.

    **Common pattern: fixed-length control vector.** Publish N floats
    per block — one per "channel" of whatever you're visualizing (e.g.
    one per comb-filter tap, one per grain in a pool). The UI reads
    `frame.telemetry["BAR_ENERGY"]` and takes the first N elements.

    Rust:

    ```rust
    use conjuredsp::*;
    const TAPS: usize = 6;
    telemetry! {
        BAR_ENERGY = vector_telemetry(),
    }
    process! { ctx =>
        // … your per-tap DSP …
        let mut bars = [0.0f32; TAPS];
        for t in 0..TAPS { bars[t] = comb[t].rms(); }
        ctx.set_telemetry_vector(BAR_ENERGY, &bars);
    }
    ```

    Python:

    ```python
    TAPS = 6
    TELEMETRY = {"BAR_ENERGY": {"shape": "vector"}}
    def process(ctx):
        # Slice-assign into the pre-seeded numpy array — don't replace it.
        for t in range(TAPS):
            ctx.telemetry["BAR_ENERGY"][t] = comb[t].rms()
    ```

    UI consumer — `<cdp-scope length="6">` truncates rendering to the
    first six samples, so the stale tail never paints:

    ```html
    <cdp-scope telemetry="BAR_ENERGY" length="6" min="0" max="1"></cdp-scope>
    ```

    Or hand-rolled, slicing the first N off the JS Array:

    ```js
    ConjureDSP.audio.onFrame(frame => {
        if (!frame.telemetry) return;
        const bars = frame.telemetry["BAR_ENERGY"];
        if (!Array.isArray(bars)) return;        // legacy/scalar
        const visible = bars.slice(0, 6);        // ignore stale tail
        // draw six bars from `visible`…
    });
    ```

    **Slot name casing.** `frame.telemetry["…"]` in raw JS is an exact
    object-property lookup — `frame.telemetry["BAR_ENERGY"]` and
    `frame.telemetry["bar_energy"]` are different keys, and only the one
    your script actually published resolves. Match casing on both sides,
    or use the `??` fallback shown under "Telemetry slots" above. The
    `<cdp-scope telemetry="…">` (and `<cdp-bargraph>`) attribute is the
    one exception: the component runs the same case/underscore/space-
    insensitive resolver as `param=`, so a single UI binds to both a
    Rust `BAR_ENERGY` slot and a Python `bar_energy` slot.

    **Audio-rate pattern: per-sample vector.** When the UI needs the
    *shape* of the signal (oscilloscope, waveform display), publish
    `frame_count` values — one per audio frame in the current block.
    No truncation needed on the read side; the JS Array length already
    matches what you wrote.

    Rust:

    ```rust
    use conjuredsp::*;
    telemetry! {
        SCOPE = vector_telemetry(),
    }
    persist_buf!(SCOPE_BUF: [f32; MAX_FR] = [0.0; MAX_FR]);
    process! { ctx =>
        SCOPE_BUF.with_mut(|scope_buf| {
            for i in 0..ctx.frames() {
                let y = saturator.process(ctx.input(0, i));
                ctx.set_output(0, i, y);
                scope_buf[i] = y;
            }
            ctx.set_telemetry_vector(SCOPE, &scope_buf[..ctx.frames()]);
        });
    }
    ```

    Python:

    ```python
    TELEMETRY = {"scope": {"shape": "vector"}}
    def process(ctx):
        # Run your per-frame DSP into ctx.outputs[0]; then publish into
        # the telemetry slot. ctx.outputs[0] is already a length-frame_count
        # row view; the telemetry slot is sized to MAX_FRAMES, so this side
        # still needs [:ctx.frame_count].
        ctx.telemetry["scope"][:ctx.frame_count] = ctx.outputs[0]
    ```

    `<cdp-scope>` decimates long vectors to one min+max pair per pixel
    column and auto-ranges the y-axis:

    ```html
    <cdp-scope telemetry="scope" min="-1" max="1" grid></cdp-scope>
    ```

    Same `audioFrames: true` manifest gate. Same 16-slot budget (scalar
    + vector combined). Pick vector only when the UI actually needs
    multiple values per block — a single-value meter is a scalar slot,
    one float instead of `frame_count` floats per block.

    **Optional `manifest.telemetry` block for static lint.** If you
    want `validate_bundle` to catch typos in `<cdp-scope telemetry="…">`
    references the way it catches `<cdp-slider param="…">` typos, declare
    the slots in the manifest (mirrors `manifest.params`):

    ```json
    "telemetry": [
        { "name": "scope",  "shape": "vector" },
        { "name": "gr_db",  "shape": "scalar", "unit": "dB" }
    ]
    ```

    Without the block, telemetry references resolve at runtime against
    whatever the loaded script publishes — works fine, just no static
    "did you mean" hint on a typo.

    ## Worked example: telemetry meter + tempo-sync

    A complete three-file preset that exercises every piece authors
    most often fumble: single-ctx Python signature, transport BPM,
    telemetry slot, `audioFrames: true`, schemaVersion 2 declared
    params, and a cdp-ui meter driven by the slot. Copy verbatim and
    edit.

    `process.py`:

    ```python
    import math
    from conjuredsp import db, mix

    PARAMS = {
        "depth":      db(min=0.0, max=24.0, default=6.0),   # duck depth
        "rate_div":   {"name": "Rate", "min": 0, "max": 2,
                        "default": 1, "style": "choice",
                        "options": ["1/4", "1/8", "1/16"]},
    }
    TELEMETRY = {"gr_db": {"unit": "dB"}}

    _phase = 0.0  # 0..1 cycle position

    def process(ctx):
        global _phase
        depth_db = ctx.params["depth"]
        beats_per_cycle = [1.0, 0.5, 0.25][int(ctx.params["rate_div"])]
        bpm = ctx.transport.bpm                    # canonical key
        rate_hz = (bpm / 60.0) / beats_per_cycle
        gain_floor = 10.0 ** (-depth_db / 20.0)

        n_ch, frame_count = ctx.inputs.shape
        max_gr_db = 0.0
        for i in range(frame_count):
            _phase = (_phase + rate_hz / ctx.sample_rate) % 1.0
            # Triangle envelope: peaks at depth at phase=0, returns to 1.0 at 0.5
            env = gain_floor + (1.0 - gain_floor) * abs(2.0 * _phase - 1.0)
            gr_db_now = -20.0 * math.log10(max(env, 1e-9))
            if gr_db_now > max_gr_db:
                max_gr_db = gr_db_now
            # env is a scalar this sample, so write to the i-th column
            # of every channel in one slice assignment.
            ctx.outputs[:, i] = ctx.inputs[:, i] * env

        ctx.telemetry["gr_db"] = max_gr_db        # peak GR over the block
    ```

    `manifest.json`:

    ```json
    {
        "schemaVersion": 2,
        "entry": "process.py",
        "language": "python",
        "params": [
            {"name": "depth", "min": 0, "max": 24, "default": 6, "unit": "dB"},
            {"name": "Rate",  "min": 0, "max": 2,  "default": 1,
             "style": "choice", "options": ["1/4", "1/8", "1/16"]}
        ],
        "ui": {
            "entryHTML": "ui/index.html",
            "width": 360,
            "height": 200,
            "fps": 30,
            "audioFrames": true
        }
    }
    ```

    `ui/index.html`:

    ```html
    <!doctype html>
    <html>
    <head>
        <meta charset="utf-8">
        <style>
            body { margin: 0; padding: 14px 16px;
                   font: 12px -apple-system, system-ui, sans-serif;
                   background: Canvas; color: CanvasText; }
            cdp-slider, cdp-choice { display: block; margin: 6px 0; }
            #meter { height: 14px; background: color-mix(in srgb,
                     CanvasText 12%, transparent); border-radius: 4px;
                     overflow: hidden; margin-top: 10px; }
            #bar { height: 100%; width: 0%; background: CanvasText;
                   transition: width 60ms linear; }
        </style>
    </head>
    <body>
        <cdp-slider param="depth"></cdp-slider>
        <cdp-choice param="Rate"></cdp-choice>
        <div id="meter"><div id="bar"></div></div>
        <script>
            ConjureDSP.ready(() => {
                const bar = document.getElementById('bar');
                const CEILING_DB = 24.0;
                ConjureDSP.audio.onFrame(frame => {
                    if (!frame.telemetry) return;
                    const gr = frame.telemetry["gr_db"] ?? 0;
                    bar.style.width = Math.min(100, gr / CEILING_DB * 100) + '%';
                });
            });
        </script>
    </body>
    </html>
    ```

    What this exercises end-to-end:
    - Canonical single-ctx `process(ctx)` signature
    - `ctx.transport.bpm` (canonical key)
    - `TELEMETRY = {...}` declaration → `ctx.telemetry["gr_db"] = ...`
      in `process` → `frame.telemetry["gr_db"]` in JS
    - `manifest.ui.audioFrames: true` so the frame pipeline runs
    - `schemaVersion: 2` with declared `params` so the UI renders
      correct defaults during script load
    - `cdp-choice` for the rate division (segmented control, ≤2 options
      becomes segmented; here 3 options → dropdown)

    ## Canvas pattern

    Canvas 2D can't parse `color-mix()` or the `CanvasText` keyword. To
    get a theme-correct stroke color:

    ```js
    function resolveFG() {
        const probe = document.createElement('span');
        probe.style.cssText = 'color: CanvasText; position: absolute; visibility: hidden;';
        document.body.appendChild(probe);
        const c = getComputedStyle(probe).color;
        probe.remove();
        return c;
    }
    ```

    Re-resolve on the `themechange` event.

    ## Network & sandbox

    The WebView runs with a strict CSP (`default-src 'self' 'unsafe-inline'
    data:; connect-src 'none';`) and a content rule list. fetch/XHR/
    WebSocket egress is blocked. All assets must live inside the bundle
    (`ui/index.html`, `ui/assets/*`). Use the `conjuredsp-preset://preset/...`
    scheme for cross-file references, or relative paths.

    ## Gotchas

    - Metadata is late-binding: on preset switch the components may render
      with a placeholder before `params` arrive. Components re-bind
      automatically; any custom JS should listen to `ConjureDSP.ready(cb)`
      before reading parameter state at startup — `parameters.get(i)` is
      `undefined`, `ConjureDSP.ui.control(i).value` is `undefined`
      (non-finite — crashes `CanvasRenderingContext2D` / `Path2D` calls
      with "provided value is non-finite"), and `parameters.metadata(i)`
      is `null` until `_init` lands. If you need a first-paint render
      before `ready` fires, hardcode a literal placeholder — do not read
      the bridge.
    - `onChange`/`onAnyChange` fires for ALL parameter writes — your own
      `parameters.set(...)` calls AND external automation (DAW, MIDI,
      MCP, preset load). Use it as the single source of truth for
      visual updates; a hand-rolled knob whose redraw lives in
      `ctrl.onChange(cb)` will redraw on the user's drag the same way
      it does on automation. Self-writes are deduped on equal values,
      so handlers that re-set the same value they received terminate.
    - The same bundle's UI also renders inside an exported standalone AU
      via `ExportCustomUIWebView`. Don't rely on devtools or host-only
      APIs.

    ## Sizing your UI

    The scaffold (`save_preset` with `scaffold_ui: true`) writes a
    `manifest.ui` block sized 520 × 260. That fits a few stacked sliders
    but clips quickly once you add panels, knob rows, or canvases. If
    your layout overflows, bump the values in `manifest.json`:

    ```json
    "ui": { "entryHTML": "ui/index.html", "width": 720, "height": 420,
            "fps": 30, "audioFrames": false }
    ```

    `width` / `height` are pt; the manifest value is the initial size
    DAWs allocate, so set it to the size your layout actually needs.

    `smoke_test_ui` reports a `content_overflow` block whenever the
    rendered document is larger than the manifest dimensions:

    ```json
    "content_overflow": {
        "actual_width": 612, "actual_height": 318,
        "manifest_width": 520, "manifest_height": 260
    }
    ```

    The field is absent when the layout fits. **Always run
    `smoke_test_ui` after authoring a new UI or resizing an existing
    one** — it catches overflow plus runtime JS errors (thrown in
    `ready(cb)` callbacks, unbound `param=` references, etc.) that the
    static validator can't see.

    If a layout legitimately needs more than ~800 × 600, weigh whether a
    custom UI is the right tool at all: narrow DAW panes (Logic's Smart
    Controls, Live's device chain) will scroll-clip a tall webview, and
    a scrollable layout inside a smaller manifest size often serves
    users better than a fixed oversized one.

    ## Common failures and how to avoid them

    Each of these has broken past custom UIs. The static validator
    (invoked automatically by write_bundle_file, or explicitly via
    validate_bundle) catches most of them. Prevent them at author time
    by using these recipes.

    ### NaN in readouts / dead sliders

    The #1 custom-UI bug. Cause: hand-rolling param math against assumed
    metadata field names (`meta.min`, `meta.range`, etc.) instead of
    using the control helpers.

    WRONG:
    ```js
    // Invented math — metadata doesn't have a `range` field, so this
    // produces NaN that propagates to every downstream calculation.
    const v = meta.min + fraction * meta.range;
    ```

    RIGHT:
    ```js
    const c = ConjureDSP.ui.control(idx);
    c.setValue(c.denormalize(fraction));   // 0..1 -> actual, curve-aware
    const t = c.normalize(c.value);        // actual -> 0..1, curve-aware
    const label = ConjureDSP.ui.formatValue(c.value, c.metadata);
    ```

    The helpers respect `curve: "log"`, unit formatting, toggle vs slider
    vs choice styles — all the metadata shapes you'd otherwise have to
    special-case.

    ### control() accepts both index and name

    `ConjureDSP.ui.control(...)` takes EITHER a numeric index OR a param
    name string — same loose match `<cdp-slider param="...">` uses
    (case / underscore / space insensitive):

    ```js
    const a = ConjureDSP.ui.control(0);          // by index
    const b = ConjureDSP.ui.control('Drive');    // by name (any case)
    const c = ConjureDSP.ui.control('low gain'); // matches LOW_GAIN, lowGain, etc.
    ```

    Returns `null` when a name doesn't resolve, with a warning logged
    via `ConjureDSP.log` so the typo shows up in Console.app instead
    of silently freezing your widget. Always check for null when you
    pass a name:

    ```js
    const drive = ConjureDSP.ui.control('Drive');
    if (drive) drive.onChange(v => redraw(v));
    ```

    ### SVG drag regions that don't respond to the mouse

    When you attach a `pointerdown` listener to an SVG `<g>`, the
    decorative children inside it can swallow the pointer event before
    it reaches the group's handler. Two rules:

    1. Give the group an invisible hit pad as its **first** child
       (first = behind, so siblings render on top but still pass events
       through). A transparent `<rect>` the size of the interactive
       bounding box works.
    2. Apply `pointer-events: none` to every decorative child in the
       group. Leave it UNSET on the hit pad.

    ```html
    <g id="ghost" onpointerdown="startDrag(event)">
        <rect x="0" y="0" width="80" height="120" fill="rgba(0,0,0,0.001)" />
        <path d="..." pointer-events="none" fill="white" opacity="0.8" />
        <circle cx="40" cy="30" r="4" pointer-events="none" />
    </g>
    ```

    Also: if the group is layered behind another element in document
    order, that other element will steal pointer events regardless of
    the hit pad. Keep interactive regions on top, or apply
    `pointer-events: none` to the overlays.

    ### Canvas 2D fillStyle = "CanvasText" silently paints black

    Canvas 2D's parser doesn't understand CSS system-color keywords or
    `color-mix()`. It falls back to black (or whatever was previously
    set), defeating the theme-aware intent.

    Resolve via a getComputedStyle probe on a hidden element:

    ```js
    function resolveFG() {
        const probe = document.createElement('span');
        probe.style.cssText = 'color: CanvasText; position: absolute; visibility: hidden;';
        document.body.appendChild(probe);
        const c = getComputedStyle(probe).color;   // "rgb(232, 232, 232)" or similar
        probe.remove();
        return c;
    }
    let FG = resolveFG();
    window.addEventListener('themechange', () => { FG = resolveFG(); redraw(); });
    ```

    ### Decorative UI with no way to change parameters

    A UI that looks great but offers zero controls leaves users stuck.
    At minimum, include one of:

    - `<cdp-panel auto></cdp-panel>` — catch-all that renders one
      control per declared param, themed to match the rest of the UI.
    - A per-param `<cdp-slider>` / `<cdp-toggle>` / `<cdp-choice>` /
      `<cdp-xy>`, even if hidden behind a toggle button.

    The validator warns when the HTML has zero interactive elements AND
    the manifest declares at least one param.

    ### External scripts, stylesheets, fonts, fetch calls

    The webview's CSP is `default-src 'self' 'unsafe-inline' data:;
    connect-src 'none';`. Any of these silently fail:

    - `<script src="https://cdn.jsdelivr.net/...">`
    - `<link rel="stylesheet" href="https://fonts.googleapis.com/...">`
    - `@import url("https://...");`
    - `fetch("https://api.example.com/...")`
    - `new WebSocket("wss://...")`

    All assets must live inside the bundle. Inline small scripts/styles
    directly in `ui/index.html`. Ship larger assets under
    `ui/assets/*.{css,js,png,woff2}` and reference with relative paths.

    ### Illegible text: low contrast or hard-coded colors against Canvas

    Two related traps:

    1. **Low contrast**: `color: #222` on `background: #333` is
       unreadable. The validator flags contrast ratios below 3.0 (WCAG
       AA large-text threshold). Pick colors that differ enough in
       luminance.
    2. **Theme-breaking hard-coded body color**: `body { color: white;
       background: Canvas; }` looks fine in dark mode — and disappears
       completely in light mode, where `Canvas` resolves to white. The
       reverse with `color: black` is invisible in dark mode.

    The cleanest pattern: let the OS do the work.

    ```css
    body {
        color: CanvasText;       /* resolves to black in light, white in dark */
        background: Canvas;      /* resolves to white in light, near-black in dark */
    }
    ```

    If you need a specific palette, commit to it fully — pair a
    hard-coded text color with a hard-coded background color that
    contrasts, and skip `Canvas`/`CanvasText` entirely for that element.
    Don't mix (hard-coded text, theme-aware background).

    ### UI renders once, breaks on hot reload

    The file watcher calls `webView.reload()` after every file change.
    The whole document is rebuilt from scratch each time. Don't capture
    DOM nodes or listeners in module-level state expecting them to
    survive reloads — they won't.

    The cdp-ui components re-bind automatically on reload. Author JS
    should do all DOM queries inside `ConjureDSP.ready(...)` or on
    `DOMContentLoaded`, not at script top level before the document is
    parsed.

    ## Minimal example

    ```html
    <!doctype html>
    <html>
    <head>
        <meta charset="utf-8">
        <style>
            body { margin: 0; padding: 14px 16px;
                   font: 12px -apple-system, system-ui, sans-serif;
                   background: Canvas; color: CanvasText; }
            cdp-slider { display: block; margin: 4px 0; }
        </style>
    </head>
    <body>
        <cdp-slider param="cutoff"></cdp-slider>
        <cdp-slider param="resonance"></cdp-slider>
    </body>
    </html>
    ```

    That's a complete, themed, DAW-ready UI. No script, no imports, no
    build.

    ## Reference presets to copy patterns from

    - `preset_svf` — XY pad driving cutoff + resonance, Canvas response
      curve, dB Y-axis labels.
    - `preset_compressor` — stacked sliders with labels/values, transfer-
      curve Canvas, GR meter column, audio-frame subscription.
    - `preset_wavefolder` — transfer curve Canvas with absolute-positioned
      wrap to avoid feedback sizing loops.
    - `preset_acid_sermon` — percent-based controls, no Canvas.
    - `preset_eq3` — three dB bands with toggles.

    Read them with `read_bundle_file` when you need a template.
    """

    /// All sections joined (excludes NAM — requires knowing downloaded tones).
    static var allDocs: String {
        [params, filters, delays, oscillators, utilities, accel, state, ui]
            .joined(separator: "\n\n")
    }

    /// All sections including NAM (for the MCP get_docs "all" topic).
    static var allDocsWithNam: String {
        [params, filters, delays, oscillators, utilities, accel, nam, state, ui]
            .joined(separator: "\n\n")
    }

    // MARK: - Language-filtered docs (for AI Prompt Helper)

    /// Returns API docs filtered to a single language — omits examples for the other language.
    static func docs(for language: ScriptLanguage) -> String {
        switch language {
        case .python:
            return [pythonParams, pythonFilters, pythonDelays, pythonOscillators, pythonUtilities, pythonAccel]
                .joined(separator: "\n\n")
        case .rust:
            return [rustParams, rustFilters, rustDelays, rustOscillators, rustUtilities, rustAccel]
                .joined(separator: "\n\n")
        }
    }

    private static let pythonParams = """
    # Parameter Builders

    Available builders and their default ranges:

    freq — 20-20000 Hz, log curve, default 1000 (audio-rate — filters, oscillators)
    lfo_rate — 0.1-20 Hz, log curve, default 1 (sub-audio — tremolo / autopan / chorus rate)
    db — -60 to +12 dB, linear curve, default 0
    time_ms — 0.1-1000 ms, log curve, default 100
    mix — 0.0-1.0, linear, default 0.5
    pct — 0-100%, linear, default 50
    toggle — 0/1, rendered as switch in UI, default 0
    ratio — 1-20 :1, linear, default 4
    param — generic with explicit min/max, default=min, linear, no unit

    ## Syntax

    Builders are functions that return dicts. Customize via keyword arguments:

      from conjuredsp import freq, db, time_ms, mix, pct, toggle, choice, ratio, param

      PARAMS = {
          "cutoff": freq(),                                # use defaults: 20-20000 Hz
          "attack": time_ms(0.5, 50, default=5),           # positional min/max, keyword default
          "damping": freq(min=500, max=16000, default=4000),  # all keyword args
          "drive": pct(default=70),
          "mix": mix(default=0.35),
          "bypass": toggle(),
          "mode": choice("Low", "Mid", "High", default="Mid"),  # dropdown
      }

    param() accepts: param(min, max, unit="", default=None, curve="linear")

    choice(*labels, default=None) — Dropdown menu, receives selected index as float \
    (0.0, 1.0, ...). Requires at least 2 labels.

    ## How parameters are delivered

    With PARAMS metadata: scripts receive denormalized actual values (e.g., 1000.0 Hz).
    Without PARAMS: scripts receive raw 0-1 normalized floats (legacy mode).
    params arg is a dict keyed by name.

    ## Reporting algorithmic latency

    Scripts with lookahead/FFT/oversampling declare LATENCY = <samples> at module scope;
    the host reports it via AUAudioUnit.latency for DAW delay compensation. Don't include
    creative delay time (delay lines, chorus, reverb) in this number — only true
    pre-process delay.
    """

    private static let rustParams = """
    # Parameter Builders

    Available builders and their default ranges:

    freq — 20-20000 Hz, log curve, default 1000 (audio-rate — filters, oscillators)
    lfo_rate — 0.1-20 Hz, log curve, default 1 (sub-audio — tremolo / autopan / chorus rate)
    db — -60 to +12 dB, linear curve, default 0
    time_ms — 0.1-1000 ms, log curve, default 100
    mix — 0.0-1.0, linear, default 0.5
    pct — 0-100%, linear, default 50
    toggle — 0/1, rendered as switch in UI, default 0
    choice — dropdown menu (style:"choice"), receives selected index as f64 (0.0, 1.0, …)
    ratio — 1-20 :1, linear, default 4
    param — generic with explicit min/max, default=min, linear, no unit

    ## Syntax

    Builders are const functions. Customize via method chaining:

      params! {
          CUTOFF = freq(),                                  // use defaults: 20-20000 Hz
          ATTACK = time_ms().min(0.5).max(50.0).default(5.0),
          DAMPING = freq().min(500.0).max(16000.0).default(4000.0),
          DRIVE = pct().default(70.0),
          MIX = mix().default(0.35),
          BYPASS = toggle(),
          DIVISION = choice(&["1/1", "1/2", "1/4", "1/8"]).default(2.0),  // dropdown
          ROTATE = param(0.0, 360.0).unit("°").default(0.0),  // generic builder
      }

    Chaining methods: .min(val), .max(val), .default(val), .unit("str"), .curve("log" or "linear")
    All are const fn and can be used in static/const contexts. The typed
    builders (freq, db, time_ms, toggle, choice, …) are presets over the same
    modifier surface; use param(min, max) when none of them fit. `choice` takes
    a static slice of labels and renders as a dropdown — the script reads the
    selected index via `ctx.param(INDEX)` (0.0, 1.0, …).

    ## How parameters are delivered

    With PARAMS metadata: scripts receive denormalized actual values (e.g., 1000.0 Hz).
    Without PARAMS: scripts receive raw 0-1 normalized floats (legacy mode).
    Params are accessed via ctx.param(INDEX).

    ## Sidechain + telemetry accessors

    ctx.sidechain(c, i) — read sidechain input sample. Returns 0.0 when nothing is routed.
    ctx.sidechain_connected() — bool. Branch on this before reading; fall back to ctx.input.
    ctx.sidechain_channels() — usize, 0 when nothing is routed, up to 2.
    ctx.set_telemetry_scalar(slot, value) — publish one f32 per render block to the host UI.

    ## Reporting algorithmic latency

    Scripts with lookahead/FFT/oversampling declare latency!(<samples>); the host reports
    it via AUAudioUnit.latency for DAW delay compensation. Don't include creative delay
    time (delay lines, chorus, reverb) in this number — only true pre-process delay.
    """

    private static let pythonFilters = """
    # Filters — BiquadCoeffs + Biquad

    Biquad filters using Audio EQ Cookbook formulas (Robert Bristow-Johnson).
    All internal math uses f64 for precision. Create one Biquad per channel.

    ## BiquadCoeffs — coefficient calculation (stateless)

    3-argument filters (freq, q, sample_rate):
      .lowpass(freq, q, sr)    — passes frequencies below cutoff
      .highpass(freq, q, sr)   — passes frequencies above cutoff
      .bandpass(freq, q, sr)   — passes a frequency band (constant skirt gain)
      .notch(freq, q, sr)      — removes a frequency band
      .allpass(freq, q, sr)    — passes all frequencies, shifts phase

    4-argument filters (freq, q, gain_db, sample_rate):
      .peak(freq, q, gain_db, sr)      — boosts or cuts at center frequency
      .lowshelf(freq, q, gain_db, sr)   — boosts or cuts below cutoff
      .highshelf(freq, q, gain_db, sr)  — boosts or cuts above cutoff

    Parameters:
      freq — center/cutoff frequency in Hz
      q — quality factor (0.707 = Butterworth/no resonance, higher = narrower/more resonant)
      gain_db — boost/cut in dB (only for peak, lowshelf, highshelf)
      sr — sample rate in Hz

    BiquadCoeffs.lowpass(freq, q, sr) — returns BiquadCoeffs instance

    Zero-value / passthrough:
      .identity() — passthrough coeffs (b0=1, rest=0). Use for pre-allocating
                    a list of slots that will be filled at runtime, e.g. a
                    parametric EQ where each band picks a filter type:
                      bands = [BiquadCoeffs.identity() for _ in range(5)]

    ## Biquad — stateful filter (Direct Form II Transposed)

    Biquad(coeffs=None) — passthrough if no coeffs

    Methods:
      .set_coeffs(coeffs)        — update coefficients without resetting state
      .process_sample(x) -> y    — filter one sample
      .reset()                   — zero internal state (z1, z2)

    ## Typical usage pattern

      _filters = None
      def process(ctx):
          global _filters
          n_ch, frame_count = ctx.inputs.shape
          if _filters is None:
              _filters = [Biquad() for _ in range(n_ch)]
          coeffs = BiquadCoeffs.lowpass(ctx.params["cutoff"], 0.707, ctx.sample_rate)
          for ch in range(n_ch):
              _filters[ch].set_coeffs(coeffs)
              row_in = ctx.inputs[ch]
              row_out = ctx.outputs[ch]
              for i in range(frame_count):
                  row_out[i] = _filters[ch].process_sample(row_in[i])
    """

    private static let rustFilters = """
    # Filters — BiquadCoeffs + Biquad

    Biquad filters using Audio EQ Cookbook formulas (Robert Bristow-Johnson).
    All internal math uses f64 for precision. Create one Biquad per channel.

    ## BiquadCoeffs — coefficient calculation (stateless)

    3-argument filters (freq, q, sample_rate):
      ::lowpass(freq, q, sr)    — passes frequencies below cutoff
      ::highpass(freq, q, sr)   — passes frequencies above cutoff
      ::bandpass(freq, q, sr)   — passes a frequency band (constant skirt gain)
      ::notch(freq, q, sr)      — removes a frequency band
      ::allpass(freq, q, sr)    — passes all frequencies, shifts phase

    4-argument filters (freq, q, gain_db, sample_rate):
      ::peak(freq, q, gain_db, sr)      — boosts or cuts at center frequency
      ::lowshelf(freq, q, gain_db, sr)   — boosts or cuts below cutoff
      ::highshelf(freq, q, gain_db, sr)  — boosts or cuts above cutoff

    Parameters:
      freq — center/cutoff frequency in Hz
      q — quality factor (0.707 = Butterworth/no resonance, higher = narrower/more resonant)
      gain_db — boost/cut in dB (only for peak, lowshelf, highshelf)
      sr — sample rate in Hz

    BiquadCoeffs::lowpass(freq, q, sr) — returns BiquadCoeffs (Copy type)
    IMPORTANT: all three arguments must be f64. Cast with `as f64`:
      BiquadCoeffs::lowpass(cutoff as f64, q as f64, sample_rate as f64)

    Zero-value / passthrough:
      ::identity() — const fn, passthrough coeffs (b0=1, rest=0). Use for
                     stack-allocating a fixed-size array of slots that will be
                     filled at runtime (e.g. a parametric EQ where each band
                     picks a filter type):
                       let mut bands: [BiquadCoeffs; 5] = [BiquadCoeffs::identity(); 5];
                     Also implements Default for runtime use
                     (`BiquadCoeffs::default()`, `#[derive(Default)]` on
                     containing structs). Array initializers must use
                     `::identity()` — trait methods aren't `const` on stable
                     Rust, so `[BiquadCoeffs::default(); N]` won't compile.

    ## Biquad — stateful filter (Direct Form II Transposed)

    Biquad::new() — const fn, passthrough by default. Copy type.

    Methods:
      .set_coeffs(coeffs)        — update coefficients without resetting state
      .process_sample(x) -> y    — filter one sample (f64)
      .reset()                   — zero internal state (z1, z2)

    ## Typical usage pattern

      persist!(BIQUADS: [Biquad; 2] = [Biquad::new(); 2]);
      // Inside process! { ctx => ... }:
      let coeffs = BiquadCoeffs::lowpass(ctx.param(CUTOFF) as f64, 0.707, ctx.sample_rate() as f64);
      let mut biquads = BIQUADS.get();
      for c in 0..ctx.channels() {
          biquads[c].set_coeffs(coeffs);
          for i in 0..ctx.frames() {
              ctx.set_output(c, i, biquads[c].process_sample(ctx.input(c, i) as f64) as f32);
          }
      }
      BIQUADS.set(biquads);
    """

    private static let pythonDelays = """
    # DelayLine — Circular Buffer

    Pre-allocated circular buffer for delay effects with fractional-sample interpolation.

    ## Construction

    DelayLine(max_samples: int) — numpy float32 backed
      Sizing: int(max_delay_seconds * sample_rate)
      Property: .max_samples → int

    ## Methods

    .write(sample)              — write one sample and advance write head
    .read(delay_samples)        — fractional delay with linear interpolation
    .read_cubic(delay_samples)  — fractional delay with 4-point Hermite interpolation (better for
                                  pitch shifting and modulated delays)
    .tap(delay_samples)         — integer delay, no interpolation
    .clear()                    — zero buffer and reset write position

    ## Delay time conversion

    delay_samples = delay_time_ms * 0.001 * sample_rate
    max_samples = int(max_delay_seconds * sample_rate)

    ## Notes

    - write() before read() each sample — write advances the head, read looks backward
    - read(0) and tap(0) return the sample at the current write position (just written)
    - read(1) / tap(1) returns the previous sample
    """

    private static let rustDelays = """
    # DelayLine — Circular Buffer

    Pre-allocated circular buffer for delay effects with fractional-sample interpolation.

    ## Construction

    DelayLine::<SIZE>::new() — const generic, compile-time size
      SIZE must be a const. Example: DelayLine::<48000>::new()
      Stored across blocks via persist_buf! (in-place via .with_mut, avoids the multi-KB get/set round-trip):
        persist_buf!(DELAYS: [DelayLine<48000>; 2] = [DelayLine::new(); 2]);

    ## Methods

    .write(sample)              — write one sample and advance write head
    .read(delay_samples)        — fractional delay with linear interpolation (f64 delay arg)
    .read_cubic(delay_samples)  — fractional delay with 4-point Hermite interpolation (better for
                                  pitch shifting and modulated delays)
    .tap(delay_samples)         — integer delay, no interpolation (usize arg)
    .clear()                    — zero buffer and reset write position

    ## Delay time conversion

    delay_samples = delay_time_ms * 0.001 * sample_rate
    SIZE = max_delay_seconds * max_sample_rate (e.g., 2.0 * 48000.0 as usize)

    ## Notes

    - write() before read() each sample — write advances the head, read looks backward
    - read(0) and tap(0) return the sample at the current write position (just written)
    - read(1) / tap(1) returns the previous sample
    - Uses f32 samples, f64 delay argument for read/read_cubic
    """

    private static let pythonOscillators = """
    # Oscillators — LFO + Waveform Functions

    ## LFO — Stateful Low-Frequency Oscillator

    LFO(sample_rate, freq=1.0, waveform="sine")

    Methods:
      .tick() -> float          — advance one sample, returns value in [-1, 1]
      .tick_n(n) -> np.ndarray  — advance n samples, returns float32 array. More efficient than tick() in a loop.
      .set_freq(hz)             — update frequency
      .set_waveform(wf)         — string: "sine", "triangle", "saw", "square"
      .reset()                  — reset phase to 0
      .value                    — last tick() value (attribute, not a method call)

    ## Stateless waveform functions

    All take phase in [0, 1) and return value in [-1, 1]:
      sine(phase)      — sin(2*pi*phase)
      triangle(phase)  — triangle wave
      saw(phase)       — sawtooth wave (rising)

    advance_phase(phase, freq, sample_rate) -> new_phase  — advance phase by one sample, wraps at 1.0

    ## Multi-channel LFO pattern

    Call tick() once per frame (every frame iteration) to advance the phase by one sample.
    Do NOT call tick() once per channel — that would advance the phase too fast.

    Frames-outer loop (most common — call tick() unconditionally every frame):
      n_ch, frame_count = ctx.inputs.shape
      for i in range(frame_count):
          mod = lfo.tick()          # tick every iteration, no condition
          ctx.outputs[:, i] = ctx.inputs[:, i] * mod   # broadcasts mod across all channels

    Channels-outer loop (tick on channel 0, use .value for others):
      mod = lfo.tick() if ch == 0 else lfo.value

    ## Multi-voice LFO phase spread

    For chorus/flanger with N voices, spread LFO phases evenly. Pre-seed each LFO at module scope
    by advancing it by phase_offset * samples_per_cycle at a reference frequency.

      NUM_VOICES = 3
      _lfos = None
      _last_sr = None

      def _init_lfos(sample_rate, rate_hz):
          global _lfos, _last_sr
          _lfos = []
          for v in range(NUM_VOICES):
              lfo = LFO(sample_rate, freq=rate_hz)
              for _ in range(int((v / NUM_VOICES) * sample_rate / rate_hz)):
                  lfo.tick()
              _lfos.append(lfo)
          _last_sr = sample_rate

      def process(ctx):
          if _last_sr != ctx.sample_rate:
              _init_lfos(ctx.sample_rate, ctx.params["rate"])
          ...
    """

    private static let rustOscillators = """
    # Oscillators — LFO + Waveform Functions

    ## LFO — Stateful Low-Frequency Oscillator

    Lfo::new() → defaults to 1 Hz sine at 44100 Hz. Call .init(sr, freq) each callback.
      Both args are f64. Cast f32 values: .init(ctx.sample_rate() as f64, rate_hz as f64)

    Methods:
      .tick() -> f32            — advance one sample, returns value in [-1, 1]
      .init(sr: f64, freq: f64) — set sample rate and frequency. Call at start of each process() callback.
      .set_freq(hz)             — update frequency
      .set_waveform(wf)         — Waveform enum: Waveform::Sine, Triangle, Saw, Square
      .reset()                  — reset phase to 0
      .value                    — last tick() value (field, not a method call)

    ## Waveform enum

    Waveform::Sine, Waveform::Triangle, Waveform::Saw, Waveform::Square

    ## Stateless waveform functions

    All take phase in [0, 1) and return value in [-1, 1]:
      sine(phase)      — sin(2*pi*phase)
      triangle(phase)  — triangle wave
      saw(phase)       — sawtooth wave (rising)

    advance_phase(phase, freq, sample_rate) -> new_phase  — advance phase by one sample, wraps at 1.0

    ## Multi-channel LFO pattern

    Call tick() once per frame to advance the phase by one sample.
    Do NOT call tick() once per channel — that would advance the phase too fast.

    Frames-outer loop (most common):
      for f in 0..ctx.frames() {
          let mod_val = unsafe { LFO.tick() };  // tick once per frame
          for c in 0..ctx.channels() {
              ctx.set_output(c, f, ctx.input(c, f) * mod_val);
          }
      }

    Channels-outer loop:
      let mod_val = if c == 0 { unsafe { LFO.tick() } } else { unsafe { LFO.value } };
    """

    private static let pythonUtilities = """
    # Utility Functions

    Stateless helpers for unit conversion and common audio math.

    ## Unit conversion

    db_to_gain(db) -> gain          — 0 dB = 1.0, -6 dB ≈ 0.5, -20 dB = 0.1
    gain_to_db(gain) -> db          — inverse of db_to_gain, clamps to avoid log(0)
    ms_to_samples(ms, sr) -> int    — milliseconds to sample count (rounded)
    samples_to_ms(samples, sr)      — sample count to milliseconds
    freq_to_period(freq, sr)        — frequency in Hz to period in samples

    ## VU calibration (house standard)

    ConjureDSP uses **0 VU = -18 dBFS** (EBU R68). Use this convention for
    any preset that exposes VU-style meters or "0 VU"-relative thresholds
    so the meaning of "0 VU" is consistent across the library.

      from conjuredsp import VU_REF_DBFS, dbfs_to_vu

      vu_db = dbfs_to_vu(rms_dbfs)   # dbfs_to_vu(-18.0) == 0.0
      # VU_REF_DBFS == -18.0

    Conversion math (if you need it inline):

      vu_db = 20 * log10(rms / VU_REF)   where VU_REF = 10^(-18/20) ≈ 0.1259
      # equivalently:  vu_db = dbfs + 18.0

    ## Smoothing

    smooth_coeff(time_ms, sr) -> alpha
      One-pole smoothing coefficient. Use as: state = alpha * state + (1 - alpha) * target
      Larger time_ms = slower smoothing (alpha closer to 1.0).
      time_ms=0 or negative returns 0.0 (instant).

    ## Waveshaping

    soft_clip(x, drive=1.0)   — tanh saturation. drive > 1 increases distortion.
    lerp(a, b, t)             — linear interpolation. t=0 → a, t=1 → b.

    ## Crossfade

    crossfade(dry, wet, mix, out, n)
      Buffer-level linear crossfade. Writes to out[:n] in-place.
      dry, wet, out are numpy arrays. mix is a float.

    equal_power_crossfade(dry, wet, mix, out, n)
      Constant-energy crossfade using sine/cosine curves.
      Preserves perceived loudness at 50% mix (no energy dip).
    """

    private static let rustUtilities = """
    # Utility Functions

    Stateless helpers for unit conversion and common audio math. All use f64.

    ## Unit conversion

    db_to_gain(db) -> gain          — 0 dB = 1.0, -6 dB ≈ 0.5, -20 dB = 0.1
    gain_to_db(gain) -> db          — inverse of db_to_gain, clamps to avoid log(0)
    ms_to_samples(ms, sr) -> int    — milliseconds to sample count (rounded)
    samples_to_ms(samples, sr)      — sample count to milliseconds
    freq_to_period(freq, sr)        — frequency in Hz to period in samples

    ## VU calibration (house standard)

    ConjureDSP uses **0 VU = -18 dBFS** (EBU R68). Use this convention for
    any preset that exposes VU-style meters or "0 VU"-relative thresholds
    so the meaning of "0 VU" is consistent across the library.

      use conjuredsp::{VU_REF_DBFS, dbfs_to_vu};

      let vu_db = dbfs_to_vu(rms_dbfs);   // dbfs_to_vu(-18.0) == 0.0
      // VU_REF_DBFS == -18.0_f64

    Conversion math (if you need it inline):

      vu_db = 20 * log10(rms / VU_REF)   where VU_REF = 10^(-18/20) ≈ 0.1259
      // equivalently: vu_db = dbfs + 18.0

    ## Smoothing

    smooth_coeff(time_ms, sr) -> alpha
      One-pole smoothing coefficient. Use as: state = alpha * state + (1 - alpha) * target
      Larger time_ms = slower smoothing (alpha closer to 1.0).
      time_ms=0 or negative returns 0.0 (instant).

    ## Waveshaping

    soft_clip(x, drive=1.0)   — tanh saturation. drive > 1 increases distortion.
    lerp(a, b, t)             — linear interpolation. t=0 → a, t=1 → b.

    ## Crossfade

    crossfade(dry: f32, wet: f32, mix: f32) -> f32
      Per-sample linear crossfade. mix=0 → dry, mix=1 → wet.
    """

    private static let pythonAccel = """
    # Accelerated Math — conjuredsp.accel

    Hardware-accelerated vectorized math operations. On WASM, these call Apple's
    Accelerate framework (vDSP/vecLib) via host imports for AMX/NEON-optimized
    performance. Use these instead of writing your own loops for matrix math,
    element-wise operations, or activation functions.

      from conjuredsp.accel import matmul, vec_add, vec_mul, vec_tanh, vec_sigmoid, vec_add_scalar

      matmul(a, b, out)               # numpy.matmul (Accelerate BLAS)
      vec_add(a, b, out)              # numpy.add
      vec_mul(a, b, out)              # numpy.multiply
      vec_tanh(x, out)                # numpy.tanh
      vec_sigmoid(x, out)             # 1 / (1 + exp(-clip(x)))
      vec_add_scalar(x, scalar, out)  # numpy.add(x, scalar)

    IMPORTANT: `out` is REQUIRED in all functions (not optional). Pre-allocate
    output buffers and reuse them across calls. This is critical for real-time
    audio — per-call allocation causes memory growth because the macOS allocator
    retains pages. Example:

      # Pre-allocate once (e.g., in module scope or __init__)
      _buf = np.empty((rows, cols), dtype=np.float32)

      # Reuse every callback
      matmul(a, b, _buf)

    Note: You can also use numpy directly (e.g., `a @ b`) but be aware that
    numpy operators allocate new arrays each call. Use conjuredsp.accel with
    pre-allocated buffers for zero-allocation real-time code.

    ## Performance

    These functions are 10-30x faster than equivalent scalar loops for
    matrix-heavy workloads (e.g., NAM inference, convolutions) because they
    use Apple's AMX coprocessor (dedicated matrix math hardware).

    Always prefer accel functions over hand-written loops for:
    - Matrix multiplication
    - Bulk activation functions (tanh, sigmoid on arrays)
    - Element-wise vector operations on large buffers
    """

    private static let rustAccel = """
    # Accelerated Math — conjuredsp::accel

    Hardware-accelerated vectorized math operations. In WASM, these call Apple's
    Accelerate framework (vDSP/vecLib) via host imports for AMX/NEON-optimized
    performance. Use these instead of writing your own loops for matrix math,
    element-wise operations, or activation functions.

      use conjuredsp::accel;

      // Matrix multiply: out[m×n] = a[m×k] @ b[k×n], row-major
      accel::matmul(a: &[f32], b: &[f32], out: &mut [f32], m: usize, k: usize, n: usize)

      // Element-wise operations (all slices must be same length)
      accel::vec_add(a: &[f32], b: &[f32], out: &mut [f32])    // out = a + b
      accel::vec_mul(a: &[f32], b: &[f32], out: &mut [f32])    // out = a * b
      accel::vec_tanh(input: &[f32], output: &mut [f32])        // out = tanh(in)
      accel::vec_sigmoid(input: &[f32], output: &mut [f32])     // out = sigmoid(in)
      accel::vec_add_scalar(input: &[f32], scalar: f32, output: &mut [f32])  // out = in + s

    ## Example

      use conjuredsp::accel;

      let a = [1.0, 2.0, 3.0, 4.0];
      let b = [5.0, 6.0, 7.0, 8.0];
      let mut c = [0.0f32; 4];
      accel::matmul(&a, &b, &mut c, 2, 2, 2);
      // c = [19.0, 22.0, 43.0, 50.0]

    ## Performance

    These functions are 10-30x faster than equivalent scalar loops for
    matrix-heavy workloads (e.g., NAM inference, convolutions) because they
    use Apple's AMX coprocessor (dedicated matrix math hardware).

    Always prefer accel:: functions over hand-written loops for:
    - Matrix multiplication
    - Bulk activation functions (tanh, sigmoid on arrays)
    - Element-wise vector operations on large buffers
    """

    // MARK: - API reference appendix (PR #5)
    //
    // For library-backed topics (filters, delays, oscillators, utilities,
    // accel, nam), we append an auto-extracted API reference to the
    // hand-curated topic strings. The sources are bundled into the appex's
    // Resources by the "Copy DSP Library Sources" build phase; the
    // extractor (DSPDocumentationExtractor) parses Python and Rust
    // docstrings via regex. Graceful fallback: if a source file is missing
    // or extraction returns nothing, the topic string ships unchanged.

    /// Maps a `get_docs` topic to the library source files that back it.
    /// Topics not in the map (`params`, `ui`, `state`) are hand-curated only.
    private static let topicSourceMap: [String: (python: [String], rust: [String])] = [
        "filters":     (python: ["filters.py"],  rust: ["filters.rs"]),
        "delays":      (python: ["buffers.py"],  rust: ["buffers.rs"]),
        "oscillators": (python: ["osc.py"],      rust: ["osc.rs"]),
        "utilities":   (python: ["dsp.py"],      rust: ["dsp.rs"]),
        "accel":       (python: ["accel.py"],    rust: []),
        "nam":         (python: ["nam.py"],      rust: []),
    ]

    /// Builds the auto-extracted API-reference Markdown appendix for a
    /// topic, or `nil` if the topic has no library backing or extraction
    /// yields nothing. Cached per-process via `appendixCache`.
    static func apiReferenceAppendix(for topic: String) -> String? {
        appendixCacheLock.lock()
        let cached = appendixCache[topic]
        appendixCacheLock.unlock()
        if let cached { return cached.isEmpty ? nil : cached }

        guard let files = topicSourceMap[topic] else { return nil }
        guard let resourceURL = appexResourceURL else { return nil }

        var pySymbols: [DSPDocumentationExtractor.Symbol] = []
        for name in files.python {
            let url = resourceURL.appendingPathComponent("conjuredsp").appendingPathComponent(name)
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                pySymbols.append(contentsOf: DSPDocumentationExtractor.extractPython(content: content))
            }
        }
        var rsSymbols: [DSPDocumentationExtractor.Symbol] = []
        for name in files.rust {
            let url = resourceURL.appendingPathComponent("conjuredsp-rs").appendingPathComponent(name)
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                rsSymbols.append(contentsOf: DSPDocumentationExtractor.extractRust(content: content))
            }
        }

        var sections: [String] = []
        if !pySymbols.isEmpty {
            sections.append("## API reference (Python)\n\n\(DSPDocumentationExtractor.renderMarkdown(pySymbols))")
        }
        if !rsSymbols.isEmpty {
            sections.append("## API reference (Rust)\n\n\(DSPDocumentationExtractor.renderMarkdown(rsSymbols))")
        }
        let joined = sections.joined(separator: "\n\n")
        appendixCacheLock.lock()
        appendixCache[topic] = joined
        appendixCacheLock.unlock()
        return joined.isEmpty ? nil : joined
    }

    /// Cache so repeat `get_docs("filters")` calls don't re-read disk.
    /// Guarded by `appendixCacheLock`; the disk-read + extractor pass runs
    /// outside the lock so concurrent topics don't serialize on I/O.
    nonisolated(unsafe) private static var appendixCache: [String: String] = [:]
    private static let appendixCacheLock = NSLock()

    /// The extension's bundle `Resources/` URL — where the build phase
    /// drops `conjuredsp/*.py` and `conjuredsp-rs/*.rs`. Resolved via the
    /// AU class so we pick up the appex (not the host app's Bundle.main).
    private static var appexResourceURL: URL? {
        Bundle(for: ConjureDSPExtensionAudioUnit.self).resourceURL
    }
}
