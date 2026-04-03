"""Generate Python NAM reference output for parity testing with Rust."""
import sys, os, json, math

# Add conjuredsp to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'conjuredsp'))
from nam import load_model

def main():
    nam_path = sys.argv[1]
    num_samples = int(sys.argv[2])
    sample_rate = float(sys.argv[3])

    model = load_model(nam_path)

    # Generate 440Hz sine wave (same as Rust test)
    audio = [math.sin(2.0 * math.pi * 440.0 * i / sample_rate) * 0.5
             for i in range(num_samples)]

    import numpy as np
    audio_np = np.array(audio, dtype=np.float32)

    # Process two consecutive buffers (channel 0)
    out1 = model.process(audio_np, 0)
    out2 = model.process(audio_np, 0)

    result = {
        "output1": [float(x) for x in out1],
        "output2": [float(x) for x in out2],
    }
    print(json.dumps(result))

if __name__ == "__main__":
    main()
