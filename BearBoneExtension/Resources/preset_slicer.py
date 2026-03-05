import numpy as np

# Reverse slicer parameters
CHUNK_MS = 150.0  # Chunk size in ms

# Max chunk size in samples (supports 200 ms at 96 kHz)
MAX_CHUNK = 19200

# Persistent state
_record_buf = None
_play_buf = None
_write_pos = 0
_chunk_size = 0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Reverse Slicer — records chunks and plays them backwards.

    Divides the audio into fixed-length chunks. While recording each new
    chunk, the previous chunk is played back in reverse. This creates a
    glitchy, backwards effect where every CHUNK_MS milliseconds the audio
    reverses direction. Uses double-buffering: one buffer records while
    the other plays back reversed.

    Args:
        inputs:      list of numpy.float32 arrays, one per channel
        outputs:     list of numpy.float32 arrays, one per channel
        frame_count: number of valid samples this callback
        sample_rate: current sample rate in Hz
        params:      list of 8 floats (0.0–1.0), DAW-automatable parameters (unused)
    """
    global _record_buf, _play_buf, _write_pos, _chunk_size

    n_ch = len(inputs)
    chunk_size = int(CHUNK_MS * 0.001 * sample_rate)
    if chunk_size > MAX_CHUNK:
        chunk_size = MAX_CHUNK

    # Initialize buffers on first call or if chunk size changed
    if _record_buf is None or len(_record_buf) != n_ch or _chunk_size != chunk_size:
        _record_buf = [np.zeros(chunk_size, dtype=np.float32) for _ in range(n_ch)]
        _play_buf = [np.zeros(chunk_size, dtype=np.float32) for _ in range(n_ch)]
        _write_pos = 0
        _chunk_size = chunk_size

    wp = _write_pos

    for i in range(frame_count):
        for ch in range(n_ch):
            # Record into record buffer
            _record_buf[ch][wp] = inputs[ch][i]

            # Play from play buffer in reverse
            read_pos = chunk_size - 1 - wp
            outputs[ch][i] = _play_buf[ch][read_pos]

        wp += 1
        if wp >= chunk_size:
            # Swap buffers
            _record_buf, _play_buf = _play_buf, _record_buf
            wp = 0

    _write_pos = wp
