import math
from conjuredsp.params import param, mix as mix_param, freq, integer

PARAMS = {
    "rate":     param(0.1, 5, unit="Hz", default=0.5),
    "min_freq": freq(min=50, max=500, default=200),
    "max_freq": freq(min=500, max=10000, default=4000),
    "stages":   integer(2, 6, default=4),
    "mix":      mix_param(default=0.5),
}

# Maximum number of allpass stages
MAX_STAGES = 6

# Persistent state per channel per stage: [x_prev, y_prev]
_ap_state = [[[0.0, 0.0] for _ in range(MAX_STAGES)] for _ in range(2)]
_lfo_phase = 0.0


def process(ctx):
    """
    Phaser — cascaded allpass filters with LFO-swept frequency.

    Passes the signal through a cascade of first-order allpass filters
    whose cutoff frequency is swept by an LFO. The allpass filters shift
    the phase of different frequencies by different amounts, and when
    mixed with the dry signal, creates notches that sweep up and down
    the spectrum. The number of stages determines how many notches appear.

    Params:
        rate:     LFO rate (0.1–5 Hz)
        min_freq: Minimum allpass frequency (50–500 Hz)
        max_freq: Maximum allpass frequency (500–10000 Hz)
        stages:   Number of allpass stages (2–6)
        mix:      Wet/dry mix (0.0 = dry, 1.0 = wet)
    """
    global _ap_state, _lfo_phase

    rate_hz = ctx.params["rate"]
    min_freq = ctx.params["min_freq"]
    max_freq = ctx.params["max_freq"]
    stages = int(ctx.params["stages"])
    mix = ctx.params["mix"]

    n_ch, frame_count = ctx.inputs.shape
    two_pi = 2.0 * math.pi
    lfo_inc = two_pi * rate_hz / ctx.sample_rate
    phase = _lfo_phase

    for i in range(frame_count):
        # LFO sweeps the allpass frequency between min_freq and max_freq
        lfo = 0.5 * (1.0 + math.sin(phase))
        freq = min_freq + (max_freq - min_freq) * lfo

        # Compute allpass coefficient
        tan_val = math.tan(math.pi * freq / ctx.sample_rate)
        a = (tan_val - 1.0) / (tan_val + 1.0)

        for ch in range(n_ch):
            x = ctx.inputs[ch][i]
            # Pass through allpass cascade
            signal = x
            for s in range(stages):
                x_prev = _ap_state[ch][s][0]
                y_prev = _ap_state[ch][s][1]
                y = a * signal + x_prev - a * y_prev
                _ap_state[ch][s][0] = signal
                _ap_state[ch][s][1] = y
                signal = y

            # Mix dry + wet
            ctx.outputs[ch][i] = x * (1.0 - mix) + signal * mix

        phase += lfo_inc

    _lfo_phase = phase % two_pi
