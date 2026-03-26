from conjuredsp.filters import Biquad, BiquadCoeffs
from conjuredsp import freq, db, param, time_ms
from conjuredsp.dsp import db_to_gain, smooth_coeff, gain_to_db

PARAMS = {
    "frequency": freq(min=2000, max=12000, default=6000),
    "q":         param(0.5, 5, default=1.5),
    "threshold": db(min=-40, max=0, default=-20),
    "reduction": db(min=-20, max=0, default=-6),
    "attack":    time_ms(min=0.1, max=10, default=1),
    "release":   time_ms(min=10, max=200, default=50),
}

# Persistent state
_sc_filters = None
_envelope = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    De-esser — sibilance reduction via sidechain compression.

    A bandpass filter isolates sibilant frequencies from the input signal.
    An envelope follower tracks the level of the isolated band. When it
    exceeds the threshold, gain reduction is applied to the full-band
    original signal, taming harshness without affecting the overall tone.

    Params:
        frequency: Sibilance center frequency (2000–12000 Hz)
        q:         Sidechain bandpass Q (0.5–5)
        threshold: Detection threshold (-40 to 0 dB)
        reduction: Maximum gain reduction (-20 to 0 dB)
        attack:    Envelope attack time (0.1–10 ms)
        release:   Envelope release time (10–200 ms)
    """
    global _sc_filters, _envelope

    n_ch = len(inputs)

    if _sc_filters is None or len(_sc_filters) != n_ch:
        _sc_filters = [Biquad() for _ in range(n_ch)]

    center_freq = params["frequency"]
    q = params["q"]
    threshold_db = params["threshold"]
    reduction_db = params["reduction"]
    attack_ms = params["attack"]
    release_ms = params["release"]

    threshold_lin = db_to_gain(threshold_db)
    attack_coeff = smooth_coeff(attack_ms, sample_rate)
    release_coeff = smooth_coeff(release_ms, sample_rate)

    # Compute bandpass coefficients once per buffer
    bp_coeffs = BiquadCoeffs.bandpass(center_freq, q, sample_rate)
    for ch in range(n_ch):
        _sc_filters[ch].set_coeffs(bp_coeffs)

    env = _envelope

    for i in range(frame_count):
        # Sidechain: bandpass filter then peak detect across channels
        sc_peak = 0.0
        for ch in range(n_ch):
            sc_sample = _sc_filters[ch].process_sample(float(inputs[ch][i]))
            sc_peak = max(sc_peak, abs(sc_sample))

        # Envelope follower
        if sc_peak > env:
            env = attack_coeff * env + (1.0 - attack_coeff) * sc_peak
        else:
            env = release_coeff * env + (1.0 - release_coeff) * sc_peak

        # Gain computation
        if env > threshold_lin:
            over_db = gain_to_db(env) - gain_to_db(threshold_lin)
            over_ratio = min(over_db / 6.0, 1.0)
            if over_ratio < 0.0:
                over_ratio = 0.0
            gain = db_to_gain(reduction_db * over_ratio)
        else:
            gain = 1.0

        for ch in range(n_ch):
            outputs[ch][i] = inputs[ch][i] * gain

    _envelope = env
