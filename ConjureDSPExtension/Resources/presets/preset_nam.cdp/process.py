import numpy as np
from conjuredsp.nam import load_model
from conjuredsp.params import db, mix

PARAMS = {
    "input_gain": db(default=0),
    "mix": mix(default=1.0),
}

# Fender Super Reverb 1977
# https://www.tone3000.com/tones/fender-super-reverb-1977-19
#
# To load this tone, open the Tones panel from the toolbar,
# search for "Fender Super Reverb 1977", download the
# "EQ Flat, Volume 3, sm57 and AKG 414" model, then click Run.
model = load_model("tone3000://19/56")


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    NAM Tone — Neural Amp Modeler preset.

    Runs a downloaded NAM tone model (guitar amp, pedal, or full rig
    emulation) on the input signal. Use the Tones browser to download
    models from tone3000.com, then update the load_model() path above.

    Params:
        input_gain: Drive into the model in dB (-60 to +12)
        mix: Dry/wet blend (0 = fully dry, 1 = fully wet)
    """
    gain = 10 ** (params["input_gain"] / 20.0)
    mix_val = params["mix"]

    for ch in range(len(inputs)):
        dry = inputs[ch][:frame_count]
        wet = model.process(dry * gain, ch)
        outputs[ch][:frame_count] = dry * (1.0 - mix_val) + wet * mix_val
