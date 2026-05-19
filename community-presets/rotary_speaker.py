import numpy as np
import math
from conjuredsp.params import param, choice, mix
from conjuredsp.buffers import DelayLine

PARAMS = {
    "speed":  choice("Slow", "Fast", default="Slow"),
    "depth":  param(0, 1, default=0.7),
    "mix":    mix(default=0.8),
}

MAX_DELAY = 512
_delays = None
_horn_phase = 0.0
_drum_phase = 0.0
_horn_speed = 0.0
_drum_speed = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Rotary Speaker — Leslie cabinet simulation.

    Models the iconic Leslie 122: a spinning horn (treble) and drum
    (bass) create doppler pitch shift, amplitude modulation, and
    phase modulation. The horn spins faster than the drum. Switching
    between slow (chorale) and fast (tremolo) produces the signature
    Leslie acceleration/deceleration. Defines the sound of gospel,
    jazz, and classic rock organ.

    Params:
        speed: Chorale (slow ~0.8 Hz) or Tremolo (fast ~6 Hz)
        depth: Modulation depth (0–1)
        mix:   Wet/dry blend
    """
    global _delays, _horn_phase, _drum_phase, _horn_speed, _drum_speed

    speed_mode = int(params["speed"])
    depth = params["depth"]
    wet_mix = params["mix"]

    # Target speeds with smooth acceleration
    target_horn = 6.0 if speed_mode == 1 else 0.8
    target_drum = 4.5 if speed_mode == 1 else 0.6
    accel = 0.5 / sample_rate  # smooth ramp

    n_ch = len(inputs)

    if _delays is None:
        _delays = [DelayLine(MAX_DELAY) for _ in range(n_ch)]

    two_pi = 2.0 * math.pi

    for i in range(frame_count):
        # Smoothly accelerate/decelerate
        _horn_speed += (target_horn - _horn_speed) * accel * 100.0
        _drum_speed += (target_drum - _drum_speed) * accel * 100.0

        # Horn modulation (higher frequencies)
        horn_mod = math.sin(two_pi * _horn_phase) * depth * 3.0  # samples
        # Drum modulation (lower frequencies, less pitch shift)
        drum_mod = math.sin(two_pi * _drum_phase) * depth * 1.5

        # Amplitude modulation from Leslie cabinet directivity
        horn_amp = 0.7 + 0.3 * math.cos(two_pi * _horn_phase)
        drum_amp = 0.8 + 0.2 * math.cos(two_pi * _drum_phase)

        for ch in range(n_ch):
            x = inputs[ch][i]
            _delays[ch].write(x)

            # Read with modulated delay
            mod = horn_mod + drum_mod + 5.0  # offset so we never go negative
            delayed = _delays[ch].read(max(1.0, mod))

            # Apply amplitude modulation
            wet = delayed * horn_amp * drum_amp

            outputs[ch][i] = x * (1.0 - wet_mix) + wet * wet_mix

        _horn_phase = (_horn_phase + _horn_speed / sample_rate) % 1.0
        _drum_phase = (_drum_phase + _drum_speed / sample_rate) % 1.0
