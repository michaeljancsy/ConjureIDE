# Plan: Link bundled numpy/scipy to Accelerate instead of OpenBLAS

## Context

`rust/setup-python.sh` installs numpy and scipy via `pip install numpy scipy`, which downloads pre-built PyPI wheels. On macOS arm64, numpy 2.x wheels bundle OpenBLAS. This means all numpy linear algebra ops in user DSP scripts use OpenBLAS rather than Apple's Accelerate framework (vecLib/BLAS/LAPACK). Accelerate is already linked at the Rust level (for the WASM `accel` module) — numpy should use it too for consistency and native Apple Silicon performance.

## Approach

Build numpy (and scipy if gfortran is available) from source during `setup-python.sh`, passing meson flags to select the Accelerate BLAS/LAPACK backend.

## Critical File

- `rust/setup-python.sh` — the only file that needs to change

## Changes

Replace:
```bash
"${PYTHON_DIR}/bin/python3" -m pip install --upgrade pip
"${PYTHON_DIR}/bin/python3" -m pip install numpy scipy
```

With:
```bash
"${PYTHON_DIR}/bin/python3" -m pip install --upgrade pip

echo "Installing numpy/scipy build tools..."
"${PYTHON_DIR}/bin/python3" -m pip install meson-python meson ninja cython

echo "Building numpy against Accelerate..."
"${PYTHON_DIR}/bin/python3" -m pip install numpy --no-binary=numpy \
  -Csetup-args=-Dblas=accelerate \
  -Csetup-args=-Dlapack=accelerate

echo "Building scipy against Accelerate..."
if command -v gfortran &>/dev/null; then
    "${PYTHON_DIR}/bin/python3" -m pip install scipy --no-binary=scipy \
      -Csetup-args=-Dblas=accelerate \
      -Csetup-args=-Dlapack=accelerate
else
    echo "gfortran not found — installing scipy from pre-built wheel (uses OpenBLAS)"
    echo "Install gfortran via Homebrew (brew install gcc) and re-run setup-python.sh to get Accelerate-linked scipy."
    "${PYTHON_DIR}/bin/python3" -m pip install scipy
fi
```

## Notes

- `meson-python`, `meson`, `ninja`, `cython` are pure-Python or have 3.14t wheels — safe for the bundled free-threaded Python
- numpy's meson build handles `-Dblas=accelerate` on macOS by passing `-framework Accelerate` — no pkg-config file needed for Accelerate
- scipy requires gfortran for its Fortran extensions; the fallback keeps the existing behavior so the script never hard-fails on machines without gfortran
- Build tools (`meson-python`, `ninja`, `cython`) remain in site-packages after setup — they're small and harmless
- The shared runtime provisioned by `ConjureDSPTerminal` is a copy of this same `python-dist/`, so Accelerate linkage flows through automatically with no other changes needed

## Verification

After running `cd rust && ./setup-python.sh` (after deleting the existing `python-dist/`):

```bash
# Confirm numpy is linked to Accelerate, not OpenBLAS
rust/python-dist/bin/python3 -c "import numpy; numpy.show_config()"
# Should show "blas_opt_info" with "Accelerate" or "vecLib", not "openblas"

# Confirm scipy if built from source
rust/python-dist/bin/python3 -c "import scipy; scipy.show_config()"

# Quick functional check
rust/python-dist/bin/python3 -c "import numpy as np; a = np.random.randn(100,100); print(np.linalg.eigh(a)[0][:3])"
```
