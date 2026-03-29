import numpy as np
import math
from conjuredsp.params import param, choice, mix
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "mode":    choice("Chorus", "Vibrato", default="Chorus"),
    "speed":   param(0.5, 10, unit="Hz", default=3),
    "depth":   param(0, 1, default=0.7),
    "mix":     mix(default=0.7),
}

_phase = 0.0
_ap = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Uni-Vibe — Univox Uni-Vibe photocell modulator.

    The Uni-Vibe is neither chorus nor phaser — it's a unique effect
    using photocells and a light bulb to create uneven phase shifts
    across 4 stages. The result is a lush, throbbing modulation with
    asymmetric sweep. Chorus mode mixes dry+wet; Vibrato is wet-only.
    Iconic for Hendrix, Robin Trower, and David Gilmour tones.

    Params:
        mode:  Chorus (dry+wet) or Vibrato (wet only)
        speed: LFO rate (0.5–10 Hz)
        depth: Modulation depth (0–1)
        mix:   Wet/dry blend (Chorus mode)
    """
    global _phase, _ap

    mode = int(params["mode"])
    speed = params["speed"]
    depth = params["depth"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    # 4 allpass stages per channel
    if _ap is None:
        _ap = [[Biquad() for _ in range(4)] for _ in range(n_ch)]

    two_pi = 2.0 * math.pi

    # Staggered center frequencies like real Uni-Vibe
    base_freqs = [200.0, 500.0, 1200.0, 3500.0]

    for i in range(frame_count):
        # LFO with asymmetric shape (photocell response)
        lfo_raw = math.sin(two_pi * _phase)
        # Asymmetric — slower rise, faster fall (lamp thermal lag)
        lfo = lfo_raw * 0.7 + 0.3 * lfo_raw * abs(lfo_raw)
        lfo_val = 0.5 + 0.5 * lfo * depth

        for ch in range(n_ch):
            x = inputs[ch][i]
            y = x

            # Sweep allpass stages with staggered frequencies
            for stage in range(4):
                sweep_freq = base_freqs[stage] * (0.5 + lfo_val * 2.0)
                sweep_freq = min(sweep_freq, sample_rate * 0.45)
                coeffs = BiquadCoeffs.allpass(sweep_freq, 0.5, sample_rate)
                _ap[ch][stage].set_coeffs(coeffs)
                y = _ap[ch][stage].process_sample(y)

            if mode == 1:  # Vibrato
                outputs[ch][i] = y
            else:  # Chorus
                outputs[ch][i] = x * (1.0 - wet_mix) + y * wet_mix

        _phase = (_phase + speed / sample_rate) % 1.0
