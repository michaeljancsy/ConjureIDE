import numpy as np
import math
from conjuredsp.params import param, mix as mix_param, time_ms

PARAMS = {
    "rate":  param(0.1, 2, unit="Hz", default=0.5),
    "depth": time_ms(min=0.5, max=15, default=5),
    "delay": time_ms(min=2, max=30, default=10),
    "mix":   mix_param(default=0.5),
}

# Max delay in samples (supports up to 96 kHz)
MAX_DELAY = 2048

# Persistent state
_delay_buf = None
_write_pos = 0
_lfo_phase = 0.0


def process(ctx):
    """
    Chorus — modulated delay for thickening.

    Uses a short delay line with an LFO-modulated read position to create
    a detuned copy of the signal. The modulated copy is mixed with the dry
    signal, producing a rich, thickened sound. Linear interpolation is used
    for sub-sample delay accuracy.

    Params:
        rate:  LFO rate (0.1–2 Hz)
        depth: LFO depth (0.5–15 ms)
        delay: Base delay (2–30 ms)
        mix:   Wet/dry mix (0.0 = dry, 1.0 = wet)
    """
    global _delay_buf, _write_pos, _lfo_phase

    rate_hz = ctx.params["rate"]
    depth_ms = ctx.params["depth"]
    base_delay_ms = ctx.params["delay"]
    mix = ctx.params["mix"]

    n_ch, frame_count = ctx.inputs.shape

    # Initialize delay buffer on first call
    if _delay_buf is None or len(_delay_buf) != n_ch:
        _delay_buf = [np.zeros(MAX_DELAY, dtype=np.float32) for _ in range(n_ch)]

    two_pi = 2.0 * math.pi
    lfo_inc = two_pi * rate_hz / ctx.sample_rate
    phase = _lfo_phase
    wp = _write_pos

    for i in range(frame_count):
        # LFO modulates delay time
        delay_samples = (base_delay_ms + depth_ms * math.sin(phase)) * ctx.sample_rate / 1000.0

        for ch in range(n_ch):
            # Write input to delay line
            _delay_buf[ch][wp] = ctx.inputs[ch][i]

            # Read with linear interpolation
            read_pos = wp - delay_samples
            if read_pos < 0.0:
                read_pos += MAX_DELAY
            idx = int(read_pos)
            frac = read_pos - idx
            idx0 = idx % MAX_DELAY
            idx1 = (idx + 1) % MAX_DELAY
            delayed = _delay_buf[ch][idx0] * (1.0 - frac) + _delay_buf[ch][idx1] * frac

            # Mix dry + wet
            ctx.outputs[ch][i] = ctx.inputs[ch][i] * (1.0 - mix) + delayed * mix

        phase += lfo_inc
        wp = (wp + 1) % MAX_DELAY

    _lfo_phase = phase % two_pi
    _write_pos = wp
