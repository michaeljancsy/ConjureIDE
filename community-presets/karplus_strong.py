import numpy as np
import math
from conjuredsp.params import freq, param, mix
from conjuredsp.buffers import DelayLine
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "pitch":      freq(min=50, max=1000, default=220),
    "brightness": param(0, 1, default=0.6),
    "decay":      param(0.5, 10, unit="s", default=2),
    "mix":        mix(default=0.6),
}

MAX_DELAY = 4096
_delays = None
_lp = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Karplus-Strong — plucked string synthesis from input.

    Uses the Karplus-Strong algorithm: a short delay line with
    lowpass-filtered feedback creates a string-like resonance at
    the delay frequency. The input audio acts as the "pluck" —
    exciting the string. Percussion input creates pitched plucks;
    noise creates bowed textures. A physical modeling classic that
    turns any sound into a stringed instrument.

    Params:
        pitch:      String pitch (50–1000 Hz)
        brightness: String brightness / damping (0 = dull gut, 1 = bright steel)
        decay:      Sustain time (0.5–10 s)
        mix:        Wet/dry blend
    """
    global _delays, _lp

    pitch_hz = params["pitch"]
    brightness = params["brightness"]
    decay_s = params["decay"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _delays is None:
        _delays = [DelayLine(MAX_DELAY) for _ in range(n_ch)]
        _lp = [Biquad() for _ in range(n_ch)]

    delay_samples = sample_rate / pitch_hz
    delay_samples = max(2.0, min(delay_samples, MAX_DELAY - 1))

    # Feedback gain for desired decay
    if decay_s > 0:
        feedback = 10.0 ** (-3.0 * delay_samples / (decay_s * sample_rate))
    else:
        feedback = 0.0

    # Brightness controls the lowpass in the loop
    lp_freq = 500.0 + brightness * 8000.0

    for ch in range(n_ch):
        _lp[ch].set_coeffs(BiquadCoeffs.lowpass(lp_freq, 0.7, sample_rate))

        for i in range(frame_count):
            delayed = _delays[ch].read(delay_samples)

            # Karplus-Strong: lowpass filter in feedback loop
            # This is the key — each cycle loses high frequencies,
            # simulating the damping of a vibrating string
            delayed = _lp[ch].process_sample(delayed)

            # Input excites the string
            _delays[ch].write(inputs[ch][i] * 0.5 + delayed * feedback)

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + delayed * wet_mix
