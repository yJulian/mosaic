library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pkg_types.all;
use work.pkg_memmap.all;

-- Top-level integration for the Tang Nano 9K. Wires together:
--   clk_reset_gen -> synchronous internal reset
--   uart_rx/uart_tx + rx_fifo/tx_fifo -> byte-stream link to cmd_processor
--   cmd_processor  -> protocol parsing/dispatch, host-facing control
--   array_ctrl     -> compute sequencer (stage/load/compute/drain/writeback)
--   systolic_array -> the 6x6 PE grid
--   ws_weight_loader / skew_feeder / result_drainer -> staging datapath
--   scratchpad     -> single BSRAM instance, port-muxed between
--                      cmd_processor (host, while idle) and array_ctrl's
--                      stage/writeback paths (while busy)
entity top is
  generic (
    CLK_FREQ_HZ : natural := 27_000_000;
    BAUD_RATE   : natural := 1_500_000
  );
  port (
    clk       : in std_logic;
    rst_btn_n : in std_logic;

    uart_rx_pin : in std_logic;
    uart_tx_pin : out std_logic;

    -- Status LEDs, active-low (Tang Nano 9K convention -- verify
    -- against the real board during bring-up per docs/bringup.md).
    led_n : out std_logic_vector(5 downto 0)
  );
end entity top;

architecture rtl of top is
  signal rst : std_logic;

  -- UART <-> FIFOs
  signal rx_data_out   : std_logic_vector(7 downto 0);
  signal rx_data_valid : std_logic;
  signal tx_data_in    : std_logic_vector(7 downto 0) := (others => '0');
  signal tx_start      : std_logic := '0';
  signal tx_busy       : std_logic;

  signal rxf_wr_en, rxf_full, rxf_rd_en, rxf_empty : std_logic;
  signal rxf_wr_data, rxf_rd_data                   : std_logic_vector(7 downto 0);
  signal txf_wr_en, txf_full, txf_rd_en, txf_empty  : std_logic;
  signal txf_wr_data, txf_rd_data                    : std_logic_vector(7 downto 0);

  -- cmd_processor <-> scratchpad (host side)
  signal host_w_addr : unsigned(ADDR_WIDTH - 1 downto 0);
  signal host_w_data : std_logic_vector(7 downto 0);
  signal host_w_en   : std_logic;
  signal host_r_addr : unsigned(ADDR_WIDTH - 1 downto 0);
  signal host_r_data : std_logic_vector(7 downto 0);

  -- cmd_processor <-> array_ctrl
  signal start_compute_ws, start_compute_os : std_logic;
  signal array_busy, array_done             : std_logic;
  signal soft_reset                          : std_logic;
  signal array_rst                           : std_logic;

  -- cmd_processor <-> systolic_array (debug)
  signal dbg_row    : natural range 0 to ARRAY_ROWS - 1;
  signal dbg_col    : natural range 0 to ARRAY_COLS - 1;
  signal dbg_weight : data_t;
  signal dbg_accum  : acc_t;

  -- array_ctrl <-> systolic_array
  signal mode         : pe_mode_t;
  signal os_clear     : std_logic;
  signal load_counter : natural range 0 to 2 * ARRAY_ROWS;
  signal phase_cycle  : natural range 0 to 31;

  -- array_ctrl <-> scratchpad (stage/writeback side)
  signal stage_addr : unsigned(ADDR_WIDTH - 1 downto 0);
  signal stage_data  : std_logic_vector(7 downto 0);
  signal stage_w_wen : std_logic;
  signal stage_w_idx : natural range 0 to WEIGHT_BYTES - 1;
  signal stage_a_wen : std_logic;
  signal stage_a_idx : natural range 0 to ACT_BYTES - 1;
  signal wb_addr      : unsigned(ADDR_WIDTH - 1 downto 0);
  signal wb_idx        : natural range 0 to RESULT_BYTES - 1;
  signal wb_wen         : std_logic;
  signal wb_data          : std_logic_vector(7 downto 0);

  -- scratchpad physical port (muxed)
  signal spad_w_addr : unsigned(ADDR_WIDTH - 1 downto 0);
  signal spad_w_data : std_logic_vector(7 downto 0);
  signal spad_w_en   : std_logic;
  signal spad_r_addr : unsigned(ADDR_WIDTH - 1 downto 0);
  signal spad_r_data : std_logic_vector(7 downto 0);

  -- systolic_array datapath
  signal act_west   : act_vec_t;
  signal wgt_north  : wgt_vec_t;
  signal psum_north : psum_vec_t := (others => (others => '0'));
  signal act_east   : act_vec_t;
  signal wgt_south  : wgt_vec_t;
  signal psum_south : psum_vec_t;

  -- simple bring-up heartbeat
  signal heartbeat_ctr : unsigned(23 downto 0) := (others => '0');
begin

  ------------------------------------------------------------------
  -- Reset
  ------------------------------------------------------------------
  reset_gen : entity work.clk_reset_gen
    port map (clk => clk, rst_btn_n => rst_btn_n, rst => rst);

  array_rst <= rst or soft_reset;

  ------------------------------------------------------------------
  -- UART + FIFOs
  ------------------------------------------------------------------
  rx : entity work.uart_rx
    generic map (CLK_FREQ_HZ => CLK_FREQ_HZ, BAUD_RATE => BAUD_RATE)
    port map (
      clk => clk, rst => rst,
      rx => uart_rx_pin,
      data_out => rx_data_out, data_valid => rx_data_valid
    );

  rxf_wr_en <= rx_data_valid;
  rxf_wr_data <= rx_data_out;

  rx_fifo : entity work.sync_fifo
    generic map (WIDTH => 8, DEPTH => 64)
    port map (
      clk => clk, rst => rst,
      wr_en => rxf_wr_en, wr_data => rxf_wr_data, full => rxf_full,
      rd_en => rxf_rd_en, rd_data => rxf_rd_data, empty => rxf_empty
    );

  tx_fifo : entity work.sync_fifo
    generic map (WIDTH => 8, DEPTH => 256)
    port map (
      clk => clk, rst => rst,
      wr_en => txf_wr_en, wr_data => txf_wr_data, full => txf_full,
      rd_en => txf_rd_en, rd_data => txf_rd_data, empty => txf_empty
    );

  tx : entity work.uart_tx
    generic map (CLK_FREQ_HZ => CLK_FREQ_HZ, BAUD_RATE => BAUD_RATE)
    port map (
      clk => clk, rst => rst,
      data_in => tx_data_in, tx_start => tx_start, busy => tx_busy,
      tx => uart_tx_pin
    );

  -- tx_fifo -> uart_tx drain. txf_rd_data is a registered FIFO read (one
  -- cycle after txf_rd_en); uart_tx's own tx_busy is combinational off a
  -- registered state transition it makes one cycle after seeing
  -- tx_start -- so D_COOLDOWN is required, not just D_ISSUED/D_SETTLE,
  -- or D_IDLE re-checks a still-stale tx_busy and issues a premature
  -- second read (see sim/tb_cmd_processor.vhd's tx_drain for the
  -- empirical trace that first exposed this).
  tx_drain : process (clk)
    type drain_state_t is (D_IDLE, D_ISSUED, D_SETTLE, D_COOLDOWN);
    variable dstate : drain_state_t := D_IDLE;
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
            dstate := D_SETTLE;
          when D_SETTLE =>
            tx_data_in <= txf_rd_data;
            tx_start <= '1';
            dstate := D_COOLDOWN;
          when D_COOLDOWN =>
            dstate := D_IDLE;
        end case;
      end if;
    end if;
  end process;

  ------------------------------------------------------------------
  -- cmd_processor
  ------------------------------------------------------------------
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

  ------------------------------------------------------------------
  -- Compute core
  ------------------------------------------------------------------
  actrl : entity work.array_ctrl
    port map (
      clk => clk, rst => array_rst,
      start_compute_ws => start_compute_ws, start_compute_os => start_compute_os,
      busy => array_busy, done => array_done,
      mode => mode, os_clear => os_clear, load_counter => load_counter, phase_cycle => phase_cycle,
      stage_addr => stage_addr, stage_data => stage_data,
      stage_w_wen => stage_w_wen, stage_w_idx => stage_w_idx,
      stage_a_wen => stage_a_wen, stage_a_idx => stage_a_idx,
      wb_addr => wb_addr, wb_idx => wb_idx, wb_wen => wb_wen
    );

  arr : entity work.systolic_array
    port map (
      clk => clk, rst => array_rst,
      mode => mode, os_clear => os_clear, load_counter => load_counter,
      act_west => act_west, wgt_north => wgt_north, psum_north => psum_north,
      act_east => act_east, wgt_south => wgt_south, psum_south => psum_south,
      debug_weight => dbg_weight, debug_accum => dbg_accum,
      debug_row => dbg_row, debug_col => dbg_col
    );

  wload : entity work.ws_weight_loader
    port map (
      clk => clk,
      stage_wen => stage_w_wen, stage_idx => stage_w_idx, stage_data => stage_data,
      mode => mode, phase_cycle => phase_cycle,
      wgt_north => wgt_north
    );

  afeed : entity work.skew_feeder
    port map (
      clk => clk,
      stage_wen => stage_a_wen, stage_idx => stage_a_idx, stage_data => stage_data,
      mode => mode, phase_cycle => phase_cycle,
      act_west => act_west
    );

  drainer : entity work.result_drainer
    port map (
      clk => clk,
      mode => mode, phase_cycle => phase_cycle, psum_south => psum_south,
      wb_idx => wb_idx, wb_data => wb_data
    );

  ------------------------------------------------------------------
  -- Scratchpad: single BSRAM instance, port-muxed between the host
  -- (cmd_processor, while idle) and the internal stage/writeback path
  -- (array_ctrl + result_drainer, while busy) -- the two are always
  -- time-disjoint since cmd_processor NACKs host writes/reads with
  -- ERR_BUSY while array_busy='1'.
  ------------------------------------------------------------------
  spad_r_addr <= stage_addr when array_busy = '1' else host_r_addr;
  spad_w_addr <= wb_addr when array_busy = '1' else host_w_addr;
  spad_w_data <= wb_data when array_busy = '1' else host_w_data;
  spad_w_en   <= wb_wen when array_busy = '1' else host_w_en;
  stage_data  <= spad_r_data;
  host_r_data <= spad_r_data;

  spad : entity work.scratchpad
    port map (
      clk => clk,
      w_addr => spad_w_addr, w_data => spad_w_data, w_en => spad_w_en,
      r_addr => spad_r_addr, r_data => spad_r_data
    );

  ------------------------------------------------------------------
  -- Status LEDs (active-low; see docs/bringup.md)
  ------------------------------------------------------------------
  process (clk)
  begin
    if rising_edge(clk) then
      heartbeat_ctr <= heartbeat_ctr + 1;
    end if;
  end process;

  led_n <= not (
    heartbeat_ctr(23) &   -- led0: ~1.6Hz heartbeat, proves the FPGA is alive
    array_busy &          -- led1: compute in progress
    array_done &          -- led2: result ready
    "000"                 -- led3..5: reserved
  );

end architecture rtl;
