import numpy as np
import math

PARAMS = {
    "threshold": {"min": -80.0, "max": -20.0, "unit": "dB", "default": -40.0},
    "attack":    {"min": 0.1,   "max": 10.0,  "unit": "ms", "default": 1.0},
    "release":   {"min": 10.0,  "max": 500.0, "unit": "ms", "default": 100.0},
    "hold":      {"min": 0.0,   "max": 100.0, "unit": "ms", "default": 20.0},
}

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
        threshold: Gate threshold (-80 to -20 dB)
        attack:    Gate open speed (0.1–10 ms)
        release:   Gate close speed (10–500 ms)
        hold:      Hold time (0–100 ms)
    """
    global _envelope, _hold_counter

    threshold_db = params["threshold"]
    attack_ms = params["attack"]
    release_ms = params["release"]
    hold_ms = params["hold"]

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
