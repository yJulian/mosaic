library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pkg_types.all;
use work.pkg_memmap.all;
use work.pkg_protocol.all;
use work.uart_bfm_pkg.all;

-- Full-chip test: drives top.vhd purely over its UART pins via the BFM,
-- exactly as the real Python host driver will -- write weights, write
-- activations, start WS compute, poll status, read results back and
-- compare against a numpy-equivalent golden model computed in VHDL;
-- repeat for OS. This is the top-level acceptance test for the whole
-- accelerator before moving to hardware bring-up.
entity tb_top is
end entity tb_top;

architecture sim of tb_top is
  constant CLK_PERIOD  : time := 10 ns; -- stand-in for the real 27MHz clock's period (37.037ns); ratio to BAUD_RATE is what matters for functional sim
  constant CLK_FREQ_HZ : natural := 27_000_000;
  constant BAUD_RATE    : natural := 1_500_000;
  constant BIT_PERIOD   : time := CLK_PERIOD * (CLK_FREQ_HZ / BAUD_RATE);

  type matrix6_t is array (0 to ARRAY_ROWS - 1, 0 to ARRAY_COLS - 1) of integer;

  constant A_MAT : matrix6_t := (
    (1, 2, 3, 4, 5, 6),
    (7, 8, 9, 10, 11, 12),
    (13, 14, 15, 16, 17, 18),
    (-1, -2, -3, -4, -5, -6),
    (2, 4, 6, 8, 10, 12),
    (0, 1, 0, 1, 0, 1)
  );

  constant W_MAT : matrix6_t := (
    (1, 0, 0, 1, 0, 0),
    (0, 1, 0, 0, 1, 0),
    (0, 0, 1, 0, 0, 1),
    (2, 0, 0, 2, 0, 0),
    (0, 2, 0, 0, 2, 0),
    (0, 0, 2, 0, 0, 2)
  );

  function matmul(a, w : matrix6_t) return matrix6_t is
    variable result : matrix6_t;
    variable sum     : integer;
  begin
    for m in 0 to ARRAY_ROWS - 1 loop
      for c in 0 to ARRAY_COLS - 1 loop
        sum := 0;
        for k in 0 to ARRAY_ROWS - 1 loop
          sum := sum + a(m, k) * w(k, c);
        end loop;
        result(m, c) := sum;
      end loop;
    end loop;
    return result;
  end function;

  constant GOLDEN_C : matrix6_t := matmul(A_MAT, W_MAT);

  signal clk       : std_logic := '0';
  signal host_to_dev : std_logic := '1';
  signal dev_to_host  : std_logic;

  signal sim_done : boolean := false;
  signal errors   : natural := 0;
begin

  dut : entity work.top
    generic map (CLK_FREQ_HZ => CLK_FREQ_HZ, BAUD_RATE => BAUD_RATE)
    port map (
      clk => clk,
      uart_rx_pin => host_to_dev, uart_tx_pin => dev_to_host,
      led_n => open
    );

  clk_gen : process
  begin
    while not sim_done loop
      clk <= '0'; wait for CLK_PERIOD / 2;
      clk <= '1'; wait for CLK_PERIOD / 2;
    end loop;
    wait;
  end process;

  stim : process
    variable rx_opcode, rx_len : natural;
    variable rx_payload : byte_array_t(0 to 199);
    variable rx_ok      : boolean;
    variable errcnt      : natural := 0;
    variable raw         : integer;
    variable b0, b1, b2, b3 : natural;

    procedure check_eq(actual, expected : integer; msg : string) is
    begin
      if actual /= expected then
        report "FAIL: " & msg & " got=" & integer'image(actual) &
               " exp=" & integer'image(expected) severity error;
        errcnt := errcnt + 1;
      else
        report "PASS: " & msg severity note;
      end if;
    end procedure;

    procedure check_true(cond : boolean; msg : string) is
    begin
      if not cond then
        report "FAIL: " & msg severity error;
        errcnt := errcnt + 1;
      else
        report "PASS: " & msg severity note;
      end if;
    end procedure;

    procedure send_matrix(opcode : natural; m : matrix6_t) is
      variable payload : byte_array_t(0 to 37);
      variable idx      : natural := 0;
    begin
      payload(0) := 0; -- offset lo
      payload(1) := 0; -- offset hi
      for r in 0 to ARRAY_ROWS - 1 loop
        for c in 0 to ARRAY_COLS - 1 loop
          payload(2 + idx) := (m(r, c) + 256) mod 256; -- int8 -> byte
          idx := idx + 1;
        end loop;
      end loop;
      uart_bfm_send_frame(host_to_dev, BIT_PERIOD, opcode, payload);
      uart_bfm_recv_frame(dev_to_host, BIT_PERIOD, rx_opcode, rx_len, rx_payload, rx_ok);
      check_true(rx_ok, "send_matrix: CRC ok");
      check_eq(rx_opcode, to_integer(unsigned(OP_ACK)), "send_matrix: ACK");
    end procedure;

    procedure wait_until_done is
      variable status : natural := 0;
      variable tries   : natural := 0;
    begin
      loop
        uart_bfm_send_frame(host_to_dev, BIT_PERIOD, to_integer(unsigned(OP_STATUS_QUERY)), byte_array_t'(0 to -1 => 0));
        uart_bfm_recv_frame(dev_to_host, BIT_PERIOD, rx_opcode, rx_len, rx_payload, rx_ok);
        status := rx_payload(0);
        tries := tries + 1;
        exit when (status mod 2) = 0 or tries > 50; -- bit0=busy; 0 => idle
      end loop;
      check_true(tries <= 50, "wait_until_done: converged within poll budget");
    end procedure;

    procedure run_compute_and_check(mode_byte : natural; msg_label : string) is
    begin
      uart_bfm_send_frame(host_to_dev, BIT_PERIOD, to_integer(unsigned(OP_START_COMPUTE)), byte_array_t'(0 => mode_byte));
      uart_bfm_recv_frame(dev_to_host, BIT_PERIOD, rx_opcode, rx_len, rx_payload, rx_ok);
      check_true(rx_ok, msg_label & ": START_COMPUTE CRC ok");
      check_eq(rx_opcode, to_integer(unsigned(OP_ACK)), msg_label & ": START_COMPUTE ACK");

      wait_until_done;

      uart_bfm_send_frame(host_to_dev, BIT_PERIOD, to_integer(unsigned(OP_READ_RESULT)), byte_array_t'(0, 0, 144));
      uart_bfm_recv_frame(dev_to_host, BIT_PERIOD, rx_opcode, rx_len, rx_payload, rx_ok);
      check_true(rx_ok, msg_label & ": READ_RESULT CRC ok");
      check_eq(rx_opcode, to_integer(unsigned(OP_RESULT_DATA)), msg_label & ": READ_RESULT opcode");
      check_eq(rx_len, 147, msg_label & ": READ_RESULT len");

      for r in 0 to ARRAY_ROWS - 1 loop
        for c in 0 to ARRAY_COLS - 1 loop
          b0 := rx_payload(3 + (r * ARRAY_COLS + c) * 4);
          b1 := rx_payload(3 + (r * ARRAY_COLS + c) * 4 + 1);
          b2 := rx_payload(3 + (r * ARRAY_COLS + c) * 4 + 2);
          b3 := rx_payload(3 + (r * ARRAY_COLS + c) * 4 + 3);
          raw := to_integer(signed(std_logic_vector(to_unsigned(b3, 8)) &
                                    std_logic_vector(to_unsigned(b2, 8)) &
                                    std_logic_vector(to_unsigned(b1, 8)) &
                                    std_logic_vector(to_unsigned(b0, 8))));
          check_eq(raw, GOLDEN_C(r, c), msg_label & ": C(" & integer'image(r) & "," & integer'image(c) & ")");
        end loop;
      end loop;
    end procedure;
  begin
    wait for 400 ns; -- clear the internal power-on reset (clk_reset_gen)

    ------------------------------------------------------------------
    -- PING sanity check
    ------------------------------------------------------------------
    uart_bfm_send_frame(host_to_dev, BIT_PERIOD, to_integer(unsigned(OP_PING)), byte_array_t'(0 to -1 => 0));
    uart_bfm_recv_frame(dev_to_host, BIT_PERIOD, rx_opcode, rx_len, rx_payload, rx_ok);
    check_true(rx_ok, "PING: CRC ok");
    check_eq(rx_opcode, to_integer(unsigned(OP_PONG)), "PING: opcode is PONG");

    ------------------------------------------------------------------
    -- Load matrices
    ------------------------------------------------------------------
    send_matrix(to_integer(unsigned(OP_WRITE_WEIGHTS)), W_MAT);
    send_matrix(to_integer(unsigned(OP_WRITE_ACTIVATIONS)), A_MAT);

    ------------------------------------------------------------------
    -- WS run
    ------------------------------------------------------------------
    run_compute_and_check(0, "WS");

    ------------------------------------------------------------------
    -- OS run (results should match WS -- same golden matrix)
    ------------------------------------------------------------------
    run_compute_and_check(1, "OS");

    ------------------------------------------------------------------
    errors <= errcnt;
    wait for 100 ns;
    report "tb_top: " & integer'image(errcnt) & " error(s)";
    if errcnt > 0 then
      report "tb_top FAILED" severity failure;
    else
      report "tb_top PASSED" severity note;
    end if;
    sim_done <= true;
    wait;
  end process;

end architecture sim;
