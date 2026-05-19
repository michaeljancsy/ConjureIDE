import numpy as np
import math
from conjuredsp.params import param, choice, mix
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "direction": choice("Up", "Down", default="Up"),
    "rate":      param(0.05, 2, unit="Hz", default=0.2),
    "depth":     param(0, 1, default=0.7),
    "mix":       mix(default=0.7),
}

_phase = 0.0
_ap_stages = None
NUM_STAGES = 6


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Barber Pole Phaser — infinite ascending/descending phase sweep.

    Uses multiple staggered allpass filter stages with offset phases
    to create the auditory illusion of an endlessly rising or falling
    phaser sweep (Shepard tone principle applied to phase shifting).
    Produces a hypnotic, psychedelic effect that never resolves.

    Params:
        direction: Up or Down sweep
        rate:      Sweep speed (0.05–2 Hz)
        depth:     Sweep range (0–1)
        mix:       Wet/dry blend
    """
    global _phase, _ap_stages

    direction = int(params["direction"])
    rate = params["rate"]
    depth = params["depth"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _ap_stages is None:
        _ap_stages = [[Biquad() for _ in range(NUM_STAGES)] for _ in range(n_ch)]

    two_pi = 2.0 * math.pi

    for i in range(frame_count):
        phase = _phase if direction == 0 else (1.0 - _phase)

        for ch in range(n_ch):
            x = inputs[ch][i]
            wet = 0.0

            # Each pair of stages sweeps at a different offset
            for s in range(NUM_STAGES):
                # Stagger phases evenly across the cycle
                stage_phase = (phase + s / NUM_STAGES) % 1.0

                # Map phase to frequency logarithmically
                sweep_freq = 100.0 * (2.0 ** (stage_phase * depth * 7.0))
                sweep_freq = min(sweep_freq, sample_rate * 0.45)

                coeffs = BiquadCoeffs.allpass(sweep_freq, 1.0, sample_rate)
                _ap_stages[ch][s].set_coeffs(coeffs)
                x = _ap_stages[ch][s].process_sample(x)

            wet = x

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + wet * wet_mix

        _phase = (_phase + rate / sample_rate) % 1.0
