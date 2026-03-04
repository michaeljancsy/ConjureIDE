import numpy as np
import math

# Flanger parameters
RATE_HZ = 0.3        # LFO speed in Hz
DEPTH_MS = 2.0       # LFO modulation depth in ms
BASE_DELAY_MS = 2.0  # Base delay time in ms
FEEDBACK = 0.7       # Feedback amount (-1.0 to 1.0)
MIX = 0.5            # Wet/dry mix

# Max delay in samples (supports up to 96 kHz)
MAX_DELAY = 1024

# Persistent state
_delay_buf = None
_write_pos = 0
_lfo_phase = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Flanger — short modulated delay with feedback.

    Similar to chorus but with a much shorter delay (0–4 ms) and feedback.
    The short delay creates comb-filter effects, and the LFO sweeps the
    comb filter notches up and down, producing the characteristic flanging
    jet-plane sweep. Higher feedback intensifies the comb-filter peaks.

    Args:
        inputs:      list of numpy.float32 arrays, one per channel
        outputs:     list of numpy.float32 arrays, one per channel
        frame_count: number of valid samples this callback
        sample_rate: current sample rate in Hz
        params:      list of 8 floats (0.0–1.0), DAW-automatable parameters (unused)
    """
    global _delay_buf, _write_pos, _lfo_phase

    n_ch = len(inputs)

    if _delay_buf is None or len(_delay_buf) != n_ch:
        _delay_buf = [np.zeros(MAX_DELAY, dtype=np.float32) for _ in range(n_ch)]

    two_pi = 2.0 * math.pi
    lfo_inc = two_pi * RATE_HZ / sample_rate
    phase = _lfo_phase
    wp = _write_pos

    for i in range(frame_count):
        delay_samples = (BASE_DELAY_MS + DEPTH_MS * math.sin(phase)) * sample_rate / 1000.0

        for ch in range(n_ch):
            # Read with linear interpolation
            read_pos = wp - delay_samples
            if read_pos < 0.0:
                read_pos += MAX_DELAY
            idx0 = int(read_pos) % MAX_DELAY
            idx1 = (idx0 + 1) % MAX_DELAY
            frac = read_pos - int(read_pos)
            delayed = _delay_buf[ch][idx0] * (1.0 - frac) + _delay_buf[ch][idx1] * frac

            # Write input + feedback to delay line
            _delay_buf[ch][wp] = inputs[ch][i] + delayed * FEEDBACK

            # Mix dry + wet
            outputs[ch][i] = inputs[ch][i] * (1.0 - MIX) + delayed * MIX

        phase += lfo_inc
        wp = (wp + 1) % MAX_DELAY

    _lfo_phase = phase % two_pi
    _write_pos = wp
