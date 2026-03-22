import numpy as np

# Script-declared parameter names (shown in UI, used in exported AUs)
PARAM_NAMES = {0: "Frequency"}

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

    Params:
        0 (Frequency): Carrier frequency — logarithmic 20 Hz to 20000 Hz
    """
    global _phase

    carrier_hz = 20.0 * (1000.0 ** params[0])  # 20 to 20000 Hz (log)

    t = np.arange(frame_count, dtype=np.float32) / sample_rate
    carrier = np.sin(2.0 * np.pi * carrier_hz * t + _phase)

    for ch in range(len(inputs)):
        outputs[ch][:frame_count] = inputs[ch][:frame_count] * carrier

    _phase += 2.0 * np.pi * carrier_hz * frame_count / sample_rate
    _phase %= 2.0 * np.pi
