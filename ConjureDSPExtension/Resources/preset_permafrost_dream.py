# Permafrost Dream — icy reverb breathing slowly under a frozen lake.
#
# Long feedback delay tail (290 ms) with octave-up pitch shift in the
# feedback path (true shimmer architecture: tail → LP → dual-tap shifter →
# back into delay input) → glassy 3-bandpass cluster (2.5 / 3.7 / 5.1 kHz)
# whose amplitude is modulated by a slow 0.09 Hz "breath" LFO → high-pass
# (400 Hz) to keep the wet bus bright → final mix.
#
# Distinct from Haunted Cathedral: bright/shimmer reverb rather than dark
# dense; first preset where the pitch shifter lives inside the reverb
# feedback loop.
#
# Params:
#   ice     (pct) — tail feedback (length of shimmer)
#   shimmer (pct) — how much pitch-shifted content re-enters the tail
#   glass   (pct) — bandpass cluster gain
#   breath  (pct) — slow LFO depth on the glass layer
#   mix           — wet/dry blend

import math
from conjuredsp import (mix, pct,
                        DelayLine, Biquad, BiquadCoeffs, LFO)

PARAMS = {
    "ice":     pct(default=70),
    "shimmer": pct(default=55),
    "glass":   pct(default=50),
    "breath":  pct(default=60),
    "mix":     mix(default=0.55),
}

TAIL_MS = 290.0
SHIFT_BASE_MS = 60.0
GRAIN_MS = 80.0
BP_HZ = [2500.0, 3700.0, 5100.0]
BREATH_HZ = 0.09

_st = None
_sr = None


class _S:
    def __init__(self, sr, nch):
        mx = int(0.5 * sr)
        self.tail_dl = [DelayLine(mx) for _ in range(nch)]
        self.tail_lp = [Biquad() for _ in range(nch)]
        self.shift_dl = [DelayLine(mx) for _ in range(nch)]
        self.glass_bp = [[Biquad() for _ in range(3)] for _ in range(nch)]
        self.hp = [Biquad() for _ in range(nch)]
        self.grain_phase = 0.0
        self.breath_lfo = LFO(sr, freq=BREATH_HZ, waveform="sine")


def process(inputs, outputs, frame_count, sample_rate, params):
    global _st, _sr
    nch = len(inputs)
    if _st is None or _sr != sample_rate:
        _st = _S(sample_rate, nch)
        _sr = sample_rate

    s = _st
    ice = params["ice"] / 100.0
    shimmer = params["shimmer"] / 100.0
    glass = params["glass"] / 100.0
    breath = params["breath"] / 100.0
    mx = params["mix"]

    glass_q = 6.0 + 6.0 * glass
    tail_lpc = BiquadCoeffs.lowpass(2800.0, 0.707, sample_rate)
    bp_c = [BiquadCoeffs.bandpass(BP_HZ[k], glass_q, sample_rate)
            for k in range(3)]
    hpc = BiquadCoeffs.highpass(400.0, 0.707, sample_rate)
    for ch in range(nch):
        s.tail_lp[ch].set_coeffs(tail_lpc)
        for k in range(3):
            s.glass_bp[ch][k].set_coeffs(bp_c[k])
        s.hp[ch].set_coeffs(hpc)

    tail_d = TAIL_MS * 0.001 * sample_rate
    tail_fb_amt = 0.55 + 0.30 * ice
    shimmer_amt = 0.70 * shimmer

    base_d = SHIFT_BASE_MS * 0.001 * sample_rate
    grain_samples = GRAIN_MS * 0.001 * sample_rate
    grain_rate = 1.0 / grain_samples

    glass_gain = 0.30 + 0.70 * glass
    breath_depth = 0.40 * breath

    for i in range(frame_count):
        ph0 = s.grain_phase
        ph1 = (s.grain_phase + 0.5) % 1.0
        w0 = math.sin(math.pi * ph0)
        w0 = w0 * w0
        w1 = math.sin(math.pi * ph1)
        w1 = w1 * w1
        # Octave-up shimmer: read approaches write
        read0 = base_d - ph0 * grain_samples
        if read0 < 1.0:
            read0 = 1.0
        read1 = base_d - ph1 * grain_samples
        if read1 < 1.0:
            read1 = 1.0
        s.grain_phase = (s.grain_phase + grain_rate) % 1.0

        b = s.breath_lfo.tick()
        breath_mod = 1.0 - breath_depth + breath_depth * (0.5 + 0.5 * b)

        for ch in range(nch):
            dry = float(inputs[ch][i])

            # Stage A: read tail, lowpass it, pitch-shift it (inside feedback)
            tail_raw = s.tail_dl[ch].read(tail_d)
            tail_lp_out = s.tail_lp[ch].process_sample(tail_raw)

            s.shift_dl[ch].write(tail_lp_out)
            g0 = s.shift_dl[ch].read(read0)
            g1 = s.shift_dl[ch].read(read1)
            shifted = w0 * g0 + w1 * g1

            # Stage B: feedback composition (dry + shimmer-shifted tail)
            fb_in = dry + shifted * shimmer_amt + tail_lp_out * tail_fb_amt
            s.tail_dl[ch].write(fb_in)

            # Stage C: glassy bandpass cluster on the raw tail
            glass_sum = 0.0
            for k in range(3):
                glass_sum += s.glass_bp[ch][k].process_sample(tail_raw)
            glass_voice = glass_sum * glass_gain * breath_mod

            # Stage D: high-pass to keep it icy
            wet = s.hp[ch].process_sample(tail_raw + glass_voice)

            outputs[ch][i] = dry * (1.0 - mx) + wet * mx
