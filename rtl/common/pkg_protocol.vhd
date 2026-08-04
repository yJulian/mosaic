library ieee;
use ieee.std_logic_1164.all;

-- UART frame protocol constants. Mirrors docs/protocol.md and
-- python/fpga_systolic/protocol.py exactly -- if one changes, all three
-- must change together.
--
-- Frame shape: [SYNC 0xA5][OPCODE 1B][LEN 1B][PAYLOAD LEN bytes][CRC8 1B]
-- CRC8 is computed over OPCODE || LEN || PAYLOAD (not SYNC), poly 0x07,
-- init 0x00, no reflect.
package pkg_protocol is

  constant SYNC_BYTE : std_logic_vector(7 downto 0) := x"A5";
  constant CRC8_POLY : std_logic_vector(7 downto 0) := x"07";

  -- Host -> device opcodes
  constant OP_WRITE_WEIGHTS     : std_logic_vector(7 downto 0) := x"01";
  constant OP_WRITE_ACTIVATIONS : std_logic_vector(7 downto 0) := x"02";
  constant OP_START_COMPUTE     : std_logic_vector(7 downto 0) := x"03";
  constant OP_READ_RESULT       : std_logic_vector(7 downto 0) := x"04";
  constant OP_STATUS_QUERY      : std_logic_vector(7 downto 0) := x"05";
  constant OP_DEBUG_READ_PE     : std_logic_vector(7 downto 0) := x"06";
  constant OP_RESET             : std_logic_vector(7 downto 0) := x"07";
  constant OP_PING              : std_logic_vector(7 downto 0) := x"08";

  -- Device -> host opcodes
  constant OP_ACK          : std_logic_vector(7 downto 0) := x"81";
  constant OP_NACK         : std_logic_vector(7 downto 0) := x"82";
  constant OP_RESULT_DATA  : std_logic_vector(7 downto 0) := x"83";
  constant OP_STATUS_DATA  : std_logic_vector(7 downto 0) := x"84";
  constant OP_DEBUG_DATA   : std_logic_vector(7 downto 0) := x"85";
  constant OP_PONG         : std_logic_vector(7 downto 0) := x"86";

  -- NACK error codes (payload byte 0 of an OP_NACK frame)
  constant ERR_CRC_FAIL  : std_logic_vector(7 downto 0) := x"01";
  constant ERR_BAD_OPCODE: std_logic_vector(7 downto 0) := x"02";
  constant ERR_BAD_LEN   : std_logic_vector(7 downto 0) := x"03";
  constant ERR_BUSY      : std_logic_vector(7 downto 0) := x"04";
  constant ERR_BAD_ADDR  : std_logic_vector(7 downto 0) := x"05";
  constant ERR_TIMEOUT   : std_logic_vector(7 downto 0) := x"06";

  -- START_COMPUTE mode payload byte values
  constant MODE_WS : std_logic_vector(7 downto 0) := x"00";
  constant MODE_OS : std_logic_vector(7 downto 0) := x"01";

  -- PONG payload
  constant FW_VERSION  : std_logic_vector(7 downto 0) := x"01";
  constant DTYPE_INT8_INT32 : std_logic_vector(7 downto 0) := x"00";

  -- STATUS_DATA bit positions
  constant STATUS_BIT_BUSY        : natural := 0;
  constant STATUS_BIT_DONE        : natural := 1;
  constant STATUS_BIT_ERROR       : natural := 2;
  constant STATUS_BIT_MODE_ACTIVE : natural := 3;

end package pkg_protocol;
