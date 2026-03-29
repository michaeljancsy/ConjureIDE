import numpy as np
import math
import random
from conjuredsp.params import param, mix
from conjuredsp.buffers import DelayLine
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "dwell":   param(0, 1, default=0.5),
    "tone":    param(0, 1, default=0.6),
    "drip":    param(0, 1, default=0.4),
    "mix":     mix(default=0.3),
}

_delays = None
_ap = None
_lp = None
_hp = None
_drip_env = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Spring Reverb — guitar amp spring tank simulation.

    Models the characteristic "boing" and splash of a spring reverb
    tank. Uses comb filtering with allpass dispersion to create the
    metallic, twangy reverb character. The "drip" control adds the
    signature spring crash when hit hard. Found in every guitar amp
    since the 60s — the sound of surf, country, and garage rock.

    Params:
        dwell: Reverb intensity / spring tension (0–1)
        tone:  Brightness (0 = dark, 1 = bright)
        drip:  Spring crash/splash intensity (0–1)
        mix:   Wet/dry blend
    """
    global _delays, _ap, _lp, _hp, _drip_env

    dwell = params["dwell"]
    tone = params["tone"]
    drip = params["drip"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _delays is None:
        # Slightly different lengths for L/R decorrelation
        _delays = [
            [DelayLine(2048) for _ in range(3)]
            for _ in range(n_ch)
        ]
        _ap = [DelayLine(512) for _ in range(n_ch)]
        _lp = [Biquad() for _ in range(n_ch)]
        _hp = [Biquad() for _ in range(n_ch)]

    feedback = 0.3 + dwell * 0.55
    lp_freq = 2000.0 + tone * 6000.0

    # Spring delay times (characteristic of real spring tanks)
    spring_times = [467, 631, 853]

    for ch in range(n_ch):
        _lp[ch].set_coeffs(BiquadCoeffs.lowpass(lp_freq, 0.8, sample_rate))
        _hp[ch].set_coeffs(BiquadCoeffs.highpass(150.0, 0.7, sample_rate))

        for i in range(frame_count):
            x = inputs[ch][i]

            # Drip detection — spring crash on transients
            level = abs(x)
            if level > _drip_env:
                _drip_env = level
            else:
                _drip_env *= 0.9995

            drip_amount = max(0.0, _drip_env - 0.1) * drip * 5.0
            drip_noise = (random.random() - 0.5) * drip_amount * 0.3

            # Comb filter network (spring resonances)
            wet = 0.0
            for s in range(3):
                delayed = _delays[ch][s].tap(spring_times[s])
                _delays[ch][s].write(x + delayed * feedback + drip_noise)
                wet += delayed

            wet /= 3.0

            # Allpass dispersion (spring is dispersive)
            ap_out = _ap[ch].tap(173)
            _ap[ch].write(wet - 0.4 * ap_out)
            wet = ap_out + 0.4 * wet

            # Tone shaping
            wet = _lp[ch].process_sample(wet)
            wet = _hp[ch].process_sample(wet)

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + wet * wet_mix
