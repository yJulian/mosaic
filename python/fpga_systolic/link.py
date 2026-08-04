"""pyserial transport (Link) plus a higher-level SystolicArrayDriver with
one method per protocol opcode. Framing/CRC errors and NACKs raise
LinkError; callers decide whether to retry."""
from __future__ import annotations

import time
from dataclasses import dataclass

import serial

from . import protocol as proto

DEFAULT_BAUD = 1_500_000


class LinkError(Exception):
    pass


class DeviceNack(LinkError):
    def __init__(self, err_code: int):
        self.err_code = err_code
        name = proto.ERR_NAMES.get(err_code, f"0x{err_code:02X}")
        super().__init__(f"device NACKed: {name}")


class Link:
    """Raw framed byte-stream transport over a serial port."""

    def __init__(self, port: str, baud: int = DEFAULT_BAUD, timeout: float = 2.0):
        self.ser = serial.Serial(port, baudrate=baud, timeout=timeout)

    def close(self) -> None:
        self.ser.close()

    def __enter__(self) -> "Link":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def _read_exact(self, n: int) -> bytes:
        data = self.ser.read(n)
        if len(data) != n:
            raise LinkError(f"timeout: wanted {n} bytes, got {len(data)}")
        return data

    def send_frame(self, opcode: int, payload: bytes = b"") -> None:
        self.ser.write(proto.encode_frame(opcode, payload))

    def recv_frame(self) -> tuple[int, bytes]:
        # Resync on SYNC_BYTE, exactly like the device's own parser: drop
        # anything that isn't SYNC and keep waiting for a real frame start.
        while True:
            b = self._read_exact(1)
            if b[0] == proto.SYNC_BYTE:
                break
        opcode = self._read_exact(1)[0]
        length = self._read_exact(1)[0]
        payload = self._read_exact(length) if length else b""
        crc_recv = self._read_exact(1)[0]
        body = bytes([opcode, length]) + payload
        crc_calc = proto.crc8(body)
        if crc_calc != crc_recv:
            raise LinkError(f"CRC mismatch in response: got 0x{crc_recv:02X}, expected 0x{crc_calc:02X}")
        return opcode, payload

    def transact(self, opcode: int, payload: bytes = b"") -> tuple[int, bytes]:
        self.send_frame(opcode, payload)
        return self.recv_frame()


@dataclass
class Status:
    busy: bool
    done: bool

    @classmethod
    def from_byte(cls, b: int) -> "Status":
        return cls(busy=bool(b & 0x01), done=bool(b & 0x02))


@dataclass
class DebugData:
    row: int
    col: int
    weight: int
    accum: int


@dataclass
class PongInfo:
    fw_version: int
    rows: int
    cols: int
    dtype: int


class SystolicArrayDriver:
    """High-level operations, one per protocol opcode, on top of Link."""

    def __init__(self, port: str, baud: int = DEFAULT_BAUD, timeout: float = 2.0):
        self.link = Link(port, baud=baud, timeout=timeout)

    def close(self) -> None:
        self.link.close()

    def __enter__(self) -> "SystolicArrayDriver":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def _expect_ack(self, opcode: int, payload: bytes = b"") -> None:
        resp_op, resp_payload = self.link.transact(opcode, payload)
        if resp_op == proto.OP_NACK:
            raise DeviceNack(resp_payload[0] if resp_payload else 0xFF)
        if resp_op != proto.OP_ACK:
            raise LinkError(f"expected ACK, got 0x{resp_op:02X}")

    def ping(self) -> PongInfo:
        resp_op, payload = self.link.transact(proto.OP_PING)
        if resp_op != proto.OP_PONG:
            raise LinkError(f"expected PONG, got 0x{resp_op:02X}")
        return PongInfo(fw_version=payload[0], rows=payload[1], cols=payload[2], dtype=payload[3])

    def reset(self) -> None:
        self._expect_ack(proto.OP_RESET)

    def status(self) -> Status:
        resp_op, payload = self.link.transact(proto.OP_STATUS_QUERY)
        if resp_op != proto.OP_STATUS_DATA:
            raise LinkError(f"expected STATUS_DATA, got 0x{resp_op:02X}")
        return Status.from_byte(payload[0])

    def load_weights(self, matrix, offset: int = 0) -> None:
        data = proto.matrix_to_bytes(matrix)
        payload = offset.to_bytes(2, "little") + data
        self._expect_ack(proto.OP_WRITE_WEIGHTS, payload)

    def load_activations(self, matrix, offset: int = 0) -> None:
        data = proto.matrix_to_bytes(matrix)
        payload = offset.to_bytes(2, "little") + data
        self._expect_ack(proto.OP_WRITE_ACTIVATIONS, payload)

    def start_compute(self, mode: int) -> None:
        self._expect_ack(proto.OP_START_COMPUTE, bytes([mode]))

    def wait_until_done(self, poll_interval: float = 0.002, timeout: float = 5.0) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            st = self.status()
            if not st.busy:
                return
            time.sleep(poll_interval)
        raise LinkError("timed out waiting for compute to finish")

    def read_result(self, offset: int = 0, length: int = proto.RESULT_BYTES):
        payload = offset.to_bytes(2, "little") + bytes([length])
        resp_op, resp_payload = self.link.transact(proto.OP_READ_RESULT, payload)
        if resp_op != proto.OP_RESULT_DATA:
            raise LinkError(f"expected RESULT_DATA, got 0x{resp_op:02X}")
        data = resp_payload[3:3 + length]
        return proto.bytes_to_int32_matrix(data)

    def debug_read_pe(self, row: int, col: int) -> DebugData:
        resp_op, payload = self.link.transact(proto.OP_DEBUG_READ_PE, bytes([row, col]))
        if resp_op != proto.OP_DEBUG_DATA:
            raise LinkError(f"expected DEBUG_DATA, got 0x{resp_op:02X}")
        weight = payload[2] if payload[2] < 128 else payload[2] - 256
        accum = int.from_bytes(payload[3:7], "little", signed=True)
        return DebugData(row=payload[0], col=payload[1], weight=weight, accum=accum)

    def run(self, weights, activations, mode: int):
        """Convenience: load both matrices, compute, wait, read back."""
        self.load_weights(weights)
        self.load_activations(activations)
        self.start_compute(mode)
        self.wait_until_done()
        return self.read_result()
