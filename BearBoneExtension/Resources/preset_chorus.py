import numpy as np
import math

# Chorus parameters
RATE_HZ = 0.5        # LFO speed in Hz
DEPTH_MS = 3.0       # LFO modulation depth in ms
BASE_DELAY_MS = 7.0  # Base delay time in ms
MIX = 0.5            # Wet/dry mix (0.0 = dry, 1.0 = wet)

# Max delay in samples (supports up to 96 kHz)
MAX_DELAY = 2048

# Persistent state
_delay_buf = None
_write_pos = 0
_lfo_phase = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Chorus — modulated delay for thickening.

    Uses a short delay line with an LFO-modulated read position to create
    a detuned copy of the signal. The modulated copy is mixed with the dry
    signal, producing a rich, thickened sound. Linear interpolation is used
    for sub-sample delay accuracy.

    Args:
        inputs:      list of numpy.float32 arrays, one per channel
        outputs:     list of numpy.float32 arrays, one per channel
        frame_count: number of valid samples this callback
        sample_rate: current sample rate in Hz
        params:      list of 8 floats (0.0–1.0), DAW-automatable parameters (unused)
    """
    global _delay_buf, _write_pos, _lfo_phase

    n_ch = len(inputs)

    # Initialize delay buffer on first call
    if _delay_buf is None or len(_delay_buf) != n_ch:
        _delay_buf = [np.zeros(MAX_DELAY, dtype=np.float32) for _ in range(n_ch)]

    two_pi = 2.0 * math.pi
    lfo_inc = two_pi * RATE_HZ / sample_rate
    phase = _lfo_phase
    wp = _write_pos

    for i in range(frame_count):
        # LFO modulates delay time
        delay_samples = (BASE_DELAY_MS + DEPTH_MS * math.sin(phase)) * sample_rate / 1000.0

        for ch in range(n_ch):
            # Write input to delay line
            _delay_buf[ch][wp] = inputs[ch][i]

            # Read with linear interpolation
            read_pos = wp - delay_samples
            if read_pos < 0.0:
                read_pos += MAX_DELAY
            idx = int(read_pos)
            frac = read_pos - idx
            idx0 = idx % MAX_DELAY
            idx1 = (idx + 1) % MAX_DELAY
            delayed = _delay_buf[ch][idx0] * (1.0 - frac) + _delay_buf[ch][idx1] * frac

            # Mix dry + wet
            outputs[ch][i] = inputs[ch][i] * (1.0 - MIX) + delayed * MIX

        phase += lfo_inc
        wp = (wp + 1) % MAX_DELAY

    _lfo_phase = phase % two_pi
    _write_pos = wp
