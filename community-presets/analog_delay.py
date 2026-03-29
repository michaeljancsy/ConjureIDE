import numpy as np
import math
from conjuredsp.params import param, time_ms, mix
from conjuredsp.buffers import DelayLine
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "time":     time_ms(min=20, max=600, default=300),
    "feedback": param(0, 0.95, default=0.5),
    "color":    param(0, 1, default=0.6),
    "mix":      mix(default=0.5),
}

MAX_DELAY = 64000
_delays = None
_lp = None
_hp = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Analog Delay — bucket brigade device (BBD) emulation.

    Models the warm, dark character of analog delay chips like the
    MN3005 and MN3207. Each repeat passes through bandpass filtering
    that rolls off both highs and lows, and subtle soft clipping adds
    compression to the repeats. The result is delays that sit warmly
    in a mix without harsh digital clarity. The sound of vintage
    Boss DM-2, Electro-Harmonix Memory Man, and MXR Carbon Copy.

    Params:
        time:     Delay time (20–600 ms)
        feedback: Repeat amount (0–0.95)
        color:    Repeat darkness (0 = bright, 1 = very dark)
        mix:      Wet/dry blend
    """
    global _delays, _lp, _hp

    delay_ms = params["time"]
    feedback = params["feedback"]
    color = params["color"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _delays is None:
        _delays = [DelayLine(MAX_DELAY) for _ in range(n_ch)]
        _lp = [Biquad() for _ in range(n_ch)]
        _hp = [Biquad() for _ in range(n_ch)]

    # BBD bandwidth: limited on both ends
    lp_freq = 6000.0 - color * 4500.0
    hp_freq = 100.0 + color * 200.0

    delay_samples = max(1.0, delay_ms * 0.001 * sample_rate)

    for ch in range(n_ch):
        _lp[ch].set_coeffs(BiquadCoeffs.lowpass(lp_freq, 0.7, sample_rate))
        _hp[ch].set_coeffs(BiquadCoeffs.highpass(hp_freq, 0.7, sample_rate))

        for i in range(frame_count):
            delayed = _delays[ch].read(delay_samples)

            # BBD coloring: bandpass + soft saturation
            delayed = _lp[ch].process_sample(delayed)
            delayed = _hp[ch].process_sample(delayed)
            delayed = math.tanh(delayed * 1.1)  # subtle compression

            _delays[ch].write(inputs[ch][i] + delayed * feedback)

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + delayed * wet_mix
