"""Host-side blocked matrix multiplication for matrices larger than the
hardware's fixed 6x6 tile.

The array has no cross-invocation accumulator (every START_COMPUTE is a
fresh, independent partial product -- see docs/architecture.md/array_ctrl.vhd),
so accumulating across the contraction (K) dimension for anything bigger
than one tile has to happen here, in software. compute_tile is injected
so this module's tiling/padding/accumulation math can be unit-tested with
a numpy-only fake, independent of real hardware (see link.py for the
hardware-backed compute_tile used by the CLI).
"""
from __future__ import annotations

import math
from typing import Callable

import numpy as np

from . import protocol as proto

ComputeTile = Callable[[np.ndarray, np.ndarray], object]


def _ceil_tiles(n: int, tile: int) -> int:
    return math.ceil(n / tile)


def _pad_to_tiles(m: np.ndarray, tile: int) -> np.ndarray:
    rows, cols = m.shape
    padded_rows = _ceil_tiles(rows, tile) * tile
    padded_cols = _ceil_tiles(cols, tile) * tile
    if padded_rows == rows and padded_cols == cols:
        return m
    out = np.zeros((padded_rows, padded_cols), dtype=m.dtype)
    out[:rows, :cols] = m
    return out


def _validate_int8_range(name: str, arr: np.ndarray) -> None:
    if arr.size and (arr.min() < -128 or arr.max() > 127):
        raise ValueError(f"{name}: values out of int8 range (-128..127)")


def tiled_matmul(
    compute_tile: ComputeTile,
    activations: np.ndarray,
    weights: np.ndarray,
    tile: int = proto.ARRAY_ROWS,
) -> np.ndarray:
    """C = activations @ weights, computed as tile x tile hardware calls.

    activations: (M, K) int8, weights: (K, N) int8. Returns (M, N) int64.

    compute_tile(weight_tile, activation_tile) -> result_tile -- this
    argument order matches SystolicArrayDriver.run(weights, activations,
    mode); don't flip it. tile only ever needs to be proto.ARRAY_ROWS
    against real hardware -- anything else desyncs read_result's hardcoded
    RESULT_BYTES and matrix_to_bytes's emitted byte count. It's a
    parameter purely so this function's tiling math can be exercised with
    small fake matrices in tests.
    """
    activations = np.asarray(activations)
    weights = np.asarray(weights)
    _validate_int8_range("activations", activations)
    _validate_int8_range("weights", weights)
    if activations.shape[1] != weights.shape[0]:
        raise ValueError(
            f"K mismatch: activations is {activations.shape}, weights is {weights.shape}"
        )

    m, k = activations.shape
    _, n = weights.shape
    m_tiles = _ceil_tiles(m, tile)
    k_tiles = _ceil_tiles(k, tile)
    n_tiles = _ceil_tiles(n, tile)

    a_padded = _pad_to_tiles(activations, tile)
    w_padded = _pad_to_tiles(weights, tile)

    result = np.zeros((m_tiles * tile, n_tiles * tile), dtype=np.int64)
    for i in range(m_tiles):
        for j in range(n_tiles):
            acc = np.zeros((tile, tile), dtype=np.int64)
            for kk in range(k_tiles):
                a_tile = a_padded[i * tile:(i + 1) * tile, kk * tile:(kk + 1) * tile]
                w_tile = w_padded[kk * tile:(kk + 1) * tile, j * tile:(j + 1) * tile]
                partial = compute_tile(w_tile, a_tile)  # matches driver.run(weights, activations, mode) arg order
                acc += np.asarray(partial, dtype=np.int64)
            result[i * tile:(i + 1) * tile, j * tile:(j + 1) * tile] = acc

    return result[:m, :n]
