import numpy as np
import math

# Noise gate parameters
THRESHOLD_DB = -40.0  # Gate opens above this level
ATTACK_MS = 0.5       # Gate open speed in ms
RELEASE_MS = 50.0     # Gate close speed in ms
HOLD_MS = 20.0        # Hold time before release starts

# Persistent state
_envelope = 0.0
_hold_counter = 0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Noise Gate — silences signal below a threshold.

    Monitors the peak level across all channels. When the level drops
    below the threshold, the gate closes (attenuates to silence) after
    a hold period. Attack and release control how quickly the gate
    opens and closes. The hold time prevents the gate from chattering
    on signals that hover near the threshold.

    Args:
        inputs:      list of numpy.float32 arrays, one per channel
        outputs:     list of numpy.float32 arrays, one per channel
        frame_count: number of valid samples this callback
        sample_rate: current sample rate in Hz
        params:      list of 8 floats (0.0–1.0), DAW-automatable parameters (unused)
    """
    global _envelope, _hold_counter

    threshold = 10.0 ** (THRESHOLD_DB / 20.0)
    attack_coeff = math.exp(-1.0 / (ATTACK_MS * 0.001 * sample_rate))
    release_coeff = math.exp(-1.0 / (RELEASE_MS * 0.001 * sample_rate))
    hold_samples = int(HOLD_MS * 0.001 * sample_rate)

    gain = np.ones(frame_count, dtype=np.float32)
    env = _envelope
    hold = _hold_counter

    for i in range(frame_count):
        # Peak detect across all channels
        peak = 0.0
        for ch in range(len(inputs)):
            peak = max(peak, abs(inputs[ch][i]))

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

    for ch in range(len(inputs)):
        outputs[ch][:frame_count] = inputs[ch][:frame_count] * gain
