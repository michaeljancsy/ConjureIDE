import numpy as np
import math

# Phaser parameters
RATE_HZ = 0.4        # LFO speed in Hz
MIN_FREQ = 200.0     # Minimum allpass frequency in Hz
MAX_FREQ = 2000.0    # Maximum allpass frequency in Hz
STAGES = 4           # Number of allpass stages
MIX = 0.5            # Wet/dry mix

# Persistent state per channel per stage: [x_prev, y_prev]
_ap_state = [[[0.0, 0.0] for _ in range(STAGES)] for _ in range(2)]
_lfo_phase = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Phaser — cascaded allpass filters with LFO-swept frequency.

    Passes the signal through a cascade of first-order allpass filters
    whose cutoff frequency is swept by an LFO. The allpass filters shift
    the phase of different frequencies by different amounts, and when
    mixed with the dry signal, creates notches that sweep up and down
    the spectrum. The number of stages determines how many notches appear.

    Args:
        inputs:      list of numpy.float32 arrays, one per channel
        outputs:     list of numpy.float32 arrays, one per channel
        frame_count: number of valid samples this callback
        sample_rate: current sample rate in Hz
        params:      list of 8 floats (0.0–1.0), DAW-automatable parameters (unused)
    """
    global _ap_state, _lfo_phase

    n_ch = len(inputs)
    two_pi = 2.0 * math.pi
    lfo_inc = two_pi * RATE_HZ / sample_rate
    phase = _lfo_phase

    for i in range(frame_count):
        # LFO sweeps the allpass frequency between MIN_FREQ and MAX_FREQ
        lfo = 0.5 * (1.0 + math.sin(phase))
        freq = MIN_FREQ + (MAX_FREQ - MIN_FREQ) * lfo

        # Compute allpass coefficient
        tan_val = math.tan(math.pi * freq / sample_rate)
        a = (tan_val - 1.0) / (tan_val + 1.0)

        for ch in range(n_ch):
            x = inputs[ch][i]
            # Pass through allpass cascade
            signal = x
            for s in range(STAGES):
                x_prev = _ap_state[ch][s][0]
                y_prev = _ap_state[ch][s][1]
                y = a * signal + x_prev - a * y_prev
                _ap_state[ch][s][0] = signal
                _ap_state[ch][s][1] = y
                signal = y

            # Mix dry + wet
            outputs[ch][i] = x * (1.0 - MIX) + signal * MIX

        phase += lfo_inc

    _lfo_phase = phase % two_pi
