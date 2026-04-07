import numpy as np
import math
from conjuredsp.params import param, mix, time_ms
from conjuredsp.buffers import DelayLine
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "time":     time_ms(min=50, max=800, default=300),
    "feedback": param(0, 0.95, default=0.5),
    "wow":      param(0, 1, default=0.3),
    "age":      param(0, 1, default=0.5),
    "mix":      mix(default=0.5),
}

_rng_state = 12345

def _rng():
    global _rng_state
    _rng_state = (_rng_state * 1664525 + 1013904223) & 0xFFFFFFFF
    return _rng_state / 4294967296.0

MAX_DELAY = 96000
_delays = None
_lp = None
_hp = None
_wow_phase = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Tape Echo — Roland Space Echo / Echoplex inspired.

    Models the warm, decaying echoes of vintage tape delay units.
    Each repeat passes through a lowpass filter (simulating tape
    head frequency loss) and wobbles in pitch (wow from motor
    irregularities). The "age" control darkens and degrades the
    repeats like worn tape. The definitive delay sound for dub,
    rockabilly, psychedelia, and ambient music.

    Params:
        time:     Delay time (50–800 ms)
        feedback: Number of repeats (0–0.95)
        wow:      Tape speed wobble (0–1)
        age:      Tape degradation / darkness (0–1)
        mix:      Wet/dry blend
    """
    global _delays, _lp, _hp, _wow_phase

    delay_ms = params["time"]
    feedback = params["feedback"]
    wow = params["wow"]
    age = params["age"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _delays is None:
        _delays = [DelayLine(MAX_DELAY) for _ in range(n_ch)]
        _lp = [Biquad() for _ in range(n_ch)]
        _hp = [Biquad() for _ in range(n_ch)]

    # Age controls the filter: new tape = 10kHz, old tape = 2kHz
    lp_freq = 10000.0 - age * 8000.0
    hp_freq = 40.0 + age * 160.0

    two_pi = 2.0 * math.pi
    wow_depth = wow * 8.0  # samples of wow

    for ch in range(n_ch):
        _lp[ch].set_coeffs(BiquadCoeffs.lowpass(lp_freq, 0.7, sample_rate))
        _hp[ch].set_coeffs(BiquadCoeffs.highpass(hp_freq, 0.7, sample_rate))

    for i in range(frame_count):
        # Wow modulation
        wow_mod = math.sin(two_pi * _wow_phase) * wow_depth
        wow_mod += (_rng() - 0.5) * wow * 1.0  # noise

        delay_samples = delay_ms * 0.001 * sample_rate + wow_mod
        delay_samples = max(1.0, min(delay_samples, MAX_DELAY - 1))

        for ch in range(n_ch):
            delayed = _delays[ch].read_cubic(delay_samples)

            # Tape coloring on feedback path
            delayed = _lp[ch].process_sample(delayed)
            delayed = _hp[ch].process_sample(delayed)

            # Soft saturation in feedback (tape compression)
            delayed = math.tanh(delayed * 1.2) * 0.85

            _delays[ch].write(inputs[ch][i] + delayed * feedback)

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + delayed * wet_mix

        _wow_phase = (_wow_phase + 0.5 / sample_rate) % 1.0
