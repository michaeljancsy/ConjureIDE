import numpy as np
from conjuredsp.params import param, time_ms, toggle

PARAMS = {
    "hold":    toggle(default=0),
    "length":  time_ms(min=10, max=200, default=50),
    "decay":   param(0.8, 1.0, default=0.95),
}

_buffer = None
_write_pos = 0
_held = False
_hold_len = 0
_read_pos = 0
_gain = 1.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Glitch Repeater — triggered loop capture and repeat.

    When the hold toggle is engaged, captures a short segment and
    repeats it indefinitely with optional decay. Release hold to
    return to live audio. The length control sets the loop size.
    Creates beat-repeat, freeze-frame, and DJ "backspin" effects.
    Use with automation for rhythmic glitch patterns.

    Params:
        hold:   Engage loop capture and repeat
        length: Loop segment length (10–200 ms)
        decay:  Volume decay per repeat (0.8–1.0)
    """
    global _buffer, _write_pos, _held, _hold_len, _read_pos, _gain

    hold = params["hold"] > 0.5
    length_ms = params["length"]
    decay = params["decay"]

    n_ch = len(inputs)
    max_samples = int(0.2 * sample_rate) + 100

    if _buffer is None or len(_buffer) != n_ch:
        _buffer = [np.zeros(max_samples, dtype=np.float32) for _ in range(n_ch)]

    loop_len = max(1, int(length_ms * 0.001 * sample_rate))
    loop_len = min(loop_len, max_samples)

    if hold and not _held:
        # Just engaged — capture buffer
        _held = True
        _hold_len = loop_len
        _read_pos = 0
        _gain = 1.0
        # Buffer already has recent audio from continuous writing
    elif not hold:
        _held = False

    for i in range(frame_count):
        if _held:
            # Play from captured loop
            for ch in range(n_ch):
                outputs[ch][i] = _buffer[ch][_read_pos % _hold_len] * _gain

            _read_pos += 1
            if _read_pos >= _hold_len:
                _read_pos = 0
                _gain *= decay
        else:
            # Normal pass-through, keep writing to buffer
            for ch in range(n_ch):
                _buffer[ch][_write_pos % max_samples] = inputs[ch][i]
                outputs[ch][i] = inputs[ch][i]
            _write_pos = (_write_pos + 1) % max_samples
