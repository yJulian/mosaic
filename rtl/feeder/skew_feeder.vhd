library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pkg_types.all;
use work.pkg_memmap.all;

-- Owns the 36-byte staged activation register file (row-major A[m][k] at
-- index m*ARRAY_COLS+k) and drives act_west during both PE_COMPUTE_WS
-- (row k gets A[g-k][k], the classic weight-stationary row skew) and
-- PE_COMPUTE_OS (row i gets A[i][g-i], the classic output-stationary row
-- skew) -- both dataflows share the identical skew-by-array-row pattern,
-- just with A's two indices playing swapped roles (see
-- sim/tb_systolic_array.vhd for the derivation). Pure datapath: no own
-- FSM, driven entirely by array_ctrl's mode/phase_cycle and stage_a_*.
entity skew_feeder is
  port (
    clk : in std_logic;

    stage_wen  : in std_logic;
    stage_idx  : in natural range 0 to ACT_BYTES - 1;
    stage_data : in std_logic_vector(7 downto 0);

    mode        : in pe_mode_t;
    phase_cycle : in natural range 0 to 31;

    act_west : out act_vec_t
  );
end entity skew_feeder;

architecture rtl of skew_feeder is
  type reg_file_t is array (0 to ARRAY_ROWS * ARRAY_COLS - 1) of data_t;
  signal regs : reg_file_t := (others => (others => '0'));
begin

  stage_proc : process (clk)
  begin
    if rising_edge(clk) then
      if stage_wen = '1' then
        regs(stage_idx) <= signed(stage_data);
      end if;
    end if;
  end process;

  drive_proc : process (mode, phase_cycle, regs)
    variable g : integer;
  begin
    act_west <= (others => (others => '0'));
    case mode is
      when PE_COMPUTE_WS =>
        g := phase_cycle;
        for k in 0 to ARRAY_ROWS - 1 loop
          if g - k >= 0 and g - k <= ARRAY_ROWS - 1 then
            act_west(k) <= regs((g - k) * ARRAY_COLS + k);
          end if;
        end loop;

      when PE_COMPUTE_OS =>
        if phase_cycle >= 1 then
          g := phase_cycle - 1;
          for i in 0 to ARRAY_ROWS - 1 loop
            if g - i >= 0 and g - i <= ARRAY_ROWS - 1 then
              act_west(i) <= regs(i * ARRAY_COLS + (g - i));
            end if;
          end loop;
        end if;

      when others =>
        null;
    end case;
  end process;

end architecture rtl;
