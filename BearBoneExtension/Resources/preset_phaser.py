import numpy as np
import math

# Script-declared parameter names (shown in UI, used in exported AUs)
PARAM_NAMES = {0: "Rate", 1: "Min Freq", 2: "Max Freq", 3: "Stages", 4: "Mix"}

# Maximum number of allpass stages
MAX_STAGES = 6

# Persistent state per channel per stage: [x_prev, y_prev]
_ap_state = [[[0.0, 0.0] for _ in range(MAX_STAGES)] for _ in range(2)]
_lfo_phase = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Phaser — cascaded allpass filters with LFO-swept frequency.

    Passes the signal through a cascade of first-order allpass filters
    whose cutoff frequency is swept by an LFO. The allpass filters shift
    the phase of different frequencies by different amounts, and when
    mixed with the dry signal, creates notches that sweep up and down
    the spectrum. The number of stages determines how many notches appear.

    Params:
        0 (Rate):     LFO rate — 0.0 = 0.1 Hz, 1.0 = 5 Hz
        1 (Min Freq): Minimum allpass freq — 0.0 = 50 Hz, 1.0 = 500 Hz
        2 (Max Freq): Maximum allpass freq — 0.0 = 500 Hz, 1.0 = 10000 Hz
        3 (Stages):   Number of allpass stages — 2 to 6 (discrete)
        4 (Mix):      Wet/dry mix — 0.0 = dry, 1.0 = wet
    """
    global _ap_state, _lfo_phase

    rate_hz = 0.1 + params[0] * 4.9          # 0.1 to 5 Hz
    min_freq = 50.0 + params[1] * 450.0      # 50 to 500 Hz
    max_freq = 500.0 + params[2] * 9500.0    # 500 to 10000 Hz
    stages = int(params[3] * 4) + 2          # 2 to 6
    mix = params[4]                           # 0 to 1

    n_ch = len(inputs)
    two_pi = 2.0 * math.pi
    lfo_inc = two_pi * rate_hz / sample_rate
    phase = _lfo_phase

    for i in range(frame_count):
        # LFO sweeps the allpass frequency between min_freq and max_freq
        lfo = 0.5 * (1.0 + math.sin(phase))
        freq = min_freq + (max_freq - min_freq) * lfo

        # Compute allpass coefficient
        tan_val = math.tan(math.pi * freq / sample_rate)
        a = (tan_val - 1.0) / (tan_val + 1.0)

        for ch in range(n_ch):
            x = inputs[ch][i]
            # Pass through allpass cascade
            signal = x
            for s in range(stages):
                x_prev = _ap_state[ch][s][0]
                y_prev = _ap_state[ch][s][1]
                y = a * signal + x_prev - a * y_prev
                _ap_state[ch][s][0] = signal
                _ap_state[ch][s][1] = y
                signal = y

            # Mix dry + wet
            outputs[ch][i] = x * (1.0 - mix) + signal * mix

        phase += lfo_inc

    _lfo_phase = phase % two_pi
