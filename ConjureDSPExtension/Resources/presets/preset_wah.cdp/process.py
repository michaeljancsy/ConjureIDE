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


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Auto-Wah — envelope-controlled bandpass filter.

    An envelope follower tracks the input level and sweeps a resonant
    bandpass filter across a frequency range. Louder playing pushes the
    filter higher; quiet passages bring it back down. The result is the
    classic funk/synth wah effect driven by playing dynamics.

    Params:
        sensitivity: Input gain for envelope detection (-40 to 0 dB)
        depth:       Frequency sweep range (0–100%)
        min_freq:    Lowest filter frequency (200–800 Hz)
        max_freq:    Highest filter frequency (1000–8000 Hz)
        q:           Filter resonance (0.5–10)
        attack:      Envelope attack time (0.5–50 ms)
        release:     Envelope release time (10–500 ms)
    """
    global _filters, _envelope

    n_ch = len(inputs)

    if _filters is None or len(_filters) != n_ch:
        _filters = [Biquad() for _ in range(n_ch)]

    sensitivity_gain = db_to_gain(params["sensitivity"])
    depth = params["depth"] / 100.0
    min_freq = params["min_freq"]
    max_freq = params["max_freq"]
    q = params["q"]
    attack_ms = params["attack"]
    release_ms = params["release"]

    attack_coeff = smooth_coeff(attack_ms, sample_rate)
    release_coeff = smooth_coeff(release_ms, sample_rate)

    freq_range = max_freq - min_freq
    env = _envelope

    for i in range(frame_count):
        # Peak detect across channels with sensitivity scaling
        peak = 0.0
        for ch in range(n_ch):
            peak = max(peak, abs(float(inputs[ch][i])) * sensitivity_gain)

        # Envelope follower
        if peak > env:
            env = attack_coeff * env + (1.0 - attack_coeff) * peak
        else:
            env = release_coeff * env + (1.0 - release_coeff) * peak

        # Map envelope to filter frequency
        env_clamped = min(max(env, 0.0), 1.0)
        wah_freq = min_freq + depth * freq_range * env_clamped

        # Compute bandpass coefficients per sample
        coeffs = BiquadCoeffs.bandpass(wah_freq, q, sample_rate)

        for ch in range(n_ch):
            _filters[ch].set_coeffs(coeffs)
            outputs[ch][i] = _filters[ch].process_sample(float(inputs[ch][i]))

    _envelope = env
