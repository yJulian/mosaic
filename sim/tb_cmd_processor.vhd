library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pkg_types.all;
use work.pkg_memmap.all;
use work.pkg_protocol.all;
use work.uart_bfm_pkg.all;

-- Instantiates the exact UART<->cmd_processor wiring top.vhd will use
-- (uart_rx -> rx_fifo -> cmd_processor -> tx_fifo -> uart_tx) and drives
-- it as a real host would, over the BFM's bit-level serial lines. The
-- real scratchpad is used (so WRITE_WEIGHTS/ACTIVATIONS and READ_RESULT
-- exercise real memory), but array_ctrl is stubbed with TB-driven
-- busy/done signals so busy/NACK behavior can be forced directly.
entity tb_cmd_processor is
end entity tb_cmd_processor;

architecture sim of tb_cmd_processor is
  constant CLK_PERIOD  : time := 10 ns;
  constant CLK_FREQ_HZ : natural := 27_000_000;
  constant BAUD_RATE    : natural := 1_500_000;
  constant BIT_PERIOD   : time := CLK_PERIOD * (CLK_FREQ_HZ / BAUD_RATE);

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal host_to_dev : std_logic := '1';
  signal dev_to_host  : std_logic;

  signal rx_data_out : std_logic_vector(7 downto 0);
  signal rx_data_valid : std_logic;
  signal tx_data_in  : std_logic_vector(7 downto 0);
  signal tx_start    : std_logic;
  signal tx_busy     : std_logic;

  signal rxf_wr_en, rxf_full, rxf_rd_en, rxf_empty : std_logic;
  signal rxf_wr_data, rxf_rd_data : std_logic_vector(7 downto 0);
  signal txf_wr_en, txf_full, txf_rd_en, txf_empty : std_logic;
  signal txf_wr_data, txf_rd_data : std_logic_vector(7 downto 0);

  signal host_w_addr : unsigned(ADDR_WIDTH - 1 downto 0);
  signal host_w_data : std_logic_vector(7 downto 0);
  signal host_w_en   : std_logic;
  signal host_r_addr : unsigned(ADDR_WIDTH - 1 downto 0);
  signal host_r_data : std_logic_vector(7 downto 0);

  -- TB-side direct scratchpad poke, muxed in ahead of cmd_processor's
  -- writes so the RESULT region can be pre-loaded (no opcode writes
  -- there in normal operation -- only array writeback does).
  signal poke_addr : unsigned(ADDR_WIDTH - 1 downto 0) := (others => '0');
  signal poke_data : std_logic_vector(7 downto 0) := (others => '0');
  signal poke_en   : std_logic := '0';

  signal spad_w_addr : unsigned(ADDR_WIDTH - 1 downto 0);
  signal spad_w_data : std_logic_vector(7 downto 0);
  signal spad_w_en   : std_logic;

  signal start_compute_ws, start_compute_os : std_logic;
  signal array_busy, array_done : std_logic := '0';
  signal soft_reset : std_logic;

  signal dbg_row : natural range 0 to ARRAY_ROWS - 1;
  signal dbg_col : natural range 0 to ARRAY_COLS - 1;
  signal dbg_weight : data_t := to_signed(0, DATA_WIDTH);
  signal dbg_accum  : acc_t := to_signed(0, ACC_WIDTH);

  signal sim_done : boolean := false;
  signal errors   : natural := 0;
begin

  rx : entity work.uart_rx
    generic map (CLK_FREQ_HZ => CLK_FREQ_HZ, BAUD_RATE => BAUD_RATE)
    port map (clk => clk, rst => rst, rx => host_to_dev,
              data_out => rx_data_out, data_valid => rx_data_valid);

  rx_fifo : entity work.sync_fifo
    generic map (WIDTH => 8, DEPTH => 32)
    port map (clk => clk, rst => rst,
              wr_en => rxf_wr_en, wr_data => rxf_wr_data, full => rxf_full,
              rd_en => rxf_rd_en, rd_data => rxf_rd_data, empty => rxf_empty);
  rxf_wr_en <= rx_data_valid;
  rxf_wr_data <= rx_data_out;

  tx_fifo : entity work.sync_fifo
    generic map (WIDTH => 8, DEPTH => 256)
    port map (clk => clk, rst => rst,
              wr_en => txf_wr_en, wr_data => txf_wr_data, full => txf_full,
              rd_en => txf_rd_en, rd_data => txf_rd_data, empty => txf_empty);

  tx : entity work.uart_tx
    generic map (CLK_FREQ_HZ => CLK_FREQ_HZ, BAUD_RATE => BAUD_RATE)
    port map (clk => clk, rst => rst,
              data_in => tx_data_in, tx_start => tx_start, busy => tx_busy,
              tx => dev_to_host);

  -- tx_fifo -> uart_tx drain: a 2-cycle fetch-then-start sequence.
  -- txf_rd_data is a *registered* FIFO read (valid one cycle after
  -- txf_rd_en), so tx_start/tx_data_in can't be driven combinationally
  -- from the same cycle as txf_rd_en -- uart_tx would latch stale data
  -- (confirmed empirically: PONG never left the device with the naive
  -- combinational version). top.vhd needs this same 2-cycle pattern.
  tx_drain : process (clk)
    type drain_state_t is (D_IDLE, D_ISSUED, D_SETTLE, D_COOLDOWN);
    variable dstate       : drain_state_t := D_IDLE;
    variable cooldown_cnt : natural range 0 to 15 := 0;
  begin
    if rising_edge(clk) then
      txf_rd_en <= '0';
      tx_start <= '0';
      if rst = '1' then
        dstate := D_IDLE;
      else
        case dstate is
          when D_IDLE =>
            if txf_empty = '0' and tx_busy = '0' then
              txf_rd_en <= '1';
              dstate := D_ISSUED;
            end if;
          when D_ISSUED =>
            -- txf_rd_data isn't valid yet: sync_fifo's own registered
            -- read only lands the cycle *after* it saw rd_en (which
            -- itself only became visible to sync_fifo the cycle after
            -- we asserted it) -- same 2-cycle round trip as
            -- cmd_processor's rx path, missed here the same way.
            dstate := D_SETTLE;
          when D_SETTLE =>
            tx_data_in <= txf_rd_data;
            tx_start <= '1';
            cooldown_cnt := 10; -- generous margin (this is TB glue, not
                                 -- synthesized RTL); a single cycle was
                                 -- not always enough for tx_busy to have
                                 -- settled by the time D_IDLE re-checked
                                 -- it, confirmed empirically (an early
                                 -- re-check silently discarded a FIFO
                                 -- entry, shifting later payload bytes).
            dstate := D_COOLDOWN;
          when D_COOLDOWN =>
            if cooldown_cnt = 0 then
              dstate := D_IDLE;
            else
              cooldown_cnt := cooldown_cnt - 1;
            end if;
        end case;
      end if;
    end if;
  end process;

  cmdp : entity work.cmd_processor
    port map (
      clk => clk, rst => rst,
      rx_rd_en => rxf_rd_en, rx_rd_data => rxf_rd_data, rx_empty => rxf_empty,
      tx_wr_en => txf_wr_en, tx_wr_data => txf_wr_data, tx_full => txf_full,
      host_w_addr => host_w_addr, host_w_data => host_w_data, host_w_en => host_w_en,
      host_r_addr => host_r_addr, host_r_data => host_r_data,
      start_compute_ws => start_compute_ws, start_compute_os => start_compute_os,
      array_busy => array_busy, array_done => array_done, soft_reset => soft_reset,
      dbg_row => dbg_row, dbg_col => dbg_col, dbg_weight => dbg_weight, dbg_accum => dbg_accum
    );

  spad_w_addr <= poke_addr when poke_en = '1' else host_w_addr;
  spad_w_data <= poke_data when poke_en = '1' else host_w_data;
  spad_w_en   <= poke_en or host_w_en;

  spad : entity work.scratchpad
    port map (
      clk => clk,
      w_addr => spad_w_addr, w_data => spad_w_data, w_en => spad_w_en,
      r_addr => host_r_addr, r_data => host_r_data
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

    procedure check_eq(actual, expected : natural; msg : string) is
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
  begin
    rst <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait for 200 ns;

    ------------------------------------------------------------------
    -- PING -> PONG
    ------------------------------------------------------------------
    uart_bfm_send_frame(host_to_dev, BIT_PERIOD, to_integer(unsigned(OP_PING)), byte_array_t'(0 to -1 => 0));
    uart_bfm_recv_frame(dev_to_host, BIT_PERIOD, rx_opcode, rx_len, rx_payload, rx_ok);
    check_true(rx_ok, "PING: response CRC ok");
    check_eq(rx_opcode, to_integer(unsigned(OP_PONG)), "PING: opcode is PONG");
    check_eq(rx_len, 4, "PING: len=4");
    check_eq(rx_payload(1), ARRAY_ROWS, "PING: rows=6");
    check_eq(rx_payload(2), ARRAY_COLS, "PING: cols=6");
    check_eq(rx_payload(3), 0, "PING: dtype=0 (int8x8->int32)");

    ------------------------------------------------------------------
    -- STATUS_QUERY while idle
    ------------------------------------------------------------------
    array_busy <= '0'; array_done <= '0';
    wait for 50 ns;
    uart_bfm_send_frame(host_to_dev, BIT_PERIOD, to_integer(unsigned(OP_STATUS_QUERY)), byte_array_t'(0 to -1 => 0));
    uart_bfm_recv_frame(dev_to_host, BIT_PERIOD, rx_opcode, rx_len, rx_payload, rx_ok);
    check_true(rx_ok, "STATUS(idle): CRC ok");
    check_eq(rx_opcode, to_integer(unsigned(OP_STATUS_DATA)), "STATUS(idle): opcode");
    check_eq(rx_payload(0), 0, "STATUS(idle): busy=0,done=0");

    ------------------------------------------------------------------
    -- WRITE_WEIGHTS: monitor host_w_* pulses directly.
    ------------------------------------------------------------------
    wait for 50 ns;
    uart_bfm_send_frame(host_to_dev, BIT_PERIOD, to_integer(unsigned(OP_WRITE_WEIGHTS)), byte_array_t'(0, 0, 11, 22, 33));
    uart_bfm_recv_frame(dev_to_host, BIT_PERIOD, rx_opcode, rx_len, rx_payload, rx_ok);
    check_true(rx_ok, "WRITE_WEIGHTS: CRC ok");
    check_eq(rx_opcode, to_integer(unsigned(OP_ACK)), "WRITE_WEIGHTS: ACK");

    ------------------------------------------------------------------
    -- WRITE_WEIGHTS while busy -> NACK(BUSY)
    ------------------------------------------------------------------
    array_busy <= '1';
    wait for 50 ns;
    uart_bfm_send_frame(host_to_dev, BIT_PERIOD, to_integer(unsigned(OP_WRITE_WEIGHTS)), byte_array_t'(0, 0, 99));
    uart_bfm_recv_frame(dev_to_host, BIT_PERIOD, rx_opcode, rx_len, rx_payload, rx_ok);
    check_true(rx_ok, "WRITE_WEIGHTS(busy): CRC ok");
    check_eq(rx_opcode, to_integer(unsigned(OP_NACK)), "WRITE_WEIGHTS(busy): NACK");
    check_eq(rx_payload(0), to_integer(unsigned(ERR_BUSY)), "WRITE_WEIGHTS(busy): ERR_BUSY");

    ------------------------------------------------------------------
    -- DEBUG_READ_PE works even while busy.
    ------------------------------------------------------------------
    dbg_weight <= to_signed(7, DATA_WIDTH);
    dbg_accum <= to_signed(1234, ACC_WIDTH);
    wait for 50 ns;
    uart_bfm_send_frame(host_to_dev, BIT_PERIOD, to_integer(unsigned(OP_DEBUG_READ_PE)), byte_array_t'(2, 3));
    uart_bfm_recv_frame(dev_to_host, BIT_PERIOD, rx_opcode, rx_len, rx_payload, rx_ok);
    check_true(rx_ok, "DEBUG_READ_PE(busy): CRC ok");
    check_eq(rx_opcode, to_integer(unsigned(OP_DEBUG_DATA)), "DEBUG_READ_PE(busy): opcode (allowed while busy)");
    check_eq(rx_payload(0), 2, "DEBUG_READ_PE: row echo");
    check_eq(rx_payload(1), 3, "DEBUG_READ_PE: col echo");
    check_eq(rx_payload(2), 7, "DEBUG_READ_PE: weight");
    check_eq(rx_payload(3) + rx_payload(4) * 256, 1234, "DEBUG_READ_PE: accum (low 16 bits)");

    array_busy <= '0';

    ------------------------------------------------------------------
    -- READ_RESULT: pre-load RESULT region via TB poke, then read back.
    ------------------------------------------------------------------
    poke_en <= '1';
    for i in 0 to 7 loop
      poke_addr <= to_unsigned(RESULT_BASE + i, ADDR_WIDTH);
      poke_data <= std_logic_vector(to_unsigned(i * 3 + 1, 8));
      wait until rising_edge(clk);
    end loop;
    poke_en <= '0';
    wait for 50 ns;

    uart_bfm_send_frame(host_to_dev, BIT_PERIOD, to_integer(unsigned(OP_READ_RESULT)), byte_array_t'(0, 0, 8));
    uart_bfm_recv_frame(dev_to_host, BIT_PERIOD, rx_opcode, rx_len, rx_payload, rx_ok);
    check_true(rx_ok, "READ_RESULT: CRC ok");
    check_eq(rx_opcode, to_integer(unsigned(OP_RESULT_DATA)), "READ_RESULT: opcode");
    check_eq(rx_len, 11, "READ_RESULT: len = 3+8");
    check_eq(rx_payload(0), 0, "READ_RESULT: offset lo echo");
    check_eq(rx_payload(1), 0, "READ_RESULT: offset hi echo");
    check_eq(rx_payload(2), 8, "READ_RESULT: len echo");
    for i in 0 to 7 loop
      check_eq(rx_payload(3 + i), i * 3 + 1, "READ_RESULT: data byte " & integer'image(i));
    end loop;

    ------------------------------------------------------------------
    -- Bad CRC -> NACK(CRC_FAIL)
    ------------------------------------------------------------------
    wait for 50 ns;
    uart_bfm_send_byte(host_to_dev, BIT_PERIOD, BFM_SYNC_BYTE);
    uart_bfm_send_byte(host_to_dev, BIT_PERIOD, to_integer(unsigned(OP_PING)));
    uart_bfm_send_byte(host_to_dev, BIT_PERIOD, 0);
    uart_bfm_send_byte(host_to_dev, BIT_PERIOD, 16#FF#); -- wrong CRC
    uart_bfm_recv_frame(dev_to_host, BIT_PERIOD, rx_opcode, rx_len, rx_payload, rx_ok);
    check_true(rx_ok, "bad CRC: NACK response itself has valid CRC");
    check_eq(rx_opcode, to_integer(unsigned(OP_NACK)), "bad CRC: NACK");
    check_eq(rx_payload(0), to_integer(unsigned(ERR_CRC_FAIL)), "bad CRC: ERR_CRC_FAIL");

    ------------------------------------------------------------------
    -- Unknown opcode -> NACK(BAD_OPCODE)
    ------------------------------------------------------------------
    wait for 50 ns;
    uart_bfm_send_frame(host_to_dev, BIT_PERIOD, 16#7F#, byte_array_t'(0 to -1 => 0));
    uart_bfm_recv_frame(dev_to_host, BIT_PERIOD, rx_opcode, rx_len, rx_payload, rx_ok);
    check_true(rx_ok, "bad opcode: response CRC ok");
    check_eq(rx_opcode, to_integer(unsigned(OP_NACK)), "bad opcode: NACK");
    check_eq(rx_payload(0), to_integer(unsigned(ERR_BAD_OPCODE)), "bad opcode: ERR_BAD_OPCODE");

    ------------------------------------------------------------------
    errors <= errcnt;
    wait for 100 ns;
    report "tb_cmd_processor: " & integer'image(errcnt) & " error(s)";
    if errcnt > 0 then
      report "tb_cmd_processor FAILED" severity failure;
    else
      report "tb_cmd_processor PASSED" severity note;
    end if;
    sim_done <= true;
    wait;
  end process;

end architecture sim;
