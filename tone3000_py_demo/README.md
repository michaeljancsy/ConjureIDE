# NAM inference demo (pure Python + NumPy)

A feasibility study for running Neural Amp Modeler (NAM) inference in pure
Python/NumPy — no PyTorch — fast enough for real-time audio. The findings
informed the production implementations in `rust/conjuredsp/nam.py` and
`rust/conjuredsp-rs/src/nam.rs`.

## Model file provenance

The three `.nam` files here are the example models from Steven Atkinson's
MIT-licensed [NeuralAmpModelerCore](https://github.com/sdatkinson/NeuralAmpModelerCore)
project, redistributed under that license:

- `lstm_tiny.nam` — LSTM, 3 hidden units, 1 layer
- `wavenet_tiny.nam` — WaveNet, 2 layer arrays, small channels
- `wavenet_standard.nam` — WaveNet, 2 layer arrays, 16/8 channels

They are test fixtures, not amp captures of any commercial hardware.
