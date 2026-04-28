import numpy as np
from conjuredsp.params import param, mix as mix_param, time_ms
from conjuredsp.buffers import DelayLine

PARAMS = {
    "time":     time_ms(min=10, max=500, default=250),
    "feedback": param(0, 0.95, default=0.4),
    "mix":      mix_param(default=0.5),
}

# Max delay in samples (supports 500 ms at 96 kHz)
MAX_DELAY = 48000

# Persistent state
_delays = None


def process(inputs, outputs, frame_count, sample_rate, params, _transport, _telemetry):
    """
    Simple Delay — echo effect with feedback.

    Delays the signal by a fixed time and feeds the delayed output back
    into the delay line. Each repeat is attenuated by the feedback amount,
    creating a decaying echo. The dry/wet mix controls the balance between
    the original signal and the delayed signal.

    Params:
        time:     Delay time (10–500 ms)
        feedback: Feedback amount (0.0–0.95)
        mix:      Wet/dry mix (0.0 = dry, 1.0 = wet)
    """
    global _delays

    delay_ms = params["time"]
    feedback = params["feedback"]
    mix = params["mix"]

    n_ch = len(inputs)

    if _delays is None or len(_delays) != n_ch:
        _delays = [DelayLine(MAX_DELAY) for _ in range(n_ch)]

    delay_samples = int(delay_ms * 0.001 * sample_rate)
    if delay_samples >= MAX_DELAY:
        delay_samples = MAX_DELAY - 1

    for i in range(frame_count):
        for ch in range(n_ch):
            delayed = _delays[ch].tap(delay_samples)
            _delays[ch].write(inputs[ch][i] + delayed * feedback)
            outputs[ch][i] = inputs[ch][i] * (1.0 - mix) + delayed * mix
