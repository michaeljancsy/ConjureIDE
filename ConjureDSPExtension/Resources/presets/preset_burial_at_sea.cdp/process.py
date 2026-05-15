# Burial at Sea — a slow descent into deep water, a single bell tolling above.
#
# Slow continuous downward pitch droop (dual-tap pitch shifter, no bit-crush)
# → closing one-pole lowpass (depth-controlled, sweeping from 6 kHz to 400 Hz)
# → distant high-Q bell resonator (peaking EQ at 880 Hz) → sub swell from
# rectified envelope → long dark feedback comb tail → final mix.
#
# Distinct from Dying Star: this is the gentle funereal cousin — pure pitch
# collapse without the bit-reduction harshness, with a tolling bell instead
# of Schwarzschild ringing.
#
# Controls:
#   depth   (pct) — closes the lowpass and deepens the descent
#   descent (pct) — pitch droop rate
#   bell    (pct) — bell resonator level
#   tail    (pct) — long comb reverb feedback
#   mix           — wet/dry blend

import math
from conjuredsp import (mix, pct,
                        DelayLine, Biquad, BiquadCoeffs)

PARAMS = {
    "depth":   pct(default=60),
    "descent": pct(default=50),
    "bell":    pct(default=55),
    "tail":    pct(default=70),
    "mix":     mix(default=0.55),
}

# Pitch shifter parameters
SHIFT_BASE_MS = 60.0
GRAIN_MS = 100.0
# Bell resonator
BELL_HZ = 880.0
# Long tail comb time (ms)
TAIL_MS = 420.0

_st = None
_sr = None


class _S:
    def __init__(self, sr, nch):
        mx = int(0.6 * sr)
        self.shift_dl = [DelayLine(mx) for _ in range(nch)]
        self.close_lp = [0.0 for _ in range(nch)]
        self.bell = [Biquad() for _ in range(nch)]
        self.sub_lp = [Biquad() for _ in range(nch)]
        self.tail_dl = [DelayLine(mx) for _ in range(nch)]
        self.tail_lp = [Biquad() for _ in range(nch)]
        self.tail_fb = [0.0 for _ in range(nch)]
        self.grain_phase = 0.0


def process(ctx):
    global _st, _sr
    nch, frame_count = ctx.inputs.shape
    if _st is None or _sr != ctx.sample_rate:
        _st = _S(ctx.sample_rate, nch)
        _sr = ctx.sample_rate

    s = _st
    depth = ctx.params["depth"] / 100.0
    descent = ctx.params["descent"] / 100.0
    bell_amt = ctx.params["bell"] / 100.0
    tail = ctx.params["tail"] / 100.0
    mx = ctx.params["mix"]

    # Closing lowpass: 6000 Hz → 400 Hz as depth increases
    close_fc = 6000.0 - 5600.0 * depth
    close_alpha = math.exp(-2.0 * math.pi * close_fc / ctx.sample_rate)
    close_one_minus = 1.0 - close_alpha

    # Bell resonator (high-Q peaking EQ at 880 Hz, +12 dB)
    bell_c = BiquadCoeffs.peak(BELL_HZ, 12.0, 12.0, ctx.sample_rate)
    sub_lpc = BiquadCoeffs.lowpass(70.0, 0.707, ctx.sample_rate)
    tail_lpc = BiquadCoeffs.lowpass(1500.0, 0.707, ctx.sample_rate)
    for ch in range(nch):
        s.bell[ch].set_coeffs(bell_c)
        s.sub_lp[ch].set_coeffs(sub_lpc)
        s.tail_lp[ch].set_coeffs(tail_lpc)

    # Pitch shifter — descent rate scales grain phase advance
    base_d = SHIFT_BASE_MS * 0.001 * ctx.sample_rate
    grain_samples = GRAIN_MS * 0.001 * ctx.sample_rate
    grain_rate = (0.2 + 1.0 * descent) / grain_samples

    tail_d = TAIL_MS * 0.001 * ctx.sample_rate
    tail_fb_amt = 0.55 + 0.30 * tail

    bell_gain = bell_amt * 0.6
    sub_gain = 1.2

    for i in range(frame_count):
        ph0 = s.grain_phase
        ph1 = (s.grain_phase + 0.5) % 1.0
        w0 = math.sin(math.pi * ph0)
        w0 = w0 * w0
        w1 = math.sin(math.pi * ph1)
        w1 = w1 * w1
        # Read falls behind write → pitch droops downward
        read0 = base_d + ph0 * grain_samples
        read1 = base_d + ph1 * grain_samples
        s.grain_phase = (s.grain_phase + grain_rate) % 1.0

        for ch in range(nch):
            dry = float(ctx.inputs[ch][i])

            # Stage A: dual-tap downward pitch shifter
            s.shift_dl[ch].write(dry)
            g0 = s.shift_dl[ch].read(read0)
            g1 = s.shift_dl[ch].read(read1)
            shifted = w0 * g0 + w1 * g1

            # Stage B: closing lowpass (depth-controlled descent)
            s.close_lp[ch] = close_alpha * s.close_lp[ch] + close_one_minus * shifted
            closed = s.close_lp[ch]

            # Stage C: distant bell resonator (peaking EQ on the closed bus)
            bell_voice = s.bell[ch].process_sample(closed) * bell_gain

            # Stage D: sub swell from rectified envelope
            sub_voice = s.sub_lp[ch].process_sample(abs(dry)) * sub_gain

            # Stage E: long dark feedback comb tail
            tail_in = closed + bell_voice
            f_in = s.tail_lp[ch].process_sample(s.tail_fb[ch])
            s.tail_dl[ch].write(tail_in + tail_fb_amt * f_in)
            s.tail_fb[ch] = s.tail_dl[ch].read(tail_d)

            # Final wet sum + mix
            wet = closed + bell_voice + sub_voice + s.tail_fb[ch] * 0.5
            ctx.outputs[ch][i] = dry * (1.0 - mx) + wet * mx
