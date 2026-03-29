import numpy as np
import math
from conjuredsp.params import param, choice, toggle
from conjuredsp.osc import LFO

PARAMS = {
    "sync":     toggle(),
    "rate":     param(0.1, 20, unit="Hz", default=2),
    "division": choice("1/1", "1/2", "1/4", "1/8", "1/16", default="1/4"),
    "depth":    param(0, 1, default=0.8),
    "shape":    choice("Sine", "Triangle", "Square", default="Sine"),
}

DIVISIONS = [4.0, 2.0, 1.0, 0.5, 0.25]

_lfo = None


def process(inputs, outputs, frame_count, sample_rate, params, transport):
    """
    Auto-Pan — stereo auto-panner.

    Moves the signal between left and right channels using an LFO.
    Supports free-running or BPM-synced operation with multiple
    waveform shapes. Sine creates smooth sweeping, triangle is
    more linear, and square creates hard left-right switching.
    Essential for wide synth pads, psychedelic guitars, and
    spatial sound design.

    Params:
        sync:     BPM sync on/off
        rate:     Free-running LFO rate (0.1–20 Hz)
        division: BPM-synced note division
        depth:    Pan depth (0 = center, 1 = hard L-R)
        shape:    LFO waveform shape
    """
    global _lfo

    depth = params["depth"]
    shape_idx = int(params["shape"])
    shapes = ["sine", "triangle", "square"]
    shape = shapes[min(shape_idx, len(shapes) - 1)]
    tempo = transport["tempo"]

    # Determine rate
    if params["sync"] > 0.5 and tempo > 0:
        div_idx = int(round(params["division"]))
        div_idx = max(0, min(div_idx, len(DIVISIONS) - 1))
        beats = DIVISIONS[div_idx]
        rate_hz = tempo / 60.0 / beats
    else:
        rate_hz = params["rate"]

    if _lfo is None:
        _lfo = LFO(sample_rate, freq=rate_hz, waveform=shape)
    _lfo.set_freq(rate_hz)
    _lfo.set_waveform(shape)

    n_ch = len(inputs)
    if n_ch < 2:
        # Mono — just copy through
        outputs[0][:frame_count] = inputs[0][:frame_count]
        return

    lfo_vals = _lfo.tick_n(frame_count)

    # Convert bipolar LFO to left/right gains
    pan = lfo_vals * depth  # -depth to +depth
    left_gain = np.cos((pan + 1.0) * 0.25 * np.pi).astype(np.float32)
    right_gain = np.sin((pan + 1.0) * 0.25 * np.pi).astype(np.float32)

    # Sum to mono then pan
    mono = (inputs[0][:frame_count] + inputs[1][:frame_count]) * 0.5
    np.multiply(mono, left_gain, out=outputs[0][:frame_count])
    np.multiply(mono, right_gain, out=outputs[1][:frame_count])
