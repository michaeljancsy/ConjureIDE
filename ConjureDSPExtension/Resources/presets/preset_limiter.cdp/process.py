import numpy as np
from conjuredsp.params import db, time_ms
from conjuredsp.dsp import db_to_gain, smooth_coeff

PARAMS = {
    "threshold": db(-20, 0, default=-6),
    "attack":    time_ms(min=0.01, max=1, default=0.1),
    "release":   time_ms(min=10, max=500, default=100),
}

# Persistent envelope follower state
_envelope = 0.0


def process(ctx):
    """
    Limiter — brick-wall peak limiter.

    Prevents the signal from exceeding the threshold using a fast-attack
    envelope follower. When the peak level exceeds the threshold, gain
    is reduced so the output stays at the threshold. The ultra-fast attack
    catches transients; the slower release allows natural decay.
    Unlike a compressor, the ratio is effectively infinite — nothing
    passes above the ceiling.

    Params:
        threshold: Ceiling level (-20 to 0 dB)
        attack:    Attack time (0.01–1 ms)
        release:   Release time (10–500 ms)
    """
    global _envelope

    threshold_db = ctx.params["threshold"]
    attack_ms = ctx.params["attack"]
    release_ms = ctx.params["release"]

    threshold = db_to_gain(threshold_db)
    attack_coeff = smooth_coeff(attack_ms, ctx.sample_rate)
    release_coeff = smooth_coeff(release_ms, ctx.sample_rate)

    gain = np.ones(ctx.frame_count, dtype=np.float32)
    env = _envelope

    for i in range(ctx.frame_count):
        # Peak detect across all channels
        peak = 0.0
        for ch in range(len(ctx.inputs)):
            peak = max(peak, abs(ctx.inputs[ch][i]))

        # Envelope follower
        if peak > env:
            env = attack_coeff * env + (1.0 - attack_coeff) * peak
        else:
            env = release_coeff * env + (1.0 - release_coeff) * peak

        # Gain reduction: clamp output to threshold
        if env > threshold:
            gain[i] = threshold / env
        else:
            gain[i] = 1.0

    _envelope = env

    for ch in range(len(ctx.inputs)):
        ctx.outputs[ch][:ctx.frame_count] = ctx.inputs[ch][:ctx.frame_count] * gain
