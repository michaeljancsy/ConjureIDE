# Methane Sea — bubbles surfacing from an alien ocean on Titan.
#
# Cross-channel ping-pong delay (L delay's tap routes to R's input and
# vice versa — true L↔R routing) with per-channel tap positions modulated
# by two coprime LFOs at 0.31 / 0.47 Hz, and the modulation depth itself
# swept by a very slow 0.07 Hz "sweep" LFO → sub drone bed (rectified |dry|
# → 80 Hz LP) → dark lowpass (2 kHz) on the wet bus → final mix.
#
# Distinct from Underwater Spy: sparse alien ocean bubbles vs lush
# submerged warmth. Second preset with true cross-channel routing (after
# Tin Can Telephone) — but here the routing is a ping-pong delay rather
# than a fast feedback clip loop.
#
# Controls:
#   ripple (pct) — ping-pong feedback amount
#   bubble (pct) — base tap LFO depth
#   drone  (pct) — sub drone level
#   sweep  (pct) — slow sweep LFO depth (modulates tap depth)
#   mix          — wet/dry blend

import math
from conjuredsp import (mix, pct,
                        DelayLine, Biquad, BiquadCoeffs, LFO)

PARAMS = {
    "ripple": pct(default=60),
    "bubble": pct(default=55),
    "drone":  pct(default=50),
    "sweep":  pct(default=60),
    "mix":    mix(default=0.55),
}

TAP_BASE_MS = 220.0
TAP_LFO_HZ = [0.31, 0.47]
SWEEP_HZ = 0.07

_st = None
_sr = None


class _S:
    def __init__(self, sr, nch):
        mx = int(0.6 * sr)
        self.delay = [DelayLine(mx) for _ in range(nch)]
        self.sub_lp = [Biquad() for _ in range(nch)]
        self.wet_lp = [Biquad() for _ in range(nch)]
        self.tap_lfo = [LFO(sr, freq=TAP_LFO_HZ[k], waveform="sine")
                        for k in range(2)]
        self.sweep_lfo = LFO(sr, freq=SWEEP_HZ, waveform="sine")


def process(ctx):
    global _st, _sr
    nch, frame_count = ctx.inputs.shape
    if _st is None or _sr != ctx.sample_rate:
        _st = _S(ctx.sample_rate, nch)
        _sr = ctx.sample_rate

    s = _st
    ripple = ctx.params["ripple"] / 100.0
    bubble = ctx.params["bubble"] / 100.0
    drone = ctx.params["drone"] / 100.0
    sweep = ctx.params["sweep"] / 100.0
    mx = ctx.params["mix"]

    sub_lpc = BiquadCoeffs.lowpass(80.0, 0.707, ctx.sample_rate)
    wet_lpc = BiquadCoeffs.lowpass(2000.0, 0.707, ctx.sample_rate)
    for ch in range(nch):
        s.sub_lp[ch].set_coeffs(sub_lpc)
        s.wet_lp[ch].set_coeffs(wet_lpc)

    tap_base = TAP_BASE_MS * 0.001 * ctx.sample_rate
    base_depth = (10.0 + 40.0 * bubble) * 0.001 * ctx.sample_rate
    sweep_depth = 0.6 * sweep
    fb_amt = 0.45 + 0.45 * ripple
    drone_gain = 0.5 + 1.2 * drone

    for i in range(frame_count):
        tl = s.tap_lfo[0].tick()
        tr = s.tap_lfo[1].tick()
        sw = s.sweep_lfo.tick()
        depth_mod = (1.0 - sweep_depth) + sweep_depth * (0.5 + 0.5 * sw)
        tap_l = tap_base + tl * base_depth * depth_mod
        tap_r = tap_base + tr * base_depth * depth_mod
        if tap_l < 1.0:
            tap_l = 1.0
        if tap_r < 1.0:
            tap_r = 1.0

        if nch >= 2:
            # Read taps BEFORE writing (classic ping-pong timing)
            fb_from_l = s.delay[0].read(tap_l)
            fb_from_r = s.delay[1].read(tap_r)

            l_dry = float(ctx.inputs[0][i])
            r_dry = float(ctx.inputs[1][i])

            # Ping-pong routing: L delay receives dry_L + R's tap feedback
            s.delay[0].write(l_dry + fb_from_r * fb_amt)
            s.delay[1].write(r_dry + fb_from_l * fb_amt)

            l_sub = s.sub_lp[0].process_sample(abs(l_dry)) * drone_gain
            r_sub = s.sub_lp[1].process_sample(abs(r_dry)) * drone_gain

            l_wet_raw = fb_from_r + l_sub
            r_wet_raw = fb_from_l + r_sub

            l_wet = s.wet_lp[0].process_sample(l_wet_raw)
            r_wet = s.wet_lp[1].process_sample(r_wet_raw)

            ctx.outputs[0][i] = l_dry * (1.0 - mx) + l_wet * mx
            ctx.outputs[1][i] = r_dry * (1.0 - mx) + r_wet * mx
        else:
            # Mono fallback
            fb_out = s.delay[0].read(tap_l)
            dry = float(ctx.inputs[0][i])
            s.delay[0].write(dry + fb_out * fb_amt)
            sub_voice = s.sub_lp[0].process_sample(abs(dry)) * drone_gain
            wet_raw = fb_out + sub_voice
            wet = s.wet_lp[0].process_sample(wet_raw)
            ctx.outputs[0][i] = dry * (1.0 - mx) + wet * mx
