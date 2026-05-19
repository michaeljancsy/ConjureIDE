import numpy as np
import math
from conjuredsp.params import param, time_ms, mix
from conjuredsp.buffers import DelayLine
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "time":     time_ms(min=100, max=800, default=375),
    "feedback": param(0, 0.95, default=0.7),
    "filter":   param(0, 1, default=0.6),
    "wobble":   param(0, 1, default=0.4),
    "mix":      mix(default=0.5),
}

MAX_DELAY = 96000
_delays = None
_lp = None
_hp = None
_phase = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Dub Delay — classic Jamaican dub/reggae delay.

    The sound of King Tubby and Lee "Scratch" Perry: a warm,
    heavily filtered delay with high feedback that creates
    cascading, ever-darkening echoes. The wobble control adds
    tape-like pitch instability. At high feedback, the delays
    build into a self-oscillating wash. The filter darkens each
    repeat until they disappear into the bass. THE defining
    effect of dub reggae.

    Params:
        time:     Delay time (100–800 ms)
        feedback: Repeat intensity — high values create runaway echoes (0–0.95)
        filter:   Repeat darkness (0 = bright, 1 = very dark)
        wobble:   Tape wobble on repeats (0–1)
        mix:      Wet/dry blend
    """
    global _delays, _lp, _hp, _phase

    delay_ms = params["time"]
    feedback = params["feedback"]
    darkness = params["filter"]
    wobble = params["wobble"]
    wet_mix = params["mix"]

    n_ch = len(inputs)
    two_pi = 2.0 * math.pi

    if _delays is None:
        _delays = [DelayLine(MAX_DELAY) for _ in range(n_ch)]
        _lp = [Biquad() for _ in range(n_ch)]
        _hp = [Biquad() for _ in range(n_ch)]

    lp_freq = 3000.0 - darkness * 2500.0
    hp_freq = 100.0 + darkness * 200.0

    for ch in range(n_ch):
        _lp[ch].set_coeffs(BiquadCoeffs.lowpass(lp_freq, 0.8, sample_rate))
        _hp[ch].set_coeffs(BiquadCoeffs.highpass(hp_freq, 0.7, sample_rate))

    for i in range(frame_count):
        # Tape wobble
        mod = math.sin(two_pi * _phase) * wobble * 5.0
        delay_samples = max(1.0, delay_ms * 0.001 * sample_rate + mod)
        delay_samples = min(delay_samples, MAX_DELAY - 1)

        for ch in range(n_ch):
            delayed = _delays[ch].read_cubic(delay_samples)

            # Heavy filtering in feedback — the dub sound
            delayed = _lp[ch].process_sample(delayed)
            delayed = _hp[ch].process_sample(delayed)

            # Dub-style saturation (mixing desk driven hot)
            delayed = math.tanh(delayed * 1.3) * 0.8

            _delays[ch].write(inputs[ch][i] + delayed * feedback)

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + delayed * wet_mix

        _phase = (_phase + 0.4 / sample_rate) % 1.0
