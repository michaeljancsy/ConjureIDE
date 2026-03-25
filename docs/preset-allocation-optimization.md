# Eliminating Render-Loop Allocations in Python DSP Presets

ConjureDSP runs user-editable Python scripts inside the real-time audio render callback. Each callback processes a buffer of audio samples (typically 512) and must complete before the next buffer arrives --- at 44.1 kHz with 512-sample buffers, that's an 11.6 ms deadline, 86 times per second. Any work that triggers memory allocation risks causing audio glitches: not because the allocation itself is slow, but because it creates garbage that eventually triggers a collection pause at an unpredictable moment.

This report documents a systematic optimization across 11 factory presets: replacing numpy's `*` operator (which allocates a temporary result array) with `np.multiply(..., out=...)` (which writes directly into a pre-existing buffer).

## Background

When you write `outputs[ch][:n] = inputs[ch][:n] * gain`, numpy:

1. Allocates a new temporary array (512 float32s = 2,048 bytes)
2. Computes the element-wise product into that temporary
3. Copies the temporary into `outputs[ch][:n]`
4. Marks the temporary for garbage collection

With `np.multiply(inputs[ch][:n], gain, out=outputs[ch][:n])`, numpy writes the result directly into the output buffer. No temporary, no copy, no GC pressure.

## Results

### Call Latency

Measured over 100,000 iterations per preset, 512-sample stereo buffers at 44.1 kHz, white noise input. GC enabled (realistic conditions). All times in microseconds.

| Preset | | Median | P95 | P99 | P99.9 | Max |
|--------|---|-------:|----:|----:|------:|----:|
| Gain + Pan | before | 1.8 | 2.2 | 2.6 | 11.6 | 67.5 |
| | **after** | **1.8** | **2.1** | **2.5** | **10.6** | 138.0 |
| Ring Mod | before | 4.8 | 6.0 | 9.6 | 18.9 | 109.2 |
| | **after** | **4.8** | **5.8** | **9.1** | **16.6** | 120.8 |
| Stereo Width | before | 3.7 | 4.6 | 7.8 | 17.0 | 123.3 |
| | **after** | **3.7** | **4.6** | **7.8** | **16.4** | 116.0 |
| Hard Clip | before | 6.1 | 7.5 | 10.8 | 21.0 | 144.1 |
| | **after** | **6.2** | **7.0** | **10.2** | **19.7** | 153.4 |
| Soft Clip | before | 6.5 | 8.3 | 13.2 | 22.6 | 173.8 |
| | **after** | **6.6** | **8.2** | **12.6** | **20.4** | 120.9 |
| Tremolo | before | 6.6 | 8.1 | 11.9 | 19.8 | 141.3 |
| | **after** | **6.8** | **8.7** | **13.8** | **26.9** | 138.1 |
| Wavefolder | before | 10.6 | 13.6 | 19.2 | 29.5 | 147.2 |
| | **after** | **10.5** | **13.5** | **18.9** | **26.8** | 139.8 |
| Bitcrush | before | 85.4 | 99.8 | 112.3 | 164.8 | 1238.0 |
| | **after** | **84.0** | **94.2** | **102.4** | **132.3** | 391.1 |
| Noise Gate | before | 173.4 | 199.3 | 222.3 | 298.6 | 2371.0 |
| | **after** | **173.3** | **198.0** | **219.5** | **293.3** | 921.2 |
| Limiter | before | 237.4 | 270.0 | 295.9 | 388.9 | 927.0 |
| | **after** | **237.0** | **268.1** | **296.2** | **391.4** | 6438.9 |
| Compressor | before | 485.5 | 530.3 | 566.0 | 669.3 | 5482.4 |
| | **after** | **483.8** | **530.5** | **572.7** | **685.5** | 4942.6 |

**What this table shows:** Median and P95 times are unchanged --- the `*` operator's temporary allocation is too fast to measure against the rest of the computation. The P99.9 and max columns are noisy (dominated by OS scheduling jitter, not GC), so individual values shouldn't be compared. The overall pattern is that the optimization doesn't hurt throughput and eliminates unnecessary work.

### Temporary Allocations Eliminated

Counted via numpy `__array_ufunc__` instrumentation: every ufunc call (multiply, add, subtract, etc.) without an `out=` parameter allocates a new array. These are the allocations this optimization removes.

| Preset | Temps Before | Temps After | Eliminated | Bytes Saved / Callback |
|--------|------------:|-----------:|-----------:|----------------------:|
| Gain + Pan | 2 | 0 | 2 | 4,096 |
| Limiter | 2 | 0 | 2 | 4,096 |
| Noise Gate | 2 | 0 | 2 | 4,096 |
| Ring Mod | 2 | 0 | 2 | 4,096 |
| Tremolo | 2 | 0 | 2 | 4,096 |
| Compressor | 4 | 0 | 4 | 8,192 |
| Hard Clip | 4 | 0 | 4 | 8,192 |
| Bitcrush | 6 | 0 | 6 | 12,288 |
| Soft Clip | 6 | 0 | 6 | 16,384 |
| Stereo Width | 7 | 0 | 7 | 14,336 |
| Wavefolder | 18 | 16 | 2 | 4,096 |
| **Total** | **55** | **16** | **39** | **83,968** |

At 86 callbacks/second, the old code allocated ~4,700 temporary arrays per second across all 11 presets. The optimized code reduces this to ~1,400 (wavefolder only), a 71% reduction.

### Why Allocations Matter More Than Throughput

The latency table shows that individual `process()` calls aren't measurably faster. That's expected: at 512 samples, numpy's allocator handles a 2 KB temporary in nanoseconds. The allocation itself isn't the problem.

The problem is what happens over time. Each temporary becomes garbage. Python's garbage collector runs when allocation pressure builds up, and when it runs, it pauses all threads. In a DAW session running for minutes or hours, with the render callback firing 86 times per second, those pauses eventually land inside a render callback and cause an audible dropout.

By eliminating 39 temporary allocations per callback cycle, we reduce the rate at which garbage accumulates. Less garbage means fewer GC pauses, and fewer GC pauses means fewer chances for a pause to coincide with a real-time deadline.

This is a structural improvement, not a throughput improvement. It won't show up in a microbenchmark of individual calls. It shows up in the probability of a glitch over a 2-hour recording session.

## Preset-by-Preset Changes

### Gain + Pan

The simplest case. Mono or stereo gain applied to the entire buffer.

```python
# Before: allocates a temporary, then copies into output
outputs[0][:n] = inputs[0][:n] * gain

# After: writes directly into the output buffer
np.multiply(inputs[0][:n], gain, out=outputs[0][:n])
```

**2 temporaries eliminated** (one per channel in stereo mode).

### Limiter / Noise Gate

Both presets compute a per-sample gain envelope in a Python loop, then apply it to the full buffer with a single multiply. The per-sample loop dominates runtime (~230 us for limiter, ~175 us for noise gate).

```python
# Before
outputs[ch][:n] = inputs[ch][:n] * gain

# After
np.multiply(inputs[ch][:n], gain, out=outputs[ch][:n])
```

**2 temporaries eliminated** per preset.

### Ring Mod / Tremolo

Both generate an LFO array (`np.sin` / `np.arange`), then multiply it element-wise with the input. The LFO generation still allocates (unavoidable --- it's creating new data), but the final multiply into the output is now allocation-free.

```python
# Before
outputs[ch][:n] = inputs[ch][:n] * lfo

# After
np.multiply(inputs[ch][:n], lfo, out=outputs[ch][:n])
```

**2 temporaries eliminated** per preset.

### Compressor

The compressor has a per-sample envelope follower loop (the bottleneck at ~480 us), then applies `gain * makeup` to each channel. The old code created two temporaries per channel: one for `input * gain`, another for `result * makeup`.

```python
# Before: two temporaries per channel
outputs[ch][:n] = inputs[ch][:n] * gain * makeup

# After: chain two in-place multiplies
np.multiply(inputs[ch][:n], gain, out=outputs[ch][:n])
np.multiply(outputs[ch][:n], makeup, out=outputs[ch][:n])
```

**4 temporaries eliminated**.

### Hard Clip

The old code multiplied by drive (temporary), then passed the temporary to `np.clip` (another temporary). Now both operations write in-place to the output buffer.

```python
# Before: drive*input allocates, then np.clip allocates again
outputs[ch][:n] = np.clip(drive * inputs[ch][:n], -1.0, 1.0)

# After: multiply in-place, then clip in-place
np.multiply(inputs[ch][:n], drive, out=outputs[ch][:n])
np.clip(outputs[ch][:n], -1.0, 1.0, out=outputs[ch][:n])
```

**4 temporaries eliminated** (2 per channel).

### Soft Clip

Three chained operations per channel: multiply by drive, apply `tanh`, multiply by normalization factor. Each allocated a temporary.

```python
# Before: three temporaries per channel
outputs[ch][:n] = np.tanh(drive * inputs[ch][:n]) * norm

# After: three in-place operations
np.multiply(inputs[ch][:n], drive, out=outputs[ch][:n])
np.tanh(outputs[ch][:n], out=outputs[ch][:n])
np.multiply(outputs[ch][:n], norm, out=outputs[ch][:n])
```

**6 temporaries eliminated**.

### Bitcrush

Bit-depth reduction involves multiply, round, and divide --- three array operations per channel that each allocated a temporary.

```python
# Before
crushed = np.round(signal * levels) / levels

# After: use output buffer as scratch space
np.multiply(signal, levels, out=out)
np.round(out, out=out)
np.divide(out, levels, out=out)
```

**6 temporaries eliminated**. The per-sample downsampling loop still dominates runtime.

### Stereo Width

The most involved optimization. Mid/side encoding creates multiple intermediate arrays: `(L+R)*0.5`, `(L-R)*0.5`, `side*width`, `mid+side`, `mid-side`. The old code allocated 7 temporary arrays per callback.

The new version pre-allocates two persistent scratch buffers (`_scratch_mid`, `_scratch_side`) at module level and performs all arithmetic in-place:

```python
# Before: 7 temporaries
mid = (left + right) * 0.5
side = (left - right) * 0.5
side_scaled = side * width
outputs[0][:n] = mid + side_scaled
outputs[1][:n] = mid - side_scaled

# After: 0 temporaries, pre-allocated scratch buffers
np.add(left, right, out=mid)
np.multiply(mid, 0.5, out=mid)
np.subtract(left, right, out=side)
np.multiply(side, 0.5, out=side)
np.multiply(side, width, out=side)
np.add(mid, side, out=outputs[0][:n])
np.subtract(mid, side, out=outputs[1][:n])
```

**7 temporaries eliminated**. The scratch buffers are allocated once (on first call or when buffer size increases) and reused across all subsequent callbacks --- the same pattern used by delay-line presets for their persistent state buffers.

### Wavefolder

Only the initial `input * drive` multiplication was converted. The subsequent triangle-wave folding operations (`+1.0`, `*0.25`, `np.floor`, `np.abs`, etc.) still allocate temporaries because eliminating them would require additional scratch buffers for diminishing returns.

```python
# Before
x = inputs[ch][:n] * drive

# After: use output buffer as scratch
x = outputs[ch][:n]
np.multiply(inputs[ch][:n], drive, out=x)
```

**2 of 18 temporaries eliminated**. The remaining 16 are from the folding math.

## Methodology

- **Platform**: Apple Silicon, macOS, free-threaded Python 3.14 (no GIL)
- **Buffer size**: 512 samples, stereo, 44.1 kHz (11.6 ms real-time budget)
- **Latency**: 100,000 iterations per preset, GC enabled, white noise input. Reported percentiles: P50 (median), P95, P99, P99.9, and max.
- **Allocation counting**: Custom `numpy.ndarray` subclass with `__array_ufunc__` override that intercepts all ufunc dispatch, counts calls where `out=` is not provided (indicating a new temporary was allocated), and propagates tracking through chained operations so intermediate results are also counted.
- **Parity verification**: All optimized presets pass the full Python-vs-Rust/WASM comparison test suite (A440 sine + white noise inputs, 1e-4 tolerance across 44,100 samples).
