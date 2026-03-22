import numpy as np
import math

# Script-declared parameter names (shown in UI, used in exported AUs)
PARAM_NAMES = {0: "Rate", 1: "Depth", 2: "Delay", 3: "Mix"}

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

    Params:
        0 (Rate):  LFO rate — 0.0 = 0.1 Hz, 1.0 = 2 Hz
        1 (Depth): LFO depth — 0.0 = 0.5 ms, 1.0 = 15 ms
        2 (Delay): Base delay — 0.0 = 2 ms, 1.0 = 30 ms
        3 (Mix):   Wet/dry mix — 0.0 = dry, 1.0 = wet
    """
    global _delay_buf, _write_pos, _lfo_phase

    rate_hz = 0.1 + params[0] * 1.9        # 0.1 to 2 Hz
    depth_ms = 0.5 + params[1] * 14.5      # 0.5 to 15 ms
    base_delay_ms = 2.0 + params[2] * 28.0 # 2 to 30 ms
    mix = params[3]                         # 0 to 1

    n_ch = len(inputs)

    # Initialize delay buffer on first call
    if _delay_buf is None or len(_delay_buf) != n_ch:
        _delay_buf = [np.zeros(MAX_DELAY, dtype=np.float32) for _ in range(n_ch)]

    two_pi = 2.0 * math.pi
    lfo_inc = two_pi * rate_hz / sample_rate
    phase = _lfo_phase
    wp = _write_pos

    for i in range(frame_count):
        # LFO modulates delay time
        delay_samples = (base_delay_ms + depth_ms * math.sin(phase)) * sample_rate / 1000.0

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
            outputs[ch][i] = inputs[ch][i] * (1.0 - mix) + delayed * mix

        phase += lfo_inc
        wp = (wp + 1) % MAX_DELAY

    _lfo_phase = phase % two_pi
    _write_pos = wp
