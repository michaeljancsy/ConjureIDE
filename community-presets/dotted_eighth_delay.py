import numpy as np
import math
from conjuredsp.params import param, mix
from conjuredsp.buffers import DelayLine
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "feedback": param(0, 0.8, default=0.35),
    "tone":     param(0, 1, default=0.6),
    "mix":      mix(default=0.45),
}

MAX_DELAY = 192000
_delays = None
_lp = None


def process(inputs, outputs, frame_count, sample_rate, params, transport):
    """
    Dotted Eighth Delay — The Edge's signature rhythmic delay.

    BPM-synced delay at a dotted eighth note (3/16), creating the
    distinctive galloping rhythm that defines U2's guitar sound.
    When played in straight eighth notes, the delayed notes fill
    in between to create intricate rhythmic patterns. The most
    famous delay setting in rock history. Also beloved in ambient,
    post-rock, and worship music.

    Params:
        feedback: Repeat amount (0–0.8)
        tone:     Repeat brightness (0 = dark, 1 = bright)
        mix:      Wet/dry blend
    """
    global _delays, _lp

    feedback = params["feedback"]
    tone = params["tone"]
    wet_mix = params["mix"]
    tempo = transport["tempo"]

    n_ch = len(inputs)

    if _delays is None:
        _delays = [DelayLine(MAX_DELAY) for _ in range(n_ch)]
        _lp = [Biquad() for _ in range(n_ch)]

    # Dotted eighth = 3/16 of a whole note = 3/4 of a beat
    if tempo > 0:
        beats = 0.75  # dotted eighth
        delay_seconds = beats * 60.0 / tempo
        delay_samples = delay_seconds * sample_rate
    else:
        delay_samples = 0.375 * sample_rate  # fallback at 120 BPM

    delay_samples = max(1.0, min(delay_samples, MAX_DELAY - 1))
    lp_freq = 3000.0 + tone * 9000.0

    for ch in range(n_ch):
        _lp[ch].set_coeffs(BiquadCoeffs.lowpass(lp_freq, 0.7, sample_rate))

        for i in range(frame_count):
            delayed = _delays[ch].read(delay_samples)
            delayed = _lp[ch].process_sample(delayed)

            _delays[ch].write(inputs[ch][i] + delayed * feedback)

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + delayed * wet_mix
