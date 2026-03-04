import numpy as np
import math

# Delay parameters
DELAY_MS = 250.0   # Delay time in ms
FEEDBACK = 0.5     # Feedback amount (0.0–0.95)
MIX = 0.5          # Wet/dry mix

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

    Args:
        inputs:      list of numpy.float32 arrays, one per channel
        outputs:     list of numpy.float32 arrays, one per channel
        frame_count: number of valid samples this callback
        sample_rate: current sample rate in Hz
        params:      list of 8 floats (0.0–1.0), DAW-automatable parameters (unused)
    """
    global _delay_buf, _write_pos

    n_ch = len(inputs)

    if _delay_buf is None or len(_delay_buf) != n_ch:
        _delay_buf = [np.zeros(MAX_DELAY, dtype=np.float32) for _ in range(n_ch)]

    delay_samples = int(DELAY_MS * 0.001 * sample_rate)
    if delay_samples >= MAX_DELAY:
        delay_samples = MAX_DELAY - 1

    wp = _write_pos

    for i in range(frame_count):
        rp = (wp - delay_samples + MAX_DELAY) % MAX_DELAY

        for ch in range(n_ch):
            delayed = _delay_buf[ch][rp]

            # Write input + feedback to delay line
            _delay_buf[ch][wp] = inputs[ch][i] + delayed * FEEDBACK

            # Mix dry + wet
            outputs[ch][i] = inputs[ch][i] * (1.0 - MIX) + delayed * MIX

        wp = (wp + 1) % MAX_DELAY

    _write_pos = wp
