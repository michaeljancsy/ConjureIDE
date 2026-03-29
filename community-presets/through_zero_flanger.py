import numpy as np
import math
from conjuredsp.params import param, mix
from conjuredsp.buffers import DelayLine

PARAMS = {
    "rate":     param(0.05, 2, unit="Hz", default=0.2),
    "depth":    param(0, 1, default=0.8),
    "feedback": param(-0.95, 0.95, default=0.5),
    "mix":      mix(default=0.7),
}

MAX_DELAY = 4096
_delays_wet = None
_delays_dry = None
_phase = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Through-Zero Flanger — the jet plane flanging effect.

    Unlike conventional flanging (where one signal is always delayed),
    through-zero flanging delays BOTH the dry and wet signals so the
    modulated delay sweeps through zero — meaning the two signals
    align perfectly at the center of the sweep, creating total
    cancellation and the iconic "jet plane" whoosh. The most dramatic
    flanging effect possible, heard on classic recordings by Electric
    Ladyland, Itchycoo Park, and countless psychedelic records.

    Params:
        rate:     Sweep speed (0.05–2 Hz)
        depth:    Sweep range (0–1)
        feedback: Regeneration (-0.95 to +0.95, negative = hollow)
        mix:      Wet/dry blend
    """
    global _delays_wet, _delays_dry, _phase

    rate = params["rate"]
    depth = params["depth"]
    feedback = params["feedback"]
    wet_mix = params["mix"]

    n_ch = len(inputs)
    two_pi = 2.0 * math.pi

    max_sweep = depth * 100.0  # up to 100 samples sweep
    center = max_sweep + 5.0

    if _delays_wet is None:
        _delays_wet = [DelayLine(MAX_DELAY) for _ in range(n_ch)]
        _delays_dry = [DelayLine(MAX_DELAY) for _ in range(n_ch)]

    for i in range(frame_count):
        mod = math.sin(two_pi * _phase) * max_sweep

        # Through-zero: dry gets (center + mod), wet gets (center - mod)
        dry_delay = center + mod
        wet_delay = center - mod

        for ch in range(n_ch):
            x = inputs[ch][i]

            wet_out = _delays_wet[ch].read(max(1.0, wet_delay))

            _delays_wet[ch].write(x + wet_out * feedback)
            _delays_dry[ch].write(x)

            dry_out = _delays_dry[ch].read(max(1.0, dry_delay))

            outputs[ch][i] = dry_out * (1.0 - wet_mix) + wet_out * wet_mix

        _phase = (_phase + rate / sample_rate) % 1.0
