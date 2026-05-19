import numpy as np
from conjuredsp.params import param, time_ms, mix

PARAMS = {
    "time":     time_ms(min=100, max=1000, default=300),
    "feedback": param(0, 0.9, default=0.3),
    "mix":      mix(default=0.5),
}

# Persistent state
_buffer = None
_write_pos = 0
_read_counter = 0
_chunk_size = 0
_output_buf = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Reverse Delay — backwards echoes.

    Captures chunks of audio, reverses them, and plays them back
    after a delay. Creates an eerie, otherworldly effect as if the
    audio is being played in reverse. The effect builds up reversed
    "swells" before each note/hit. Used extensively in shoegaze,
    ambient, and psychedelic music. Think of it as the sound of
    hearing into the future.

    Params:
        time:     Reverse chunk length (100–1000 ms)
        feedback: Feed reversed audio back (0–0.9)
        mix:      Wet/dry blend
    """
    global _buffer, _write_pos, _read_counter, _chunk_size, _output_buf

    delay_ms = params["time"]
    feedback = params["feedback"]
    wet_mix = params["mix"]

    chunk = int(delay_ms * 0.001 * sample_rate)
    n_ch = len(inputs)
    max_samples = int(1.0 * sample_rate) + 1024

    if _buffer is None or len(_buffer) != n_ch:
        _buffer = [np.zeros(max_samples, dtype=np.float32) for _ in range(n_ch)]
        _output_buf = [np.zeros(max_samples, dtype=np.float32) for _ in range(n_ch)]
        _chunk_size = chunk
        _read_counter = 0
        _write_pos = 0

    _chunk_size = chunk

    for i in range(frame_count):
        for ch in range(n_ch):
            _buffer[ch][_write_pos] = inputs[ch][i]

        _read_counter += 1

        if _read_counter >= _chunk_size:
            # Reverse the chunk we just recorded into output buffer
            for ch in range(n_ch):
                start = (_write_pos - _chunk_size + 1 + len(_buffer[ch])) % len(_buffer[ch])
                for j in range(_chunk_size):
                    src = (start + j) % len(_buffer[ch])
                    dst = (start + _chunk_size - 1 - j) % len(_output_buf[ch])
                    _output_buf[ch][dst] = _buffer[ch][src]

            _read_counter = 0

        # Read from output buffer (one chunk behind)
        read_pos = (_write_pos - _chunk_size + len(_output_buf[0])) % len(_output_buf[0])

        for ch in range(n_ch):
            wet = _output_buf[ch][read_pos]

            # Feedback: feed reversed audio back into input buffer
            _buffer[ch][_write_pos] += wet * feedback

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + wet * wet_mix

        _write_pos = (_write_pos + 1) % len(_buffer[0])
