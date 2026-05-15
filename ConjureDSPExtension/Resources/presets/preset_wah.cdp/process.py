import numpy as np
from conjuredsp.filters import Biquad, BiquadCoeffs
from conjuredsp import freq, db, pct, param, time_ms
from conjuredsp.dsp import db_to_gain, smooth_coeff

PARAMS = {
    "sensitivity": db(min=-40, max=0, default=-20),
    "depth":       pct(default=80),
    "min_freq":    freq(min=200, max=800, default=400),
    "max_freq":    freq(min=1000, max=8000, default=3000),
    "q":           param(0.5, 10, default=3),
    "attack":      time_ms(min=0.5, max=50, default=5),
    "release":     time_ms(min=10, max=500, default=50),
}

# Persistent state
_filters = None
_envelope = 0.0


def process(ctx):
    """
    Auto-Wah — envelope-controlled bandpass filter.

    An envelope follower tracks the input level and sweeps a resonant
    bandpass filter across a frequency range. Louder playing pushes the
    filter higher; quiet passages bring it back down. The result is the
    classic funk/synth wah effect driven by playing dynamics.

    Controls:
        sensitivity: Input gain for envelope detection (-40 to 0 dB)
        depth:       Frequency sweep range (0–100%)
        min_freq:    Lowest filter frequency (200–800 Hz)
        max_freq:    Highest filter frequency (1000–8000 Hz)
        q:           Filter resonance (0.5–10)
        attack:      Envelope attack time (0.5–50 ms)
        release:     Envelope release time (10–500 ms)
    """
    global _filters, _envelope

    n_ch, frame_count = ctx.inputs.shape

    if _filters is None or len(_filters) != n_ch:
        _filters = [Biquad() for _ in range(n_ch)]

    sensitivity_gain = db_to_gain(ctx.params["sensitivity"])
    depth = ctx.params["depth"] / 100.0
    min_freq = ctx.params["min_freq"]
    max_freq = ctx.params["max_freq"]
    q = ctx.params["q"]
    attack_ms = ctx.params["attack"]
    release_ms = ctx.params["release"]

    attack_coeff = smooth_coeff(attack_ms, ctx.sample_rate)
    release_coeff = smooth_coeff(release_ms, ctx.sample_rate)

    freq_range = max_freq - min_freq
    env = _envelope

    # Vectorized per-sample max-abs across channels, scaled by sensitivity.
    # Replaces the inner `for ch in range(n_ch): peak = max(peak, abs(...) *
    # sensitivity_gain)` — sensitivity_gain is always positive (db_to_gain
    # on a real number), so scaling outside max is equivalent.
    peak_per_sample = np.abs(ctx.inputs).max(axis=0) * sensitivity_gain

    # Bind row views once per block so the inner filter loop reads/writes
    # a 1D contiguous slice instead of allocating a row view per (sample,
    # channel). Same dcblocker-style pattern; cuts per-sample overhead on
    # the 2D ctx arrays.
    row_ins = [ctx.inputs[ch] for ch in range(n_ch)]
    row_outs = [ctx.outputs[ch] for ch in range(n_ch)]

    for i in range(frame_count):
        peak = peak_per_sample[i]

        # Envelope follower
        if peak > env:
            env = attack_coeff * env + (1.0 - attack_coeff) * peak
        else:
            env = release_coeff * env + (1.0 - release_coeff) * peak

        # Map envelope to filter frequency
        env_clamped = min(max(env, 0.0), 1.0)
        wah_freq = min_freq + depth * freq_range * env_clamped

        # Compute bandpass coefficients per sample
        coeffs = BiquadCoeffs.bandpass(wah_freq, q, ctx.sample_rate)

        for ch in range(n_ch):
            _filters[ch].set_coeffs(coeffs)
            row_outs[ch][i] = _filters[ch].process_sample(float(row_ins[ch][i]))

    _envelope = env
