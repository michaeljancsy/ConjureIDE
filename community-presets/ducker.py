import numpy as np
import math
from conjuredsp.params import db, time_ms, param
from conjuredsp.dsp import db_to_gain, smooth_coeff

PARAMS = {
    "threshold": db(-40, -5, default=-25),
    "duck":      db(-30, 0, default=-15),
    "attack":    time_ms(min=1, max=50, default=5),
    "hold":      time_ms(min=10, max=1000, default=200),
    "release":   time_ms(min=50, max=2000, default=500),
}

_envelope = 0.0
_hold_counter = 0
_gate_open = False


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Ducker — auto-ducking for podcasts and voiceover.

    Reduces the music/background level when speech is detected.
    When the input exceeds the threshold (someone is speaking),
    the output is attenuated by the duck amount. When speech stops,
    the level recovers after the hold time. Essential for podcasts,
    YouTube videos, live streams, and broadcasting where music
    needs to duck under dialogue.

    Params:
        threshold: Speech detection level (-40 to -5 dB)
        duck:      Amount of volume reduction (-30 to 0 dB)
        attack:    How fast ducking engages (1–50 ms)
        hold:      How long to stay ducked after speech stops (10–1000 ms)
        release:   Recovery time after hold (50–2000 ms)
    """
    global _envelope, _hold_counter, _gate_open

    threshold = db_to_gain(params["threshold"])
    duck_gain = db_to_gain(params["duck"])
    att = smooth_coeff(params["attack"], sample_rate)
    rel = smooth_coeff(params["release"], sample_rate)
    hold_samples = int(params["hold"] * 0.001 * sample_rate)

    for i in range(frame_count):
        peak = 0.0
        for ch in range(len(inputs)):
            peak = max(peak, abs(inputs[ch][i]))

        # Detect speech (above threshold)
        if peak > threshold:
            _gate_open = True
            _hold_counter = hold_samples

        if _hold_counter > 0:
            _hold_counter -= 1
        else:
            _gate_open = False

        # Smooth gain change
        target = duck_gain if _gate_open else 1.0
        if target < _envelope:
            _envelope = att * _envelope + (1.0 - att) * target
        else:
            _envelope = rel * _envelope + (1.0 - rel) * target

        for ch in range(len(inputs)):
            outputs[ch][i] = inputs[ch][i] * _envelope
