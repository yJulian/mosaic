"""UART frame protocol: constants, CRC-8, frame encode/decode.

Single source of truth is docs/protocol.md; this module and
rtl/common/pkg_protocol.vhd both implement it exactly and must be kept
in sync if it ever changes.

Frame shape: [SYNC 0xA5][OPCODE 1B][LEN 1B][PAYLOAD LEN bytes][CRC8 1B]
CRC8 is computed over OPCODE||LEN||PAYLOAD (not SYNC), poly 0x07,
init 0x00, MSB-first, no reflection.
"""
from __future__ import annotations

SYNC_BYTE = 0xA5
CRC8_POLY = 0x07

# Host -> device opcodes
OP_WRITE_WEIGHTS = 0x01
OP_WRITE_ACTIVATIONS = 0x02
OP_START_COMPUTE = 0x03
OP_READ_RESULT = 0x04
OP_STATUS_QUERY = 0x05
OP_DEBUG_READ_PE = 0x06
OP_RESET = 0x07
OP_PING = 0x08

# Device -> host opcodes
OP_ACK = 0x81
OP_NACK = 0x82
OP_RESULT_DATA = 0x83
OP_STATUS_DATA = 0x84
OP_DEBUG_DATA = 0x85
OP_PONG = 0x86

OPCODE_NAMES = {
    OP_WRITE_WEIGHTS: "WRITE_WEIGHTS",
    OP_WRITE_ACTIVATIONS: "WRITE_ACTIVATIONS",
    OP_START_COMPUTE: "START_COMPUTE",
    OP_READ_RESULT: "READ_RESULT",
    OP_STATUS_QUERY: "STATUS_QUERY",
    OP_DEBUG_READ_PE: "DEBUG_READ_PE",
    OP_RESET: "RESET",
    OP_PING: "PING",
    OP_ACK: "ACK",
    OP_NACK: "NACK",
    OP_RESULT_DATA: "RESULT_DATA",
    OP_STATUS_DATA: "STATUS_DATA",
    OP_DEBUG_DATA: "DEBUG_DATA",
    OP_PONG: "PONG",
}

# NACK error codes (payload byte 0 of an OP_NACK frame)
ERR_CRC_FAIL = 0x01
ERR_BAD_OPCODE = 0x02
ERR_BAD_LEN = 0x03
ERR_BUSY = 0x04
ERR_BAD_ADDR = 0x05
ERR_TIMEOUT = 0x06
ERR_BAD_K = 0x07

ERR_NAMES = {
    ERR_CRC_FAIL: "CRC_FAIL",
    ERR_BAD_OPCODE: "BAD_OPCODE",
    ERR_BAD_LEN: "BAD_LEN",
    ERR_BUSY: "BUSY",
    ERR_BAD_ADDR: "BAD_ADDR",
    ERR_TIMEOUT: "TIMEOUT",
    ERR_BAD_K: "BAD_K",
}

# START_COMPUTE mode payload byte values
MODE_WS = 0x00
MODE_OS = 0x01

FW_VERSION = 0x01
DTYPE_INT8_INT32 = 0x00

# Must match rtl/common/pkg_types.vhd / pkg_memmap.vhd
ARRAY_ROWS = 6
ARRAY_COLS = 6
MATRIX_ELEMENTS = ARRAY_ROWS * ARRAY_COLS

# Max contraction (K) length for a single native OS (output-stationary)
# compute call -- see rtl/common/pkg_types.vhd's OS_K_MAX. WS mode ignores
# this entirely (always behaves as K=ARRAY_ROWS).
OS_K_MAX = 16

WEIGHT_BASE = 0x0000
ACT_BASE = 0x4000
RESULT_BASE = 0x8000
DEBUG_BASE = 0x9800

WEIGHT_BYTES = MATRIX_ELEMENTS       # 6x6 int8, row-major
ACT_BYTES = MATRIX_ELEMENTS          # 6x6 int8, row-major
RESULT_BYTES = MATRIX_ELEMENTS * 4   # 6x6 int32, row-major


def crc8(data: bytes, poly: int = CRC8_POLY) -> int:
    """Bit-serial CRC-8, MSB-first, no reflection -- matches rtl/ctrl/crc8.vhd."""
    crc = 0
    for byte in data:
        for i in range(7, -1, -1):
            bit = (byte >> i) & 1
            msb = (crc >> 7) & 1
            if msb ^ bit:
                crc = ((crc << 1) & 0xFF) ^ poly
            else:
                crc = (crc << 1) & 0xFF
    return crc


class FrameError(Exception):
    pass


def encode_frame(opcode: int, payload: bytes = b"") -> bytes:
    if len(payload) > 255:
        raise ValueError(f"payload too long: {len(payload)} > 255")
    body = bytes([opcode, len(payload)]) + payload
    crc = crc8(body)
    return bytes([SYNC_BYTE]) + body + bytes([crc])


def decode_frame(buf: bytes) -> tuple[int, bytes]:
    """Decode a single complete frame. buf must start at SYNC and contain
    at least [SYNC][OPCODE][LEN][PAYLOAD][CRC]. Returns (opcode, payload)."""
    if len(buf) < 4:
        raise FrameError(f"frame too short: {len(buf)} bytes")
    if buf[0] != SYNC_BYTE:
        raise FrameError(f"bad sync byte: 0x{buf[0]:02X}")
    opcode = buf[1]
    length = buf[2]
    if len(buf) < 4 + length:
        raise FrameError(f"truncated frame: need {4 + length} bytes, got {len(buf)}")
    payload = buf[3:3 + length]
    crc_recv = buf[3 + length]
    body = buf[1:3 + length]
    crc_calc = crc8(body)
    if crc_calc != crc_recv:
        raise FrameError(f"CRC mismatch: got 0x{crc_recv:02X}, expected 0x{crc_calc:02X}")
    return opcode, payload


def matrix_to_bytes(matrix) -> bytes:
    """Row-major int8 matrix (list-of-lists or 2D numpy array) -> bytes."""
    out = bytearray()
    for row in matrix:
        for v in row:
            iv = int(v)
            if not -128 <= iv <= 127:
                raise ValueError(f"value {iv} out of int8 range")
            out.append(iv & 0xFF)
    return bytes(out)


def encode_start_compute_payload(mode: int, k: int) -> bytes:
    """START_COMPUTE payload: MODE(1B) K(2B,LE). WS ignores k on-device
    (always behaves as K=ARRAY_ROWS); OS accepts 1..OS_K_MAX."""
    return bytes([mode]) + k.to_bytes(2, "little")


def bytes_to_int32_matrix(data: bytes, rows: int = ARRAY_ROWS, cols: int = ARRAY_COLS):
    """RESULT_DATA payload bytes -> rows x cols list-of-lists of signed int32."""
    if len(data) < rows * cols * 4:
        raise ValueError(f"expected {rows * cols * 4} bytes, got {len(data)}")
    result = []
    idx = 0
    for _ in range(rows):
        row = []
        for _ in range(cols):
            raw = int.from_bytes(data[idx:idx + 4], "little", signed=True)
            row.append(raw)
            idx += 4
        result.append(row)
    return result
