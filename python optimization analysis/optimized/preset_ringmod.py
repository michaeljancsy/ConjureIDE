import numpy as np

PARAMS = {
    "frequency": {"min": 20.0, "max": 20000.0, "unit": "Hz", "default": 440.0, "curve": "log"},
}

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
        frequency: Carrier frequency (20–20000 Hz)
    """
    global _phase

    carrier_hz = params["frequency"]

    t = np.arange(frame_count, dtype=np.float32) / sample_rate
    carrier = np.sin(2.0 * np.pi * carrier_hz * t + _phase)

    for ch in range(len(inputs)):
        np.multiply(inputs[ch][:frame_count], carrier, out=outputs[ch][:frame_count])

    _phase += 2.0 * np.pi * carrier_hz * frame_count / sample_rate
    _phase %= 2.0 * np.pi
