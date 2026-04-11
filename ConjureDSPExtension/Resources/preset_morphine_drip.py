# Morphine Drip — narcotic haze, time slowing between heartbeats.
#
# Slow 0.5 Hz "drip" envelope (triangle LFO squared → sin²-like pulsing) as
# the primary amplitude gate → narcotic slow pitch drift (single dual-tap
# delay modulated by a 0.23 Hz sine LFO) → soft tanh saturation → long
# lowpass-feedback delay (380 ms, dark feedback path) → final mix.
#
# Distinct from Broken Fax Lullaby: single slow drip instead of coprime
# square-gate chorus; narcotic mood vs broken-fax mechanical clatter. The
# drip envelope IS the sound rather than a side stage.
#
# Params:
#   drip  (pct) — drip envelope depth
#   haze  (pct) — tanh saturation drive
#   drift (pct) — slow pitch drift depth
#   bleed (pct) — feedback delay amount
#   mix         — wet/dry blend

import math
from conjuredsp import (mix, pct,
                        DelayLine, Biquad, BiquadCoeffs, LFO)

PARAMS = {
    "drip":  pct(default=70),
    "haze":  pct(default=50),
    "drift": pct(default=45),
    "bleed": pct(default=60),
    "mix":   mix(default=0.55),
}

DRIP_HZ = 0.5
DRIFT_HZ = 0.23
DELAY_MS = 380.0
DRIFT_BASE_MS = 15.0

_st = None
_sr = None


class _S:
    def __init__(self, sr, nch):
        mx = int(0.6 * sr)
        self.drip_lfo = LFO(sr, freq=DRIP_HZ, waveform="triangle")
        self.drift_lfo = LFO(sr, freq=DRIFT_HZ, waveform="sine")
        self.drift_dl = [DelayLine(mx) for _ in range(nch)]
        self.delay_dl = [DelayLine(mx) for _ in range(nch)]
        self.delay_lp = [Biquad() for _ in range(nch)]
        self.delay_fb = [0.0 for _ in range(nch)]


def process(inputs, outputs, frame_count, sample_rate, params):
    global _st, _sr
    nch = len(inputs)
    if _st is None or _sr != sample_rate:
        _st = _S(sample_rate, nch)
        _sr = sample_rate

    s = _st
    drip = params["drip"] / 100.0
    haze = params["haze"] / 100.0
    drift = params["drift"] / 100.0
    bleed = params["bleed"] / 100.0
    mx = params["mix"]

    delay_lpc = BiquadCoeffs.lowpass(1200.0, 0.707, sample_rate)
    for ch in range(nch):
        s.delay_lp[ch].set_coeffs(delay_lpc)

    drip_depth = 0.85 * drip
    drive = 1.0 + 4.0 * haze
    drift_base = DRIFT_BASE_MS * 0.001 * sample_rate
    drift_depth = (2.0 + 8.0 * drift) * 0.001 * sample_rate
    delay_d = DELAY_MS * 0.001 * sample_rate
    delay_fb_amt = 0.55 + 0.30 * bleed

    for i in range(frame_count):
        tri = s.drip_lfo.tick()
        pulse = (0.5 + 0.5 * tri)
        drip_env = (1.0 - drip_depth) + drip_depth * pulse * pulse

        drift_val = s.drift_lfo.tick()
        dd = drift_base + drift_val * drift_depth
        if dd < 1.0:
            dd = 1.0

        for ch in range(nch):
            dry = float(inputs[ch][i])

            # Stage A: drip amplitude gate
            gated = dry * drip_env

            # Stage B: narcotic pitch drift
            s.drift_dl[ch].write(gated)
            drifted = s.drift_dl[ch].read(dd)

            # Stage C: soft tanh saturation
            sat = math.tanh(drifted * drive) / drive

            # Stage D: long LP feedback delay
            f_in = s.delay_lp[ch].process_sample(s.delay_fb[ch])
            s.delay_dl[ch].write(sat + delay_fb_amt * f_in)
            s.delay_fb[ch] = s.delay_dl[ch].read(delay_d)

            wet = sat + s.delay_fb[ch] * 0.7
            outputs[ch][i] = dry * (1.0 - mx) + wet * mx
