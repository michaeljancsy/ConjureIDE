import numpy as np
import math

# Gain + Pan parameters
GAIN_DB = -6.0   # Gain in decibels
PAN = 0.75       # 0.0 = hard left, 0.5 = center, 1.0 = hard right


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Gain + Pan — volume control with stereo panning.

    Applies a fixed gain (in dB) and constant-power panning to the signal.
    Panning uses a sine/cosine law for constant power across the stereo
    field. For mono signals, only gain is applied (panning has no effect
    with a single channel).

    Args:
        inputs:      list of numpy.float32 arrays, one per channel
        outputs:     list of numpy.float32 arrays, one per channel
        frame_count: number of valid samples this callback
        sample_rate: current sample rate in Hz
        params:      list of 8 floats (0.0–1.0), DAW-automatable parameters (unused)
    """
    gain = 10.0 ** (GAIN_DB / 20.0)
    n_ch = len(inputs)

    if n_ch == 1:
        # Mono: just apply gain
        outputs[0][:frame_count] = inputs[0][:frame_count] * gain
    else:
        # Stereo: constant-power pan
        left_gain = gain * math.cos(PAN * math.pi * 0.5)
        right_gain = gain * math.sin(PAN * math.pi * 0.5)
        outputs[0][:frame_count] = inputs[0][:frame_count] * left_gain
        outputs[1][:frame_count] = inputs[1][:frame_count] * right_gain
