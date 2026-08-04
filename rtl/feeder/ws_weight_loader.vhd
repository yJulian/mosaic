library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pkg_types.all;
use work.pkg_memmap.all;

-- Owns the 36-byte staged weight register file (row-major W[r][c] at
-- index r*ARRAY_COLS+c) and drives wgt_north during both PE_LOAD_WEIGHT
-- (row-broadcast, one row of W per cycle to all columns) and
-- PE_COMPUTE_OS (column-skewed streaming). Pure datapath: no own FSM,
-- driven entirely by array_ctrl's mode/phase_cycle and stage_* pulses.
entity ws_weight_loader is
  port (
    clk : in std_logic;

    stage_wen  : in std_logic;
    stage_idx  : in natural range 0 to WEIGHT_BYTES - 1;
    stage_data : in std_logic_vector(7 downto 0);

    mode        : in pe_mode_t;
    phase_cycle : in natural range 0 to 31;

    wgt_north : out wgt_vec_t
  );
end entity ws_weight_loader;

architecture rtl of ws_weight_loader is
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
    wgt_north <= (others => (others => '0'));
    case mode is
      when PE_LOAD_WEIGHT =>
        if phase_cycle <= ARRAY_ROWS - 1 then
          for c in 0 to ARRAY_COLS - 1 loop
            wgt_north(c) <= regs(phase_cycle * ARRAY_COLS + c);
          end loop;
        end if;

      when PE_COMPUTE_OS =>
        if phase_cycle >= 1 then
          g := phase_cycle - 1;
          for j in 0 to ARRAY_COLS - 1 loop
            if g - j >= 0 and g - j <= ARRAY_ROWS - 1 then
              wgt_north(j) <= regs((g - j) * ARRAY_COLS + j);
            end if;
          end loop;
        end if;

      when others =>
        null;
    end case;
  end process;

end architecture rtl;
