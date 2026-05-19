import numpy as np
import math
from conjuredsp.params import param, time_ms, mix
from conjuredsp.buffers import DelayLine
from conjuredsp.dsp import smooth_coeff

PARAMS = {
    "time":     time_ms(min=50, max=800, default=350),
    "feedback": param(0, 0.9, default=0.4),
    "duck":     param(0, 1, default=0.7),
    "release":  time_ms(min=50, max=1000, default=200),
    "mix":      mix(default=0.7),
}

MAX_DELAY = 96000
_delays = None
_envelope = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Ducking Delay — delay that hides under the dry signal.

    The delay output is automatically reduced when the input is loud
    and swells up during quiet moments. This keeps delays from
    cluttering the mix during busy passages while still providing
    ambience in gaps. Used by guitar players who want long delay
    tails that never step on their playing. Think David Gilmour,
    Andy Summers.

    Params:
        time:     Delay time (50–800 ms)
        feedback: Repeat amount (0–0.9)
        duck:     Ducking sensitivity (0 = no ducking, 1 = heavy)
        release:  How fast delays come back (50–1000 ms)
        mix:      Maximum wet level (0–1)
    """
    global _delays, _envelope

    delay_ms = params["time"]
    feedback = params["feedback"]
    duck = params["duck"]
    release_ms = params["release"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _delays is None:
        _delays = [DelayLine(MAX_DELAY) for _ in range(n_ch)]

    delay_samples = max(1.0, delay_ms * 0.001 * sample_rate)
    attack_coeff = smooth_coeff(1.0, sample_rate)  # fast attack
    release_coeff = smooth_coeff(release_ms, sample_rate)

    for i in range(frame_count):
        # Peak detect across channels
        peak = 0.0
        for ch in range(n_ch):
            peak = max(peak, abs(inputs[ch][i]))

        # Envelope follower
        if peak > _envelope:
            _envelope = attack_coeff * _envelope + (1.0 - attack_coeff) * peak
        else:
            _envelope = release_coeff * _envelope + (1.0 - release_coeff) * peak

        # Duck factor: higher envelope = lower wet level
        duck_gain = max(0.0, 1.0 - _envelope * duck * 10.0)

        for ch in range(n_ch):
            delayed = _delays[ch].read(delay_samples)
            _delays[ch].write(inputs[ch][i] + delayed * feedback)

            outputs[ch][i] = inputs[ch][i] + delayed * wet_mix * duck_gain
