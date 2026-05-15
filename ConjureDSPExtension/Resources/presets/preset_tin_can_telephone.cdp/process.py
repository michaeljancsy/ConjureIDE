# Tin Can Telephone — two voices on a string between cans.
#
# Aggressive narrow bandpass (~1 kHz, high Q) per channel → cross-channel
# feedback routing (L[n] input = L_dry + (previous frame's R wet) * fb_amt,
# and vice versa — true L↔R routing, NOT M/S widening) → asymmetric soft
# clip (hard on positive, soft on negative) → occasional dropout gate (slow
# LFO + sparse threshold) → final mix.
#
# First preset in the set with cross-channel L↔R feedback. Intimate stereo
# image (the stereo separation is the string, not the room).
#
# Controls:
#   can     (pct) — bandpass narrowness (Q)
#   string  (pct) — cross-channel feedback amount
#   clip    (pct) — asymmetric clip drive
#   dropout (pct) — dropout density
#   mix           — wet/dry blend

import math
from conjuredsp import mix, pct, Biquad, BiquadCoeffs, LFO

PARAMS = {
    "can":     pct(default=65),
    "string":  pct(default=50),
    "clip":    pct(default=55),
    "dropout": pct(default=30),
    "mix":     mix(default=0.6),
}

BP_HZ = 1000.0
DROPOUT_HZ = 0.37

_st = None
_sr = None


class _S:
    def __init__(self, sr, nch):
        self.bp = [Biquad() for _ in range(nch)]
        self.cross_fb = [0.0 for _ in range(nch)]
        self.dropout_lfo = LFO(sr, freq=DROPOUT_HZ, waveform="sine")


def process(ctx):
    global _st, _sr
    nch, frame_count = ctx.inputs.shape
    if _st is None or _sr != ctx.sample_rate:
        _st = _S(ctx.sample_rate, nch)
        _sr = ctx.sample_rate

    s = _st
    can = ctx.params["can"] / 100.0
    string = ctx.params["string"] / 100.0
    clip = ctx.params["clip"] / 100.0
    dropout = ctx.params["dropout"] / 100.0
    mx = ctx.params["mix"]

    bp_q = 5.0 + 12.0 * can
    bp_c = BiquadCoeffs.bandpass(BP_HZ, bp_q, ctx.sample_rate)
    for ch in range(nch):
        s.bp[ch].set_coeffs(bp_c)

    fb_amt = 0.75 * string
    drive = 1.0 + 5.0 * clip
    drop_thresh = -0.6 + 1.2 * dropout

    for i in range(frame_count):
        drop_val = s.dropout_lfo.tick()
        gate = drop_val - drop_thresh
        if gate < 0.0:
            gate_val = 0.0
        elif gate > 0.3:
            gate_val = 1.0
        else:
            gate_val = gate / 0.3

        if nch >= 2:
            # Cross-channel L↔R feedback
            l_dry = float(ctx.inputs[0][i])
            r_dry = float(ctx.inputs[1][i])

            l_in = l_dry + s.cross_fb[1] * fb_amt
            r_in = r_dry + s.cross_fb[0] * fb_amt

            l_bp = s.bp[0].process_sample(l_in)
            r_bp = s.bp[1].process_sample(r_in)

            # Asymmetric clip: hard positive, soft negative
            if l_bp >= 0.0:
                l_clip = math.tanh(l_bp * drive * 1.8) / (drive * 1.8)
            else:
                l_clip = math.tanh(l_bp * drive * 0.7) / (drive * 0.7)
            if r_bp >= 0.0:
                r_clip = math.tanh(r_bp * drive * 1.8) / (drive * 1.8)
            else:
                r_clip = math.tanh(r_bp * drive * 0.7) / (drive * 0.7)

            l_wet = l_clip * gate_val
            r_wet = r_clip * gate_val

            s.cross_fb[0] = l_wet
            s.cross_fb[1] = r_wet

            ctx.outputs[0][i] = l_dry * (1.0 - mx) + l_wet * mx
            ctx.outputs[1][i] = r_dry * (1.0 - mx) + r_wet * mx
        else:
            # Mono fallback: self feedback
            dry = float(ctx.inputs[0][i])
            x_in = dry + s.cross_fb[0] * fb_amt
            x_bp = s.bp[0].process_sample(x_in)
            if x_bp >= 0.0:
                x_clip = math.tanh(x_bp * drive * 1.8) / (drive * 1.8)
            else:
                x_clip = math.tanh(x_bp * drive * 0.7) / (drive * 0.7)
            wet = x_clip * gate_val
            s.cross_fb[0] = wet
            ctx.outputs[0][i] = dry * (1.0 - mx) + wet * mx
