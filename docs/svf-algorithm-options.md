# SVF Algorithm Options

Reference notes on state variable filter algorithms considered for the `preset_svf` factory presets (Python and Rust). The current implementation uses the **TPT SVF** (option 2). This doc captures the alternatives for reference.

## 1. Chamberlin SVF (current)

Hal Chamberlin, *Musical Applications of Microprocessors* (1980). The form currently in the preset:

```
f = 2 * sin(pi * cutoff / sr)
q = 1 / Q

low  += f * band
high  = x - low - q * band
band += f * high
```

**Pros.** Extremely compact. Four multiplies and four adds per sample. Simultaneous LP/BP/HP/notch outputs. Great teaching example.

**Cons.** Only **conditionally stable**. Stability requires `f < 2 − q`, which collapses the usable cutoff range as resonance drops (larger `q`). At Q = 1 (q = 1) the upper limit is roughly `sr/6` (~8 kHz at 48 kHz). Above that, the coupled feedback diverges to `±inf`, then `inf − inf` produces `NaN`, and the persistent state is poisoned until reset. Also exhibits frequency warping at high cutoffs relative to the ideal analog response.

## 2. TPT SVF (Topology-Preserving Transform, Zavalishin)

Vadim Zavalishin, *The Art of VA Filter Design* (2012, freely available PDF). Derives digital filters by applying the trapezoidal (bilinear) integrator to the analog state-variable topology, preserving the zero-delay feedback structure. This is the modern standard for virtual-analog filters.

Core update (per sample):

```
g  = tan(pi * cutoff / sr)         // prewarped integrator gain
k  = 1 / Q                          // damping
a1 = 1 / (1 + g * (g + k))
a2 = g * a1
a3 = g * a2

v3 = x - ic2eq
v1 = a1 * ic1eq + a2 * v3
v2 = ic2eq + a2 * ic1eq + a3 * v3
ic1eq = 2 * v1 - ic1eq
ic2eq = 2 * v2 - ic2eq

low  = v2
band = v1
high = x - k * v1 - v2
```

**Pros.** **Unconditionally stable** across the full audible range at any Q. Frequency response matches the analog prototype exactly at DC and at the cutoff (the "prewarping" property of the bilinear transform). All four standard outputs (LP/BP/HP/notch) plus peak and all-pass come from the same core. This is what u-he, Native Instruments, and most modern virtual-analog plugins use.

**Cons.** More code (three precomputed coefficients per block, two integrator states instead of `low`/`band`). `tan()` is more expensive than `sin()` but only computed once per block. `g` still needs clamping near Nyquist because `tan(π/2)` is infinite — clamp cutoff to something like `0.49 * sr` in practice.

## 3. Andrew Simper's "Linear Trapezoidal Integrated State Variable Filter"

Andrew Simper (Cytomic), [*Linear Trapezoidal State Variable Filter SVF in state increment form*](https://cytomic.com/files/dsp/SvfLinearTrapOptimised2.pdf). This is the same family as Zavalishin's TPT SVF — both are trapezoidal/bilinear-transform derivations of the state variable topology — but Simper's paper presents a slightly reordered update that's popular as a reference implementation and derives LP, BP, HP, notch, peak, all-pass, bell, low-shelf, and high-shelf from one core.

Functionally equivalent to TPT SVF for the LP/BP/HP/notch outputs we use. Choosing between the two is a matter of code style; they produce bit-identical output when rearranged.

## 4. "Clamp cutoff internally" (not really a different algorithm)

Keep Chamberlin but clamp `cutoff` inside `process()` to `sr / 6` (or a Q-dependent bound). Simplest possible fix, but silently ignores slider values above the clamp, which is confusing UX. Listed here only for completeness.

## Current choice

Both `preset_svf.py` and `preset_svf_rust.rs` use **TPT SVF** (option 2) with cutoff clamped to `0.49 * sr` before computing `g = tan(...)` to handle the Nyquist edge.
