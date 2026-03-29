import numpy as np
from conjuredsp.params import db, param
from conjuredsp.filters import Biquad, BiquadCoeffs
from conjuredsp.dsp import db_to_gain

PARAMS = {
    "boost":   db(0, 25, default=10),
    "treble":  db(-6, 6, default=3),
    "bass":    db(-6, 6, default=0),
}

_ls = None
_hs = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Clean Boost — transparent signal boost with tone shaping.

    A clean volume boost with treble and bass EQ controls. Adds
    no distortion of its own — just pushes level into whatever
    comes next. With treble boosted, cuts through a mix; with bass
    boosted, thickens the tone. The most transparent guitar pedal
    concept: push a tube amp harder, stack before overdrive, or
    use as a solo volume lift. Think EP Booster, Xotic RC Booster.

    Params:
        boost:  Volume boost (0–25 dB)
        treble: High frequency adjustment (-6 to +6 dB)
        bass:   Low frequency adjustment (-6 to +6 dB)
    """
    global _ls, _hs

    boost = db_to_gain(params["boost"])
    treble_db = params["treble"]
    bass_db = params["bass"]

    n_ch = len(inputs)

    if _ls is None:
        _ls = [Biquad() for _ in range(n_ch)]
        _hs = [Biquad() for _ in range(n_ch)]

    for ch in range(n_ch):
        _ls[ch].set_coeffs(BiquadCoeffs.lowshelf(250.0, 0.7, bass_db, sample_rate))
        _hs[ch].set_coeffs(BiquadCoeffs.highshelf(3000.0, 0.7, treble_db, sample_rate))

        for i in range(frame_count):
            x = inputs[ch][i] * boost
            x = _ls[ch].process_sample(x)
            x = _hs[ch].process_sample(x)
            outputs[ch][i] = x
