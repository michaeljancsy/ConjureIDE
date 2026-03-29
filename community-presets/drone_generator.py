import numpy as np
import math
from conjuredsp.params import freq, param, mix
from conjuredsp.buffers import DelayLine
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "pitch":  freq(min=30, max=500, default=110),
    "sustain": param(0.95, 1.0, default=0.995),
    "tone":   param(0, 1, default=0.4),
    "mix":    mix(default=0.5),
}

MAX_DELAY = 8192
_delays = None
_lp = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Drone Generator — create sustained drones from any input.

    Feeds input into a tuned resonator with very high feedback,
    causing the resonant pitch to build up and sustain. Short
    percussive inputs create pitched drones that evolve over time.
    Long sustained inputs create harmonic textures. Perfect for
    ambient music, meditation soundscapes, and creating pad layers
    from found sounds.

    Params:
        pitch:   Drone fundamental frequency (30–500 Hz)
        sustain: How long the drone sustains (0.95–1.0)
        tone:    Drone brightness (0 = dark, 1 = bright)
        mix:     Wet/dry blend
    """
    global _delays, _lp

    pitch_hz = params["pitch"]
    sustain = params["sustain"]
    tone = params["tone"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _delays is None:
        _delays = [DelayLine(MAX_DELAY) for _ in range(n_ch)]
        _lp = [Biquad() for _ in range(n_ch)]

    delay_samples = sample_rate / pitch_hz
    delay_samples = max(2.0, min(delay_samples, MAX_DELAY - 1))

    lp_freq = 300.0 + tone * 5000.0

    for ch in range(n_ch):
        _lp[ch].set_coeffs(BiquadCoeffs.lowpass(lp_freq, 0.7, sample_rate))

        for i in range(frame_count):
            delayed = _delays[ch].read(delay_samples)
            delayed = _lp[ch].process_sample(delayed)
            delayed = math.tanh(delayed)  # prevent blowup

            _delays[ch].write(inputs[ch][i] * 0.2 + delayed * sustain)

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + delayed * wet_mix
