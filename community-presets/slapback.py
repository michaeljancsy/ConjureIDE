import numpy as np
from conjuredsp.params import param, time_ms, mix
from conjuredsp.buffers import DelayLine

PARAMS = {
    "time": time_ms(min=30, max=120, default=75),
    "mix":  mix(default=0.4),
}

MAX_DELAY = 12000
_delays = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Slapback — classic rockabilly/surf single echo.

    A single short echo with no feedback, creating the characteristic
    "slap" heard on 1950s rockabilly vocals and guitar. The effect
    adds depth and energy without the complexity of repeating delays.
    Think Elvis, Eddie Cochran, and Dick Dale. Also commonly used
    on country vocals and garage rock guitars.

    Params:
        time: Echo delay (30–120 ms, sweet spot around 75 ms)
        mix:  Echo level (0–1)
    """
    global _delays

    delay_ms = params["time"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _delays is None:
        _delays = [DelayLine(MAX_DELAY) for _ in range(n_ch)]

    delay_samples = int(delay_ms * 0.001 * sample_rate)
    delay_samples = max(1, min(delay_samples, MAX_DELAY - 1))

    for i in range(frame_count):
        for ch in range(n_ch):
            _delays[ch].write(inputs[ch][i])
            delayed = _delays[ch].tap(delay_samples)
            outputs[ch][i] = inputs[ch][i] + delayed * wet_mix
