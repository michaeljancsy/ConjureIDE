import numpy as np
import math

# Limiter parameters
THRESHOLD_DB = -3.0    # Ceiling level in dB
ATTACK_MS = 0.1        # Ultra-fast attack
RELEASE_MS = 100.0     # Release time in ms

# Persistent envelope follower state
_envelope = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Limiter — brick-wall peak limiter.

    Prevents the signal from exceeding the threshold using a fast-attack
    envelope follower. When the peak level exceeds the threshold, gain
    is reduced so the output stays at the threshold. The ultra-fast attack
    (0.1 ms) catches transients; the slower release allows natural decay.
    Unlike a compressor, the ratio is effectively infinite — nothing
    passes above the ceiling.

    Args:
        inputs:      list of numpy.float32 arrays, one per channel
        outputs:     list of numpy.float32 arrays, one per channel
        frame_count: number of valid samples this callback
        sample_rate: current sample rate in Hz
        params:      list of 8 floats (0.0–1.0), DAW-automatable parameters (unused)
    """
    global _envelope

    threshold = 10.0 ** (THRESHOLD_DB / 20.0)
    attack_coeff = math.exp(-1.0 / (ATTACK_MS * 0.001 * sample_rate))
    release_coeff = math.exp(-1.0 / (RELEASE_MS * 0.001 * sample_rate))

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
