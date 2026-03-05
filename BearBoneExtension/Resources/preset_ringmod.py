import numpy as np

# Ring modulator parameters
CARRIER_HZ = 440.0  # Carrier frequency

# Persistent phase across callbacks
_phase = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Ring Modulator — multiplies the signal by a sine-wave carrier.

    Multiplies the input signal by a sine wave at the carrier frequency.
    This creates sum and difference frequencies, producing metallic,
    bell-like, or robotic timbres. Unlike tremolo (which modulates
    amplitude around a bias), ring modulation has no DC offset, so the
    carrier frequency components are always present in the output.

    Args:
        inputs:      list of numpy.float32 arrays, one per channel
        outputs:     list of numpy.float32 arrays, one per channel
        frame_count: number of valid samples this callback
        sample_rate: current sample rate in Hz
        params:      list of 8 floats (0.0–1.0), DAW-automatable parameters (unused)
    """
    global _phase

    t = np.arange(frame_count, dtype=np.float32) / sample_rate
    carrier = np.sin(2.0 * np.pi * CARRIER_HZ * t + _phase)

    for ch in range(len(inputs)):
        outputs[ch][:frame_count] = inputs[ch][:frame_count] * carrier

    _phase += 2.0 * np.pi * CARRIER_HZ * frame_count / sample_rate
    _phase %= 2.0 * np.pi
