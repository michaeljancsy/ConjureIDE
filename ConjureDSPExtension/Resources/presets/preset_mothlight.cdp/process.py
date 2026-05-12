# Mothlight — moths around a porchlight, erratic and bright.
#
# Fast random-walk tremolo (3 coprime LFOs at 5.7 / 8.3 / 12.1 Hz summed —
# chaotic, not periodic) → bright 3-bandpass cluster (1.8 / 3.2 / 5.5 kHz)
# → micro-pitch jitter via a single delay line modulated by a fast 17 Hz
# LFO → light octave-up shimmer (dual-tap pitch shifter) → final mix.
#
# Distinct from everything else in the set: high-frequency-emphasised,
# erratic, chaotic modulation; first use of summed-LFO random-walk and
# fast-LFO pitch jitter (distinct from Sun-Baked Cassette's slow wow).
#
# Params:
#   flutter (pct) — tremolo depth
#   bright  (pct) — bandpass Q
#   jitter  (pct) — pitch jitter depth
#   shimmer (pct) — octave-up shimmer level
#   mix           — wet/dry blend

import math
from conjuredsp import (mix, pct,
                        DelayLine, Biquad, BiquadCoeffs, LFO)

PARAMS = {
    "flutter": pct(default=60),
    "bright":  pct(default=55),
    "jitter":  pct(default=45),
    "shimmer": pct(default=40),
    "mix":     mix(default=0.55),
}

TREM_HZ = [5.7, 8.3, 12.1]
BP_HZ = [1800.0, 3200.0, 5500.0]
JITTER_LFO_HZ = 17.0
JITTER_BASE_MS = 4.0
SHIFT_BASE_MS = 40.0
GRAIN_MS = 50.0

_st = None
_sr = None


class _S:
    def __init__(self, sr, nch):
        mx = int(0.2 * sr)
        self.trem_lfo = [LFO(sr, freq=TREM_HZ[k], waveform="sine")
                         for k in range(3)]
        self.bp = [[Biquad() for _ in range(3)] for _ in range(nch)]
        self.jitter_dl = [DelayLine(mx) for _ in range(nch)]
        self.jitter_lfo = LFO(sr, freq=JITTER_LFO_HZ, waveform="sine")
        self.shift_dl = [DelayLine(mx) for _ in range(nch)]
        self.grain_phase = 0.0


def process(ctx):
    global _st, _sr
    nch, frame_count = ctx.inputs.shape
    if _st is None or _sr != ctx.sample_rate:
        _st = _S(ctx.sample_rate, nch)
        _sr = ctx.sample_rate

    s = _st
    flutter = ctx.params["flutter"] / 100.0
    bright = ctx.params["bright"] / 100.0
    jitter = ctx.params["jitter"] / 100.0
    shimmer = ctx.params["shimmer"] / 100.0
    mx = ctx.params["mix"]

    bp_q = 3.0 + 7.0 * bright
    bp_c = [BiquadCoeffs.bandpass(BP_HZ[k], bp_q, ctx.sample_rate)
            for k in range(3)]
    for ch in range(nch):
        for k in range(3):
            s.bp[ch][k].set_coeffs(bp_c[k])

    trem_depth = 0.60 * flutter
    jitter_base = JITTER_BASE_MS * 0.001 * ctx.sample_rate
    jitter_depth = (0.3 + 2.2 * jitter) * 0.001 * ctx.sample_rate

    base_d = SHIFT_BASE_MS * 0.001 * ctx.sample_rate
    grain_samples = GRAIN_MS * 0.001 * ctx.sample_rate
    grain_rate = 1.0 / grain_samples

    shimmer_amt = 0.6 * shimmer
    bp_gain = (0.5 + 0.5 * bright) / 3.0

    for i in range(frame_count):
        t0 = s.trem_lfo[0].tick()
        t1 = s.trem_lfo[1].tick()
        t2 = s.trem_lfo[2].tick()
        walk = (t0 + t1 + t2) / 3.0
        trem_mod = (1.0 - trem_depth) + trem_depth * (0.5 + 0.5 * walk)

        j = s.jitter_lfo.tick()
        jd = jitter_base + j * jitter_depth
        if jd < 1.0:
            jd = 1.0

        ph0 = s.grain_phase
        ph1 = (s.grain_phase + 0.5) % 1.0
        w0 = math.sin(math.pi * ph0)
        w0 = w0 * w0
        w1 = math.sin(math.pi * ph1)
        w1 = w1 * w1
        read0 = base_d - ph0 * grain_samples
        if read0 < 1.0:
            read0 = 1.0
        read1 = base_d - ph1 * grain_samples
        if read1 < 1.0:
            read1 = 1.0
        s.grain_phase = (s.grain_phase + grain_rate) % 1.0

        for ch in range(nch):
            dry = float(ctx.inputs[ch][i])
            dry_trem = dry * trem_mod

            bp_sum = 0.0
            for k in range(3):
                bp_sum += s.bp[ch][k].process_sample(dry_trem)
            bp_sum = bp_sum * bp_gain

            s.jitter_dl[ch].write(bp_sum)
            jittered = s.jitter_dl[ch].read(jd)

            s.shift_dl[ch].write(jittered)
            g0 = s.shift_dl[ch].read(read0)
            g1 = s.shift_dl[ch].read(read1)
            shimmer_voice = (w0 * g0 + w1 * g1) * shimmer_amt

            wet = jittered + shimmer_voice
            ctx.outputs[ch][i] = dry * (1.0 - mx) + wet * mx
