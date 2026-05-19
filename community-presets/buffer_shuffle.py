import numpy as np
from conjuredsp.params import param, choice, mix

PARAMS = {
    "size":    choice("1/16", "1/8", "1/4", default="1/8"),
    "shuffle": param(0, 1, default=0.5),
    "reverse": param(0, 1, default=0.3),
    "mix":     mix(default=0.7),
}

_rng_state = 12345

def _rng():
    global _rng_state
    _rng_state = (_rng_state * 1664525 + 1013904223) & 0xFFFFFFFF
    return _rng_state / 4294967296.0

DIVISIONS = [0.25, 0.5, 1.0]

_buffer = None
_shuffled = None
_write_pos = 0
_read_pos = 0
_chunk_size = 0


def process(inputs, outputs, frame_count, sample_rate, params, transport):
    """
    Buffer Shuffle — randomized audio chunk rearrangement.

    Captures audio in beat-synced chunks and rearranges them randomly.
    The shuffle control determines how much rearrangement occurs.
    Some chunks may be reversed. Creates beat-mangling, cut-up
    effects reminiscent of Aphex Twin, Autechre, and IDM. Also
    useful for creating unpredictable rhythmic variations.

    Params:
        size:    Chunk size in beats (1/16, 1/8, 1/4)
        shuffle: Rearrangement probability (0–1)
        reverse: Chance of reversing a chunk (0–1)
        mix:     Wet/dry blend
    """
    global _buffer, _shuffled, _write_pos, _read_pos, _chunk_size

    div_idx = int(round(params["size"]))
    div_idx = max(0, min(div_idx, len(DIVISIONS) - 1))
    beats = DIVISIONS[div_idx]
    shuffle_prob = params["shuffle"]
    reverse_prob = params["reverse"]
    wet_mix = params["mix"]

    tempo = transport["tempo"]
    n_ch = len(inputs)

    # Calculate chunk size
    if tempo > 0:
        chunk_seconds = beats * 60.0 / tempo
        chunk = int(chunk_seconds * sample_rate)
    else:
        chunk = int(0.125 * sample_rate)

    chunk = max(64, min(chunk, int(sample_rate * 2)))
    max_buf = chunk * 8  # store 8 chunks

    if _buffer is None or len(_buffer) != n_ch or len(_buffer[0]) != max_buf:
        _buffer = [np.zeros(max_buf, dtype=np.float32) for _ in range(n_ch)]
        _shuffled = [np.zeros(max_buf, dtype=np.float32) for _ in range(n_ch)]
        _chunk_size = chunk
        _write_pos = 0
        _read_pos = 0

    _chunk_size = chunk

    for i in range(frame_count):
        # Write to buffer
        wp = _write_pos % max_buf
        for ch in range(n_ch):
            _buffer[ch][wp] = inputs[ch][i]
        _write_pos += 1

        # At chunk boundary, maybe shuffle
        if _write_pos % chunk == 0 and _write_pos > 0:
            chunk_start = ((_write_pos - chunk) % max_buf)

            if _rng() < shuffle_prob:
                # Pick a random previous chunk to play instead
                num_chunks = min(8, _write_pos // chunk)
                src_chunk = 0 + int(_rng() * (max(0, num_chunks - 1) - 0 + 1))
                src_start = (chunk_start - src_chunk * chunk + max_buf) % max_buf

                for ch in range(n_ch):
                    for j in range(chunk):
                        _shuffled[ch][(chunk_start + j) % max_buf] = _buffer[ch][(src_start + j) % max_buf]

                # Maybe reverse
                if _rng() < reverse_prob:
                    for ch in range(n_ch):
                        temp = [_shuffled[ch][(chunk_start + j) % max_buf] for j in range(chunk)]
                        temp.reverse()
                        for j in range(chunk):
                            _shuffled[ch][(chunk_start + j) % max_buf] = temp[j]
            else:
                for ch in range(n_ch):
                    for j in range(chunk):
                        _shuffled[ch][(chunk_start + j) % max_buf] = _buffer[ch][(chunk_start + j) % max_buf]

        # Read from shuffled buffer (one chunk behind)
        rp = (_write_pos - chunk + max_buf) % max_buf

        for ch in range(n_ch):
            wet = _shuffled[ch][rp] if _write_pos > chunk else inputs[ch][i]
            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + wet * wet_mix
