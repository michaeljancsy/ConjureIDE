"""Hardware-accelerated vectorized math operations.

Thin wrappers around NumPy for API symmetry with the Rust ``conjuredsp::accel``
module.  On macOS, NumPy's BLAS backend is Apple Accelerate, so these calls
map to the same AMX/NEON-optimised routines that the Rust/WASM host imports use.

All functions require a pre-allocated ``out`` buffer to avoid per-call memory
allocation.  This is critical for real-time audio where allocation causes memory
growth (macOS magazine allocator retains pages).

Example::

    from conjuredsp.accel import matmul, vec_tanh
    import numpy as np

    a = np.array([[1, 2], [3, 4]], dtype=np.float32)
    b = np.array([[5, 6], [7, 8]], dtype=np.float32)
    c = np.empty((2, 2), dtype=np.float32)
    matmul(a, b, c)  # c = [[19, 22], [43, 50]]

    x = np.array([0.0, 1.0, -1.0], dtype=np.float32)
    y = np.empty_like(x)
    vec_tanh(x, y)   # y = [0.0, 0.7616, -0.7616]
"""

import numpy as np


def matmul(a, b, out):
    """Matrix multiply: ``out = a @ b``.

    Parameters match ``numpy.matmul``.  *a* and *b* can be any array-like;
    *out* must be a pre-allocated output array of the correct shape.
    """
    return np.matmul(a, b, out=out)


def vec_add(a, b, out):
    """Element-wise addition: ``out[i] = a[i] + b[i]``."""
    return np.add(a, b, out=out)


def vec_mul(a, b, out):
    """Element-wise multiplication: ``out[i] = a[i] * b[i]``."""
    return np.multiply(a, b, out=out)


def vec_tanh(x, out):
    """Element-wise tanh: ``out[i] = tanh(x[i])``."""
    return np.tanh(x, out=out)


def vec_sigmoid(x, out):
    """Element-wise sigmoid: ``out[i] = 1 / (1 + exp(-x[i]))``."""
    np.negative(x, out=out)
    np.clip(out, -88, 88, out=out)
    np.exp(out, out=out)
    out += 1.0
    np.reciprocal(out, out=out)
    return out


def vec_add_scalar(x, scalar, out):
    """Add scalar to each element: ``out[i] = x[i] + scalar``."""
    return np.add(x, scalar, out=out)
