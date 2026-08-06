library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pkg_types.all;
use work.pkg_memmap.all;
use work.pkg_protocol.all;

-- Framed UART protocol parser/dispatcher (docs/protocol.md is the
-- authoritative spec, mirrored in pkg_protocol.vhd and
-- python/fpga_systolic/protocol.py). Talks to rx_fifo/tx_fifo (byte
-- streams, not directly to uart_rx/uart_tx -- see top.vhd for that
-- glue), the scratchpad's host-side port, array_ctrl's start/busy/done,
-- and systolic_array's debug readback port.
--
-- WRITE_WEIGHTS/WRITE_ACTIVATIONS stream straight into the scratchpad
-- byte-by-byte as they arrive; READ_RESULT streams straight out the
-- same way -- no local payload buffering needed for either. Every
-- byte-consuming state follows the same two-phase pattern: a _WAIT state
-- pulses rx_rd_en once the FIFO is non-empty, and the following
-- _CAPTURE state processes rx_rd_data (valid one cycle after rd_en,
-- matching sync_fifo's registered-read convention).
--
-- DEBUG_READ_PE, STATUS_QUERY, PING and RESET are always accepted even
-- while the array is busy (they're read-only / soft-control); WRITE_*,
-- START_COMPUTE and READ_RESULT are NACKed with ERR_BUSY while busy,
-- since the scratchpad's ports belong to the internal stage/writeback
-- path during that time (see top.vhd's port mux).
entity cmd_processor is
  port (
    clk : in std_logic;
    rst : in std_logic;

    rx_rd_en   : out std_logic;
    rx_rd_data : in std_logic_vector(7 downto 0);
    rx_empty   : in std_logic;

    tx_wr_en   : out std_logic;
    tx_wr_data : out std_logic_vector(7 downto 0);
    tx_full    : in std_logic;

    host_w_addr : out unsigned(ADDR_WIDTH - 1 downto 0);
    host_w_data : out std_logic_vector(7 downto 0);
    host_w_en   : out std_logic;
    host_r_addr : out unsigned(ADDR_WIDTH - 1 downto 0);
    host_r_data : in std_logic_vector(7 downto 0);
    -- Pulses for one cycle whenever a scratchpad read address is issued
    -- for OP_READ_RESULT data (debug/LED use only, see top.vhd).
    host_r_en   : out std_logic;

    start_compute_ws : out std_logic;
    start_compute_os : out std_logic;
    -- START_COMPUTE's K field (OS mode's contraction length), range-
    -- validated below before start_compute_os is ever pulsed -- see
    -- rtl/array/array_ctrl.vhd for why it's safe for that entity to
    -- convert this straight to a constrained natural at the moment it
    -- latches. Ignored by WS (always behaves as K=ARRAY_ROWS).
    k_len_raw        : out unsigned(15 downto 0);
    array_busy       : in std_logic;
    array_done       : in std_logic;
    soft_reset       : out std_logic;

    dbg_row    : out natural range 0 to ARRAY_ROWS - 1;
    dbg_col    : out natural range 0 to ARRAY_COLS - 1;
    dbg_weight : in data_t;
    dbg_accum  : in acc_t
  );
end entity cmd_processor;

architecture rtl of cmd_processor is
  type state_t is (
    S_SYNC_WAIT, S_BYTE_SETTLE, S_SYNC_CAPTURE,
    S_OPCODE_WAIT, S_OPCODE_CAPTURE,
    S_LEN_WAIT, S_LEN_CAPTURE,
    S_PAYLOAD_WAIT, S_PAYLOAD_CAPTURE,
    S_CRC_WAIT, S_CRC_CAPTURE,
    S_DISPATCH,
    S_RESP_SYNC, S_RESP_OPCODE, S_RESP_LEN,
    S_RESULT_ADDR_SETTLE, S_RESP_PAYLOAD,
    S_RESP_CRC_SETTLE, S_RESP_CRC
  );
  signal state : state_t := S_SYNC_WAIT;
  -- Where to resume after S_BYTE_SETTLE. Needed because rx_rd_en is a
  -- *registered* output: sync_fifo doesn't see it until the cycle after
  -- it's decided, and its rd_data isn't valid until the cycle after
  -- that -- a 2-cycle round trip, not the 1-cycle a plain WAIT/CAPTURE
  -- pair assumes. Confirmed empirically: without this settle state,
  -- every capture silently read the *previous* byte's value (the very
  -- first SYNC byte read back as all-undefined, having nothing to lag
  -- into). All byte-consuming _WAIT states route through here now.
  signal after_settle_state : state_t := S_SYNC_CAPTURE;

  signal opcode      : std_logic_vector(7 downto 0) := (others => '0');
  signal req_len     : natural range 0 to 255 := 0;
  signal payload_idx : natural range 0 to 255 := 0; -- 0-based index of NEXT payload byte to capture

  signal offset_lo    : std_logic_vector(7 downto 0) := (others => '0');
  signal req_offset   : unsigned(15 downto 0) := (others => '0');
  signal result_len   : natural range 0 to RESULT_BYTES := 0;
  signal mode_byte    : std_logic_vector(7 downto 0) := (others => '0');
  signal k_lo, k_hi   : std_logic_vector(7 downto 0) := (others => '0');
  signal debug_row_b  : std_logic_vector(7 downto 0) := (others => '0');
  signal debug_col_b  : std_logic_vector(7 downto 0) := (others => '0');
  signal data_byte_cnt : unsigned(15 downto 0) := (others => '0'); -- counts DATA bytes only, for WRITE_*

  signal rx_crc_init, rx_crc_valid : std_logic := '0';
  signal rx_crc_out                : std_logic_vector(7 downto 0);

  signal tx_crc_init, tx_crc_valid : std_logic := '0';
  signal tx_crc_byte               : std_logic_vector(7 downto 0);
  signal tx_crc_out                : std_logic_vector(7 downto 0);
  -- Mux output only (payload bytes for OP_RESULT_DATA/STATUS_DATA/
  -- DEBUG_DATA/PONG). Must NOT be the same signal as tx_crc_byte: that
  -- one is also driven directly by the clocked process for the
  -- OPCODE/LEN bytes, and two drivers on one std_logic_vector signal
  -- resolve to 'X' wherever they disagree -- confirmed empirically,
  -- this exact conflict silently corrupted every PONG/STATUS/DEBUG
  -- payload byte.
  signal resp_payload_byte : std_logic_vector(7 downto 0);

  signal resp_opcode : std_logic_vector(7 downto 0) := (others => '0');
  signal resp_len    : natural range 0 to RESULT_BYTES + 3 := 0;
  signal resp_idx    : natural range 0 to RESULT_BYTES + 3 := 0;
  signal nack_err    : std_logic_vector(7 downto 0) := (others => '0');

  signal reject_busy : std_logic := '0';
  signal crc_failed  : std_logic := '0';

  function is_gated_opcode(op : std_logic_vector(7 downto 0)) return boolean is
  begin
    return op = OP_WRITE_WEIGHTS or op = OP_WRITE_ACTIVATIONS or
           op = OP_START_COMPUTE or op = OP_READ_RESULT;
  end function;
begin

  rx_crc : entity work.crc8
    port map (
      clk => clk, rst => rst,
      init => rx_crc_init, byte_in => rx_rd_data, byte_valid => rx_crc_valid,
      crc_out => rx_crc_out
    );

  tx_crc : entity work.crc8
    port map (
      clk => clk, rst => rst,
      init => tx_crc_init, byte_in => tx_crc_byte, byte_valid => tx_crc_valid,
      crc_out => tx_crc_out
    );

  -- Response payload byte generator, indexed by resp_idx (0-based within
  -- just the payload).
  process (resp_opcode, resp_idx, host_r_data, nack_err, offset_lo, req_offset,
           result_len, array_busy, array_done, debug_row_b, debug_col_b,
           dbg_weight, dbg_accum)
    variable byte : std_logic_vector(7 downto 0);
  begin
    byte := x"00";
    case resp_opcode is
      when OP_NACK =>
        byte := nack_err;
      when OP_RESULT_DATA =>
        case resp_idx is
          when 0 => byte := offset_lo;
          when 1 => byte := std_logic_vector(req_offset(15 downto 8));
          when 2 => byte := std_logic_vector(to_unsigned(result_len, 8));
          when others => byte := host_r_data;
        end case;
      when OP_STATUS_DATA =>
        byte := (0 => array_busy, 1 => array_done, others => '0');
      when OP_DEBUG_DATA =>
        case resp_idx is
          when 0 => byte := debug_row_b;
          when 1 => byte := debug_col_b;
          when 2 => byte := std_logic_vector(dbg_weight);
          when 3 => byte := std_logic_vector(dbg_accum(7 downto 0));
          when 4 => byte := std_logic_vector(dbg_accum(15 downto 8));
          when 5 => byte := std_logic_vector(dbg_accum(23 downto 16));
          when others => byte := std_logic_vector(dbg_accum(31 downto 24));
        end case;
      when OP_PONG =>
        case resp_idx is
          when 0 => byte := FW_VERSION;
          when 1 => byte := std_logic_vector(to_unsigned(ARRAY_ROWS, 8));
          when 2 => byte := std_logic_vector(to_unsigned(ARRAY_COLS, 8));
          when others => byte := DTYPE_INT8_INT32;
        end case;
      when others =>
        byte := x"00";
    end case;
    resp_payload_byte <= byte;
  end process;

  main : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state <= S_SYNC_WAIT;
        rx_rd_en <= '0';
        tx_wr_en <= '0';
        host_w_en <= '0';
        host_r_en <= '0';
        start_compute_ws <= '0';
        start_compute_os <= '0';
        soft_reset <= '0';
        rx_crc_init <= '0';
        rx_crc_valid <= '0';
        tx_crc_init <= '0';
        tx_crc_valid <= '0';
        payload_idx <= 0;
        req_len <= 0;
        data_byte_cnt <= (others => '0');
      else
        rx_rd_en <= '0';
        tx_wr_en <= '0';
        host_w_en <= '0';
        host_r_en <= '0';
        start_compute_ws <= '0';
        start_compute_os <= '0';
        soft_reset <= '0';
        rx_crc_valid <= '0';
        tx_crc_valid <= '0';
        rx_crc_init <= '0';
        tx_crc_init <= '0';

        case state is
          ----------------------------------------------------------------
          when S_SYNC_WAIT =>
            if rx_empty = '0' then
              rx_rd_en <= '1';
              state <= S_BYTE_SETTLE;
              after_settle_state <= S_SYNC_CAPTURE;
            end if;

          when S_BYTE_SETTLE =>
            state <= after_settle_state;

          when S_SYNC_CAPTURE =>
            if rx_rd_data = SYNC_BYTE then
              state <= S_OPCODE_WAIT;
              -- Reset here (a "free" cycle, no byte to feed) so
              -- S_OPCODE_CAPTURE can immediately *feed* the opcode byte
              -- instead of resetting -- CRC must cover OPCODE||LEN||
              -- PAYLOAD, and init/byte_valid can't both fire in the same
              -- crc8 cycle (confirmed empirically: PING was getting
              -- NACKed with ERR_CRC_FAIL because the opcode byte was
              -- silently dropped from the running CRC).
              rx_crc_init <= '1';
            else
              state <= S_SYNC_WAIT;
            end if;

          ----------------------------------------------------------------
          when S_OPCODE_WAIT =>
            if rx_empty = '0' then
              rx_rd_en <= '1';
              state <= S_BYTE_SETTLE;
              after_settle_state <= S_OPCODE_CAPTURE;
            end if;

          when S_OPCODE_CAPTURE =>
            opcode <= rx_rd_data;
            rx_crc_valid <= '1';
            if array_busy = '1' and is_gated_opcode(rx_rd_data) then
              reject_busy <= '1';
            else
              reject_busy <= '0';
            end if;
            state <= S_LEN_WAIT;

          ----------------------------------------------------------------
          when S_LEN_WAIT =>
            if rx_empty = '0' then
              rx_rd_en <= '1';
              state <= S_BYTE_SETTLE;
              after_settle_state <= S_LEN_CAPTURE;
            end if;

          when S_LEN_CAPTURE =>
            rx_crc_valid <= '1';
            req_len <= to_integer(unsigned(rx_rd_data));
            payload_idx <= 0;
            data_byte_cnt <= (others => '0');
            -- Defined fallback (K=ARRAY_ROWS) for any START_COMPUTE frame
            -- that doesn't carry K bytes (LEN<3) -- without this, k_lo/
            -- k_hi would silently keep whatever a *previous* frame last
            -- left them at, the same class of stale-register bug the CRC
            -- state's own comment already warns about for resp_opcode.
            k_lo <= x"06";
            k_hi <= x"00";
            if unsigned(rx_rd_data) = 0 then
              state <= S_CRC_WAIT;
            else
              state <= S_PAYLOAD_WAIT;
            end if;

          ----------------------------------------------------------------
          when S_PAYLOAD_WAIT =>
            if rx_empty = '0' then
              rx_rd_en <= '1';
              state <= S_BYTE_SETTLE;
              after_settle_state <= S_PAYLOAD_CAPTURE;
            end if;

          when S_PAYLOAD_CAPTURE =>
            rx_crc_valid <= '1';
            case opcode is
              when OP_WRITE_WEIGHTS | OP_WRITE_ACTIVATIONS =>
                case payload_idx is
                  when 0 => offset_lo <= rx_rd_data;
                  when 1 => req_offset <= unsigned(rx_rd_data & offset_lo);
                  when others =>
                    if reject_busy = '0' then
                      host_w_en <= '1';
                      host_w_data <= rx_rd_data;
                      if opcode = OP_WRITE_WEIGHTS then
                        host_w_addr <= to_unsigned(WEIGHT_BASE, ADDR_WIDTH) + req_offset + data_byte_cnt;
                      else
                        host_w_addr <= to_unsigned(ACT_BASE, ADDR_WIDTH) + req_offset + data_byte_cnt;
                      end if;
                    end if;
                    data_byte_cnt <= data_byte_cnt + 1;
                end case;
              when OP_START_COMPUTE =>
                case payload_idx is
                  when 0 => mode_byte <= rx_rd_data;
                  when 1 => k_lo <= rx_rd_data;
                  when 2 => k_hi <= rx_rd_data;
                  when others => null;
                end case;
              when OP_READ_RESULT =>
                case payload_idx is
                  when 0 => offset_lo <= rx_rd_data;
                  when 1 => req_offset <= unsigned(rx_rd_data & offset_lo);
                  when 2 => result_len <= to_integer(unsigned(rx_rd_data));
                  when others => null;
                end case;
              when OP_DEBUG_READ_PE =>
                case payload_idx is
                  when 0 => debug_row_b <= rx_rd_data;
                  when 1 => debug_col_b <= rx_rd_data;
                  when others => null;
                end case;
              when others =>
                null;
            end case;

            if payload_idx = req_len - 1 then
              state <= S_CRC_WAIT;
            else
              payload_idx <= payload_idx + 1;
              state <= S_PAYLOAD_WAIT;
            end if;

          ----------------------------------------------------------------
          when S_CRC_WAIT =>
            if rx_empty = '0' then
              rx_rd_en <= '1';
              state <= S_BYTE_SETTLE;
              after_settle_state <= S_CRC_CAPTURE;
            end if;

          when S_CRC_CAPTURE =>
            if rx_rd_data /= rx_crc_out then
              crc_failed <= '1';
              resp_opcode <= OP_NACK;
              nack_err <= ERR_CRC_FAIL;
              resp_len <= 1;
            else
              -- Must explicitly clear: resp_opcode/nack_err otherwise
              -- keep whatever a *previous* command last left them at,
              -- which S_DISPATCH would misread as "this frame's CRC
              -- failed" -- confirmed empirically (an unrelated bad-
              -- opcode frame was NACKed with the prior frame's stale
              -- ERR_CRC_FAIL instead of ERR_BAD_OPCODE).
              crc_failed <= '0';
            end if;
            state <= S_DISPATCH;

          ----------------------------------------------------------------
          when S_DISPATCH =>
            resp_idx <= 0;
            tx_crc_init <= '1';
            state <= S_RESP_SYNC;
            if crc_failed = '1' then
              null; -- already set up by S_CRC_CAPTURE
            elsif reject_busy = '1' then
              resp_opcode <= OP_NACK;
              nack_err <= ERR_BUSY;
              resp_len <= 1;
            else
              case opcode is
                when OP_WRITE_WEIGHTS | OP_WRITE_ACTIVATIONS =>
                  resp_opcode <= OP_ACK;
                  resp_len <= 0;
                when OP_START_COMPUTE =>
                  -- Validated regardless of mode (WS ignores k_len_raw
                  -- once accepted, but catching a malformed K here is
                  -- free and catches host bugs on WS calls too).
                  if unsigned(k_hi & k_lo) = 0 or unsigned(k_hi & k_lo) > to_unsigned(OS_K_MAX, 16) then
                    resp_opcode <= OP_NACK;
                    nack_err <= ERR_BAD_K;
                    resp_len <= 1;
                  else
                    resp_opcode <= OP_ACK;
                    resp_len <= 0;
                    if mode_byte = MODE_WS then
                      start_compute_ws <= '1';
                    else
                      start_compute_os <= '1';
                    end if;
                  end if;
                when OP_READ_RESULT =>
                  resp_opcode <= OP_RESULT_DATA;
                  resp_len <= 3 + result_len;
                when OP_STATUS_QUERY =>
                  resp_opcode <= OP_STATUS_DATA;
                  resp_len <= 1;
                when OP_DEBUG_READ_PE =>
                  resp_opcode <= OP_DEBUG_DATA;
                  resp_len <= 7;
                when OP_RESET =>
                  resp_opcode <= OP_ACK;
                  resp_len <= 0;
                  soft_reset <= '1';
                when OP_PING =>
                  resp_opcode <= OP_PONG;
                  resp_len <= 4;
                when others =>
                  resp_opcode <= OP_NACK;
                  nack_err <= ERR_BAD_OPCODE;
                  resp_len <= 1;
              end case;
            end if;

          ----------------------------------------------------------------
          when S_RESP_SYNC =>
            if tx_full = '0' then
              tx_wr_data <= SYNC_BYTE;
              tx_wr_en <= '1';
              state <= S_RESP_OPCODE;
            end if;

          when S_RESP_OPCODE =>
            if tx_full = '0' then
              tx_wr_data <= resp_opcode;
              tx_wr_en <= '1';
              tx_crc_byte <= resp_opcode;
              tx_crc_valid <= '1';
              state <= S_RESP_LEN;
            end if;

          when S_RESP_LEN =>
            if tx_full = '0' then
              tx_wr_data <= std_logic_vector(to_unsigned(resp_len, 8));
              tx_wr_en <= '1';
              tx_crc_byte <= std_logic_vector(to_unsigned(resp_len, 8));
              tx_crc_valid <= '1';
              if resp_len = 0 then
                state <= S_RESP_CRC_SETTLE;
              elsif resp_opcode = OP_RESULT_DATA then
                host_r_addr <= to_unsigned(RESULT_BASE, ADDR_WIDTH) + req_offset;
                host_r_en <= '1';
                state <= S_RESULT_ADDR_SETTLE;
              else
                state <= S_RESP_PAYLOAD;
              end if;
            end if;

          ----------------------------------------------------------------
          -- One extra cycle so host_r_data (registered scratchpad read)
          -- settles before S_RESP_PAYLOAD samples it for resp_idx=3
          -- (the first real DATA byte; resp_idx 0..2 are OFFSET/LEN,
          -- generated directly from registers, no scratchpad read).
          when S_RESULT_ADDR_SETTLE =>
            state <= S_RESP_PAYLOAD;

          when S_RESP_PAYLOAD =>
            if tx_full = '0' then
              tx_wr_data <= resp_payload_byte; -- combinational mux output above
              tx_crc_byte <= resp_payload_byte;
              tx_wr_en <= '1';
              tx_crc_valid <= '1';

              if resp_idx = resp_len - 1 then
                state <= S_RESP_CRC_SETTLE;
              else
                resp_idx <= resp_idx + 1;
                if resp_opcode = OP_RESULT_DATA and resp_idx >= 2 then
                  -- about to move past OFFSET/LEN or the previous DATA
                  -- byte: prefetch the next scratchpad byte.
                  host_r_addr <= to_unsigned(RESULT_BASE, ADDR_WIDTH) + req_offset +
                                  to_unsigned(resp_idx - 2, ADDR_WIDTH);
                  host_r_en <= '1';
                  state <= S_RESULT_ADDR_SETTLE;
                end if;
              end if;
            end if;

          ----------------------------------------------------------------
          -- crc8's registered update for the last fed byte (LEN, for a
          -- zero-length payload, or the final payload byte) is still
          -- propagating when that byte's state transition fires --
          -- tx_crc_out would otherwise be read one cycle stale, missing
          -- that last byte's contribution (confirmed empirically: every
          -- response's self-computed CRC came out wrong by exactly the
          -- last-byte-shaped amount).
          when S_RESP_CRC_SETTLE =>
            state <= S_RESP_CRC;

          when S_RESP_CRC =>
            if tx_full = '0' then
              tx_wr_data <= tx_crc_out;
              tx_wr_en <= '1';
              state <= S_SYNC_WAIT;
            end if;
        end case;
      end if;
    end if;
  end process;

  dbg_row <= to_integer(unsigned(debug_row_b)) mod ARRAY_ROWS;
  dbg_col <= to_integer(unsigned(debug_col_b)) mod ARRAY_COLS;

  k_len_raw <= unsigned(k_hi & k_lo);

end architecture rtl;
