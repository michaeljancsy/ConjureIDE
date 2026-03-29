import numpy as np
import math
from conjuredsp.params import param, time_ms, mix, choice
from conjuredsp.buffers import DelayLine
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "time":     time_ms(min=100, max=800, default=400),
    "feedback": param(0, 0.95, default=0.6),
    "shimmer":  param(0, 1, default=0.5),
    "damping":  param(0, 1, default=0.3),
    "mix":      mix(default=0.5),
}

MAX_DELAY = 96000
_delays = None
_lp = None
_octave_phase = [0.0, 0.0]


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Shimmer Delay — delay with octave-shifted feedback.

    Each delay repeat is pitch-shifted up by an octave (or a fifth),
    creating ethereal, crystalline trails that rise endlessly. The
    "shimmer" control blends between normal feedback and pitch-shifted
    feedback. With high feedback, creates infinite ascending cascades.
    Popularized by Brian Eno, U2's The Edge, and Sigur Ros. The
    definitive ambient/post-rock delay sound.

    Params:
        time:     Delay time (100–800 ms)
        feedback: Repeat amount (0–0.95)
        shimmer:  Pitch-shift blend in feedback (0–1)
        damping:  High-frequency rolloff per repeat (0–1)
        mix:      Wet/dry blend
    """
    global _delays, _lp, _octave_phase

    delay_ms = params["time"]
    feedback = params["feedback"]
    shimmer = params["shimmer"]
    damping = params["damping"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _delays is None:
        _delays = [DelayLine(MAX_DELAY) for _ in range(n_ch)]
        _lp = [Biquad() for _ in range(n_ch)]

    delay_samples = max(1.0, delay_ms * 0.001 * sample_rate)
    lp_freq = 16000.0 - damping * 12000.0

    for ch in range(n_ch):
        _lp[ch].set_coeffs(BiquadCoeffs.lowpass(lp_freq, 0.7, sample_rate))

    two_pi = 2.0 * math.pi

    for i in range(frame_count):
        for ch in range(n_ch):
            delayed = _delays[ch].read(delay_samples)

            # Damping filter
            delayed = _lp[ch].process_sample(delayed)

            # Octave-up shimmer via ring modulation approximation
            # Multiply by a signal at the frequency of the content
            # Simple approach: use a high-frequency carrier for brightness
            oct_signal = delayed * math.cos(two_pi * _octave_phase[ch])
            _octave_phase[ch] = (_octave_phase[ch] + 2.0 * 440.0 / sample_rate) % 1.0

            # Blend normal and shimmer feedback
            fb_signal = delayed * (1.0 - shimmer) + oct_signal * shimmer

            _delays[ch].write(inputs[ch][i] + fb_signal * feedback)

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + delayed * wet_mix
