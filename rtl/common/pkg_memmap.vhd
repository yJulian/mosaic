library ieee;
use ieee.std_logic_1164.all;

-- BSRAM scratchpad memory map. Single source of truth for cmd_processor's
-- address decoding, the feeder/drainer's burst-copy addressing, and the
-- Python host driver's protocol.py (mirrored there byte-for-byte).
--
-- Budget: Tang Nano 9K has 26 x 18Kbit BSRAM blocks = 58.5KB total. This
-- map uses ~39KB (~20 blocks, ~77%), leaving ~6 blocks free for UART
-- FIFOs / skew buffers / P&R routing slack and headroom for a later
-- tiling extension (v1 itself only needs 36B weights, 36B activations,
-- 144B int32 results per region).
package pkg_memmap is

  constant ADDR_WIDTH : natural := 16;

  constant WEIGHT_BASE : natural := 16#0000#;
  constant WEIGHT_SIZE : natural := 16384; -- 16 KB

  constant ACT_BASE : natural := 16#4000#;
  constant ACT_SIZE  : natural := 16384; -- 16 KB

  constant RESULT_BASE : natural := 16#8000#;
  constant RESULT_SIZE : natural := 6144; -- 6 KB

  constant DEBUG_BASE : natural := 16#9800#;
  constant DEBUG_SIZE : natural := 1024; -- 1 KB

  constant SCRATCHPAD_SIZE : natural := DEBUG_BASE + DEBUG_SIZE; -- 39936 B, ~39 KB

  -- v1 payload sizes (6x6 matrices), placed at offset 0 of their region.
  constant WEIGHT_BYTES : natural := 36;  -- 6x6 int8, row-major
  constant ACT_BYTES    : natural := 36;  -- 6x6 int8, row-major
  constant RESULT_BYTES : natural := 144; -- 6x6 int32, row-major

end package pkg_memmap;
