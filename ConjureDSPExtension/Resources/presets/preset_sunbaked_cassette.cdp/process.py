# Sun-Baked Cassette — cassette tape left in the sun for 30 years.
#
# Wow + flutter modulated delay → frequency-dependent + asymmetric tanh
# saturation → tone shaping shelves → print-through pre-echo → tape echo
# (LP in feedback) → head-wear feedback comb → final mix.
#
# Controls:
#   wow     (ms)  — slow pitch drift depth (0–6)
#   flutter (ms)  — fast warble depth (0–3)
#   wear    (pct) — drives saturation amount, 0=clean / 100=destroyed
#   tone    (pct) — high-frequency rolloff amount (0=bright / 100=dull)
#   mix           — wet/dry blend

import math
from conjuredsp import (time_ms, mix, pct,
                        DelayLine, Biquad, BiquadCoeffs, LFO)

PARAMS = {
    "wow":     time_ms(0.0, 6.0, default=3.0),
    "flutter": time_ms(0.0, 3.0, default=1.2),
    "wear":    pct(default=45),
    "tone":    pct(default=50),
    "mix":     mix(default=0.6),
}

# Wow + flutter base delay (ms)
WF_BASE_MS = 8.0
# Print-through pre-echo time (ms)
PRINT_MS = 150.0
# Tape echo time (ms)
ECHO_MS = 280.0
# Head-wear comb (ms)
COMB_MS = 0.7

_st = None
_sr = None


class _S:
    def __init__(self, sr, nch):
        mx = int(0.5 * sr)
        self.wf = [DelayLine(mx) for _ in range(nch)]
        self.pre_hs = [Biquad() for _ in range(nch)]
        self.de_hs = [Biquad() for _ in range(nch)]
        self.lo_sh = [Biquad() for _ in range(nch)]
        self.hi_sh = [Biquad() for _ in range(nch)]
        self.print_dl = [DelayLine(mx) for _ in range(nch)]
        self.print_lp = [Biquad() for _ in range(nch)]
        self.echo_dl = [DelayLine(mx) for _ in range(nch)]
        self.echo_lp = [Biquad() for _ in range(nch)]
        self.echo_fb = [0.0 for _ in range(nch)]
        self.comb_dl = [DelayLine(mx) for _ in range(nch)]
        self.comb_fb = [0.0 for _ in range(nch)]
        self.lfo_wow = LFO(sr, freq=0.5, waveform="sine")
        self.lfo_flutter = LFO(sr, freq=7.0, waveform="sine")


def process(ctx):
    global _st, _sr
    nch, frame_count = ctx.inputs.shape
    if _st is None or _sr != ctx.sample_rate:
        _st = _S(ctx.sample_rate, nch)
        _sr = ctx.sample_rate

    s = _st
    wow_ms = ctx.params["wow"]
    flutter_ms = ctx.params["flutter"]
    wear = ctx.params["wear"] / 100.0
    tone = ctx.params["tone"] / 100.0
    mx = ctx.params["mix"]

    # Pre/de-emphasis (frequency-dependent saturation envelope)
    pre_hsc = BiquadCoeffs.highshelf(5000.0, 0.707, 6.0, ctx.sample_rate)
    de_hsc = BiquadCoeffs.highshelf(5000.0, 0.707, -9.0, ctx.sample_rate)
    # Tone shaping
    lo_shc = BiquadCoeffs.lowshelf(120.0, 0.707, 3.0, ctx.sample_rate)
    hi_shc = BiquadCoeffs.highshelf(8000.0, 0.707, -12.0 * tone, ctx.sample_rate)
    # Print-through and feedback lowpasses
    print_lpc = BiquadCoeffs.lowpass(1500.0, 0.707, ctx.sample_rate)
    echo_lpc = BiquadCoeffs.lowpass(3000.0, 0.707, ctx.sample_rate)
    for ch in range(nch):
        s.pre_hs[ch].set_coeffs(pre_hsc)
        s.de_hs[ch].set_coeffs(de_hsc)
        s.lo_sh[ch].set_coeffs(lo_shc)
        s.hi_sh[ch].set_coeffs(hi_shc)
        s.print_lp[ch].set_coeffs(print_lpc)
        s.echo_lp[ch].set_coeffs(echo_lpc)

    # Asymmetric saturation drives
    drive_pos = 1.0 + wear * 2.5
    drive_neg = 1.0 + wear * 1.6

    # Delay times (samples)
    base_d = WF_BASE_MS * 0.001 * ctx.sample_rate
    wow_depth = wow_ms * 0.001 * ctx.sample_rate
    flutter_depth = flutter_ms * 0.001 * ctx.sample_rate
    print_d = PRINT_MS * 0.001 * ctx.sample_rate
    echo_d = ECHO_MS * 0.001 * ctx.sample_rate
    comb_d = max(COMB_MS * 0.001 * ctx.sample_rate, 1.0)

    print_gain = 0.04  # ≈ −28 dB
    echo_fb_amt = 0.4
    comb_fb_amt = 0.35

    for i in range(frame_count):
        wlfo = s.lfo_wow.tick()
        flfo = s.lfo_flutter.tick()
        d = max(base_d + wlfo * wow_depth + flfo * flutter_depth, 1.0)

        for ch in range(nch):
            dry = float(ctx.inputs[ch][i])

            # Stage A: wow + flutter modulated delay
            s.wf[ch].write(dry)
            x = s.wf[ch].read(d)

            # Stage B: pre-emphasis highshelf
            x = s.pre_hs[ch].process_sample(x)

            # Stage C: asymmetric tanh saturation
            if x > 0.0:
                x = math.tanh(x * drive_pos)
            else:
                x = math.tanh(x * drive_neg)

            # Stage D: de-emphasis highshelf
            x = s.de_hs[ch].process_sample(x)

            # Stage E: tone shaping (warmth + HF rolloff)
            x = s.lo_sh[ch].process_sample(x)
            x = s.hi_sh[ch].process_sample(x)

            # Stage F: print-through pre-echo (lowpassed delayed dry)
            s.print_dl[ch].write(dry)
            print_tap = s.print_dl[ch].read(print_d)
            print_tap = s.print_lp[ch].process_sample(print_tap)
            x = x + print_tap * print_gain

            # Stage G: tape echo (LP in feedback)
            eflt = s.echo_lp[ch].process_sample(s.echo_fb[ch])
            s.echo_dl[ch].write(x + echo_fb_amt * eflt)
            s.echo_fb[ch] = s.echo_dl[ch].read(echo_d)
            x = x + 0.5 * s.echo_fb[ch]

            # Stage H: head-wear feedback comb
            s.comb_dl[ch].write(x + comb_fb_amt * s.comb_fb[ch])
            s.comb_fb[ch] = s.comb_dl[ch].read(comb_d)
            x = x + 0.3 * s.comb_fb[ch]

            ctx.outputs[ch][i] = dry * (1.0 - mx) + x * mx
