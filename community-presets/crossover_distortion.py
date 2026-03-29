import numpy as np
import math
from conjuredsp.params import param, mix

PARAMS = {
    "deadzone": param(0.01, 0.5, default=0.1),
    "drive":    param(1, 10, unit="x", default=3),
    "mix":      mix(default=0.5),
}


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Crossover Distortion — Class B amplifier artifact.

    Simulates the dead zone around zero crossing found in push-pull
    Class B amplifiers where neither transistor is conducting. Creates
    a harsh, gritty distortion that's most apparent on quiet signals.
    Used as a lo-fi effect or to add edge to clean sounds.

    Params:
        deadzone: Width of the zero-crossing dead zone (0.01–0.5)
        drive:    Pre-gain (1–10x)
        mix:      Wet/dry blend
    """
    deadzone = params["deadzone"]
    drive = params["drive"]
    wet_mix = params["mix"]

    for ch in range(len(inputs)):
        for i in range(frame_count):
            x = inputs[ch][i] * drive

            # Dead zone around zero
            if x > deadzone:
                y = x - deadzone
            elif x < -deadzone:
                y = x + deadzone
            else:
                y = 0.0

            # Soft limit
            y = math.tanh(y)

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + y * wet_mix
