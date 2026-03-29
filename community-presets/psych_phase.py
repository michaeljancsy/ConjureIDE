import numpy as np
import math
from conjuredsp.params import param, mix
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "rate":     param(0.05, 5, unit="Hz", default=0.3),
    "depth":    param(0, 1, default=0.9),
    "feedback": param(-0.9, 0.9, default=0.7),
    "stages":   param(4, 12, default=8),
    "mix":      mix(default=0.7),
}

_phase = 0.0
_ap = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Psychedelic Phaser — deep, swirling phase shifting.

    A deep, slow phaser with many stages and high feedback for
    maximum psychedelic swirl. More stages = deeper notches and
    a more complex sweep. High feedback creates a resonant,
    almost vocal quality. The signature effect of 60s/70s
    psychedelic rock — Small Stone, Phase 90, and Univibe
    territory but pushed further into the cosmic.

    Params:
        rate:     Sweep speed (0.05–5 Hz)
        depth:    Sweep range (0–1)
        feedback: Resonance/regeneration (-0.9 to +0.9)
        stages:   Number of allpass stages (4–12)
        mix:      Wet/dry blend
    """
    global _phase, _ap

    rate = params["rate"]
    depth = params["depth"]
    feedback = params["feedback"]
    n_stages = int(params["stages"])
    wet_mix = params["mix"]

    n_ch = len(inputs)
    two_pi = 2.0 * math.pi

    if _ap is None or len(_ap[0]) < n_stages:
        _ap = [[Biquad() for _ in range(12)] for _ in range(n_ch)]

    _fb_sample = [0.0] * n_ch

    for i in range(frame_count):
        # Sine LFO for sweep
        lfo = math.sin(two_pi * _phase)
        sweep = 0.5 + 0.5 * lfo * depth

        # Sweep frequency range (logarithmic)
        min_f = 100.0
        max_f = 4000.0
        sweep_freq = min_f * (max_f / min_f) ** sweep
        sweep_freq = min(sweep_freq, sample_rate * 0.45)

        for ch in range(n_ch):
            x = inputs[ch][i] + _fb_sample[ch] * feedback

            y = x
            for s in range(n_stages):
                # Stagger each stage slightly for richer effect
                stage_freq = sweep_freq * (0.8 + 0.4 * s / max(n_stages - 1, 1))
                stage_freq = min(stage_freq, sample_rate * 0.45)
                coeffs = BiquadCoeffs.allpass(stage_freq, 0.5, sample_rate)
                _ap[ch][s].set_coeffs(coeffs)
                y = _ap[ch][s].process_sample(y)

            _fb_sample[ch] = y

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + y * wet_mix

        _phase = (_phase + rate / sample_rate) % 1.0
