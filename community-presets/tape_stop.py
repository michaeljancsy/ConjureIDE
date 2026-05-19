import numpy as np
import math
from conjuredsp.params import param, toggle
from conjuredsp.buffers import DelayLine

PARAMS = {
    "engage":  toggle(default=0),
    "speed":   param(0.1, 3, unit="s", default=1),
    "restart": param(0.05, 1, unit="s", default=0.3),
}

MAX_DELAY = 192000
_delay = None
_rate = 1.0
_ramp_pos = 0.0
_was_engaged = False
_restarting = False


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Tape Stop — turntable/tape brake effect.

    When engaged, simulates a record player or tape machine being
    stopped — the audio slows down and drops in pitch until it
    stops completely. When released, the audio speeds back up like
    pressing play again. A dramatic DJ and electronic music effect
    used for transitions, drops, and breakdowns.

    Params:
        engage:  Toggle the stop effect on/off
        speed:   How fast it slows down (0.1–3 s)
        restart: How fast it speeds back up (0.05–1 s)
    """
    global _delay, _rate, _ramp_pos, _was_engaged, _restarting

    engaged = params["engage"] > 0.5
    stop_time = params["speed"]
    restart_time = params["restart"]

    n_ch = len(inputs)

    if _delay is None:
        _delay = [DelayLine(MAX_DELAY) for _ in range(n_ch)]

    # Detect state changes
    if engaged and not _was_engaged:
        _restarting = False
    elif not engaged and _was_engaged:
        _restarting = True
    _was_engaged = engaged

    for i in range(frame_count):
        if engaged and not _restarting:
            # Slowing down
            decel = 1.0 / (stop_time * sample_rate)
            _rate = max(0.0, _rate - decel)
        elif _restarting:
            # Speeding back up
            accel = 1.0 / (restart_time * sample_rate)
            _rate = min(1.0, _rate + accel)
            if _rate >= 1.0:
                _restarting = False
        else:
            _rate = 1.0

        for ch in range(n_ch):
            _delay[ch].write(inputs[ch][i])

        # Read at variable rate (pitch drops as rate decreases)
        _ramp_pos += _rate
        if _ramp_pos >= MAX_DELAY:
            _ramp_pos = _ramp_pos % MAX_DELAY

        read_delay = max(1.0, frame_count - _ramp_pos % frame_count)

        for ch in range(n_ch):
            if _rate < 0.01:
                outputs[ch][i] = 0.0  # fully stopped
            else:
                outputs[ch][i] = _delay[ch].read(min(read_delay, MAX_DELAY - 1)) * min(_rate * 2.0, 1.0)
