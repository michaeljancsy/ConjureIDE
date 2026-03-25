import numpy as np
import math

PARAMS = {
    "time":     {"min": 10.0,  "max": 500.0, "unit": "ms", "default": 250.0},
    "feedback": {"min": 0.0,   "max": 0.95,  "unit": "",   "default": 0.4},
    "mix":      {"min": 0.0,   "max": 1.0,   "unit": "",   "default": 0.5},
}

# Max delay in samples (supports 500 ms at 96 kHz)
MAX_DELAY = 48000

# Persistent state
_delay_buf = None
_write_pos = 0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Simple Delay — echo effect with feedback.

    Delays the signal by a fixed time and feeds the delayed output back
    into the delay line. Each repeat is attenuated by the feedback amount,
    creating a decaying echo. The dry/wet mix controls the balance between
    the original signal and the delayed signal.

    Params:
        time:     Delay time (10–500 ms)
        feedback: Feedback amount (0.0–0.95)
        mix:      Wet/dry mix (0.0 = dry, 1.0 = wet)
    """
    global _delay_buf, _write_pos

    delay_ms = params["time"]
    feedback = params["feedback"]
    mix = params["mix"]

    n_ch = len(inputs)

    if _delay_buf is None or len(_delay_buf) != n_ch:
        _delay_buf = [np.zeros(MAX_DELAY, dtype=np.float32) for _ in range(n_ch)]

    delay_samples = int(delay_ms * 0.001 * sample_rate)
    if delay_samples >= MAX_DELAY:
        delay_samples = MAX_DELAY - 1

    wp = _write_pos

    for i in range(frame_count):
        rp = (wp - delay_samples + MAX_DELAY) % MAX_DELAY

        for ch in range(n_ch):
            delayed = _delay_buf[ch][rp]

            # Write input + feedback to delay line
            _delay_buf[ch][wp] = inputs[ch][i] + delayed * feedback

            # Mix dry + wet
            outputs[ch][i] = inputs[ch][i] * (1.0 - mix) + delayed * mix

        wp = (wp + 1) % MAX_DELAY

    _write_pos = wp
