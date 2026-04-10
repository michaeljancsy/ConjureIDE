# Glass Smash — snare → glass bottle smashing in slow motion.
#
# 6-partial modal resonator bank (inharmonic glass frequencies with high-Q
# bandpass biquads) → octave-up crystalline shimmer (dual-tap pitch shifter)
# → granular slow-motion freezer (dual-tap pitch shifter, octave down) →
# sub-octave impact thud (rectify → 80 Hz LP) → 4 parallel feedback comb
# reverb tail (LP in feedback) → final mix.
#
# Params:
#   shimmer  (pct) — octave-up shimmer level
#   time     (pct) — reverb tail feedback
#   partials (pct) — modal resonator Q (12 → 35)
#   slowmo   (pct) — granular freezer level
#   mix            — wet/dry blend

import math
from conjuredsp import (mix, pct,
                        DelayLine, Biquad, BiquadCoeffs)

PARAMS = {
    "shimmer":  pct(default=55),
    "time":     pct(default=60),
    "partials": pct(default=50),
    "slowmo":   pct(default=40),
    "mix":      mix(default=0.55),
}

# Inharmonic glass partial frequencies (Hz) — modeled on real glass spectra
PARTIAL_HZ = [2700.0, 3850.0, 5100.0, 6700.0, 8400.0, 11200.0]
# Pitch shifter parameters
SHIMMER_BASE_MS = 60.0
SHIMMER_GRAIN_MS = 60.0
GRAN_BASE_MS = 80.0
GRAN_GRAIN_MS = 100.0
# Reverb tail comb times (ms)
COMB_MS = [200.0, 250.0, 310.0, 370.0]

_st = None
_sr = None


class _S:
    def __init__(self, sr, nch):
        mx = int(0.5 * sr)
        self.modal = [[Biquad() for _ in range(6)] for _ in range(nch)]
        self.shimmer_dl = [DelayLine(mx) for _ in range(nch)]
        self.gran_dl = [DelayLine(mx) for _ in range(nch)]
        self.sub_lp = [Biquad() for _ in range(nch)]
        self.shim_hp = [Biquad() for _ in range(nch)]
        self.combs = [[DelayLine(mx) for _ in range(4)] for _ in range(nch)]
        self.comb_fb = [[0.0 for _ in range(4)] for _ in range(nch)]
        self.comb_lp = [[Biquad() for _ in range(4)] for _ in range(nch)]
        self.shim_phase = 0.0
        self.gran_phase = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    global _st, _sr
    nch = len(inputs)
    if _st is None or _sr != sample_rate:
        _st = _S(sample_rate, nch)
        _sr = sample_rate

    s = _st
    shimmer = params["shimmer"] / 100.0
    time_p = params["time"] / 100.0
    partials = params["partials"] / 100.0
    slowmo = params["slowmo"] / 100.0
    mx = params["mix"]

    # Modal Q ranges from 12 (low partials) to 35 (high partials)
    modal_q = 12.0 + 23.0 * partials
    modal_c = [BiquadCoeffs.bandpass(PARTIAL_HZ[k], modal_q, sample_rate)
               for k in range(6)]
    sub_lpc = BiquadCoeffs.lowpass(80.0, 0.707, sample_rate)
    shim_hpc = BiquadCoeffs.highpass(800.0, 0.707, sample_rate)
    comb_lpc = BiquadCoeffs.lowpass(4000.0, 0.707, sample_rate)
    for ch in range(nch):
        for k in range(6):
            s.modal[ch][k].set_coeffs(modal_c[k])
        s.sub_lp[ch].set_coeffs(sub_lpc)
        s.shim_hp[ch].set_coeffs(shim_hpc)
        for k in range(4):
            s.comb_lp[ch][k].set_coeffs(comb_lpc)

    # Pitch shifter delay parameters (samples)
    shim_base = SHIMMER_BASE_MS * 0.001 * sample_rate
    shim_grain = SHIMMER_GRAIN_MS * 0.001 * sample_rate
    gran_base = GRAN_BASE_MS * 0.001 * sample_rate
    gran_grain = GRAN_GRAIN_MS * 0.001 * sample_rate

    # Shimmer = octave up: read advances 1 sample faster per sample → grain_rate = 1.0/grain
    shim_rate = 1.0 / shim_grain
    # Granular slow-motion = octave down: read falls behind 0.5/sample
    gran_rate = 0.5 / gran_grain

    # Comb tail
    comb_d = [COMB_MS[k] * 0.001 * sample_rate for k in range(4)]
    comb_fb_amt = 0.55 + 0.30 * time_p

    modal_gain = 1.0 / 6.0
    sub_gain = 0.4

    for i in range(frame_count):
        # Advance shimmer phase (octave up: read approaches write)
        sh_ph0 = s.shim_phase
        sh_ph1 = (s.shim_phase + 0.5) % 1.0
        sh_w0 = math.sin(math.pi * sh_ph0)
        sh_w0 = sh_w0 * sh_w0
        sh_w1 = math.sin(math.pi * sh_ph1)
        sh_w1 = sh_w1 * sh_w1
        sh_read0 = shim_base - sh_ph0 * shim_grain
        sh_read1 = shim_base - sh_ph1 * shim_grain
        if sh_read0 < 1.0:
            sh_read0 = 1.0
        if sh_read1 < 1.0:
            sh_read1 = 1.0
        s.shim_phase = (s.shim_phase + shim_rate) % 1.0

        # Advance granular phase (octave down: read falls behind)
        gr_ph0 = s.gran_phase
        gr_ph1 = (s.gran_phase + 0.5) % 1.0
        gr_w0 = math.sin(math.pi * gr_ph0)
        gr_w0 = gr_w0 * gr_w0
        gr_w1 = math.sin(math.pi * gr_ph1)
        gr_w1 = gr_w1 * gr_w1
        gr_read0 = gran_base + gr_ph0 * gran_grain
        gr_read1 = gran_base + gr_ph1 * gran_grain
        s.gran_phase = (s.gran_phase + gran_rate) % 1.0

        for ch in range(nch):
            dry = float(inputs[ch][i])

            # Stage A: modal resonator bank (6 parallel high-Q bandpasses)
            m0 = s.modal[ch][0].process_sample(dry)
            m1 = s.modal[ch][1].process_sample(dry)
            m2 = s.modal[ch][2].process_sample(dry)
            m3 = s.modal[ch][3].process_sample(dry)
            m4 = s.modal[ch][4].process_sample(dry)
            m5 = s.modal[ch][5].process_sample(dry)
            modal_sum = (m0 + m1 + m2 + m3 + m4 + m5) * modal_gain

            # Stage B: octave-up crystalline shimmer (dual-tap pitch shifter)
            s.shimmer_dl[ch].write(modal_sum)
            sg0 = s.shimmer_dl[ch].read(sh_read0)
            sg1 = s.shimmer_dl[ch].read(sh_read1)
            shim_voice = (sh_w0 * sg0 + sh_w1 * sg1) * shimmer
            shim_voice = s.shim_hp[ch].process_sample(shim_voice)

            # Stage C: granular slow-motion (octave down, dual-tap shifter)
            s.gran_dl[ch].write(modal_sum)
            ng0 = s.gran_dl[ch].read(gr_read0)
            ng1 = s.gran_dl[ch].read(gr_read1)
            gran_voice = (gr_w0 * ng0 + gr_w1 * ng1) * slowmo

            # Stage D: sub-octave impact thud (rectify → LP → gain)
            sub_voice = s.sub_lp[ch].process_sample(abs(dry)) * sub_gain

            # Stage E: 4-comb reverb tail
            comb_in = modal_sum + shim_voice + gran_voice
            f0 = s.comb_lp[ch][0].process_sample(s.comb_fb[ch][0])
            f1 = s.comb_lp[ch][1].process_sample(s.comb_fb[ch][1])
            f2 = s.comb_lp[ch][2].process_sample(s.comb_fb[ch][2])
            f3 = s.comb_lp[ch][3].process_sample(s.comb_fb[ch][3])
            s.combs[ch][0].write(comb_in + comb_fb_amt * f0)
            s.combs[ch][1].write(comb_in + comb_fb_amt * f1)
            s.combs[ch][2].write(comb_in + comb_fb_amt * f2)
            s.combs[ch][3].write(comb_in + comb_fb_amt * f3)
            s.comb_fb[ch][0] = s.combs[ch][0].read(comb_d[0])
            s.comb_fb[ch][1] = s.combs[ch][1].read(comb_d[1])
            s.comb_fb[ch][2] = s.combs[ch][2].read(comb_d[2])
            s.comb_fb[ch][3] = s.combs[ch][3].read(comb_d[3])
            tail = (s.comb_fb[ch][0] + s.comb_fb[ch][1]
                    + s.comb_fb[ch][2] + s.comb_fb[ch][3]) * 0.25

            # Stage F: final wet sum + mix
            wet = modal_sum + shim_voice + gran_voice + sub_voice + tail
            outputs[ch][i] = dry * (1.0 - mx) + wet * mx
