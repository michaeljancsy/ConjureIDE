import numpy as np

PARAMS = {
    "division":  {"min": 0.0, "max": 6.0, "unit": "", "default": 2.0},
    "feedback":  {"min": 0.0, "max": 0.95, "unit": "", "default": 0.4},
    "mix":       {"min": 0.0, "max": 1.0,  "unit": "", "default": 0.5},
}

# Division mapping: 0=1/1, 1=1/2, 2=1/4, 3=1/8, 4=1/16, 5=1/4T, 6=1/8T
# Values are in beats (quarter notes)
DIVISIONS = [4.0, 2.0, 1.0, 0.5, 0.25, 2.0 / 3.0, 1.0 / 3.0]

# Max delay in samples (supports 1/1 note at 40 BPM, 96 kHz)
MAX_DELAY = 576000

# Persistent state
_delay_buf = None
_write_pos = 0


def process(inputs, outputs, frame_count, sample_rate, params, transport):
    """
    Tempo-Synced Delay — delay time locked to host BPM.

    Reads the host DAW's tempo and calculates delay time from musical
    note divisions. Falls back to 250 ms if no tempo is available.

    Params:
        division: Note division (0=1/1, 1=1/2, 2=1/4, 3=1/8, 4=1/16, 5=1/4T, 6=1/8T)
        feedback: Feedback amount (0.0–0.95)
        mix:      Wet/dry mix (0.0 = dry, 1.0 = wet)
    """
    global _delay_buf, _write_pos

    div_idx = int(round(params["division"]))
    div_idx = max(0, min(div_idx, len(DIVISIONS) - 1))
    feedback = params["feedback"]
    mix = params["mix"]

    tempo = transport["tempo"]
    n_ch = len(inputs)

    if _delay_buf is None or len(_delay_buf) != n_ch:
        _delay_buf = [np.zeros(MAX_DELAY, dtype=np.float32) for _ in range(n_ch)]

    # Calculate delay from tempo and note division
    if tempo > 0:
        beats = DIVISIONS[div_idx]
        delay_seconds = beats * 60.0 / tempo
        delay_samples = int(delay_seconds * sample_rate)
    else:
        delay_samples = int(0.25 * sample_rate)  # fallback 250 ms

    delay_samples = max(1, min(delay_samples, MAX_DELAY - 1))
    wp = _write_pos

    for i in range(frame_count):
        rp = (wp - delay_samples + MAX_DELAY) % MAX_DELAY

        for ch in range(n_ch):
            delayed = _delay_buf[ch][rp]

            # Write input + feedback to delay line
            _delay_buf[ch][wp] = inputs[ch][i] + delayed * feedback

            # Mix dry + wet
            outputs[ch][i] = inputs[ch][i] * (1.0 - mix) + delayed * mix

        wp = (wp + 1) % MAX_DELAY

    _write_pos = wp
