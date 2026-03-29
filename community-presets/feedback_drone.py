import numpy as np
import math
from conjuredsp.params import freq, param, mix
from conjuredsp.buffers import DelayLine
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "pitch":     freq(min=30, max=1000, default=110),
    "feedback":  param(0.9, 1.05, default=0.99),
    "brightness": param(0, 1, default=0.4),
    "mix":       mix(default=0.5),
}

MAX_DELAY = 4096
_delays = None
_lp = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Feedback Drone — self-oscillating resonant feedback.

    A tuned delay line with feedback at or above unity creates a
    sustained drone at the specified pitch. The input signal excites
    and modulates the drone. At feedback just below 1.0, the drone
    slowly decays. At feedback above 1.0, it grows (soft-limited
    for safety). Creates otherworldly sustained tones from any
    input — perfect for ambient drones, noise walls, and feedback
    performance.

    Params:
        pitch:      Drone pitch (30–1000 Hz)
        feedback:   Self-oscillation amount (0.9–1.05, >1 = self-sustaining)
        brightness: Feedback brightness (0–1)
        mix:        Wet/dry blend
    """
    global _delays, _lp

    pitch_hz = params["pitch"]
    feedback = params["feedback"]
    brightness = params["brightness"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _delays is None:
        _delays = [DelayLine(MAX_DELAY) for _ in range(n_ch)]
        _lp = [Biquad() for _ in range(n_ch)]

    delay_samples = sample_rate / pitch_hz
    delay_samples = max(2.0, min(delay_samples, MAX_DELAY - 1))

    lp_freq = 500.0 + brightness * 8000.0

    for ch in range(n_ch):
        _lp[ch].set_coeffs(BiquadCoeffs.lowpass(lp_freq, 0.7, sample_rate))

        for i in range(frame_count):
            delayed = _delays[ch].read(delay_samples)

            # Filter in feedback loop
            delayed = _lp[ch].process_sample(delayed)

            # Soft limit to prevent blowup at feedback > 1.0
            delayed = math.tanh(delayed)

            _delays[ch].write(inputs[ch][i] * 0.3 + delayed * feedback)

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + delayed * wet_mix
