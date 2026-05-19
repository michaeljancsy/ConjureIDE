import numpy as np
from conjuredsp.params import param, choice, toggle

PARAMS = {
    "sync":     toggle(default=1),
    "rate":     param(2, 32, unit="Hz", default=8),
    "division": choice("1/4", "1/8", "1/16", "1/32", default="1/16"),
    "length":   param(0.1, 1, default=0.5),
}

DIVISIONS = [1.0, 0.5, 0.25, 0.125]

_buffer = None
_write_pos = 0
_read_pos = 0
_phase = 0.0
_capturing = True
_chunk_len = 0


def process(inputs, outputs, frame_count, sample_rate, params, transport):
    """
    Stutter — rhythmic glitch stutter effect.

    Captures a short chunk of audio and repeats it rapidly, creating
    a machine-gun stutter effect. BPM sync locks the stutter to the
    beat grid. The length control determines what fraction of each
    beat is captured and repeated. Used in EDM drops, glitch hop,
    trap, and experimental electronic music.

    Params:
        sync:     BPM sync on/off
        rate:     Free-running stutter rate (2–32 Hz)
        division: BPM-synced division
        length:   Stutter chunk length as fraction of period (0.1–1)
    """
    global _buffer, _write_pos, _read_pos, _phase, _capturing, _chunk_len

    length_frac = params["length"]
    tempo = transport["tempo"]

    if params["sync"] > 0.5 and tempo > 0:
        div_idx = int(round(params["division"]))
        div_idx = max(0, min(div_idx, len(DIVISIONS) - 1))
        beats = DIVISIONS[div_idx]
        rate_hz = tempo / 60.0 / beats
    else:
        rate_hz = params["rate"]

    n_ch = len(inputs)
    max_samples = int(sample_rate)  # 1 second max

    if _buffer is None or len(_buffer) != n_ch:
        _buffer = [np.zeros(max_samples, dtype=np.float32) for _ in range(n_ch)]

    period_samples = int(sample_rate / rate_hz)
    _chunk_len = max(1, int(period_samples * length_frac))

    for i in range(frame_count):
        old_phase = _phase
        _phase = (_phase + rate_hz / sample_rate) % 1.0

        # On phase reset, start capturing
        if _phase < old_phase:
            _capturing = True
            _write_pos = 0
            _read_pos = 0

        if _capturing and _write_pos < _chunk_len:
            for ch in range(n_ch):
                _buffer[ch][_write_pos] = inputs[ch][i]
            _write_pos += 1
            if _write_pos >= _chunk_len:
                _capturing = False
                _read_pos = 0

        # Play back the captured chunk on repeat
        if _chunk_len > 0:
            for ch in range(n_ch):
                outputs[ch][i] = _buffer[ch][_read_pos % _chunk_len]
            _read_pos = (_read_pos + 1) % _chunk_len
        else:
            for ch in range(n_ch):
                outputs[ch][i] = inputs[ch][i]
