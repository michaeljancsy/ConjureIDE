import numpy as np
import math

# Script-declared parameter names (shown in UI, used in exported AUs)
PARAM_NAMES = {0: "Threshold", 1: "Attack", 2: "Release"}

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
        0 (Threshold): Ceiling level — 0.0 = -20 dB, 1.0 = 0 dB
        1 (Attack):    Attack time — 0.0 = 0.01 ms, 1.0 = 1 ms
        2 (Release):   Release time — 0.0 = 10 ms, 1.0 = 500 ms
    """
    global _envelope

    threshold_db = -20.0 + params[0] * 20.0     # -20 to 0 dB
    attack_ms = 0.01 + params[1] * 0.99         # 0.01 to 1 ms
    release_ms = 10.0 + params[2] * 490.0       # 10 to 500 ms

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
