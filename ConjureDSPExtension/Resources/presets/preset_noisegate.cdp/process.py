import numpy as np
from conjuredsp.params import db, time_ms
from conjuredsp.dsp import db_to_gain, smooth_coeff

PARAMS = {
    "threshold": db(-80, -20, default=-40),
    "attack":    time_ms(min=0.1, max=10, default=1),
    "release":   time_ms(min=10, max=500, default=100),
    "hold":      time_ms(min=0.1, max=100, default=20),
}

# Persistent state
_envelope = 0.0
_hold_counter = 0


def process(ctx):
    """
    Noise Gate — silences signal below a threshold.

    Monitors the peak level across all channels. When the level drops
    below the threshold, the gate closes (attenuates to silence) after
    a hold period. Attack and release control how quickly the gate
    opens and closes. The hold time prevents the gate from chattering
    on signals that hover near the threshold.

    Params:
        threshold: Gate threshold (-80 to -20 dB)
        attack:    Gate open speed (0.1–10 ms)
        release:   Gate close speed (10–500 ms)
        hold:      Hold time (0–100 ms)
    """
    global _envelope, _hold_counter

    threshold_db = ctx.params["threshold"]
    attack_ms = ctx.params["attack"]
    release_ms = ctx.params["release"]
    hold_ms = ctx.params["hold"]

    threshold = db_to_gain(threshold_db)
    attack_coeff = smooth_coeff(attack_ms, ctx.sample_rate)
    release_coeff = smooth_coeff(release_ms, ctx.sample_rate)
    hold_samples = int(hold_ms * 0.001 * ctx.sample_rate)

    n_ch, frame_count = ctx.inputs.shape

    # Vectorized per-sample max-abs across channels; one numpy call replaces
    # the inner `for ch in range(n_ch): peak = max(peak, abs(ctx.inputs[ch][i]))`,
    # which on the 2D ctx.inputs allocates a row view every fetch.
    peak_per_sample = np.abs(ctx.inputs).max(axis=0)

    gain = np.ones(frame_count, dtype=np.float32)
    env = _envelope
    hold = _hold_counter

    for i in range(frame_count):
        peak = peak_per_sample[i]

        if peak > threshold:
            # Gate open: envelope approaches 1.0
            env = attack_coeff * env + (1.0 - attack_coeff) * 1.0
            hold = hold_samples
        else:
            if hold > 0:
                # Hold: maintain current envelope
                hold -= 1
            else:
                # Release: envelope approaches 0.0
                env = release_coeff * env

        gain[i] = env

    _envelope = env
    _hold_counter = hold

    for ch in range(n_ch):
        ctx.outputs[ch] = ctx.inputs[ch] * gain
