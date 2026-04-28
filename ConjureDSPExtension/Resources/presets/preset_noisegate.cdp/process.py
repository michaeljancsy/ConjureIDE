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


def process(inputs, outputs, frame_count, sample_rate, params, _transport, _telemetry):
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

    threshold = db_to_gain(threshold_db)
    attack_coeff = smooth_coeff(attack_ms, sample_rate)
    release_coeff = smooth_coeff(release_ms, sample_rate)
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
