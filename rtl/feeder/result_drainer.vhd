library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pkg_types.all;
use work.pkg_memmap.all;

-- Captures psum_south into a local 36x32-bit register file during both
-- PE_COMPUTE_WS (rolling diagonal outputs, C(m,c) captured when valid)
-- and PE_DRAIN_OS (columnar shift-out, one row per cycle), then exposes
-- a byte-addressable read mux (wb_idx 0..143, little-endian per int32)
-- for array_ctrl's WRITEBACK burst to the scratchpad. Capture timing
-- mirrors the empirically-validated formulas in array_ctrl.vhd; see
-- sim/tb_result_drainer.vhd for the integrated cross-check.
entity result_drainer is
  port (
    clk : in std_logic;

    mode        : in pe_mode_t;
    phase_cycle : in phase_cycle_t;
    psum_south  : in psum_vec_t;

    wb_idx  : in natural range 0 to RESULT_BYTES - 1;
    wb_data : out std_logic_vector(7 downto 0)
  );
end entity result_drainer;

architecture rtl of result_drainer is
  type result_reg_t is array (0 to ARRAY_ROWS * ARRAY_COLS - 1) of acc_t;
  signal results : result_reg_t := (others => (others => '0'));
begin

  capture_proc : process (clk)
    variable m        : integer;
    variable elem_idx : integer;
  begin
    if rising_edge(clk) then
      case mode is
        when PE_COMPUTE_WS =>
          -- Note: this clocked process reads phase_cycle/psum_south at
          -- the same edge that array_ctrl advances phase_cycle, so both
          -- values are one cycle "behind" what a post-edge testbench
          -- check (as in tb_array_ctrl) would observe -- hence no "+1"
          -- here, unlike the m=g-ROWS-c+1 formula used there (confirmed
          -- empirically: with "+1" every row landed one slot too low,
          -- row 0 stayed all-zero).
          for c in 0 to ARRAY_COLS - 1 loop
            m := phase_cycle - ARRAY_ROWS - c;
            if m >= 0 and m <= ARRAY_ROWS - 1 then
              results(m * ARRAY_COLS + c) <= psum_south(c);
            end if;
          end loop;

        when PE_DRAIN_OS =>
          if phase_cycle <= ARRAY_ROWS - 1 then
            elem_idx := (ARRAY_ROWS - 1 - phase_cycle) * ARRAY_COLS;
            for c in 0 to ARRAY_COLS - 1 loop
              results(elem_idx + c) <= psum_south(c);
            end loop;
          end if;

        when others =>
          null;
      end case;
    end if;
  end process;

  byte_mux : process (wb_idx, results)
    variable elem     : integer;
    variable byte_sel : integer;
    variable val      : acc_t;
  begin
    elem := wb_idx / 4;
    byte_sel := wb_idx mod 4;
    val := results(elem);
    case byte_sel is
      when 0 => wb_data <= std_logic_vector(val(7 downto 0));
      when 1 => wb_data <= std_logic_vector(val(15 downto 8));
      when 2 => wb_data <= std_logic_vector(val(23 downto 16));
      when others => wb_data <= std_logic_vector(val(31 downto 24));
    end case;
  end process;

end architecture rtl;
