//
//  DSPDocumentation.swift
//  ConjureDSPExtension
//
//  Authoritative API reference strings for the conjuredsp library.
//  Used by the MCP get_docs tool and the AI Prompt Helper view.
//

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

    freq — 20-20000 Hz, log curve, default 1000
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
          "mode": choice("Low", "Mid", "High", default="Mid"),  # Python-only dropdown
      }

    param() accepts: param(min, max, unit="", default=None, curve="linear")

    choice(*labels, default=None) — Python-only. Dropdown menu, receives selected index as float \
    (0.0, 1.0, ...). Requires at least 2 labels.

    ## Rust syntax

    Builders are const functions. Customize via method chaining:

      params! {
          CUTOFF = freq(),                                  // use defaults: 20-20000 Hz
          ATTACK = time_ms().min(0.5).max(50.0).default(5.0),
          DAMPING = freq().min(500.0).max(16000.0).default(4000.0),
          DRIVE = pct().default(70.0),
          MIX = mix().default(0.35),
          BYPASS = toggle(),
      }

    Chaining methods: .min(val), .max(val), .default(val), .unit("str"), .curve("log" or "linear")
    All are const fn and can be used in static/const contexts.

    ## How parameters are delivered to scripts

    With PARAMS metadata: scripts receive denormalized actual values (e.g., 1000.0 Hz).
    Without PARAMS: scripts receive raw 0-1 normalized floats (legacy mode).
    Python params arg is a dict keyed by name. Rust params are accessed via ctx.param(INDEX).

    ## Python process() signature — copy this verbatim

    Always use the 7-argument form, even if you don't need transport or
    telemetry. Use `_transport` and `_telemetry` (Python's
    underscore-prefix convention for unused args) when you don't read
    them — adding telemetry later is a one-line edit instead of a
    refactor. Every factory Python preset uses this canonical shape:

      import numpy as np
      from conjuredsp import freq, mix

      PARAMS = {
          "drive": freq(min=20.0, max=2000.0, default=200.0),
          "mix": mix(default=0.5),
      }

      def process(inputs, outputs, frame_count, sample_rate, params, _transport, _telemetry):
          drive = params["drive"]
          mix_v = params["mix"]
          for ch in range(len(inputs)):
              # IMPORTANT: slice with [:frame_count] on BOTH sides.
              # inputs/outputs are pre-allocated to maximumFramesToRender
              # (often larger than frame_count); reading or writing past
              # frame_count gives stale or zero samples.
              x = inputs[ch][:frame_count]
              wet = np.tanh(x * drive)
              outputs[ch][:frame_count] = (1.0 - mix_v) * x + mix_v * wet

    Notes on the args:

    - `inputs` / `outputs` — lists of numpy float32 arrays, one per
      channel. `len(inputs)` IS the channel count (no separate
      `channel_count` arg, unlike Rust). Both arrays are sized to the
      AU's `maximumFramesToRender`, NOT `frame_count` — always slice
      with `[:frame_count]`.
    - `frame_count` — int, samples in this block.
    - `sample_rate` — float, Hz.
    - `params` — dict keyed by parameter name when `PARAMS` metadata
      is declared (the recommended path), or a plain list of 0–1
      normalized floats in legacy mode (no PARAMS dict).
    - `_transport` — dict from the host's transport state. **Exact
      keys** (use these verbatim — wrong keys silently return None /
      your fallback default and the bug is invisible until someone
      changes tempo and you can't tell):

      ```python
      transport = {
          "tempo":        120.0,   # BPM — NOT "bpm". Use transport["tempo"].
          "beat":         0.0,     # current beat position (float)
          "playing":      False,   # bool
          "time_sig_num": 4.0,     # time signature numerator
          "time_sig_den": 4.0,     # time signature denominator
          "sample_pos":   0.0,     # absolute sample position
      }
      ```

      Accept it even if you don't use it; rename to `transport` when
      you do.
    - `_telemetry` — dict pre-seeded with declared `TELEMETRY` slot
      keys at zero. Write to it (e.g. `_telemetry["gr_db"] = -3.5`)
      to publish per-block values to the host UI's `audio.onFrame`.
      Rename to `telemetry` when you use it. **Reading telemetry from
      JS also requires `manifest.ui.audioFrames: true`** — see the
      `ui` topic for the manifest snippet.

    The kernel still supports legacy 4/5/6-arg forms (back-compat for
    older user presets). New code should always use the 7-arg
    canonical so adding transport or telemetry later is just deleting
    an underscore.

    ## Rust process() signature — copy this verbatim

    The `setup!()` macro provides the buffers + helpers, but the
    `process()` extern function is YOUR responsibility. The host calls
    it with this EXACT shape, including the parameter names. Use this
    template — do not rename the parameters:

      use conjuredsp::*;

      setup!();

      params! {
          DRIVE = db().min(0.0).max(24.0).default(6.0),
          MIX   = mix().default(0.5),
      }

      #[no_mangle]
      pub extern "C" fn process(
          input: *const f32,
          output: *mut f32,
          channel_count: i32,
          frame_count: i32,
          sample_rate: f32,
      ) {
          let ctx = ctx(input, output, channel_count, frame_count, sample_rate);

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

    Why the names matter, even though Rust doesn't care:

    The host's WASM bridge calls `process` with positional args
    `(input, output, channel_count, frame_count, sample_rate)`. If you
    rename the third arg to anything that suggests "frames" — or the
    fourth to anything that suggests "channels" — it's very easy to
    write a loop that uses your local var names as bounds and ends up
    walking the buffer with the wrong stride. Both args are `i32`, so
    the compiler can't catch the swap. Most `ctx.set_output` calls
    then write past the end of OUTPUT_BUF into adjacent WASM memory,
    the kernel reads leftover/zero output, and the audio looks
    unchanged or intermittently silent. No compile error, no runtime
    panic, just silently wrong output.

    Every factory Rust preset uses these exact parameter names. Match
    them, and the loop pattern below is guaranteed to be correct:
    `for c in 0..ctx.channels() { for i in 0..ctx.frames() { ... } }`
    — using `ctx.channels()` and `ctx.frames()` (NOT the raw
    `channel_count` / `frame_count` parameters) means the loop can
    never disagree with what Context thinks the buffer shape is.
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
      def process(inputs, outputs, frame_count, sample_rate, params, _transport, _telemetry):
          global _filters
          if _filters is None:
              _filters = [Biquad() for _ in range(len(inputs))]
          coeffs = BiquadCoeffs.lowpass(params["cutoff"], 0.707, sample_rate)
          for ch in range(len(inputs)):
              _filters[ch].set_coeffs(coeffs)
              for i in range(frame_count):
                  outputs[ch][i] = _filters[ch].process_sample(inputs[ch][i])

    Rust:
      static mut FILTERS: [Biquad; 2] = [Biquad::new(); 2];
      // in process():
      let coeffs = BiquadCoeffs::lowpass(ctx.param(CUTOFF) as f64, 0.707, ctx.sample_rate() as f64);
      unsafe {
          FILTERS[c].set_coeffs(coeffs);
          ctx.set_output(c, i, FILTERS[c].process_sample(ctx.input(c, i) as f64) as f32);
      }
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
      Stored in static mut for persistence: static mut DELAYS: [DelayLine<48000>; 2] = [DelayLine::new(); 2];

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
        for i in range(frame_count):
            mod = lfo.tick()          # tick every iteration, no condition
            for ch in range(len(inputs)):
                outputs[ch][i] = inputs[ch][i] * mod
      Rust:
        for f in 0..ctx.frames() {
            let mod_val = unsafe { LFO.tick() };  // tick once per frame
            for c in 0..ctx.channels() {
                ctx.set_output(c, f, ctx.input(c, f) * mod_val);
            }
        }

    Channels-outer loop (tick on channel 0, use .value for others):
      Python: mod = lfo.tick() if ch == 0 else lfo.value
      Rust: let mod_val = if c == 0 { unsafe { LFO.tick() } } else { unsafe { LFO.value } };

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

      def process(inputs, outputs, frame_count, sample_rate, params, _transport, _telemetry):
          if _last_sr != sample_rate:
              _init_lfos(sample_rate, params["rate"])
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

      def process(inputs, outputs, frame_count, sample_rate, params, _transport, _telemetry):
          gain = 10 ** (params["input_gain"] / 20.0)
          mix_val = params["mix"]
          for ch in range(len(inputs)):
              wet = model.process(inputs[ch][:frame_count] * gain, ch)
              outputs[ch][:frame_count] = inputs[ch][:frame_count] * (1 - mix_val) + wet * mix_val

    ## Rust API

      use conjuredsp::*;
      setup!();
      nam!("tone3000://TONE_ID/MODEL_ID");

      // In process():
      unsafe {
          if let Some(model) = NAM_MODEL.as_mut() {
              for c in 0..ctx.channels() {
                  let n = ctx.frames();
                  for i in 0..n { NAM_IN[i] = ctx.input(c, i); }
                  model.process_buffer(&NAM_IN[..n], &mut NAM_OUT[..n], c);
                  for i in 0..n { ctx.set_output(c, i, NAM_OUT[i]); }
              }
          }
      }

    ### nam!("path") macro

    Declares which NAM model to use. Expands to:
      - static mut NAM_MODEL: Option<NamModel> — the loaded model
      - static mut NAM_IN / NAM_OUT: [f32; MAX_FR] — scratch buffers
      - WASM exports: get_nam_data_ptr, init_nam, get_nam_active
      - Path metadata exports: get_nam_path_ptr, get_nam_path_len

    The host reads the path from the compiled WASM, loads the .nam file,
    and injects the model data into WASM memory before the first process() call.

    ### NamModel methods (Rust)

      model.process_buffer(input: &[f32], output: &mut [f32], channel: usize)
        Process one channel. Input and output slices must be same length.

    ## Notes

    - NAM models are mono — process() runs independently per channel with shared weights
    - WaveNet models maintain a sliding history window across callbacks (automatic)
    - If model sample rate != DAW sample rate, a warning is logged on first process() call
    - Use list_tones tool to see downloaded tones and their tone3000:// paths
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
    `::part(option)`, `::part(thumb)` for restyling without re-rendering.

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
    `puck`, `option`.

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

    ## DSP→UI telemetry channel

    For meters / visualizers that need to show **internal DSP state**
    (gain reduction, envelope follower output, sidechain RMS, NAM
    model magnitude) — values that aren't reconstructible from
    rmsIn/rmsOut — declare named float slots the DSP writes per block.

    Rust:

    ```rust
    use conjuredsp::*;
    setup!();
    telemetry! {
        GR_DB  = telemetry().unit("dB"),
        ENV_DB = telemetry().unit("dB"),
    }
    // inside process():
    ctx.set_telemetry(GR_DB, max_gr_db_this_block);
    ctx.set_telemetry(ENV_DB, env_db);
    ```

    Python (`process()` must accept all 7 args including transport):

    ```python
    TELEMETRY = {"gr_db": {"unit": "dB"}, "env_db": {"unit": "dB"}}
    def process(inputs, outputs, frame_count, sample_rate, params, transport, telemetry):
        telemetry["gr_db"] = max_gr_db_this_block
        telemetry["env_db"] = env_db
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

    ## Vector telemetry (per-frame visualizers)

    Scalar slots emit one value per block — fine for meters that show
    "how much" but useless for an oscilloscope or waveform display
    that needs the *shape* of the signal. Declare a `vector_telemetry`
    slot to publish one float per audio frame in the current block:

    Rust:

    ```rust
    use conjuredsp::*;
    setup!();
    telemetry! {
        SCOPE = vector_telemetry(),
    }
    // inside process(): write your per-frame samples (e.g. the wet
    // signal post-saturation) into the slot:
    for i in 0..frame_count {
        let y = saturator.process(ctx.input(0, i));
        ctx.set_output(0, i, y);
        scope_buf[i] = y;
    }
    ctx.set_telemetry_vector(SCOPE, &scope_buf[..frame_count]);
    ```

    Python:

    ```python
    TELEMETRY = {"scope": {"shape": "vector"}}
    def process(inputs, outputs, frame_count, sample_rate, params,
                transport, telemetry):
        # Run your per-frame DSP into outputs[0]; then publish a slice
        # of length frame_count into the slot.
        telemetry["scope"][:frame_count] = outputs[0][:frame_count]
    ```

    The pre-seeded numpy array lives in the dict — slice-assign into
    it, don't replace it. Length must equal `frame_count`; longer
    slices are truncated to `MAX_FRAMES` (4096), shorter slices leave
    stale data past the live tail (the host caps the read to the
    actual published length).

    UI consumer — `frame.telemetry["scope"]` is now a JS Array, not a
    number:

    ```js
    ConjureDSP.audio.onFrame(frame => {
        if (!frame.telemetry) return;
        const scope = frame.telemetry["scope"];   // [-0.3, 0.4, …]
        if (!Array.isArray(scope)) return;        // legacy/scalar
        // draw onto a <canvas>: one pixel column per sample, etc.
    });
    ```

    Same `audioFrames: true` manifest gate. Same 16-slot budget. Pick
    vector only when you need waveform shape — for a meter, a scalar
    slot is one float instead of `frame_count` floats per block.

    ## Worked example: telemetry meter + tempo-sync

    A complete three-file preset that exercises every piece authors
    most often fumble: 7-arg Python signature, transport BPM, telemetry
    slot, `audioFrames: true`, schemaVersion 2 declared params, and a
    cdp-ui meter driven by the slot. Copy verbatim and edit.

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

    def process(inputs, outputs, frame_count, sample_rate, params,
                transport, telemetry):
        global _phase
        depth_db = params["depth"]
        beats_per_cycle = [1.0, 0.5, 0.25][int(params["rate_div"])]
        bpm = transport["tempo"]               # NOT "bpm" — see params docs
        rate_hz = (bpm / 60.0) / beats_per_cycle
        gain_floor = 10.0 ** (-depth_db / 20.0)

        max_gr_db = 0.0
        for i in range(frame_count):
            _phase = (_phase + rate_hz / sample_rate) % 1.0
            # Triangle envelope: peaks at depth at phase=0, returns to 1.0 at 0.5
            env = gain_floor + (1.0 - gain_floor) * abs(2.0 * _phase - 1.0)
            gr_db_now = -20.0 * math.log10(max(env, 1e-9))
            if gr_db_now > max_gr_db:
                max_gr_db = gr_db_now
            for ch in range(len(inputs)):
                outputs[ch][i] = inputs[ch][i] * env

        telemetry["gr_db"] = max_gr_db        # peak GR over the block
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
    - 7-arg `process` (Python takes `transport` + `telemetry` by name)
    - `transport["tempo"]` (not `"bpm"`)
    - `TELEMETRY = {...}` declaration → `telemetry["gr_db"] = ...` in
      `process` → `frame.telemetry["gr_db"]` in JS
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
      before reading `parameters.get(i)` at startup.
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
        [params, filters, delays, oscillators, utilities, accel, ui]
            .joined(separator: "\n\n")
    }

    /// All sections including NAM (for the MCP get_docs "all" topic).
    static var allDocsWithNam: String {
        [params, filters, delays, oscillators, utilities, accel, nam, ui]
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

    freq — 20-20000 Hz, log curve, default 1000
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
    """

    private static let rustParams = """
    # Parameter Builders

    Available builders and their default ranges:

    freq — 20-20000 Hz, log curve, default 1000
    db — -60 to +12 dB, linear curve, default 0
    time_ms — 0.1-1000 ms, log curve, default 100
    mix — 0.0-1.0, linear, default 0.5
    pct — 0-100%, linear, default 50
    toggle — 0/1, rendered as switch in UI, default 0
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
      }

    Chaining methods: .min(val), .max(val), .default(val), .unit("str"), .curve("log" or "linear")
    All are const fn and can be used in static/const contexts.

    ## How parameters are delivered

    With PARAMS metadata: scripts receive denormalized actual values (e.g., 1000.0 Hz).
    Without PARAMS: scripts receive raw 0-1 normalized floats (legacy mode).
    Params are accessed via ctx.param(INDEX).
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

    ## Biquad — stateful filter (Direct Form II Transposed)

    Biquad(coeffs=None) — passthrough if no coeffs

    Methods:
      .set_coeffs(coeffs)        — update coefficients without resetting state
      .process_sample(x) -> y    — filter one sample
      .reset()                   — zero internal state (z1, z2)

    ## Typical usage pattern

      _filters = None
      def process(inputs, outputs, frame_count, sample_rate, params, _transport, _telemetry):
          global _filters
          if _filters is None:
              _filters = [Biquad() for _ in range(len(inputs))]
          coeffs = BiquadCoeffs.lowpass(params["cutoff"], 0.707, sample_rate)
          for ch in range(len(inputs)):
              _filters[ch].set_coeffs(coeffs)
              for i in range(frame_count):
                  outputs[ch][i] = _filters[ch].process_sample(inputs[ch][i])
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

    ## Biquad — stateful filter (Direct Form II Transposed)

    Biquad::new() — const fn, passthrough by default. Copy type.

    Methods:
      .set_coeffs(coeffs)        — update coefficients without resetting state
      .process_sample(x) -> y    — filter one sample (f64)
      .reset()                   — zero internal state (z1, z2)

    ## Typical usage pattern

      static mut FILTERS: [Biquad; 2] = [Biquad::new(); 2];
      // in process():
      let coeffs = BiquadCoeffs::lowpass(ctx.param(CUTOFF) as f64, 0.707, ctx.sample_rate() as f64);
      unsafe {
          FILTERS[c].set_coeffs(coeffs);
          ctx.set_output(c, i, FILTERS[c].process_sample(ctx.input(c, i) as f64) as f32);
      }
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
      Stored in static mut for persistence: static mut DELAYS: [DelayLine<48000>; 2] = [DelayLine::new(); 2];

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
      for i in range(frame_count):
          mod = lfo.tick()          # tick every iteration, no condition
          for ch in range(len(inputs)):
              outputs[ch][i] = inputs[ch][i] * mod

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

      def process(inputs, outputs, frame_count, sample_rate, params, _transport, _telemetry):
          if _last_sr != sample_rate:
              _init_lfos(sample_rate, params["rate"])
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
}
