library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Bit-level UART bus-functional-model procedures for testbenches: send
-- raw bytes/framed packets onto a serial signal (simulating a host's TX
-- into the device's RX pin) and receive raw bytes/framed packets off a
-- serial signal (simulating a host reading the device's TX pin). Frame
-- shape and CRC-8 match docs/protocol.md / pkg_protocol.vhd exactly.
package uart_bfm_pkg is

  type byte_array_t is array (natural range <>) of natural range 0 to 255;

  constant BFM_SYNC_BYTE : natural := 16#A5#;

  function bfm_crc8(data : byte_array_t) return natural;

  procedure uart_bfm_send_byte(
    signal   line      : out std_logic;
    constant bit_period : in time;
    constant b          : in natural
  );

  procedure uart_bfm_send_frame(
    signal   line       : out std_logic;
    constant bit_period : in time;
    constant opcode     : in natural;
    constant payload    : in byte_array_t
  );

  procedure uart_bfm_recv_byte(
    signal   line      : in  std_logic;
    constant bit_period : in time;
    variable result      : out natural
  );

  -- Receives one full framed response: resyncs on 0xA5 (dropping stray
  -- bytes, same policy as the device's own parser), then OPCODE/LEN/
  -- PAYLOAD/CRC. `payload` must be pre-sized by the caller to at least
  -- the largest expected response length (e.g. 0 to 199); only
  -- payload(0 to len-1) is written.
  procedure uart_bfm_recv_frame(
    signal   line       : in  std_logic;
    constant bit_period : in time;
    variable opcode      : out natural;
    variable len          : out natural;
    variable payload      : out byte_array_t;
    variable crc_ok       : out boolean
  );

end package uart_bfm_pkg;

package body uart_bfm_pkg is

  function bfm_crc8(data : byte_array_t) return natural is
    variable crc : std_logic_vector(7 downto 0) := (others => '0');
    variable d   : std_logic_vector(7 downto 0);
  begin
    for i in data'range loop
      d := std_logic_vector(to_unsigned(data(i), 8));
      for b in 7 downto 0 loop
        if (crc(7) xor d(b)) = '1' then
          crc := (crc(6 downto 0) & '0') xor x"07";
        else
          crc := crc(6 downto 0) & '0';
        end if;
      end loop;
    end loop;
    return to_integer(unsigned(crc));
  end function;

  procedure uart_bfm_send_byte(
    signal   line      : out std_logic;
    constant bit_period : in time;
    constant b          : in natural
  ) is
    variable v : std_logic_vector(7 downto 0);
  begin
    v := std_logic_vector(to_unsigned(b, 8));
    -- Small phase offset so bit transitions never land exactly on a
    -- clk edge -- without it, this pure time-based bit-banging can race
    -- uart_rx's clocked sampling process (confirmed empirically: the
    -- very first SYNC byte was being misread without this offset, even
    -- though uart_rx/uart_tx already pass their own loopback test).
    wait for 3 ns;
    line <= '0'; -- start bit
    wait for bit_period;
    for i in 0 to 7 loop
      line <= v(i); -- LSB first
      wait for bit_period;
    end loop;
    line <= '1'; -- stop bit
    wait for bit_period;
  end procedure;

  procedure uart_bfm_send_frame(
    signal   line       : out std_logic;
    constant bit_period : in time;
    constant opcode     : in natural;
    constant payload    : in byte_array_t
  ) is
    variable crc_input : byte_array_t(0 to payload'length + 1);
    variable crc        : natural;
  begin
    crc_input(0) := opcode;
    crc_input(1) := payload'length;
    for i in payload'range loop
      crc_input(2 + i - payload'low) := payload(i);
    end loop;
    crc := bfm_crc8(crc_input);

    uart_bfm_send_byte(line, bit_period, BFM_SYNC_BYTE);
    uart_bfm_send_byte(line, bit_period, opcode);
    uart_bfm_send_byte(line, bit_period, payload'length);
    for i in payload'range loop
      uart_bfm_send_byte(line, bit_period, payload(i));
    end loop;
    uart_bfm_send_byte(line, bit_period, crc);
  end procedure;

  procedure uart_bfm_recv_byte(
    signal   line      : in  std_logic;
    constant bit_period : in time;
    variable result      : out natural
  ) is
    variable v : std_logic_vector(7 downto 0);
  begin
    wait until line = '0'; -- start bit edge
    -- Same clock-alignment concern as uart_bfm_send_byte: line changed
    -- exactly on a clk edge (uart_tx is itself clock-driven), so
    -- sampling instants derived purely from bit_period multiples would
    -- keep landing exactly on edges too. Nudge off of that.
    wait for 2 ns;
    wait for bit_period + bit_period / 2; -- center of bit 0
    for i in 0 to 7 loop
      v(i) := line;
      wait for bit_period;
    end loop;
    result := to_integer(unsigned(v));
    -- remaining time is the stop bit; caller may immediately wait for
    -- the next start-bit falling edge.
  end procedure;

  procedure uart_bfm_recv_frame(
    signal   line       : in  std_logic;
    constant bit_period : in time;
    variable opcode      : out natural;
    variable len          : out natural;
    variable payload      : out byte_array_t;
    variable crc_ok       : out boolean
  ) is
    variable b        : natural;
    variable rx_opcode : natural;
    variable rx_len     : natural;
    variable rx_crc     : natural;
    variable crc_input  : byte_array_t(0 to payload'length + 1);
  begin
    loop
      uart_bfm_recv_byte(line, bit_period, b);
      exit when b = BFM_SYNC_BYTE;
    end loop;
    uart_bfm_recv_byte(line, bit_period, rx_opcode);
    uart_bfm_recv_byte(line, bit_period, rx_len);
    crc_input(0) := rx_opcode;
    crc_input(1) := rx_len;
    for i in 0 to rx_len - 1 loop
      uart_bfm_recv_byte(line, bit_period, b);
      payload(i) := b;
      crc_input(2 + i) := b;
    end loop;
    uart_bfm_recv_byte(line, bit_period, rx_crc);

    opcode := rx_opcode;
    len := rx_len;
    if rx_len = 0 then
      crc_ok := (rx_crc = bfm_crc8(crc_input(0 to 1)));
    else
      crc_ok := (rx_crc = bfm_crc8(crc_input(0 to 1 + rx_len)));
    end if;
  end procedure;

end package body uart_bfm_pkg;
