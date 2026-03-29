import numpy as np
import math
from conjuredsp.params import freq, param, mix
from conjuredsp.buffers import DelayLine
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "note":      freq(min=50, max=2000, default=220),
    "decay":     param(0.1, 5, unit="s", default=1),
    "brightness": param(0, 1, default=0.5),
    "mix":       mix(default=0.5),
}

MAX_DELAY = 4096
_delays = None
_lp = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Resonator — tuned resonant body simulation.

    Uses a tuned comb filter with damping to create a resonant body
    at a specific pitch. Any input excites the resonator like striking
    a tuned surface. With short decay, acts like a body resonance;
    with long decay, creates sustained pitched drones from any input.
    Used for Karplus-Strong string synthesis, body modeling, and
    creating pitched drones from noise or percussion.

    Params:
        note:       Resonant pitch (50–2000 Hz)
        decay:      Ring time (0.1–5 s)
        brightness: Damping filter (0 = dull, 1 = bright)
        mix:        Wet/dry blend
    """
    global _delays, _lp

    note_hz = params["note"]
    decay_s = params["decay"]
    brightness = params["brightness"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _delays is None:
        _delays = [DelayLine(MAX_DELAY) for _ in range(n_ch)]
        _lp = [Biquad() for _ in range(n_ch)]

    delay_samples = sample_rate / note_hz
    delay_samples = max(2.0, min(delay_samples, MAX_DELAY - 1))

    # Feedback for desired decay time
    if decay_s > 0:
        feedback = 10.0 ** (-3.0 * delay_samples / (decay_s * sample_rate))
    else:
        feedback = 0.0

    lp_freq = 1000.0 + brightness * 10000.0

    for ch in range(n_ch):
        _lp[ch].set_coeffs(BiquadCoeffs.lowpass(lp_freq, 0.7, sample_rate))

        for i in range(frame_count):
            delayed = _delays[ch].read(delay_samples)

            # Damping filter in feedback loop
            delayed = _lp[ch].process_sample(delayed)

            _delays[ch].write(inputs[ch][i] + delayed * feedback)

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + delayed * wet_mix
