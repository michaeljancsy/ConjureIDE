import numpy as np
import math
from conjuredsp.params import param, mix
from conjuredsp.buffers import DelayLine

PARAMS = {
    "cents": param(1, 50, unit="ct", default=10),
    "mix":   mix(default=0.5),
}

MAX_DELAY = 4096
_delays = None
_phase = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Detune — subtle pitch detuning for stereo width.

    Creates a slightly detuned copy of the signal using a slowly
    modulated delay line, then pans original and detuned signals
    for stereo width. Even small amounts (5-15 cents) create a
    lush, wide sound. A studio staple for vocals, synths, and
    guitars — the "instant wide" button. Similar to the Eventide
    H3000's micropitch effect.

    Params:
        cents: Detuning amount in cents (1–50)
        mix:   Detuned signal level (0–1)
    """
    global _delays, _phase

    cents = params["cents"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _delays is None:
        _delays = [DelayLine(MAX_DELAY) for _ in range(n_ch)]

    # Convert cents to pitch ratio, then to modulation rate
    # Detune by slowly varying delay time
    mod_rate = cents * 0.01  # slow rate proportional to cents
    mod_depth = cents * 0.5  # depth in samples

    two_pi = 2.0 * math.pi
    base_delay = 100.0

    for i in range(frame_count):
        mod = math.sin(two_pi * _phase) * mod_depth
        delay = base_delay + mod

        for ch in range(n_ch):
            _delays[ch].write(inputs[ch][i])
            detuned = _delays[ch].read_cubic(max(1.0, delay))

            if n_ch >= 2:
                # Stereo: original panned left, detuned panned right
                if ch == 0:
                    outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix * 0.3) + detuned * wet_mix * 0.3
                else:
                    outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix * 0.7) + detuned * wet_mix * 0.7
            else:
                outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + detuned * wet_mix

        _phase = (_phase + mod_rate / sample_rate) % 1.0
