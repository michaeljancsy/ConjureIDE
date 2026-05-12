# Geiger Bells — radioactive clicks blossoming into bell tones.
#
# Deterministic stochastic impulse train (countdown sequence at 8 prime-ish
# inter-click distances scaled by density) → each impulse strikes a 4-partial
# harmonic bell resonator bank (440 / 880 / 1320 / 1760 Hz high-Q bandpass)
# → soft sub-pad bed derived from rectified input (80 Hz LP) → final mix.
#
# The source is the stochastic impulse generator, NOT the input audio — the
# bells blossom independently of what's playing. Distinct from all previous
# presets where the input drives the resonators.
#
# Params:
#   density  (pct) — click rate (fewer → more)
#   shimmer  (pct) — bell resonator Q (18 → 45)
#   bloom    (pct) — bell level
#   subpad   (pct) — sub-bass bed level
#   mix            — wet/dry blend

import math
from conjuredsp import mix, pct, Biquad, BiquadCoeffs

PARAMS = {
    "density": pct(default=55),
    "shimmer": pct(default=60),
    "bloom":   pct(default=60),
    "subpad":  pct(default=45),
    "mix":     mix(default=0.55),
}

BELL_HZ = [440.0, 880.0, 1320.0, 1760.0]
BELL_GAIN = [1.0, 0.7, 0.5, 0.35]
# Inter-click distances in milliseconds (prime-ish, deterministic sequence)
CLICK_MS = [77.0, 113.0, 59.0, 89.0, 137.0, 71.0, 103.0, 61.0]

_st = None
_sr = None


class _S:
    def __init__(self, sr, nch):
        self.bell = [[Biquad() for _ in range(4)] for _ in range(nch)]
        self.sub_lp = [Biquad() for _ in range(nch)]
        self.click_ix = 0
        self.countdown = 0.0


def process(ctx):
    global _st, _sr
    nch, frame_count = ctx.inputs.shape
    if _st is None or _sr != ctx.sample_rate:
        _st = _S(ctx.sample_rate, nch)
        _sr = ctx.sample_rate

    s = _st
    density = ctx.params["density"] / 100.0
    shimmer = ctx.params["shimmer"] / 100.0
    bloom = ctx.params["bloom"] / 100.0
    subpad = ctx.params["subpad"] / 100.0
    mx = ctx.params["mix"]

    bell_q = 18.0 + 27.0 * shimmer
    bell_c = [BiquadCoeffs.bandpass(BELL_HZ[k], bell_q, ctx.sample_rate)
              for k in range(4)]
    sub_lpc = BiquadCoeffs.lowpass(80.0, 0.707, ctx.sample_rate)
    for ch in range(nch):
        for k in range(4):
            s.bell[ch][k].set_coeffs(bell_c[k])
        s.sub_lp[ch].set_coeffs(sub_lpc)

    # Higher density → shorter countdown scale
    period_scale = 2.2 - 1.8 * density  # 2.2 (slow) → 0.4 (fast)
    bell_gain = 2.0 + 4.0 * bloom
    sub_gain = 0.6 + 1.2 * subpad

    for i in range(frame_count):
        s.countdown -= 1.0
        impulse = 0.0
        if s.countdown <= 0.0:
            impulse = 1.0
            next_ms = CLICK_MS[s.click_ix] * period_scale
            s.countdown = next_ms * 0.001 * ctx.sample_rate
            s.click_ix = (s.click_ix + 1) % 8

        for ch in range(nch):
            dry = float(ctx.inputs[ch][i])

            # Stage A: sub-pad bed from rectified input
            sub_voice = s.sub_lp[ch].process_sample(abs(dry)) * sub_gain

            # Stage B: 4-partial bell bank struck by impulse
            bell_sum = 0.0
            for k in range(4):
                bell_sum += s.bell[ch][k].process_sample(impulse) * BELL_GAIN[k]
            bell_voice = bell_sum * bell_gain

            wet = bell_voice + sub_voice
            ctx.outputs[ch][i] = dry * (1.0 - mx) + wet * mx
