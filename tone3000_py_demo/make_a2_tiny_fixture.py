#!/usr/bin/env python3
"""Generate a2_tiny.nam — a small A2-shaped SlimmableContainer fixture for tests.

Layout matches the NAM 0.7.0 trainer export exactly (see NeuralAmpModelerCore
NAM/wavenet/a2_fast.cpp weight-order comment):

  per layer array:
    _rechannel      Conv1x1 input_size -> channels, no bias
    per layer:
      _conv         Conv1D  channels -> bottleneck (K taps), with bias
      _input_mixin  Conv1x1 condition_size -> bottleneck, no bias
      _layer1x1     Conv1x1 bottleneck -> channels, WITH bias
    _head_rechannel Conv1D  bottleneck -> head.out_channels (head.kernel_size taps), bias per head.bias
  trailing float = head_scale override

Conv1D read order: for out_ch { for in_ch { for tap } }; Conv1x1: for out_ch { for in_ch }.

The Lite submodel (max_value 0.5) has all-zero weights so tests can prove the
loader selects the Full submodel (max_value 1.0), whose seeded weights produce
non-silent output.
"""

import json
import random
from pathlib import Path

CHANNELS = 2
BOTTLENECK = 2
INPUT_SIZE = 1
CONDITION_SIZE = 1
KERNEL_SIZES = [3, 3, 5]
DILATIONS = [1, 3, 9]
HEAD = {"out_channels": 1, "kernel_size": 4, "bias": True}
HEAD_SCALE = 0.01  # overridden by the trailing weight below
SAMPLE_RATE = 48000

FILM_INACTIVE = {"active": False, "shift": True, "groups": 1}


def layer_array_config():
    n = len(DILATIONS)
    return {
        "input_size": INPUT_SIZE,
        "condition_size": CONDITION_SIZE,
        "channels": CHANNELS,
        "bottleneck": BOTTLENECK,
        "kernel_sizes": KERNEL_SIZES,
        "dilations": DILATIONS,
        "activation": [{"type": "LeakyReLU", "negative_slope": 0.01}] * n,
        "gating_mode": ["none"] * n,
        "secondary_activation": [None] * n,
        "layer1x1": {"active": True, "groups": 1},
        "head1x1": {"active": False, "out_channels": 1, "groups": 1},
        "head": HEAD,
        "groups_input": 1,
        "groups_input_mixin": 1,
        "conv_pre_film": FILM_INACTIVE,
        "conv_post_film": FILM_INACTIVE,
        "input_mixin_pre_film": FILM_INACTIVE,
        "input_mixin_post_film": FILM_INACTIVE,
        "activation_pre_film": FILM_INACTIVE,
        "activation_post_film": FILM_INACTIVE,
        "layer1x1_post_film": FILM_INACTIVE,
        "head1x1_post_film": FILM_INACTIVE,
        "slimmable": None,
    }


def weight_count():
    total = CHANNELS * INPUT_SIZE  # _rechannel
    for k in KERNEL_SIZES:
        total += BOTTLENECK * CHANNELS * k + BOTTLENECK      # _conv w + b
        total += BOTTLENECK * CONDITION_SIZE                 # _input_mixin
        total += CHANNELS * BOTTLENECK + CHANNELS            # _layer1x1 w + b
    total += HEAD["out_channels"] * BOTTLENECK * HEAD["kernel_size"]  # _head_rechannel w
    if HEAD["bias"]:
        total += HEAD["out_channels"]
    total += 1  # trailing head_scale
    return total


def submodel(weights, name):
    return {
        "version": "0.7.0",
        "architecture": "WaveNet",
        "metadata": {"name": name},
        "config": {
            "layers": [layer_array_config()],
            "head": None,
            "head_scale": HEAD_SCALE,
        },
        "weights": weights,
        "sample_rate": SAMPLE_RATE,
    }


def main():
    n = weight_count()
    rng = random.Random(20260716)
    # Small weights keep the 3-layer net stable; trailing head_scale = 0.5.
    full_weights = [round(rng.uniform(-0.3, 0.3), 6) for _ in range(n - 1)] + [0.5]
    lite_weights = [0.0] * n

    doc = {
        "version": "0.7.0",
        "architecture": "SlimmableContainer",
        # Escaped quote exercises the JSON string scanner's escape handling.
        "metadata": {"name": "tiny \"a2\" fixture", "generator": "make_a2_tiny_fixture.py"},
        "config": {
            "submodels": [
                {"max_value": 0.5, "model": submodel(lite_weights, "a2-tiny-lite (silent)")},
                {"max_value": 1.0, "model": submodel(full_weights, "a2-tiny-full")},
            ]
        },
        "weights": [],
        "sample_rate": float(SAMPLE_RATE),
    }

    out = Path(__file__).parent / "a2_tiny.nam"
    out.write_text(json.dumps(doc, indent=1))
    print(f"wrote {out} ({n} weights per submodel)")


if __name__ == "__main__":
    main()
