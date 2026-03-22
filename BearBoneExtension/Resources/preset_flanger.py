import numpy as np
import math

# Script-declared parameter names (shown in UI, used in exported AUs)
PARAM_NAMES = {0: "Rate", 1: "Depth", 2: "Delay", 3: "Feedback", 4: "Mix"}

# Max delay in samples (supports up to 96 kHz)
MAX_DELAY = 1024

# Persistent state
_delay_buf = None
_write_pos = 0
_lfo_phase = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Flanger — short modulated delay with feedback.

    Similar to chorus but with a much shorter delay (0-4 ms) and feedback.
    The short delay creates comb-filter effects, and the LFO sweeps the
    comb filter notches up and down, producing the characteristic flanging
    jet-plane sweep. Higher feedback intensifies the comb-filter peaks.

    Params:
        0 (Rate):     LFO rate — 0.0 = 0.1 Hz, 1.0 = 5 Hz
        1 (Depth):    LFO depth — 0.0 = 0.5 ms, 1.0 = 5 ms
        2 (Delay):    Base delay — 0.0 = 1 ms, 1.0 = 5 ms
        3 (Feedback): Feedback amount — 0.0 = none, 1.0 = full
        4 (Mix):      Wet/dry mix — 0.0 = dry, 1.0 = wet
    """
    global _delay_buf, _write_pos, _lfo_phase

    rate_hz = 0.1 + params[0] * 4.9        # 0.1 to 5 Hz
    depth_ms = 0.5 + params[1] * 4.5       # 0.5 to 5 ms
    base_delay_ms = 1.0 + params[2] * 4.0  # 1 to 5 ms
    feedback = params[3]                    # 0 to 1
    mix = params[4]                         # 0 to 1

    n_ch = len(inputs)

    if _delay_buf is None or len(_delay_buf) != n_ch:
        _delay_buf = [np.zeros(MAX_DELAY, dtype=np.float32) for _ in range(n_ch)]

    two_pi = 2.0 * math.pi
    lfo_inc = two_pi * rate_hz / sample_rate
    phase = _lfo_phase
    wp = _write_pos

    for i in range(frame_count):
        delay_samples = (base_delay_ms + depth_ms * math.sin(phase)) * sample_rate / 1000.0

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
            _delay_buf[ch][wp] = inputs[ch][i] + delayed * feedback

            # Mix dry + wet
            outputs[ch][i] = inputs[ch][i] * (1.0 - mix) + delayed * mix

        phase += lfo_inc
        wp = (wp + 1) % MAX_DELAY

    _lfo_phase = phase % two_pi
    _write_pos = wp
