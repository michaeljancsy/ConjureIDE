"""Hardware-accelerated vectorized math operations.

Thin wrappers around NumPy for API symmetry with the Rust ``conjuredsp::accel``
module.  On macOS, NumPy's BLAS backend is Apple Accelerate, so these calls
map to the same AMX/NEON-optimised routines that the Rust/WASM host imports use.

Example::

    from conjuredsp.accel import matmul, vec_tanh

    c = matmul(a, b)           # vDSP_mmul under the hood
    y = vec_tanh(x)            # vvtanhf under the hood
"""

import numpy as np


def matmul(a, b, out=None):
    """Matrix multiply: ``out = a @ b``.

    Parameters match ``numpy.matmul``.  *a* and *b* can be any array-like;
    *out* is an optional pre-allocated output array.
    """
    return np.matmul(a, b, out=out)


def vec_add(a, b, out=None):
    """Element-wise addition: ``out[i] = a[i] + b[i]``."""
    return np.add(a, b, out=out)


def vec_mul(a, b, out=None):
    """Element-wise multiplication: ``out[i] = a[i] * b[i]``."""
    return np.multiply(a, b, out=out)


def vec_tanh(x, out=None):
    """Element-wise tanh: ``out[i] = tanh(x[i])``."""
    return np.tanh(x, out=out)


def vec_sigmoid(x, out=None):
    """Element-wise sigmoid: ``out[i] = 1 / (1 + exp(-x[i]))``."""
    clipped = np.clip(x, -88, 88)
    exp_neg = np.exp(-clipped)
    return np.divide(1.0, np.add(1.0, exp_neg), out=out)


def vec_add_scalar(x, scalar, out=None):
    """Add scalar to each element: ``out[i] = x[i] + scalar``."""
    return np.add(x, scalar, out=out)
