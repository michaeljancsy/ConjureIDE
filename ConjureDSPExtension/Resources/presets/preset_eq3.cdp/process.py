from conjuredsp.filters import Biquad, BiquadCoeffs
from conjuredsp import db, toggle

PARAMS = {
    "low_gain":    db(min=-12, max=12, default=0),
    "mid_gain":    db(min=-12, max=12, default=0),
    "high_gain":   db(min=-12, max=12, default=0),
    "low_bypass":  toggle(),
    "mid_bypass":  toggle(),
    "high_bypass": toggle(),
}

# Fixed crossover points (non-parametric)
LOW_FREQ = 200.0
MID_FREQ = 1000.0
HIGH_FREQ = 5000.0
Q = 0.707

# Persistent filter state: [low, mid, high] per channel
_filters = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    3-Band EQ — non-parametric equalizer with low shelf, mid peak, and high shelf.

    Fixed crossover frequencies at 200 Hz, 1 kHz, and 5 kHz. Each band has
    a gain control (+/-12 dB) and a bypass toggle. Three biquad filters in
    series shape the tone without requiring frequency knob adjustments.

    Params:
        low_gain:    Low shelf gain (-12 to +12 dB)
        mid_gain:    Mid peak gain (-12 to +12 dB)
        high_gain:   High shelf gain (-12 to +12 dB)
        low_bypass:  Bypass low band (0 = active, 1 = bypass)
        mid_bypass:  Bypass mid band (0 = active, 1 = bypass)
        high_bypass: Bypass high band (0 = active, 1 = bypass)
    """
    global _filters

    n_ch = len(inputs)

    if _filters is None or len(_filters) != n_ch:
        _filters = [[Biquad(), Biquad(), Biquad()] for _ in range(n_ch)]

    low_gain = params["low_gain"]
    mid_gain = params["mid_gain"]
    high_gain = params["high_gain"]
    low_bypass = params["low_bypass"] > 0.5
    mid_bypass = params["mid_bypass"] > 0.5
    high_bypass = params["high_bypass"] > 0.5

    # Compute coefficients once per buffer
    low_coeffs = BiquadCoeffs.lowshelf(LOW_FREQ, Q, low_gain, sample_rate)
    mid_coeffs = BiquadCoeffs.peak(MID_FREQ, Q, mid_gain, sample_rate)
    high_coeffs = BiquadCoeffs.highshelf(HIGH_FREQ, Q, high_gain, sample_rate)

    for ch in range(n_ch):
        _filters[ch][0].set_coeffs(low_coeffs)
        _filters[ch][1].set_coeffs(mid_coeffs)
        _filters[ch][2].set_coeffs(high_coeffs)

        for i in range(frame_count):
            x = float(inputs[ch][i])

            if not low_bypass:
                x = _filters[ch][0].process_sample(x)
            else:
                _filters[ch][0].process_sample(x)

            if not mid_bypass:
                x = _filters[ch][1].process_sample(x)
            else:
                _filters[ch][1].process_sample(x)

            if not high_bypass:
                x = _filters[ch][2].process_sample(x)
            else:
                _filters[ch][2].process_sample(x)

            outputs[ch][i] = x
