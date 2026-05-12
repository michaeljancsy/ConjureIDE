import numpy as np
from conjuredsp.params import param, mix as mix_param, time_ms
from conjuredsp.buffers import DelayLine

PARAMS = {
    "time":     time_ms(min=50, max=500, default=250),
    "feedback": param(0, 0.95, default=0.4),
    "mix":      mix_param(default=0.5),
}

# Max delay in samples (supports 500 ms at 96 kHz)
MAX_DELAY = 48000

# Persistent state
_left_dl = None
_right_dl = None


def process(ctx):
    """
    Ping-Pong Delay — stereo bouncing echo.

    Creates echoes that alternate between left and right channels. The
    input feeds into the left delay, the left delay's output feeds into
    the right delay, and the right delay feeds back into the left. This
    creates a bouncing stereo effect. For mono input, the bouncing still
    occurs across the single delay line with feedback.

    Params:
        time:     Delay time per side (50–500 ms)
        feedback: Cross-feedback (0.0–0.95)
        mix:      Wet/dry mix (0.0 = dry, 1.0 = wet)
    """
    global _left_dl, _right_dl

    delay_ms = ctx.params["time"]
    feedback = ctx.params["feedback"]
    mix = ctx.params["mix"]

    n_ch, frame_count = ctx.inputs.shape

    if _left_dl is None:
        _left_dl = DelayLine(MAX_DELAY)
        _right_dl = DelayLine(MAX_DELAY)

    delay_samples = int(delay_ms * 0.001 * ctx.sample_rate)
    if delay_samples >= MAX_DELAY:
        delay_samples = MAX_DELAY - 1

    if n_ch < 2:
        # Mono: simple delay with feedback
        for i in range(frame_count):
            delayed = _left_dl.tap(delay_samples)
            _left_dl.write(ctx.inputs[0][i] + delayed * feedback)
            ctx.outputs[0][i] = ctx.inputs[0][i] * (1.0 - mix) + delayed * mix
    else:
        # Stereo: ping-pong
        for i in range(frame_count):
            left_delayed = _left_dl.tap(delay_samples)
            right_delayed = _right_dl.tap(delay_samples)

            # Input goes to left, left feeds right, right feeds back to left
            mono_in = (ctx.inputs[0][i] + ctx.inputs[1][i]) * 0.5
            _left_dl.write(mono_in + right_delayed * feedback)
            _right_dl.write(left_delayed * feedback)

            # Mix dry + wet
            ctx.outputs[0][i] = ctx.inputs[0][i] * (1.0 - mix) + left_delayed * mix
            ctx.outputs[1][i] = ctx.inputs[1][i] * (1.0 - mix) + right_delayed * mix
