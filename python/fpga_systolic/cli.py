"""Command-line interface for the systolic array accelerator.

Examples:
  fpga-systolic ping -p /dev/ttyUSB0
  fpga-systolic run -p /dev/ttyUSB0 --mode ws --random --verify
  fpga-systolic run -p /dev/ttyUSB0 --mode os --weights w.npy --activations a.npy
  fpga-systolic tiled-run -p /dev/ttyUSB0 --mode ws --random --m 12 --k 9 --n 6 --verify
  fpga-systolic run-k -p /dev/ttyUSB0 --mode os --random --k 17 --verify
  fpga-systolic status -p /dev/ttyUSB0
  fpga-systolic debug-pe -p /dev/ttyUSB0 --row 2 --col 3
  fpga-systolic monitor -p /dev/ttyUSB0
"""
from __future__ import annotations

import sys

import click
import numpy as np

from . import protocol as proto
from . import tiling
from .goldenmodel import matmul_int8, random_int8_matrix
from .link import DEFAULT_BAUD, DeviceNack, LinkError, SystolicArrayDriver

MODE_CHOICES = {"ws": proto.MODE_WS, "os": proto.MODE_OS}


def _load_array_file(path: str) -> np.ndarray:
    if path.endswith(".npy"):
        m = np.load(path)
    else:
        m = np.loadtxt(path, delimiter=",", dtype=np.int32)
    return m.astype(np.int32)


def _load_matrix(path: str | None, random_: bool, rng: np.random.Generator) -> np.ndarray:
    if path:
        m = _load_array_file(path)
        if m.shape != (proto.ARRAY_ROWS, proto.ARRAY_COLS):
            raise click.ClickException(f"{path}: expected {proto.ARRAY_ROWS}x{proto.ARRAY_COLS}, got {m.shape}")
        return m
    if random_:
        return random_int8_matrix(rng)
    raise click.ClickException("no matrix given: pass --file or --random")


def _load_tiled_matrix(
    path: str | None,
    random_: bool,
    rng: np.random.Generator,
    shape: tuple[int, int] | None,
) -> np.ndarray:
    if path:
        return _load_array_file(path)
    if random_:
        if shape is None:
            raise click.ClickException("--random needs a shape (e.g. --m/--k/--n)")
        return rng.integers(-128, 128, size=shape, dtype=np.int32)
    raise click.ClickException("no matrix given: pass --file or --random")


def _print_matrix(m, label: str) -> None:
    click.echo(f"{label}:")
    for row in m:
        click.echo("  " + " ".join(f"{v:6d}" for v in row))


@click.group()
@click.option("-p", "--port", required=True, help="Serial port, e.g. /dev/ttyUSB0 or COM3")
@click.option("-b", "--baud", default=DEFAULT_BAUD, show_default=True)
@click.option("-t", "--timeout", default=2.0, show_default=True, help="Serial read timeout (s)")
@click.pass_context
def main(ctx: click.Context, port: str, baud: int, timeout: float) -> None:
    ctx.ensure_object(dict)
    ctx.obj["port"] = port
    ctx.obj["baud"] = baud
    ctx.obj["timeout"] = timeout


def _driver(ctx: click.Context) -> SystolicArrayDriver:
    return SystolicArrayDriver(ctx.obj["port"], baud=ctx.obj["baud"], timeout=ctx.obj["timeout"])


@main.command()
@click.pass_context
def ping(ctx: click.Context) -> None:
    """Check the link and print firmware/array info."""
    with _driver(ctx) as d:
        info = d.ping()
        click.echo(f"fw_version={info.fw_version} rows={info.rows} cols={info.cols} dtype={info.dtype}")


@main.command()
@click.pass_context
def status(ctx: click.Context) -> None:
    """Print busy/done status."""
    with _driver(ctx) as d:
        st = d.status()
        click.echo(f"busy={st.busy} done={st.done}")


@main.command()
@click.pass_context
def reset(ctx: click.Context) -> None:
    """Soft-reset the array controller (does not reset the UART link itself)."""
    with _driver(ctx) as d:
        d.reset()
        click.echo("reset OK")


@main.command("load-weights")
@click.option("--file", "path", type=click.Path(exists=True), help="6x6 int8 matrix (.npy or .csv)")
@click.option("--random", "random_", is_flag=True, help="use a random matrix instead")
@click.pass_context
def load_weights(ctx: click.Context, path: str | None, random_: bool) -> None:
    """Write the 6x6 weight matrix into the FPGA's scratchpad."""
    rng = np.random.default_rng()
    m = _load_matrix(path, random_, rng)
    with _driver(ctx) as d:
        d.load_weights(m)
    _print_matrix(m, "loaded weights")


@main.command("load-activations")
@click.option("--file", "path", type=click.Path(exists=True), help="6x6 int8 matrix (.npy or .csv)")
@click.option("--random", "random_", is_flag=True, help="use a random matrix instead")
@click.pass_context
def load_activations(ctx: click.Context, path: str | None, random_: bool) -> None:
    """Write the 6x6 activation matrix into the FPGA's scratchpad."""
    rng = np.random.default_rng()
    m = _load_matrix(path, random_, rng)
    with _driver(ctx) as d:
        d.load_activations(m)
    _print_matrix(m, "loaded activations")


@main.command()
@click.option("--mode", type=click.Choice(MODE_CHOICES.keys()), required=True)
@click.pass_context
def compute(ctx: click.Context, mode: str) -> None:
    """Start a compute pass over whatever matrices are already loaded."""
    with _driver(ctx) as d:
        d.start_compute(MODE_CHOICES[mode])
        d.wait_until_done()
        click.echo("done")


@main.command("read-result")
@click.pass_context
def read_result(ctx: click.Context) -> None:
    """Read back the 6x6 int32 result matrix."""
    with _driver(ctx) as d:
        m = d.read_result()
    _print_matrix(m, "result")


@main.command()
@click.option("--mode", type=click.Choice(MODE_CHOICES.keys()), required=True)
@click.option("--weights", "weights_path", type=click.Path(exists=True))
@click.option("--activations", "activations_path", type=click.Path(exists=True))
@click.option("--random", "random_", is_flag=True, help="use random matrices instead of --weights/--activations")
@click.option("--verify", is_flag=True, help="compare against a numpy golden model")
@click.option("--seed", type=int, default=None, help="RNG seed for --random")
@click.pass_context
def run(ctx: click.Context, mode: str, weights_path: str | None, activations_path: str | None,
        random_: bool, verify: bool, seed: int | None) -> None:
    """Load matrices, compute, read back the result -- all in one shot."""
    rng = np.random.default_rng(seed)
    w = _load_matrix(weights_path, random_, rng)
    a = _load_matrix(activations_path, random_, rng)

    with _driver(ctx) as d:
        result = np.array(d.run(w, a, MODE_CHOICES[mode]), dtype=np.int64)

    _print_matrix(w, "weights")
    _print_matrix(a, "activations")
    _print_matrix(result, "result")

    if verify:
        golden = matmul_int8(a, w)
        if np.array_equal(result, golden):
            click.echo(click.style("VERIFY OK: matches numpy", fg="green"))
        else:
            _print_matrix(golden, "expected (numpy)")
            click.echo(click.style("VERIFY FAILED: mismatch", fg="red"))
            sys.exit(1)


@main.command("tiled-run")
@click.option("--mode", type=click.Choice(MODE_CHOICES.keys()), required=True)
@click.option("--weights", "weights_path", type=click.Path(exists=True), help="KxN int8 matrix (.npy or .csv)")
@click.option("--activations", "activations_path", type=click.Path(exists=True), help="MxK int8 matrix (.npy or .csv)")
@click.option("--random", "random_", is_flag=True, help="use random MxK/KxN matrices instead of --weights/--activations")
@click.option("--m", "m", type=click.IntRange(1), help="activations rows (with --random)")
@click.option("--k", "k", type=click.IntRange(1), help="contraction dim: activations cols / weights rows (with --random)")
@click.option("--n", "n", type=click.IntRange(1), help="weights cols (with --random)")
@click.option("--verify", is_flag=True, help="compare against a numpy golden model")
@click.option("--seed", type=int, default=None, help="RNG seed for --random")
@click.pass_context
def tiled_run(ctx: click.Context, mode: str, weights_path: str | None, activations_path: str | None,
              random_: bool, m: int | None, k: int | None, n: int | None,
              verify: bool, seed: int | None) -> None:
    """Multiply matrices larger than 6x6 by tiling them into 6x6 blocks and
    running one hardware compute per tile -- see docs/architecture.md for
    why accumulation across tiles has to happen here, not on-device."""
    rng = np.random.default_rng(seed)
    a = _load_tiled_matrix(activations_path, random_, rng, (m, k) if m and k else None)
    w = _load_tiled_matrix(weights_path, random_, rng, (k, n) if k and n else None)
    if a.shape[1] != w.shape[0]:
        raise click.ClickException(f"K mismatch: activations is {a.shape}, weights is {w.shape}")

    m_tiles = -(-a.shape[0] // proto.ARRAY_ROWS)
    k_tiles = -(-a.shape[1] // proto.ARRAY_ROWS)
    n_tiles = -(-w.shape[1] // proto.ARRAY_ROWS)
    total_tiles = m_tiles * k_tiles * n_tiles

    with _driver(ctx) as d:
        with click.progressbar(length=total_tiles, label="computing tiles") as bar:
            def compute_tile(w_tile, a_tile):
                res = d.run(w_tile, a_tile, MODE_CHOICES[mode])
                bar.update(1)
                return res

            result = tiling.tiled_matmul(compute_tile, a, w)

    _print_matrix(a, "activations")
    _print_matrix(w, "weights")
    _print_matrix(result, "result")

    if verify:
        golden = matmul_int8(a, w)
        if np.array_equal(result, golden):
            click.echo(click.style("VERIFY OK: matches numpy", fg="green"))
        else:
            _print_matrix(golden, "expected (numpy)")
            click.echo(click.style("VERIFY FAILED: mismatch", fg="red"))
            sys.exit(1)


@main.command("run-k")
@click.option("--mode", type=click.Choice(MODE_CHOICES.keys()), required=True)
@click.option("--weights", "weights_path", type=click.Path(exists=True), help=f"Kx{proto.ARRAY_COLS} int8 matrix (.npy or .csv)")
@click.option("--activations", "activations_path", type=click.Path(exists=True), help=f"{proto.ARRAY_ROWS}xK int8 matrix (.npy or .csv)")
@click.option("--random", "random_", is_flag=True, help="use random matrices instead of --weights/--activations")
@click.option("--k", "k", type=click.IntRange(1, proto.OS_K_MAX), help="contraction dim (with --random)")
@click.option("--verify", is_flag=True, help="compare against a numpy golden model")
@click.option("--seed", type=int, default=None, help="RNG seed for --random")
@click.pass_context
def run_k(ctx: click.Context, mode: str, weights_path: str | None, activations_path: str | None,
          random_: bool, k: int | None, verify: bool, seed: int | None) -> None:
    """Multiply a fixed-6xK activations matrix by a Kx6 weights matrix in
    ONE native hardware compute call (K up to proto.OS_K_MAX) -- unlike
    tiled-run, no host-side tiling/summing happens at all. OS-only: WS's
    K is physically fixed at 6 (see docs/architecture.md), so this raises
    a clear error rather than a confusing hardware NACK if K != 6 there."""
    if mode == "ws" and k is not None and k != proto.ARRAY_ROWS:
        raise click.ClickException(f"WS mode only supports k={proto.ARRAY_ROWS} (K is physically fixed there)")

    rng = np.random.default_rng(seed)
    a = _load_tiled_matrix(activations_path, random_, rng, (proto.ARRAY_ROWS, k) if k else None)
    w = _load_tiled_matrix(weights_path, random_, rng, (k, proto.ARRAY_COLS) if k else None)
    if a.shape[0] != proto.ARRAY_ROWS or w.shape[1] != proto.ARRAY_COLS:
        raise click.ClickException(
            f"run-k needs {proto.ARRAY_ROWS}xK activations and Kx{proto.ARRAY_COLS} weights, got {a.shape} and {w.shape}"
        )
    if a.shape[1] != w.shape[0]:
        raise click.ClickException(f"K mismatch: activations is {a.shape}, weights is {w.shape}")

    with _driver(ctx) as d:
        result = np.array(d.run(w, a, MODE_CHOICES[mode]), dtype=np.int64)

    _print_matrix(a, "activations")
    _print_matrix(w, "weights")
    _print_matrix(result, "result")

    if verify:
        golden = matmul_int8(a, w)
        if np.array_equal(result, golden):
            click.echo(click.style("VERIFY OK: matches numpy", fg="green"))
        else:
            _print_matrix(golden, "expected (numpy)")
            click.echo(click.style("VERIFY FAILED: mismatch", fg="red"))
            sys.exit(1)


@main.command("debug-pe")
@click.option("--row", type=click.IntRange(0, proto.ARRAY_ROWS - 1), required=True)
@click.option("--col", type=click.IntRange(0, proto.ARRAY_COLS - 1), required=True)
@click.pass_context
def debug_pe(ctx: click.Context, row: int, col: int) -> None:
    """Read a single PE's raw weight/accumulator registers (works even while busy)."""
    with _driver(ctx) as d:
        dbg = d.debug_read_pe(row, col)
    click.echo(f"PE({dbg.row},{dbg.col}): weight={dbg.weight} accum={dbg.accum}")


@main.command()
@click.option("--interval", default=0.5, show_default=True, help="poll interval in seconds")
@click.pass_context
def monitor(ctx: click.Context, interval: float) -> None:
    """Continuously poll and print status (Ctrl-C to stop)."""
    import time

    with _driver(ctx) as d:
        try:
            while True:
                st = d.status()
                click.echo(f"busy={st.busy} done={st.done}")
                time.sleep(interval)
        except KeyboardInterrupt:
            pass


def entrypoint() -> None:
    try:
        main(obj={})
    except (LinkError, DeviceNack) as e:
        click.echo(click.style(f"error: {e}", fg="red"), err=True)
        sys.exit(1)


if __name__ == "__main__":
    entrypoint()
