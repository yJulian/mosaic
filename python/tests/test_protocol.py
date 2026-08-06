"""Host-only protocol tests (no hardware/simulator needed). CRC vectors
mirror sim/tb_crc8.vhd exactly, so both implementations are checked
against the same independently-verified expected values."""
import pytest

from fpga_systolic import protocol as proto


@pytest.mark.parametrize(
    "data,expected",
    [
        (b"", 0x00),
        (bytes([0x00]), 0x00),
        (bytes([0xFF]), 0xF3),
        (bytes([0x01, 0x00]), 0x15),
        (bytes([0x03, 0x02, 0x11, 0x22]), 0x40),
        (bytes(range(36)), 0xFF),
    ],
)
def test_crc8_vectors(data, expected):
    assert proto.crc8(data) == expected


def test_frame_round_trip_no_payload():
    frame = proto.encode_frame(proto.OP_PING)
    opcode, payload = proto.decode_frame(frame)
    assert opcode == proto.OP_PING
    assert payload == b""


def test_frame_round_trip_with_payload():
    payload = bytes(range(36))
    frame = proto.encode_frame(proto.OP_WRITE_WEIGHTS, payload)
    assert frame[0] == proto.SYNC_BYTE
    assert frame[1] == proto.OP_WRITE_WEIGHTS
    assert frame[2] == len(payload)
    opcode, decoded_payload = proto.decode_frame(frame)
    assert opcode == proto.OP_WRITE_WEIGHTS
    assert decoded_payload == payload


def test_decode_rejects_bad_sync():
    frame = bytearray(proto.encode_frame(proto.OP_PING))
    frame[0] = 0x00
    with pytest.raises(proto.FrameError):
        proto.decode_frame(bytes(frame))


def test_decode_rejects_bad_crc():
    frame = bytearray(proto.encode_frame(proto.OP_PING))
    frame[-1] ^= 0xFF
    with pytest.raises(proto.FrameError):
        proto.decode_frame(bytes(frame))


def test_decode_rejects_truncated_frame():
    frame = proto.encode_frame(proto.OP_WRITE_WEIGHTS, bytes(36))
    with pytest.raises(proto.FrameError):
        proto.decode_frame(frame[:-5])


def test_matrix_to_bytes_row_major():
    matrix = [[1, 2, 3], [4, 5, -1]]
    data = proto.matrix_to_bytes(matrix)
    assert data == bytes([1, 2, 3, 4, 5, 0xFF])


def test_matrix_to_bytes_rejects_out_of_range():
    with pytest.raises(ValueError):
        proto.matrix_to_bytes([[200]])


def test_bytes_to_int32_matrix_round_trip():
    import struct

    values = [[1, -1], [1000000, -1000000]]
    data = b"".join(struct.pack("<i", v) for row in values for v in row)
    decoded = proto.bytes_to_int32_matrix(data, rows=2, cols=2)
    assert decoded == values


def test_encode_start_compute_payload_shape():
    payload = proto.encode_start_compute_payload(proto.MODE_OS, 17)
    assert len(payload) == 3
    assert payload[0] == proto.MODE_OS
    assert int.from_bytes(payload[1:3], "little") == 17


def test_encode_start_compute_payload_k_little_endian():
    # k=300 needs both bytes (300 = 0x012C); catches an accidental single-byte encoding
    payload = proto.encode_start_compute_payload(proto.MODE_WS, 300)
    assert payload[1:3] == (300).to_bytes(2, "little")


def test_err_bad_k_registered():
    assert proto.ERR_NAMES[proto.ERR_BAD_K] == "BAD_K"


def test_os_k_max_matches_rtl():
    # Mirrors rtl/common/pkg_types.vhd's OS_K_MAX -- if this drifts, the
    # host would accept K values the hardware will NACK (or vice versa).
    assert proto.OS_K_MAX == 16
