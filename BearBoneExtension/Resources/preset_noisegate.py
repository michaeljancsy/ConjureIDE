import numpy as np
import math

# Script-declared parameter names (shown in UI, used in exported AUs)
PARAM_NAMES = {0: "Threshold", 1: "Attack", 2: "Release", 3: "Hold"}

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

    Params:
        0 (Threshold): Gate threshold — 0.0 = -80 dB, 1.0 = -20 dB
        1 (Attack):    Gate open speed — 0.0 = 0.1 ms, 1.0 = 10 ms
        2 (Release):   Gate close speed — 0.0 = 10 ms, 1.0 = 500 ms
        3 (Hold):      Hold time — 0.0 = 0 ms, 1.0 = 100 ms
    """
    global _envelope, _hold_counter

    threshold_db = -80.0 + params[0] * 60.0    # -80 to -20 dB
    attack_ms = 0.1 + params[1] * 9.9          # 0.1 to 10 ms
    release_ms = 10.0 + params[2] * 490.0      # 10 to 500 ms
    hold_ms = params[3] * 100.0                # 0 to 100 ms

    threshold = 10.0 ** (threshold_db / 20.0)
    attack_coeff = math.exp(-1.0 / (attack_ms * 0.001 * sample_rate))
    release_coeff = math.exp(-1.0 / (release_ms * 0.001 * sample_rate))
    hold_samples = int(hold_ms * 0.001 * sample_rate)

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
