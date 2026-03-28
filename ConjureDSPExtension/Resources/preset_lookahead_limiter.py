import numpy as np
from conjuredsp.params import db, time_ms
from conjuredsp.dsp import db_to_gain, smooth_coeff
from conjuredsp.buffers import DelayLine

# Algorithmic latency: the lookahead window in samples.
# The DAW compensates by delaying other tracks by this amount.
LATENCY = 256

PARAMS = {
    "threshold": db(-24, 0, default=-3),
    "release":   time_ms(10, 500, default=100),
}

# Persistent state
_delay_lines = None
_gain = 1.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Lookahead Limiter — transparent brick-wall limiter.

    Delays the audio signal by LATENCY samples while analyzing peaks
    from the non-delayed input. By the time a transient arrives through
    the delay line, the gain is already reduced — enabling transparent
    limiting without the artifacts of a fast attack time.

    Params:
        threshold: Ceiling level (-24 to 0 dB)
        release:   Release time (10–500 ms)
    """
    global _delay_lines, _gain

    if _delay_lines is None:
        _delay_lines = [DelayLine(LATENCY + 1) for _ in range(len(inputs))]

    threshold_db = params["threshold"]
    release_ms = params["release"]

    threshold = db_to_gain(threshold_db)
    release_coeff = smooth_coeff(release_ms, sample_rate)

    gain_arr = np.ones(frame_count, dtype=np.float32)
    g = _gain

    for i in range(frame_count):
        # Peak detect from raw (non-delayed) input
        peak = 0.0
        for ch in range(len(inputs)):
            peak = max(peak, abs(inputs[ch][i]))

        # Compute target gain
        if peak > threshold:
            target = threshold / peak
        else:
            target = 1.0

        # Instant attack (snap to lower gain), smooth release
        if target < g:
            g = target
        else:
            g = release_coeff * g + (1.0 - release_coeff) * target

        # Truncate to f32 to match Rust's behavior
        gain_arr[i] = float(np.float32(g))

    _gain = g

    for ch in range(len(inputs)):
        dl = _delay_lines[ch]
        for i in range(frame_count):
            dl.write(inputs[ch][i])
            delayed = dl.tap(LATENCY)
            outputs[ch][i] = delayed * gain_arr[i]
