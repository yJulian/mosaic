"""numpy reference model: what the hardware is supposed to compute.
Used both by hardware bring-up (cli.py's `verify`/`run` commands) and by
the VHDL testbenches' golden vectors, so hardware and simulation are
checked against the exact same definition of "correct"."""
from __future__ import annotations

import numpy as np

from . import protocol as proto


def matmul_int8(a, w) -> np.ndarray:
    """int8 x int8 -> int32 matmul, no saturation (matches the hardware:
    PEs accumulate in a 32-bit register with no overflow clamping).
    Not restricted to 6x6 -- only requires K-compatible shapes -- so this
    also serves as the golden model for tiled matmuls (see tiling.py)."""
    a = np.asarray(a, dtype=np.int64)
    w = np.asarray(w, dtype=np.int64)
    if a.shape[1] != w.shape[0]:
        raise ValueError(f"K mismatch: a is {a.shape}, w is {w.shape}")
    return a @ w


def random_int8_matrix(rng: np.random.Generator | None = None) -> np.ndarray:
    rng = rng or np.random.default_rng()
    return rng.integers(-128, 128, size=(proto.ARRAY_ROWS, proto.ARRAY_COLS), dtype=np.int32)
