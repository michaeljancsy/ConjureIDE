#!/usr/bin/env python3
"""
NAM (Neural Amp Modeler) Pure Python+NumPy Inference
=====================================================
Implements LSTM and WaveNet NAM model inference using only Python and NumPy.
Tests with 3 models and profiles performance for real-time feasibility.
"""

import json
import time
import numpy as np
import cProfile
import pstats
import io
from typing import Optional

print(f"NumPy version: {np.__version__}")

# ==============================================================================
# 1. Weight Reader
# ==============================================================================

class WeightReader:
    """Sequential reader for NAM's flat weight array."""
    def __init__(self, weights):
        self.weights = np.array(weights, dtype=np.float32)
        self.offset = 0

    def read(self, count):
        result = self.weights[self.offset:self.offset + count]
        self.offset += count
        return result

    def read_conv1d(self, out_ch, in_ch, kernel_size=1, has_bias=True):
        w = self.read(out_ch * in_ch * kernel_size).reshape(out_ch, in_ch, kernel_size)
        b = self.read(out_ch) if has_bias else None
        return w, b

    def read_conv1x1(self, out_ch, in_ch, has_bias=True):
        w = self.read(out_ch * in_ch).reshape(out_ch, in_ch)
        b = self.read(out_ch) if has_bias else None
        return w, b

    @property
    def remaining(self):
        return len(self.weights) - self.offset

# ==============================================================================
# 2. LSTM Implementation
# ==============================================================================

def sigmoid(x):
    return 1.0 / (1.0 + np.exp(-np.clip(x, -88, 88)))


class LSTMCell:
    """Single LSTM cell processing one sample at a time."""
    def __init__(self, input_size, hidden_size, W, b, initial_h, initial_c):
        self.input_size = input_size
        self.hidden_size = hidden_size
        self.W = W
        self.b = b
        self._initial_h = initial_h.copy()
        self._initial_c = initial_c.copy()
        self.h = initial_h.copy()
        self.c = initial_c.copy()

    def reset(self):
        self.h = self._initial_h.copy()
        self.c = self._initial_c.copy()

    def process(self, x):
        H = self.hidden_size
        xh = np.concatenate([x, self.h])
        ifgo = self.W @ xh + self.b

        i_gate = sigmoid(ifgo[0:H])
        f_gate = sigmoid(ifgo[H:2*H])
        g_gate = np.tanh(ifgo[2*H:3*H])
        o_gate = sigmoid(ifgo[3*H:4*H])

        self.c = f_gate * self.c + i_gate * g_gate
        self.h = o_gate * np.tanh(self.c)
        return self.h


class LSTMModel:
    """NAM LSTM model: stacked LSTM cells + linear head."""

    def __init__(self, config, reader):
        self.input_size = config.get('input_size', 1)
        self.hidden_size = config['hidden_size']
        self.num_layers = config.get('num_layers', 1)

        H = self.hidden_size
        self.cells = []

        for i in range(self.num_layers):
            in_sz = self.input_size if i == 0 else H
            W = reader.read(4 * H * (in_sz + H)).reshape(4 * H, in_sz + H)
            b = reader.read(4 * H)
            initial_h = reader.read(H)
            initial_c = reader.read(H)
            self.cells.append(LSTMCell(in_sz, H, W, b, initial_h, initial_c))

        out_ch = config.get('out_channels', 1)
        self.head_w = reader.read(out_ch * H).reshape(out_ch, H)
        self.head_b = reader.read(out_ch)
        self.receptive_field = 1  # LSTM has no receptive field concept

    def reset(self):
        for cell in self.cells:
            cell.reset()

    def process(self, audio):
        output = np.zeros_like(audio)
        for t in range(len(audio)):
            x = np.array([audio[t]], dtype=np.float32)
            for cell in self.cells:
                x = cell.process(x)
            output[t] = (self.head_w @ x + self.head_b)[0]
        return output

# ==============================================================================
# 3. WaveNet Implementation
# ==============================================================================

def conv1d(x, weight, bias=None, dilation=1):
    """1D causal convolution. x: (C_in, L), weight: (C_out, C_in, K) -> (C_out, L')."""
    C_out, C_in, K = weight.shape
    L = x.shape[1]
    L_out = L - (K - 1) * dilation
    if L_out <= 0:
        return np.zeros((C_out, 0), dtype=np.float32)

    cols = np.zeros((C_in * K, L_out), dtype=np.float32)
    for k in range(K):
        offset = (K - 1 - k) * dilation
        cols[k * C_in:(k + 1) * C_in, :] = x[:, offset:offset + L_out]

    W_flat = weight.reshape(C_out, C_in * K)
    out = W_flat @ cols

    if bias is not None:
        out += bias[:, np.newaxis]
    return out


def conv1x1(x, weight, bias=None):
    """1x1 convolution (channel mixing)."""
    out = weight @ x
    if bias is not None:
        out += bias[:, np.newaxis]
    return out


ACTIVATIONS = {
    'Tanh': np.tanh,
    'ReLU': lambda x: np.maximum(0, x),
    'Sigmoid': sigmoid,
}


class WaveNetLayer:
    """Single WaveNet layer."""

    def __init__(self, channels, condition_size, kernel_size, dilation, activation,
                 gated, reader, has_layer1x1=True, has_head1x1=False, head1x1_out=1):
        self.channels = channels
        self.dilation = dilation
        self.kernel_size = kernel_size
        self.gated = gated

        mid_ch = 2 * channels if gated else channels
        self.act_fn = ACTIVATIONS.get(activation, np.tanh)

        self.conv_w, self.conv_b = reader.read_conv1d(mid_ch, channels, kernel_size)
        self.mix_w, _ = reader.read_conv1x1(mid_ch, condition_size, has_bias=False)

        self.has_layer1x1 = has_layer1x1
        if has_layer1x1:
            self.l1x1_w, _ = reader.read_conv1x1(channels, channels, has_bias=False)

        self.has_head1x1 = has_head1x1
        if has_head1x1:
            self.h1x1_w, _ = reader.read_conv1x1(head1x1_out, channels, has_bias=False)

    def forward(self, x, condition, out_length):
        z_conv = conv1d(x, self.conv_w, self.conv_b, dilation=self.dilation)
        z_mix = conv1x1(condition, self.mix_w)

        L = min(z_conv.shape[1], z_mix.shape[1])
        z = z_conv[:, -L:] + z_mix[:, -L:]

        if self.gated:
            half = self.channels
            z_act = np.tanh(z[:half]) * sigmoid(z[half:])
        else:
            z_act = self.act_fn(z)

        if self.has_layer1x1:
            layer_out = conv1x1(z_act, self.l1x1_w)
        else:
            layer_out = z_act

        if self.has_head1x1:
            head_out = conv1x1(z_act, self.h1x1_w)[:, -out_length:]
        else:
            head_out = z_act[:, -out_length:]

        residual = x[:, -layer_out.shape[1]:] + layer_out
        return residual, head_out


class WaveNetLayerArray:
    """Array of WaveNet layers with rechannel + head_rechannel."""

    def __init__(self, config, reader):
        input_size = config['input_size']
        condition_size = config['condition_size']
        channels = config['channels']
        head_size = config['head_size']
        kernel_size = config.get('kernel_size', 3)
        dilations = config['dilations']
        activation = config.get('activation', 'Tanh')
        gated = config.get('gated', False)
        head_bias = config.get('head_bias', False)

        l1x1_cfg = config.get('layer1x1', None)
        h1x1_cfg = config.get('head1x1', None)
        has_layer1x1 = l1x1_cfg.get('active', True) if isinstance(l1x1_cfg, dict) else True
        has_head1x1 = h1x1_cfg.get('active', False) if isinstance(h1x1_cfg, dict) else False
        head1x1_out = h1x1_cfg.get('out_channels', 1) if isinstance(h1x1_cfg, dict) else 1

        self.receptive_field = 1 + sum((kernel_size - 1) * d for d in dilations)

        self.rechannel_w, _ = reader.read_conv1x1(channels, input_size, has_bias=False)

        self.layers = []
        for dil in dilations:
            layer = WaveNetLayer(
                channels=channels, condition_size=condition_size,
                kernel_size=kernel_size, dilation=dil,
                activation=activation, gated=gated, reader=reader,
                has_layer1x1=has_layer1x1, has_head1x1=has_head1x1,
                head1x1_out=head1x1_out
            )
            self.layers.append(layer)

        skip_ch = head1x1_out if has_head1x1 else channels
        self.head_rechannel_w, self.head_rechannel_b = reader.read_conv1x1(
            head_size, skip_ch, has_bias=head_bias
        )

    def forward(self, x, condition, head_input=None):
        out_length = min(x.shape[1], condition.shape[1]) - (self.receptive_field - 1)
        if out_length <= 0:
            raise ValueError(f"Input too short: need > {self.receptive_field - 1} samples")

        x = conv1x1(x, self.rechannel_w)

        for layer in self.layers:
            x, head_term = layer.forward(x, condition, out_length)
            if head_input is None:
                head_input = head_term
            else:
                head_input = head_input[:, -out_length:] + head_term

        head_output = conv1x1(head_input, self.head_rechannel_w, self.head_rechannel_b)
        return head_output, x


class WaveNetModel:
    """NAM WaveNet model."""

    def __init__(self, config, reader):
        self.condition_dsp = None
        if config.get('condition_dsp'):
            cond_cfg = config['condition_dsp']
            cond_reader = WeightReader(cond_cfg['weights']) if 'weights' in cond_cfg else reader
            self.condition_dsp = WaveNetModel(
                cond_cfg['config'] if 'config' in cond_cfg else cond_cfg, cond_reader
            )

        self.layer_arrays = []
        for la_config in config['layers']:
            self.layer_arrays.append(WaveNetLayerArray(la_config, reader))

        self.head_layers = None
        head_cfg = config.get('head')
        if head_cfg is not None:
            self.head_layers = []
            in_ch = head_cfg.get('in_channels', config['layers'][-1]['head_size'])
            ch = head_cfg['channels']
            out_ch = head_cfg.get('out_channels', 1)
            n_layers = head_cfg['num_layers']
            act = ACTIVATIONS.get(head_cfg.get('activation', 'ReLU'), lambda x: np.maximum(0, x))
            for i in range(n_layers):
                o = out_ch if i == n_layers - 1 else ch
                c = in_ch if i == 0 else ch
                w, b = reader.read_conv1x1(o, c, has_bias=True)
                self.head_layers.append((act, w, b))

        if reader.remaining >= 1:
            self.head_scale = reader.read(1)[0]
        else:
            self.head_scale = config.get('head_scale', 1.0)

        self.receptive_field = 1
        for la in self.layer_arrays:
            self.receptive_field += la.receptive_field - 1

    def process(self, audio):
        x = audio[np.newaxis, :]
        condition = self.condition_dsp.process_2d(x) if self.condition_dsp else x

        head_input = None
        y = x
        for la in self.layer_arrays:
            head_input, y = la.forward(y, condition, head_input)

        result = self.head_scale * head_input

        if self.head_layers:
            for act, w, b in self.head_layers:
                result = conv1x1(act(result), w, b)

        return result[0]

    def process_2d(self, x):
        condition = self.condition_dsp.process_2d(x) if self.condition_dsp else x
        head_input = None
        y = x
        for la in self.layer_arrays:
            head_input, y = la.forward(y, condition, head_input)
        return self.head_scale * head_input

# ==============================================================================
# 4. Model Loading
# ==============================================================================

def load_nam_model(path):
    with open(path) as f:
        data = json.load(f)

    arch = data['architecture']
    config = data['config']
    reader = WeightReader(data['weights'])

    if arch == 'LSTM':
        model = LSTMModel(config, reader)
    elif arch == 'WaveNet':
        model = WaveNetModel(config, reader)
    else:
        raise ValueError(f"Unknown architecture: {arch}")

    print(f"Loaded {arch} from {path}")
    print(f"  Weights consumed: {reader.offset}/{len(reader.weights)} (remaining: {reader.remaining})")
    return model, data


SAMPLE_RATE = 48000

def make_test_audio(duration_sec=1.0, freq=440.0):
    t = np.arange(int(SAMPLE_RATE * duration_sec), dtype=np.float32) / SAMPLE_RATE
    signal = (
        0.5 * np.sin(2 * np.pi * freq * t) +
        0.3 * np.sin(2 * np.pi * 2 * freq * t) +
        0.1 * np.sin(2 * np.pi * 3 * freq * t) +
        0.05 * np.sin(2 * np.pi * 5 * freq * t)
    ).astype(np.float32)
    envelope = np.exp(-t * 2.0).astype(np.float32)
    return signal * envelope

# ==============================================================================
# 5. Load Models
# ==============================================================================

print("=" * 60)
print("LOADING MODELS")
print("=" * 60)

lstm_model, lstm_data = load_nam_model('lstm_tiny.nam')
wavenet_tiny_model, wt_data = load_nam_model('wavenet_tiny.nam')
wavenet_std_model, ws_data = load_nam_model('wavenet_standard.nam')

# ==============================================================================
# 6. Correctness Tests
# ==============================================================================

print("\n" + "=" * 60)
print("CORRECTNESS TESTS")
print("=" * 60)

def test_model(name, model, audio):
    print(f"\n--- Testing {name} ---")

    if isinstance(model, LSTMModel):
        model.reset()
        out = model.process(audio)
        expected_len = len(audio)
        rf = 0
    else:
        out = model.process(audio)
        rf = model.receptive_field
        expected_len = len(audio) - (rf - 1)
        print(f"  Receptive field: {rf} samples ({rf/SAMPLE_RATE*1000:.1f} ms)")

    print(f"  Input:  {len(audio)} samples")
    print(f"  Output: {len(out)} samples (expected: {expected_len})")
    assert len(out) == expected_len, f"Length mismatch: {len(out)} != {expected_len}"

    print(f"  Output range: [{out.min():.6f}, {out.max():.6f}]")
    print(f"  Output RMS: {np.sqrt(np.mean(out**2)):.6f}")

    assert not np.all(out == 0), "Output is all zeros!"
    assert not np.any(np.isnan(out)), "Output contains NaN!"
    assert not np.any(np.isinf(out)), "Output contains Inf!"

    # Silence test — use enough samples for receptive field
    sil_len = max(2048, rf + 512) if rf > 0 else 1024
    silence = np.zeros(sil_len, dtype=np.float32)
    if isinstance(model, LSTMModel):
        model.reset()
        sil_out = model.process(silence)
    else:
        sil_out = model.process(silence)
    print(f"  Silence output max abs: {np.abs(sil_out).max():.8f}")
    print(f"  PASSED")
    return out

short_audio = make_test_audio(0.2)  # 9600 samples — enough for all models
test_model("LSTM tiny", lstm_model, short_audio)
test_model("WaveNet tiny", wavenet_tiny_model, short_audio)
test_model("WaveNet standard", wavenet_std_model, short_audio)

# ==============================================================================
# 7. Performance Profiling — Batch
# ==============================================================================

print("\n" + "=" * 60)
print("PERFORMANCE: BATCH PROCESSING (1 second @ 48kHz)")
print("=" * 60)

test_1s = make_test_audio(1.0)
results = []

def benchmark_batch(name, model, audio, n_runs=3):
    duration_sec = len(audio) / SAMPLE_RATE

    times = []
    for i in range(n_runs):
        if isinstance(model, LSTMModel):
            model.reset()
        t0 = time.perf_counter()
        out = model.process(audio)
        t1 = time.perf_counter()
        times.append(t1 - t0)

    avg_time = np.mean(times)
    min_time = np.min(times)
    throughput = len(audio) / avg_time
    rtf = avg_time / duration_sec

    print(f"\n  {name}")
    print(f"    Time: {avg_time*1000:.1f} ms avg, {min_time*1000:.1f} ms best")
    print(f"    Throughput: {throughput:.0f} samples/sec ({throughput/SAMPLE_RATE:.2f}x real-time)")
    print(f"    Real-time factor: {rtf:.3f}x {'OK' if rtf < 1.0 else 'TOO SLOW'}")

    return {'name': name, 'avg_ms': avg_time*1000, 'throughput': throughput, 'rtf': rtf}

results.append(benchmark_batch("LSTM tiny (H=3)", lstm_model, test_1s))
results.append(benchmark_batch("WaveNet tiny", wavenet_tiny_model, test_1s))
results.append(benchmark_batch("WaveNet standard (16ch)", wavenet_std_model, test_1s))

# ==============================================================================
# 8. Performance Profiling — Per-Buffer (Simulated Real-Time)
# ==============================================================================

print("\n" + "=" * 60)
print("PERFORMANCE: PER-BUFFER LATENCY (simulated DAW callbacks)")
print("=" * 60)

def benchmark_buffers(name, model, buffer_sizes=[64, 128, 256, 512, 1024, 2048]):
    print(f"\n  {name}")
    print(f"  {'Buffer':>8} {'Time(ms)':>10} {'Budget(ms)':>12} {'Usage':>8} {'Verdict':>10}")

    for bs in buffer_sizes:
        budget_ms = bs / SAMPLE_RATE * 1000

        if isinstance(model, LSTMModel):
            model.reset()
            warmup = np.zeros(bs, dtype=np.float32)
            model.process(warmup)

            buf = make_test_audio(bs / SAMPLE_RATE)[:bs]
            times = []
            for _ in range(20):
                t0 = time.perf_counter()
                model.process(buf)
                t1 = time.perf_counter()
                times.append(t1 - t0)
        else:
            rf = model.receptive_field
            total_needed = bs + rf - 1
            buf = make_test_audio(total_needed / SAMPLE_RATE)[:total_needed]

            times = []
            for _ in range(20):
                t0 = time.perf_counter()
                model.process(buf)
                t1 = time.perf_counter()
                times.append(t1 - t0)

        avg_ms = np.mean(times) * 1000
        usage_pct = avg_ms / budget_ms * 100
        ok = "OK" if usage_pct < 100 else "OVER"
        print(f"  {bs:>8} {avg_ms:>10.2f} {budget_ms:>12.2f} {usage_pct:>7.0f}% {ok:>10}")

benchmark_buffers("LSTM tiny (H=3)", lstm_model)
benchmark_buffers("WaveNet tiny", wavenet_tiny_model)
benchmark_buffers("WaveNet standard (16ch)", wavenet_std_model)

# ==============================================================================
# 9. cProfile — Where Does Time Go?
# ==============================================================================

print("\n" + "=" * 60)
print("DETAILED PROFILING (cProfile)")
print("=" * 60)

def profile_model(name, model, audio):
    print(f"\n--- {name} ---")
    if isinstance(model, LSTMModel):
        model.reset()

    pr = cProfile.Profile()
    pr.enable()
    model.process(audio)
    pr.disable()

    s = io.StringIO()
    ps = pstats.Stats(pr, stream=s).sort_stats('cumulative')
    ps.print_stats(10)
    print(s.getvalue())

profile_model("LSTM tiny (1s)", lstm_model, test_1s)
profile_model("WaveNet standard (1s)", wavenet_std_model, test_1s)

# ==============================================================================
# 10. LSTM Scaling with Hidden Size
# ==============================================================================

print("\n" + "=" * 60)
print("LSTM SCALING: Time vs Hidden Size")
print("=" * 60)

test_quarter = make_test_audio(0.25)
budget_128 = 128 / SAMPLE_RATE * 1000

print(f"\n  {'H':>4} {'1s proc(ms)':>12} {'RTF':>8} {'128-buf(ms)':>12} {'Budget(ms)':>12}")
for H in [3, 8, 16, 24, 32, 40, 64]:
    n_weights = 4 * H * (1 + H) + 4 * H + H + H + 1 * H + 1
    fake_weights = (np.random.randn(n_weights) * 0.01).tolist()
    reader = WeightReader(fake_weights)
    config = {'input_size': 1, 'hidden_size': H, 'num_layers': 1}
    model = LSTMModel(config, reader)
    model.reset()

    t0 = time.perf_counter()
    model.process(test_quarter)
    t1 = time.perf_counter()

    proc_1s_ms = (t1 - t0) * 4 * 1000
    rtf = proc_1s_ms / 1000
    per_128_ms = proc_1s_ms / (SAMPLE_RATE / 128)

    print(f"  {H:>4} {proc_1s_ms:>12.1f} {rtf:>8.3f} {per_128_ms:>12.3f} {budget_128:>12.3f}")

# ==============================================================================
# 11. Summary
# ==============================================================================

print("\n" + "=" * 70)
print("SUMMARY: NAM Inference Performance (Pure Python + NumPy)")
print("=" * 70)

print(f"\n{'Model':<30} {'Time(ms)':>10} {'RTF':>8} {'Verdict':>15}")
print("-" * 65)
for r in results:
    verdict = 'REAL-TIME OK' if r['rtf'] < 1.0 else f"{r['rtf']:.0f}x too slow"
    print(f"{r['name']:<30} {r['avg_ms']:>10.1f} {r['rtf']:>8.3f} {verdict:>15}")

print("""
Key findings:
  - LSTM: sample-by-sample Python loop is the bottleneck (not matrix math)
  - WaveNet: batch matrix ops in numpy are efficient, but still overhead
  - Real-world NAM models (H=24+ LSTM, 16ch WaveNet) are much larger
  - Python function call overhead dominates for small operations

For ConjureDSP integration:
  - Pure Python+NumPy: likely too slow for production NAM models in real-time
  - WaveNet *might* work at large buffer sizes (>1024) for simple models
  - LSTM is fundamentally too slow — Python per-sample loop can't compete
  - A C extension or native Rust implementation would be needed
""")
