"""numpy reference model: what the hardware is supposed to compute.
Used both by hardware bring-up (cli.py's `verify`/`run` commands) and by
the VHDL testbenches' golden vectors, so hardware and simulation are
checked against the exact same definition of "correct"."""
from __future__ import annotations

import numpy as np

from . import protocol as proto


def matmul_int8(a, w) -> np.ndarray:
    """int8 x int8 -> int32 matmul, no saturation (matches the hardware:
    PEs accumulate in a 32-bit register with no overflow clamping)."""
    a = np.asarray(a, dtype=np.int32)
    w = np.asarray(w, dtype=np.int32)
    if a.shape != (proto.ARRAY_ROWS, proto.ARRAY_COLS) or w.shape != (proto.ARRAY_ROWS, proto.ARRAY_COLS):
        raise ValueError(f"expected {proto.ARRAY_ROWS}x{proto.ARRAY_COLS} matrices")
    return a @ w


def random_int8_matrix(rng: np.random.Generator | None = None) -> np.ndarray:
    rng = rng or np.random.default_rng()
    return rng.integers(-128, 128, size=(proto.ARRAY_ROWS, proto.ARRAY_COLS), dtype=np.int32)
