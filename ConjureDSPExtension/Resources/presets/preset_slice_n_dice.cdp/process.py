"""Slice n Dice — sliced delay with a 32-step gate sequencer.

A Pluggo-style "slice / repeat" effect. Audio is sent through a tempo-synced
delay line whose wet output is gated by a 32-step pattern. Each step's gate
amount (0..15, ~0% to 100%) is held in `ctx.state["slots"]`, the bundle's
private STATE channel — so the 32 slot positions don't burn host parameters.

The custom UI (ui/index.html) renders `slots` as a 32-bar multislider that
the user click-drags to paint a pattern.
"""

import numpy as np
from conjuredsp.params import db, choice, param

PARAMS = {
    "time_quarter": param(0.0, 4.0, default=1.0, unit="q"),
    "sync_mode": choice("Manual", "Sync", default="Sync"),
    "note_value": choice(
        "1/1", "1/2", "1/2t", "1/2.", "1/4", "1/4t", "1/4.", "1/8",
        "1/8t", "1/8.", "1/16", "1/16t", "1/16.", "1/32", "1/32t",
        "1/32.", "1/64", "1/64t",
        default="1/4",
    ),
    "dry_level": db(min=-60.0, max=0.0, default=0.0),
    "wet_level": db(min=-60.0, max=0.0, default=0.0),
}

# 32 slots, each 0..15 (rendered as a vertical bar 0..15 high in the
# multislider UI). Default pattern: alternating tall/short to give a clear
# audible "slice" demo on first load.
STATE = {
    "slots": [15, 4, 12, 4, 14, 4, 10, 4, 15, 4, 12, 4, 14, 4, 10, 4,
              15, 4, 12, 4, 14, 4, 10, 4, 15, 4, 12, 4, 14, 4, 10, 4],
}

LATENCY = 0
NUM_STEPS = 32
SLOT_MAX = 15
MAX_DELAY_SECS = 4.0  # covers "1/1 at 60 BPM" with margin

# Note values in beats (relative to a quarter note = 1.0 beat).
# Order matches PARAMS["note_value"] options exactly.
NOTE_VALUE_BEATS = [
    4.0,    # 1/1
    2.0,    # 1/2
    4.0/3,  # 1/2t (triplet)
    3.0,    # 1/2. (dotted)
    1.0,    # 1/4
    2.0/3,  # 1/4t
    1.5,    # 1/4.
    0.5,    # 1/8
    1.0/3,  # 1/8t
    0.75,   # 1/8.
    0.25,   # 1/16
    1.0/6,  # 1/16t
    0.375,  # 1/16.
    0.125,  # 1/32
    1.0/12, # 1/32t
    0.1875, # 1/32.
    0.0625, # 1/64
    1.0/24, # 1/64t
]

# Persistent (module-lived) state. Survives across blocks within a process()
# lifetime; reset on script reload (the kernel reinitializes the backend).
_state = {
    "delay_buf": None,        # list of np.float32 circular buffers (one per channel)
    "buf_len": 0,
    "write_idx": 0,
    "step_idx": 0,
    "samples_into_step": 0.0,
    "last_sr": 0.0,
    "last_channels": 0,
}


def _ensure_buffers(channel_count, sample_rate):
    """Allocate per-channel delay lines on first call or if SR / channel
    count changes. Buffer length is sized for the longest delay we'll
    ever need (MAX_DELAY_SECS at the active SR), plus a frame of slack."""
    if (
        _state["delay_buf"] is None
        or _state["last_channels"] != channel_count
        or _state["last_sr"] != sample_rate
    ):
        n = int(MAX_DELAY_SECS * sample_rate) + 64
        _state["delay_buf"] = [np.zeros(n, dtype=np.float32) for _ in range(channel_count)]
        _state["buf_len"] = n
        _state["write_idx"] = 0
        _state["step_idx"] = 0
        _state["samples_into_step"] = 0.0
        _state["last_sr"] = sample_rate
        _state["last_channels"] = channel_count


def process(ctx):
    sr = float(ctx.sample_rate)
    channels, n = ctx.outputs.shape
    _ensure_buffers(channels, sr)

    bpm = ctx.transport.bpm if ctx.transport.bpm > 0 else 120.0

    # Resolve step length in seconds based on sync mode.
    sync_mode = int(ctx.params["sync_mode"])  # 0 = Manual, 1 = Sync
    if sync_mode == 1:
        nv_idx = int(ctx.params["note_value"])
        if nv_idx < 0 or nv_idx >= len(NOTE_VALUE_BEATS):
            nv_idx = 4  # fall back to 1/4
        beats_per_step = NOTE_VALUE_BEATS[nv_idx]
        secs_per_step = beats_per_step * 60.0 / bpm
    else:
        # Manual: time_quarter is in quarter notes; convert via bpm.
        secs_per_step = float(ctx.params["time_quarter"]) * 60.0 / bpm

    # Clamp to a useful range (>= ~5 ms, <= MAX_DELAY_SECS).
    if secs_per_step < 0.005:
        secs_per_step = 0.005
    elif secs_per_step > MAX_DELAY_SECS:
        secs_per_step = MAX_DELAY_SECS
    samples_per_step = secs_per_step * sr

    dry_gain = 10.0 ** (float(ctx.params["dry_level"]) / 20.0)
    wet_gain = 10.0 ** (float(ctx.params["wet_level"]) / 20.0)

    # Pull `slots` out of state. Defensive in case the persisted blob got
    # corrupted or shrunk.
    slots = ctx.state["slots"] if "slots" in ctx.state else None
    if not isinstance(slots, list) or len(slots) != NUM_STEPS:
        slots = [0] * NUM_STEPS

    delay_samples = int(samples_per_step)
    if delay_samples < 1:
        delay_samples = 1

    delay_bufs = _state["delay_buf"]
    buf_len = _state["buf_len"]
    write_idx = _state["write_idx"]
    step_idx = _state["step_idx"]
    samples_into_step = _state["samples_into_step"]

    # Per-channel inner loop. We advance the step counter using channel 0
    # so step_idx stays in sync across channels for the same input frame.
    step_idx_start = step_idx
    samples_into_step_start = samples_into_step
    write_idx_start = write_idx

    for ch in range(channels):
        in_buf = ctx.inputs[ch]
        out_buf = ctx.outputs[ch]
        delay = delay_bufs[ch]

        # Reset per-channel sequencer counters from the snapshot, so each
        # channel walks the same step pattern in lock-step.
        step_idx = step_idx_start
        samples_into_step = samples_into_step_start
        write_idx = write_idx_start

        for i in range(n):
            # Write input into delay line.
            delay[write_idx] = in_buf[i]
            # Read with `delay_samples` lag.
            read_idx = write_idx - delay_samples
            if read_idx < 0:
                read_idx += buf_len
            wet = delay[read_idx]
            # Gate wet by current slot (0..15 → 0..1).
            slot_val = slots[step_idx]
            if slot_val < 0:
                slot_val = 0
            elif slot_val > SLOT_MAX:
                slot_val = SLOT_MAX
            gate = float(slot_val) / float(SLOT_MAX)
            out_buf[i] = (in_buf[i] * dry_gain) + (wet * wet_gain * gate)
            # Advance write head + step counter.
            write_idx += 1
            if write_idx >= buf_len:
                write_idx = 0
            samples_into_step += 1.0
            if samples_into_step >= samples_per_step:
                samples_into_step = 0.0
                step_idx += 1
                if step_idx >= NUM_STEPS:
                    step_idx = 0

    _state["write_idx"] = write_idx
    _state["step_idx"] = step_idx
    _state["samples_into_step"] = samples_into_step
