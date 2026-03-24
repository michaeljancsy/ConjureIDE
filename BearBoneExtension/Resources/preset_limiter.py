import numpy as np
import math

PARAMS = {
    "threshold": {"min": -20.0, "max": 0.0,   "unit": "dB", "default": -6.0},
    "attack":    {"min": 0.01,  "max": 1.0,   "unit": "ms", "default": 0.1},
    "release":   {"min": 10.0,  "max": 500.0, "unit": "ms", "default": 100.0},
}

# Persistent envelope follower state
_envelope = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
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

    threshold_db = params["threshold"]
    attack_ms = params["attack"]
    release_ms = params["release"]

    threshold = 10.0 ** (threshold_db / 20.0)
    attack_coeff = math.exp(-1.0 / (attack_ms * 0.001 * sample_rate))
    release_coeff = math.exp(-1.0 / (release_ms * 0.001 * sample_rate))

    gain = np.ones(frame_count, dtype=np.float32)
    env = _envelope

    for i in range(frame_count):
        # Peak detect across all channels
        peak = 0.0
        for ch in range(len(inputs)):
            peak = max(peak, abs(inputs[ch][i]))

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

    for ch in range(len(inputs)):
        outputs[ch][:frame_count] = inputs[ch][:frame_count] * gain
