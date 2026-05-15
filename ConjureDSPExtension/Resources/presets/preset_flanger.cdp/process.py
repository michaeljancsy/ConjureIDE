import math
from conjuredsp.params import param, mix as mix_param, time_ms
from conjuredsp.buffers import DelayLine

PARAMS = {
    "rate":     param(0.1, 5, unit="Hz", default=0.5),
    "depth":    time_ms(min=0.5, max=5, default=2),
    "delay":    time_ms(min=1, max=5, default=2),
    "feedback": param(0, 1, default=0.5),
    "mix":      mix_param(default=0.5),
}

# Max delay in samples (supports up to 96 kHz)
MAX_DELAY = 1024

# Persistent state
_delays = None
_lfo_phase = 0.0


def process(ctx):
    """
    Flanger — short modulated delay with feedback.

    Similar to chorus but with a much shorter delay (0-4 ms) and feedback.
    The short delay creates comb-filter effects, and the LFO sweeps the
    comb filter notches up and down, producing the characteristic flanging
    jet-plane sweep. Higher feedback intensifies the comb-filter peaks.

    Controls:
        rate:     LFO rate (0.1–5 Hz)
        depth:    LFO depth (0.5–5 ms)
        delay:    Base delay (1–5 ms)
        feedback: Feedback amount (0.0–1.0)
        mix:      Wet/dry mix (0.0 = dry, 1.0 = wet)
    """
    global _delays, _lfo_phase

    rate_hz = ctx.params["rate"]
    depth_ms = ctx.params["depth"]
    base_delay_ms = ctx.params["delay"]
    feedback = ctx.params["feedback"]
    mix = ctx.params["mix"]

    n_ch, frame_count = ctx.inputs.shape

    if _delays is None or len(_delays) != n_ch:
        _delays = [DelayLine(MAX_DELAY) for _ in range(n_ch)]

    two_pi = 2.0 * math.pi
    lfo_inc = two_pi * rate_hz / ctx.sample_rate
    phase = _lfo_phase

    for i in range(frame_count):
        delay_samples = (base_delay_ms + depth_ms * math.sin(phase)) * ctx.sample_rate / 1000.0

        for ch in range(n_ch):
            delayed = _delays[ch].read(delay_samples)
            _delays[ch].write(ctx.inputs[ch][i] + delayed * feedback)
            ctx.outputs[ch][i] = ctx.inputs[ch][i] * (1.0 - mix) + delayed * mix

        phase += lfo_inc

    _lfo_phase = phase % two_pi
