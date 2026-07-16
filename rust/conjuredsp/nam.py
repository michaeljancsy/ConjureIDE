"""NAM (Neural Amp Modeler) inference for ConjureDSP presets.

Load and run NAM models (.nam files) within your ``process()`` function.
Supports both WaveNet and LSTM architectures.

Quick start::

    from conjuredsp.nam import load_model

    model = load_model("tone3000://abc123/def456")

    def process(ctx):
        for ch in range(ctx.inputs.shape[0]):
            ctx.outputs[ch] = model.process(ctx.inputs[ch], ch)

Path schemes:
    - ``tone3000://tone_id/model_id`` — downloaded via tone browser
    - ``~/path/to/model.nam`` — tilde expansion
    - ``/absolute/path/to/model.nam`` — absolute path
    - ``relative/path.nam`` — relative to cwd, then tones dir
"""

import json
import os
import sys

import numpy as np

__all__ = ["NamModel", "load_model"]

# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------

_TONE3000_SCHEME = "tone3000://"


def _resolve_path(path: str) -> str:
    """Resolve a NAM model path to an absolute filesystem path."""
    if path.startswith(_TONE3000_SCHEME):
        tones_dir = os.environ.get("CONJUREDSP_TONES_DIR", "")
        if not tones_dir:
            raise FileNotFoundError(
                f"Cannot resolve {path}: CONJUREDSP_TONES_DIR not set"
            )
        relative = path[len(_TONE3000_SCHEME) :]
        # tone3000://tone_id/model_id -> {tones_dir}/tone_id/model_id.nam
        if not relative.endswith(".nam"):
            relative += ".nam"
        resolved = os.path.join(tones_dir, relative)
        if os.path.isfile(resolved):
            return resolved
        raise FileNotFoundError(f"NAM model not found: {resolved}")

    expanded = os.path.expanduser(path)
    if os.path.isabs(expanded):
        if os.path.isfile(expanded):
            return expanded
        raise FileNotFoundError(f"NAM model not found: {expanded}")

    # Relative path: try cwd first, then tones dir
    cwd_path = os.path.abspath(expanded)
    if os.path.isfile(cwd_path):
        return cwd_path

    tones_dir = os.environ.get("CONJUREDSP_TONES_DIR", "")
    if tones_dir:
        tones_path = os.path.join(tones_dir, expanded)
        if os.path.isfile(tones_path):
            return tones_path

    raise FileNotFoundError(f"NAM model not found: {path}")


# ---------------------------------------------------------------------------
# Weight reader
# ---------------------------------------------------------------------------


class _WeightReader:
    """Sequential reader for NAM's flat weight array."""

    __slots__ = ("weights", "offset")

    def __init__(self, weights):
        self.weights = np.array(weights, dtype=np.float32)
        self.offset = 0

    def read(self, count: int) -> np.ndarray:
        result = self.weights[self.offset : self.offset + count]
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
    def remaining(self) -> int:
        return len(self.weights) - self.offset


# ---------------------------------------------------------------------------
# Activations
# ---------------------------------------------------------------------------


def _sigmoid(x):
    return 1.0 / (1.0 + np.exp(-np.clip(x, -88, 88)))


def _sigmoid_inplace(x, out):
    """Compute sigmoid into pre-allocated *out* buffer, no temporaries."""
    np.negative(x, out=out)
    np.clip(out, -88, 88, out=out)
    np.exp(out, out=out)
    out += 1.0
    np.reciprocal(out, out=out)


def _relu(x):
    return np.maximum(0, x)


def _make_leaky_relu(negative_slope):
    # For 0 < slope < 1, leaky_relu(x) == max(x, slope * x).
    def leaky_relu(x, _s=np.float32(negative_slope)):
        return np.maximum(x, _s * x)
    return leaky_relu


def _resolve_activation(spec, default="Tanh"):
    """Resolve a .nam activation spec — a string (``"Tanh"``) or an object
    (``{"type": "LeakyReLU", "negative_slope": 0.01}``) — to a callable.
    Unknown activations are a hard error so unsupported models fail loudly
    instead of sounding wrong."""
    slope = 0.01
    if spec is None:
        name = default
    elif isinstance(spec, str):
        name = spec
    elif isinstance(spec, dict):
        name = spec.get("type")
        if not isinstance(name, str):
            raise ValueError('Unsupported NAM feature: activation object without a "type" string')
        slope = spec.get("negative_slope", 0.01)
    else:
        raise ValueError("Unsupported NAM feature: activation must be a string or object")

    if name == "Tanh":
        return np.tanh
    if name == "ReLU":
        return _relu
    if name == "Sigmoid":
        return _sigmoid
    if name == "LeakyReLU":
        return _make_leaky_relu(slope)
    raise ValueError(f'Unsupported NAM feature: activation "{name}"')

# ---------------------------------------------------------------------------
# Convolution primitives
# ---------------------------------------------------------------------------


def _conv1d(x, weight, bias=None, dilation=1, scratch=None, conv_out=None):
    """1D causal convolution.  x: (C_in, L), weight: (C_out, C_in, K) -> (C_out, L')."""
    C_out, C_in, K = weight.shape
    L = x.shape[1]
    L_out = L - (K - 1) * dilation
    if L_out <= 0:
        return np.zeros((C_out, 0), dtype=np.float32)

    # Use pre-allocated scratch buffer if provided, else allocate
    if scratch is not None and scratch.shape[0] >= C_in * K and scratch.shape[1] >= L_out:
        cols = scratch[: C_in * K, :L_out]
        cols[:] = 0
    else:
        cols = np.zeros((C_in * K, L_out), dtype=np.float32)

    # Row order MUST match the weight's inner layout: .nam serializes Conv1D
    # weights as [out][in][tap], so im2col row (c * K + k) pairs with weight
    # element [c][k].  (cols[k::K] selects rows k, K+k, 2K+k, … = c*K + k.)
    # Tap orientation follows PyTorch Conv1d / NeuralAmpModelerCore: tap k
    # multiplies x[t + k·d] within the window — the LAST tap sees the newest
    # sample.
    for k in range(K):
        offset = k * dilation
        cols[k::K, :] = x[:, offset : offset + L_out]

    W_flat = weight.reshape(C_out, C_in * K)
    # Reuse conv_out buffer if provided and large enough
    if conv_out is not None and conv_out.shape[0] >= C_out and conv_out.shape[1] >= L_out:
        out = conv_out[:C_out, :L_out]
        np.matmul(W_flat, cols, out=out)
    else:
        out = W_flat @ cols

    if bias is not None:
        out += bias[:, np.newaxis]
    return out


def _conv1x1(x, weight, bias=None, out=None):
    """1x1 convolution (channel mixing).  Reuses *out* buffer if provided and big enough."""
    rows, cols = weight.shape[0], x.shape[1]
    if out is not None and out.shape[0] >= rows and out.shape[1] >= cols:
        result = out[:rows, :cols]
        np.matmul(weight, x, out=result)
    else:
        result = weight @ x
    if bias is not None:
        result += bias[:, np.newaxis]
    return result


# ---------------------------------------------------------------------------
# LSTM
# ---------------------------------------------------------------------------


class _LSTMCell:
    __slots__ = ("input_size", "hidden_size", "W", "b", "_initial_h", "_initial_c", "h", "c")

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
        i_gate = _sigmoid(ifgo[0:H])
        f_gate = _sigmoid(ifgo[H : 2 * H])
        g_gate = np.tanh(ifgo[2 * H : 3 * H])
        o_gate = _sigmoid(ifgo[3 * H : 4 * H])
        self.c = f_gate * self.c + i_gate * g_gate
        self.h = o_gate * np.tanh(self.c)
        return self.h


class _LSTMModel:
    """NAM LSTM model: stacked LSTM cells + linear head."""

    def __init__(self, config, reader):
        self.input_size = config.get("input_size", 1)
        self.hidden_size = config["hidden_size"]
        self.num_layers = config.get("num_layers", 1)
        H = self.hidden_size
        self.cells = []
        for i in range(self.num_layers):
            in_sz = self.input_size if i == 0 else H
            W = reader.read(4 * H * (in_sz + H)).reshape(4 * H, in_sz + H)
            b = reader.read(4 * H)
            initial_h = reader.read(H)
            initial_c = reader.read(H)
            self.cells.append(_LSTMCell(in_sz, H, W, b, initial_h, initial_c))
        out_ch = config.get("out_channels", 1)
        self.head_w = reader.read(out_ch * H).reshape(out_ch, H)
        self.head_b = reader.read(out_ch)
        if reader.remaining != 0:
            raise ValueError(
                f"NAM LSTM weight mismatch: {reader.remaining} unconsumed weights "
                f"after loading all cells"
            )
        self.receptive_field = 1

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


# ---------------------------------------------------------------------------
# WaveNet
# ---------------------------------------------------------------------------


class _WaveNetLayer:
    __slots__ = (
        "channels", "dilation", "kernel_size", "bottleneck", "gated", "activation_fn",
        "conv_w", "conv_b", "mix_w",
        "has_layer1x1", "l1x1_w", "l1x1_b",
        "has_head1x1", "h1x1_w", "h1x1_b",
        "mid_ch", "head1x1_out",
    )

    def __init__(self, channels, condition_size, kernel_size, dilation, activation_fn,
                 gated, reader, bottleneck=None, has_layer1x1=True, has_head1x1=False,
                 head1x1_out=1):
        self.channels = channels
        self.dilation = dilation
        self.kernel_size = kernel_size
        self.bottleneck = channels if bottleneck is None else bottleneck
        self.gated = gated
        self.mid_ch = 2 * self.bottleneck if gated else self.bottleneck
        self.activation_fn = activation_fn
        self.head1x1_out = head1x1_out
        self.conv_w, self.conv_b = reader.read_conv1d(self.mid_ch, channels, kernel_size)
        self.mix_w, _ = reader.read_conv1x1(self.mid_ch, condition_size, has_bias=False)
        # layer1x1 / head1x1 always carry a bias when active (both the legacy
        # and current NeuralAmpModelerCore construct them with bias=true).
        self.has_layer1x1 = has_layer1x1
        if has_layer1x1:
            self.l1x1_w, self.l1x1_b = reader.read_conv1x1(channels, self.bottleneck, has_bias=True)
        else:
            self.l1x1_w = None
            self.l1x1_b = None
        self.has_head1x1 = has_head1x1
        if has_head1x1:
            self.h1x1_w, self.h1x1_b = reader.read_conv1x1(head1x1_out, self.bottleneck, has_bias=True)
        else:
            self.h1x1_w = None
            self.h1x1_b = None

    def forward(self, x, condition, out_length, scratch=None, bufs=None):
        conv_out_buf = bufs["conv_out"] if bufs else None
        z_conv = _conv1d(x, self.conv_w, self.conv_b, dilation=self.dilation, scratch=scratch, conv_out=conv_out_buf)
        L = z_conv.shape[1]

        # z_mix = mix_w @ condition — reuse buffer
        z_mix_buf = bufs["z_mix"] if bufs else None
        z_mix = _conv1x1(condition[:, -L:], self.mix_w, out=z_mix_buf)

        # z = z_conv + z_mix — in-place into z_conv
        np.add(z_conv[:, -L:], z_mix[:, :L], out=z_conv[:, -L:])
        z = z_conv[:, -L:]

        if self.gated:
            half = self.bottleneck
            # Gated activation: tanh(z[:half]) * sigmoid(z[half:]) — use buffers
            z_tanh = bufs["z_act"][:half, :L] if bufs else np.empty((half, L), dtype=np.float32)
            np.tanh(z[:half], out=z_tanh)
            z_sig = bufs["z_act"][half:half * 2, :L] if bufs else np.empty((half, L), dtype=np.float32)
            _sigmoid_inplace(z[half:], z_sig)
            z_act_buf = bufs["z_act2"][:half, :L] if bufs else np.empty((half, L), dtype=np.float32)
            np.multiply(z_tanh, z_sig, out=z_act_buf)
            z_act = z_act_buf
        else:
            act = self.activation_fn
            if act is np.tanh:
                z_act = bufs["z_act"][:self.bottleneck, :L] if bufs else np.empty_like(z)
                np.tanh(z, out=z_act)
            else:
                z_act = act(z)

        if self.has_layer1x1:
            lo_buf = bufs["layer_out"] if bufs else None
            layer_out = _conv1x1(z_act, self.l1x1_w, self.l1x1_b, out=lo_buf)
        else:
            layer_out = z_act
        if self.has_head1x1:
            ho_buf = bufs["head_out"] if bufs else None
            head_out = _conv1x1(z_act, self.h1x1_w, self.h1x1_b, out=ho_buf)[:, -out_length:]
        else:
            head_out = z_act[:, -out_length:]

        # residual = x[:, -L:] + layer_out — in-place into residual buffer
        lo_len = layer_out.shape[1]
        res_buf = bufs["residual"] if bufs else None
        if res_buf is not None and res_buf.shape[0] >= self.channels and res_buf.shape[1] >= lo_len:
            residual = res_buf[:self.channels, :lo_len]
            np.add(x[:, -lo_len:], layer_out, out=residual)
        else:
            residual = x[:, -lo_len:] + layer_out
        return residual, head_out


def _check_unsupported_layer_features(config):
    """Hard-error on active 0.6.0+ features outside the supported A2 subset."""
    gating_mode = config.get("gating_mode")
    if gating_mode is not None:
        modes = gating_mode if isinstance(gating_mode, list) else [gating_mode]
        for m in modes:
            if m != "none":
                raise ValueError(f'Unsupported NAM feature: gating_mode "{m}"')
    secondary = config.get("secondary_activation")
    if secondary is not None:
        entries = secondary if isinstance(secondary, list) else [secondary]
        for s in entries:
            if s is not None:
                raise ValueError("Unsupported NAM feature: secondary_activation")
    for key in (
        "conv_pre_film", "conv_post_film",
        "input_mixin_pre_film", "input_mixin_post_film",
        "activation_pre_film", "activation_post_film",
        "layer1x1_post_film", "head1x1_post_film",
    ):
        film = config.get(key)
        if isinstance(film, dict) and film.get("active", False):
            raise ValueError(f"Unsupported NAM feature: {key} is active (FiLM conditioning)")
    if config.get("slimmable") is not None:
        raise ValueError("Unsupported NAM feature: slimmable (channel-sliced WaveNet)")
    for key in ("groups_input", "groups_input_mixin"):
        if config.get(key, 1) != 1:
            raise ValueError(f"Unsupported NAM feature: {key} = {config[key]} (grouped convolutions)")
    for key in ("layer1x1", "head1x1"):
        sub = config.get(key)
        if isinstance(sub, dict) and sub.get("groups", 1) != 1:
            raise ValueError(f"Unsupported NAM feature: groups = {sub['groups']} (grouped convolutions)")


class _WaveNetLayerArray:
    def __init__(self, config, reader):
        _check_unsupported_layer_features(config)

        input_size = config["input_size"]
        condition_size = config["condition_size"]
        channels = config["channels"]
        dilations = config["dilations"]
        gated = config.get("gated", False)

        bottleneck = config.get("bottleneck")
        if bottleneck is None:
            bottleneck = channels
        l1x1_cfg = config.get("layer1x1", None)
        h1x1_cfg = config.get("head1x1", None)
        has_layer1x1 = l1x1_cfg.get("active", True) if isinstance(l1x1_cfg, dict) else True
        has_head1x1 = h1x1_cfg.get("active", False) if isinstance(h1x1_cfg, dict) else False
        head1x1_out = h1x1_cfg.get("out_channels", 1) if isinstance(h1x1_cfg, dict) else 1
        if not has_layer1x1 and bottleneck != channels:
            raise ValueError(
                f"NAM WaveNet config invalid: bottleneck ({bottleneck}) must equal "
                f"channels ({channels}) when layer1x1 is inactive"
            )

        # Per-layer kernel sizes: new-format array, or legacy scalar replicated.
        kernel_sizes = config.get("kernel_sizes")
        if kernel_sizes is None:
            kernel_sizes = [config.get("kernel_size", 3)] * len(dilations)
        elif not isinstance(kernel_sizes, list):
            kernel_sizes = [kernel_sizes] * len(dilations)
        elif len(kernel_sizes) != len(dilations):
            raise ValueError(
                f"NAM WaveNet config invalid: kernel_sizes has {len(kernel_sizes)} "
                f"entries but dilations has {len(dilations)}"
            )

        # Per-layer activations: new-format array of strings/objects, or a
        # single value replicated.
        activation = config.get("activation", "Tanh")
        if isinstance(activation, list):
            if len(activation) != len(dilations):
                raise ValueError(
                    f"NAM WaveNet config invalid: activation has {len(activation)} "
                    f"entries but dilations has {len(dilations)}"
                )
            activation_fns = [_resolve_activation(a) for a in activation]
        else:
            activation_fns = [_resolve_activation(activation)] * len(dilations)

        # Head rechannel conv: nested `head` object (0.6.0+, explicit kernel) or
        # legacy head_size/head_bias (implicit kernel 1).
        head_cfg = config.get("head")
        if isinstance(head_cfg, dict):
            head_size = head_cfg.get("out_channels", 1)
            head_kernel = head_cfg.get("kernel_size", 1)
            head_bias = head_cfg.get("bias", False)
        else:
            head_size = config["head_size"]
            head_kernel = 1
            head_bias = config.get("head_bias", False)

        self.channels = channels
        self.gated = gated
        self.head_kernel = head_kernel
        self.receptive_field = (
            1
            + sum((k - 1) * d for k, d in zip(kernel_sizes, dilations))
            + (head_kernel - 1)
        )
        self.rechannel_w, _ = reader.read_conv1x1(channels, input_size, has_bias=False)
        self.layers = []
        for i, dil in enumerate(dilations):
            layer = _WaveNetLayer(
                channels=channels, condition_size=condition_size,
                kernel_size=kernel_sizes[i], dilation=dil,
                activation_fn=activation_fns[i], gated=gated, reader=reader,
                bottleneck=bottleneck,
                has_layer1x1=has_layer1x1, has_head1x1=has_head1x1,
                head1x1_out=head1x1_out,
            )
            self.layers.append(layer)
        skip_ch = head1x1_out if has_head1x1 else bottleneck
        # Conv1D with head_kernel taps; legacy kernel-1 files reduce to the old
        # conv1x1 exactly.
        self.head_rechannel_w, self.head_rechannel_b = reader.read_conv1d(
            head_size, skip_ch, head_kernel, has_bias=head_bias
        )
        self._skip_ch = skip_ch
        # Pre-allocate scratch buffer for conv1d im2col (worst case across
        # layers, plus the head conv)
        max_k = max(kernel_sizes)
        mid_ch = 2 * bottleneck if gated else bottleneck
        self._scratch_rows = max(channels * max_k, mid_ch * max_k, skip_ch * head_kernel)
        self._scratch = None  # lazily allocated on first forward(), reused thereafter
        # Pre-allocated work buffers for layer forward passes (lazily sized)
        self._bufs = None
        self._bufs_cols = 0
        self._mid_ch = mid_ch
        self._head1x1_out = head1x1_out

    def _ensure_bufs(self, max_cols):
        """Lazily allocate or grow work buffers for layer forward passes."""
        if self._bufs is not None and self._bufs_cols >= max_cols:
            return
        ch = self.channels
        mid = self._mid_ch
        ho = self._head1x1_out
        self._bufs = {
            "conv_out": np.empty((mid, max_cols), dtype=np.float32),
            "z_mix": np.empty((mid, max_cols), dtype=np.float32),
            "z_act": np.empty((mid, max_cols), dtype=np.float32),
            "z_act2": np.empty((max(ch, mid), max_cols), dtype=np.float32),
            "layer_out": np.empty((ch, max_cols), dtype=np.float32),
            "head_out": np.empty((ho, max_cols), dtype=np.float32),
            "residual": np.empty((ch, max_cols), dtype=np.float32),
            "head_acc": np.empty((max(ho, ch, self._skip_ch), max_cols), dtype=np.float32),
        }
        self._bufs_cols = max_cols

    def forward(self, x, condition, head_input=None, max_frames=0):
        out_length = min(x.shape[1], condition.shape[1]) - (self.receptive_field - 1)
        if out_length <= 0:
            raise ValueError(f"Input too short: need > {self.receptive_field - 1} samples")
        # The per-layer head terms accumulate at the conv stack's output length;
        # the head conv (kernel ≥ 1) then shrinks it to out_length.
        head_target = out_length + (self.head_kernel - 1)
        # Reuse scratch buffer across calls; only reallocate if buffer size grew
        scratch_cols = out_length + self.receptive_field
        if self._scratch is None or self._scratch.shape[1] < scratch_cols:
            self._scratch = np.zeros((self._scratch_rows, scratch_cols), dtype=np.float32)
        scratch = self._scratch
        # Ensure work buffers are large enough
        self._ensure_bufs(scratch_cols)
        bufs = self._bufs
        x = _conv1x1(x, self.rechannel_w)
        for layer in self.layers:
            x, head_term = layer.forward(x, condition, head_target, scratch=scratch, bufs=bufs)
            ha = bufs["head_acc"]
            ht_cols = head_term.shape[1]
            ht_rows = head_term.shape[0]
            if head_input is None:
                # Copy into stable head_acc buffer — head_term is a view into bufs["z_act"]
                # which gets overwritten on the next layer iteration.
                ha[:ht_rows, :ht_cols] = head_term
                head_input = ha[:ht_rows, :ht_cols]
            else:
                # In-place accumulation into head_acc buffer
                np.add(head_input[:, -ht_cols:], head_term, out=ha[:ht_rows, :ht_cols])
                head_input = ha[:ht_rows, :ht_cols]
        head_output = _conv1d(
            head_input, self.head_rechannel_w, self.head_rechannel_b,
            dilation=1, scratch=scratch,
        )
        return head_output, x


class _WaveNetModel:
    def __init__(self, config, reader):
        self.condition_dsp = None
        if config.get("condition_dsp"):
            cond_cfg = config["condition_dsp"]
            cond_reader = _WeightReader(cond_cfg["weights"]) if "weights" in cond_cfg else reader
            self.condition_dsp = _WaveNetModel(
                cond_cfg["config"] if "config" in cond_cfg else cond_cfg, cond_reader
            )
        self.layer_arrays = []
        for la_config in config["layers"]:
            self.layer_arrays.append(_WaveNetLayerArray(la_config, reader))
        self.head_layers = None
        head_cfg = config.get("head")
        if head_cfg is not None:
            self.head_layers = []
            default_in = self.layer_arrays[-1].head_rechannel_w.shape[0]
            in_ch = head_cfg.get("in_channels", default_in)
            ch = head_cfg["channels"]
            out_ch = head_cfg.get("out_channels", 1)
            n_layers = head_cfg["num_layers"]
            act = _resolve_activation(head_cfg.get("activation"), default="ReLU")
            for i in range(n_layers):
                o = out_ch if i == n_layers - 1 else ch
                c = in_ch if i == 0 else ch
                w, b = reader.read_conv1x1(o, c, has_bias=True)
                self.head_layers.append((act, w, b))
        # Strict tail check: the trainer appends exactly one trailing weight
        # (head_scale).  Anything else left over means the weight-read order
        # diverged from the file — fail loudly rather than play garbage.
        remaining = reader.remaining
        if remaining == 1:
            self.head_scale = reader.read(1)[0]
        elif remaining == 0:
            self.head_scale = config.get("head_scale", 1.0)
        else:
            raise ValueError(
                f"NAM WaveNet weight mismatch: {remaining} unconsumed weights after "
                f"loading all layers — weight-order mismatch between file and parser"
            )
        self.receptive_field = 1
        for la in self.layer_arrays:
            self.receptive_field += la.receptive_field - 1

    def process(self, audio):
        x = audio[np.newaxis, :]
        condition = self.condition_dsp._process_2d(x) if self.condition_dsp else x
        head_input = None
        y = x
        for la in self.layer_arrays:
            head_input, y = la.forward(y, condition, head_input)
        result = self.head_scale * head_input
        if self.head_layers:
            for act, w, b in self.head_layers:
                result = _conv1x1(act(result), w, b)
        return result[0]

    def _process_2d(self, x):
        condition = self.condition_dsp._process_2d(x) if self.condition_dsp else x
        head_input = None
        y = x
        for la in self.layer_arrays:
            head_input, y = la.forward(y, condition, head_input)
        return self.head_scale * head_input


# ---------------------------------------------------------------------------
# NamModel — public wrapper with per-channel state + sliding window
# ---------------------------------------------------------------------------


class NamModel:
    """A loaded NAM model that processes audio buffers.

    Use :func:`load_model` to create instances.

    Attributes:
        architecture: ``"WaveNet"`` or ``"LSTM"`` after loading.  A2 tones
            (``SlimmableContainer`` files) load their highest-quality packed
            submodel (A2-Full) and report as ``"WaveNet"``.
        receptive_field: Number of samples the model needs as context.
            For LSTM this is 1.  For an A1 WaveNet-standard it is typically
            4093; for A2 it is 6347.
        sample_rate: The sample rate the model was trained at (usually 48000).
    """

    def __init__(self, model, architecture: str, sample_rate: int):
        self._model = model
        self.architecture = architecture
        self.receptive_field = model.receptive_field
        self.sample_rate = sample_rate
        self._history: list[np.ndarray | None] = []
        self._warned_sr = False
        # Per-channel LSTM state: each channel needs independent cells
        self._lstm_channels: list[_LSTMModel | None] = []
        # Pre-allocated buffers for WaveNet (per-channel, lazily sized)
        self._full_input: list[np.ndarray | None] = []

    def process(self, audio: np.ndarray, channel: int) -> np.ndarray:
        """Process a mono audio buffer through the NAM model.

        Args:
            audio: 1-D float32 array of input samples for one channel.
            channel: Channel index (0 = left, 1 = right).  Each channel
                maintains independent state (history / hidden state).

        Returns:
            1-D float32 array of the same length as *audio*.
        """
        n = len(audio)
        if n == 0:
            return audio.copy()

        if self.architecture == "WaveNet":
            return self._process_wavenet(audio, channel)
        else:
            return self._process_lstm(audio, channel)

    def _process_wavenet(self, audio: np.ndarray, channel: int) -> np.ndarray:
        # Grow per-channel lists if needed
        while len(self._history) <= channel:
            self._history.append(None)
        while len(self._full_input) <= channel:
            self._full_input.append(None)

        rf = self.receptive_field
        hist = self._history[channel]
        n = len(audio)
        total_len = (rf - 1) + n

        if hist is None:
            hist = np.zeros(rf - 1, dtype=np.float32)

        # Reuse pre-allocated full_input buffer; only reallocate if size grew
        buf = self._full_input[channel]
        if buf is None or len(buf) < total_len:
            buf = np.empty(total_len, dtype=np.float32)
            self._full_input[channel] = buf
        fi = buf[:total_len]
        fi[: rf - 1] = hist
        fi[rf - 1 :] = audio

        raw_output = self._model.process(fi)

        output = raw_output[-n:]

        # Update history in-place (copy last rf-1 samples into existing hist)
        if self._history[channel] is None or len(self._history[channel]) != rf - 1:
            self._history[channel] = np.empty(rf - 1, dtype=np.float32)
        self._history[channel][:] = fi[-(rf - 1) :]

        return output.astype(np.float32)

    def _process_lstm(self, audio: np.ndarray, channel: int) -> np.ndarray:
        # Each channel needs independent LSTM state.
        # Channel 0 uses self._model directly.
        # Additional channels get deep-copied models.
        while len(self._lstm_channels) <= channel:
            self._lstm_channels.append(None)

        if channel == 0:
            return self._model.process(audio)

        if self._lstm_channels[channel] is None:
            import copy
            self._lstm_channels[channel] = copy.deepcopy(self._model)

        return self._lstm_channels[channel].process(audio)

    def reset(self):
        """Clear all per-channel state (history buffers, LSTM hidden state)."""
        self._history = []
        self._full_input = []
        if self.architecture == "LSTM":
            self._model.reset()
            for ch_model in self._lstm_channels:
                if ch_model is not None:
                    ch_model.reset()
            self._lstm_channels = []

    def _check_sample_rate(self, daw_sr: float):
        if not self._warned_sr and self.sample_rate and daw_sr != self.sample_rate:
            print(
                f"Warning: NAM model trained at {self.sample_rate}Hz "
                f"but running at {int(daw_sr)}Hz — output may sound wrong",
                file=sys.stderr,
            )
            self._warned_sr = True


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def load_model(path: str) -> NamModel:
    """Load a NAM model from a ``.nam`` file.

    Args:
        path: One of:
            - ``tone3000://tone_id/model_id`` — downloaded tone (resolved via
              ``CONJUREDSP_TONES_DIR`` environment variable)
            - ``~/path/to/model.nam`` — tilde-expanded path
            - ``/absolute/path/to/model.nam`` — absolute path
            - ``relative/path.nam`` — resolved against cwd, then tones dir

    Returns:
        A :class:`NamModel` ready for use in ``process()``.
    """
    resolved = _resolve_path(path)

    with open(resolved) as f:
        data = json.load(f)

    arch = data["architecture"]

    if arch == "SlimmableContainer":
        # NAM A2 packaging: submodels sorted by quality; load the
        # highest-quality one (largest max_value → A2-Full).
        submodels = data.get("config", {}).get("submodels", [])
        if not submodels:
            raise ValueError("SlimmableContainer has no submodels")
        best = max(submodels, key=lambda s: s.get("max_value", 0.0))
        data = best["model"]
        arch = data["architecture"]

    config = data["config"]
    reader = _WeightReader(data["weights"])
    sample_rate = data.get("sample_rate", 48000)

    if arch == "LSTM":
        model = _LSTMModel(config, reader)
    elif arch == "WaveNet":
        model = _WaveNetModel(config, reader)
    else:
        raise ValueError(
            f'Unsupported NAM architecture "{arch}" — ConjureDSP supports '
            f"WaveNet, LSTM, and SlimmableContainer (NAM A2)"
        )

    return NamModel(model, arch, sample_rate)
