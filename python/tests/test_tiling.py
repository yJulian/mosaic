"""Host-only tiling tests (no hardware needed): tiled_matmul is exercised
with a numpy-matmul-based fake compute_tile and checked against
goldenmodel.matmul_int8 on the full, untiled matrices."""
import numpy as np
import pytest

from fpga_systolic import tiling
from fpga_systolic.goldenmodel import matmul_int8


def _fake_compute_tile_counting(calls: list):
    def compute_tile(w_tile, a_tile):
        calls.append((np.array(w_tile), np.array(a_tile)))
        return matmul_int8(a_tile, w_tile)

    return compute_tile


def _random_matrix(rng, rows, cols):
    return rng.integers(-128, 128, size=(rows, cols), dtype=np.int64)


@pytest.mark.parametrize(
    "m,k,n,seed",
    [
        (6, 6, 6, 0),      # exact single tile
        (12, 6, 18, 1),    # exact multiples, >1 tile per axis
        (7, 6, 6, 2),      # M not a multiple of 6
        (6, 5, 6, 3),      # K not a multiple of 6
        (6, 6, 8, 4),      # N not a multiple of 6
        (3, 4, 5, 5),      # every axis smaller than one tile
        (13, 9, 11, 6),    # non-multiples on every axis at once
    ],
)
def test_tiled_matmul_matches_golden_model(m, k, n, seed):
    rng = np.random.default_rng(seed)
    a = _random_matrix(rng, m, k)
    w = _random_matrix(rng, k, n)

    calls: list = []
    result = tiling.tiled_matmul(_fake_compute_tile_counting(calls), a, w)

    assert result.shape == (m, n)
    np.testing.assert_array_equal(result, matmul_int8(a, w))


@pytest.mark.parametrize(
    "m,k,n,expected_calls",
    [
        (6, 6, 6, 1),
        (12, 6, 18, 2 * 1 * 3),
        (7, 6, 6, 2 * 1 * 1),   # M rounds up to 2 tiles
        (13, 9, 11, 3 * 2 * 2),  # 13->3, 9->2, 11->2 tiles
    ],
)
def test_tiled_matmul_calls_compute_tile_exactly_mt_kt_nt_times(m, k, n, expected_calls):
    rng = np.random.default_rng(0)
    a = _random_matrix(rng, m, k)
    w = _random_matrix(rng, k, n)

    calls: list = []
    tiling.tiled_matmul(_fake_compute_tile_counting(calls), a, w)

    assert len(calls) == expected_calls


def test_tiled_matmul_rejects_k_mismatch():
    rng = np.random.default_rng(0)
    a = _random_matrix(rng, 6, 6)
    w = _random_matrix(rng, 5, 6)
    with pytest.raises(ValueError):
        tiling.tiled_matmul(_fake_compute_tile_counting([]), a, w)


def test_tiled_matmul_rejects_out_of_int8_range():
    a = np.array([[200]], dtype=np.int64)
    w = np.array([[1]], dtype=np.int64)
    with pytest.raises(ValueError):
        tiling.tiled_matmul(_fake_compute_tile_counting([]), a, w)


@pytest.mark.parametrize(
    "rows,cols,tile,expected_shape",
    [
        (6, 6, 6, (6, 6)),
        (7, 6, 6, (12, 6)),
        (1, 1, 6, (6, 6)),
        (13, 9, 6, (18, 12)),
    ],
)
def test_pad_to_tiles_shape(rows, cols, tile, expected_shape):
    m = np.ones((rows, cols), dtype=np.int64)
    padded = tiling._pad_to_tiles(m, tile)
    assert padded.shape == expected_shape
    assert np.array_equal(padded[:rows, :cols], m)
    assert padded.sum() == m.sum()  # padding is all zero


def test_tiled_matmul_with_small_tile_size():
    # exercises the tiling math itself with tile=2, independent of the
    # hardware's fixed 6x6 -- confirms tile is a genuine parameter, not
    # hardcoded anywhere in the loop logic.
    rng = np.random.default_rng(0)
    a = _random_matrix(rng, 5, 3)
    w = _random_matrix(rng, 3, 4)

    calls: list = []
    result = tiling.tiled_matmul(_fake_compute_tile_counting(calls), a, w, tile=2)

    np.testing.assert_array_equal(result, matmul_int8(a, w))
    assert len(calls) == 3 * 2 * 2  # ceil(5/2)*ceil(3/2)*ceil(4/2)
